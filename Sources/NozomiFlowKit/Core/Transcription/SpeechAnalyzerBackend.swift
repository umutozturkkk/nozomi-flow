import Foundation
import AVFAudio
import Speech

// MARK: - Unifying SpeechTranscriber.Result / DictationTranscriber.Result

/// SpeechTranscriber and DictationTranscriber are separate, parallel classes with their own
/// nominally-distinct Result types that happen to share the same shape (SpeechModuleResult
/// already supplies `isFinal`; `text` is declared separately on each concrete Result struct).
/// Conforming both to this local protocol lets the generic session below treat them uniformly.
protocol TranscriberResultLike {
    var text: AttributedString { get }
    var isFinal: Bool { get }
}
extension SpeechTranscriber.Result: TranscriberResultLike {}
extension DictationTranscriber.Result: TranscriberResultLike {}

// MARK: - Generic SpeechAnalyzer-backed session

/// Streaming session shared by SpeechTranscriber (highest quality, 30 locales) and
/// DictationTranscriber (54 locales, incl. tr_TR) -- both Sendable classes conforming to
/// SpeechModule + LocaleDependentSpeechModule with parallel-but-distinct initializers.
/// Owns the SpeechAnalyzer, the AsyncStream that feeds it, and a per-session AVAudioConverter
/// that adapts mic buffers to whatever format the analyzer requires (it never resamples on
/// its own -- every buffer handed to it must already match `targetFormat`).
final class SpeechAnalyzerSession<Module: SpeechModule & LocaleDependentSpeechModule>: TranscriptionBackendSession, @unchecked Sendable where Module.Result: TranscriberResultLike {

    var onPartial: (@Sendable (String) -> Void)?
    let engineKind: TranscriptionEngineKind
    let resolvedLocaleIdentifier: String

    private let module: Module
    private let analyzer: SpeechAnalyzer
    private let continuation: AsyncStream<AnalyzerInput>.Continuation
    private let targetFormat: AVAudioFormat

    private let lock = NSLock()
    private var converter: AVAudioConverter?
    private var converterInputFormat: AVAudioFormat?
    private var finalizedText = ""
    private var volatileText = ""
    private var torndown = false
    private var resultsTask: Task<Void, Never>?

    private init(
        module: Module,
        analyzer: SpeechAnalyzer,
        continuation: AsyncStream<AnalyzerInput>.Continuation,
        targetFormat: AVAudioFormat,
        engineKind: TranscriptionEngineKind,
        resolvedLocaleIdentifier: String
    ) {
        self.module = module
        self.analyzer = analyzer
        self.continuation = continuation
        self.targetFormat = targetFormat
        self.engineKind = engineKind
        self.resolvedLocaleIdentifier = resolvedLocaleIdentifier
    }

    /// Resolves the best compatible audio format, wires the analyzer to a fresh input
    /// stream and begins consuming results. Uses the `inputSequence:` initializer, which
    /// starts analysis immediately -- there is no separate start() call. contextualStrings
    /// are plumbed through `AnalysisContext` when non-empty.
    /// `allowAssetInstall` gates the self-heal download below. It must be false on any
    /// path that runs inside a live dictation, because installing a speech asset is an
    /// unbounded network operation and would hang the session instead of failing it.
    static func make(
        module: Module,
        engineKind: TranscriptionEngineKind,
        resolvedLocaleIdentifier: String,
        contextualStrings: [String],
        allowAssetInstall: Bool = true
    ) async throws -> SpeechAnalyzerSession<Module> {
        var resolvedFormat = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [module])
        if resolvedFormat == nil, allowAssetInstall {
            // Self-heal: the asset files may already exist system-wide while this
            // app lacks its per-app locale reservation (or a final asset piece).
            // Reserve + request once, then retry the format query.
            let locale = Locale(identifier: resolvedLocaleIdentifier)
            _ = try? await AssetInventory.reserve(locale: locale)
            if let request = try? await AssetInventory.assetInstallationRequest(supporting: [module]) {
                try? await request.downloadAndInstall()
            }
            resolvedFormat = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [module])
        }
        guard let format = resolvedFormat else {
            throw DictationError.modelUnavailable(resolvedLocaleIdentifier)
        }
        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()
        let context = AnalysisContext()
        if !contextualStrings.isEmpty {
            context.contextualStrings = [.general: contextualStrings]
        }
        let analyzer = SpeechAnalyzer(
            inputSequence: stream,
            modules: [module],
            analysisContext: context
        )
        let session = SpeechAnalyzerSession(
            module: module,
            analyzer: analyzer,
            continuation: continuation,
            targetFormat: format,
            engineKind: engineKind,
            resolvedLocaleIdentifier: resolvedLocaleIdentifier
        )
        session.startConsumingResults()
        return session
    }

    private func startConsumingResults() {
        let module = self.module
        resultsTask = Task { [weak self] in
            guard let self else { return }
            do {
                for try await result in module.results {
                    self.handle(text: String(result.text.characters), isFinal: result.isFinal)
                }
            } catch {
                Log.asr.error("speech analyzer results stream ended with error: \(error.localizedDescription)")
            }
        }
    }

    private func handle(text: String, isFinal: Bool) {
        lock.lock()
        if isFinal {
            if !text.isEmpty {
                finalizedText = finalizedText.isEmpty ? text : finalizedText + " " + text
            }
            volatileText = ""
        } else {
            volatileText = text
        }
        let combined = combinedLocked()
        lock.unlock()
        onPartial?(combined)
    }

    /// Caller must hold `lock`.
    private func combinedLocked() -> String {
        if volatileText.isEmpty { return finalizedText }
        if finalizedText.isEmpty { return volatileText }
        return finalizedText + " " + volatileText
    }

    // MARK: - TranscriptionBackendSession

    func accept(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        let done = torndown
        lock.unlock()
        guard !done else { return }
        guard let converted = convert(buffer) else { return }
        continuation.yield(AnalyzerInput(buffer: converted))
    }

    func finish() async throws -> String {
        let shouldRun: Bool = {
            lock.lock(); defer { lock.unlock() }
            guard !torndown else { return false }
            torndown = true
            return true
        }()
        guard shouldRun else { return snapshotText() }

        continuation.finish()
        try await analyzer.finalizeAndFinishThroughEndOfInput()
        await resultsTask?.value
        return snapshotText()
    }

    func cancel() {
        let shouldRun: Bool = {
            lock.lock(); defer { lock.unlock() }
            guard !torndown else { return false }
            torndown = true
            return true
        }()
        guard shouldRun else { return }
        continuation.finish()
        resultsTask?.cancel()
        let analyzer = self.analyzer
        Task { await analyzer.cancelAndFinishNow() }
    }

    func snapshotText() -> String {
        lock.lock(); defer { lock.unlock() }
        return finalizedText
    }

    // MARK: - Audio conversion (audio thread)

    /// The AVAudioConverter multi-callback gotcha: `convert(to:error:withInputFrom:)` may
    /// invoke the input block several times per call. We only ever have one buffer to give
    /// it, so a `delivered` flag makes every call after the first report `.noDataNow` --
    /// otherwise the converter hangs waiting for more input that will never come.
    private func convert(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard buffer.frameLength > 0 else { return nil }
        let inputFormat = buffer.format

        if converter == nil || !formatsMatch(converterInputFormat, inputFormat) {
            converter = AVAudioConverter(from: inputFormat, to: targetFormat)
            converterInputFormat = inputFormat
            if converter == nil {
                Log.asr.error("could not build audio converter for the current input format")
            }
        }
        guard let converter else { return nil }

        let ratio = targetFormat.sampleRate / max(inputFormat.sampleRate, 1)
        let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 32
        guard let output = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: max(capacity, 32)) else { return nil }

        var delivered = false
        var conversionError: NSError?
        let status = converter.convert(to: output, error: &conversionError) { _, inputStatus in
            if delivered {
                inputStatus.pointee = .noDataNow
                return nil
            }
            delivered = true
            inputStatus.pointee = .haveData
            return buffer
        }

        guard status != .error else {
            Log.asr.error("audio convert failed: \(conversionError?.localizedDescription ?? "unknown")")
            return nil
        }
        guard output.frameLength > 0 else { return nil }
        return output
    }

    private func formatsMatch(_ a: AVAudioFormat?, _ b: AVAudioFormat) -> Bool {
        guard let a else { return false }
        return a.sampleRate == b.sampleRate
            && a.channelCount == b.channelCount
            && a.commonFormat == b.commonFormat
            && a.isInterleaved == b.isInterleaved
    }
}
