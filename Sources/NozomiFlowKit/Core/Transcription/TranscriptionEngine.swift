import Foundation
import AVFAudio
import Speech

// MARK: - Shared backend session seam

/// Common surface every concrete backend session (SpeechAnalyzer-based or legacy SF)
/// exposes to the facade, so TranscriptionEngine can hold a single active session
/// regardless of which engine is in use.
protocol TranscriptionBackendSession: AnyObject, Sendable {
    /// Fired whenever the running transcript (finalized + volatile) changes. Not tied to
    /// any particular thread/actor -- the facade re-dispatches to main before forwarding.
    var onPartial: (@Sendable (String) -> Void)? { get set }
    var engineKind: TranscriptionEngineKind { get }
    var resolvedLocaleIdentifier: String { get }
    /// Feed one mic buffer. Must be safe to call from the audio thread.
    func accept(_ buffer: AVAudioPCMBuffer)
    /// Stop feeding, flush, and return the finalized transcript. Idempotent.
    func finish() async throws -> String
    /// Synchronous, idempotent teardown.
    func cancel()
    /// Best-effort finalized transcript accumulated so far, without waiting on anything.
    func snapshotText() -> String
    /// How long `finish()` may take before the facade gives up on it.
    var finishTimeoutSeconds: Double { get }
}

extension TranscriptionBackendSession {
    /// Generous for an on-device engine; the cloud session raises it for the round trip.
    var finishTimeoutSeconds: Double { 10 }
}

// MARK: - Pure engine-selection chain (unit-tested in isolation)

/// The decision chain behind `TranscriptionEngine.engineKind(for:)`, extracted so it can be
/// tested without touching the real Speech framework. Order: SpeechTranscriber ->
/// DictationTranscriber -> SFSpeechRecognizer -> none. Short-circuits on the first match.
enum EngineSelector {
    static func select(
        locale: Locale,
        speechTranscriberAvailable: (Locale) -> Bool,
        dictationTranscriberAvailable: (Locale) -> Bool,
        legacySFAvailable: (Locale) -> Bool
    ) -> TranscriptionEngineKind {
        if speechTranscriberAvailable(locale) { return .speechAnalyzer }
        if dictationTranscriberAvailable(locale) { return .dictation }
        if legacySFAvailable(locale) { return .legacySF }
        return .none
    }
}

// MARK: - Facade

/// Streaming speech-to-text with engine selection per locale: SpeechTranscriber (30 locales,
/// highest quality) -> DictationTranscriber (54, incl. tr_TR) -> SFSpeechRecognizer (63).
/// Holds at most one active backend session; acceptBuffer is called from the audio thread
/// and stays cheap (lock + forward) regardless of which backend is live.
final class TranscriptionEngine: TranscriptionServiceProtocol, CloudConfigurableTranscriber, @unchecked Sendable {
    var onPartial: ((String) -> Void)?

    private let sessionLock = NSLock()
    private var activeSession: (any TranscriptionBackendSession)?
    /// Guards the window where cancelSession() races an in-flight beginSession().
    private var cancelledBeforeStart = false
    private var cloudConfig = CloudTranscriptionConfig()
    /// Retained from beginSession so a cloud failure can replay into a local engine
    /// with the same dictionary boost words.
    private var lastContextualStrings: [String] = []

    /// Snapshotted from SettingsStore whenever it changes. Safe to call from any thread.
    func updateCloudConfig(_ config: CloudTranscriptionConfig) {
        sessionLock.lock(); defer { sessionLock.unlock() }
        cloudConfig = config
    }

    private var currentCloudConfig: CloudTranscriptionConfig {
        sessionLock.lock(); defer { sessionLock.unlock() }
        return cloudConfig
    }

    // MARK: - Engine selection

    func engineKind(for locale: Locale) async -> TranscriptionEngineKind {
        // Cloud is a deliberate user choice, so it short-circuits the on-device chain
        // rather than sitting anywhere inside it.
        if currentCloudConfig.isUsable { return .cloud }
        return await localEngineKind(for: locale)
    }

    /// The on-device chain alone, ignoring the cloud setting. Used both for normal
    /// selection and for the fallback when a cloud request comes back empty.
    private func localEngineKind(for locale: Locale) async -> TranscriptionEngineKind {
        async let st = SpeechTranscriber.supportedLocale(equivalentTo: locale)
        async let dt = DictationTranscriber.supportedLocale(equivalentTo: locale)
        let stMatch = await st
        let dtMatch = await dt
        let sfMatch = SFSpeechRecognizer(locale: locale) != nil
        return EngineSelector.select(
            locale: locale,
            speechTranscriberAvailable: { _ in stMatch != nil },
            dictationTranscriberAvailable: { _ in dtMatch != nil },
            legacySFAvailable: { _ in sfMatch }
        )
    }

    // MARK: - Asset / permission prepare

    func prepare(locale: Locale, progress: @escaping @Sendable (Double) -> Void) async throws {
        switch await engineKind(for: locale) {
        case .cloud:
            // Nothing to install: no model assets, no per-app locale reservation, no
            // permission beyond the microphone the app already holds.
            deliver(1.0, to: progress)
        case .speechAnalyzer:
            guard let canonical = await SpeechTranscriber.supportedLocale(equivalentTo: locale) else {
                deliver(1.0, to: progress)
                return
            }
            let transcriber = SpeechTranscriber(
                locale: canonical, transcriptionOptions: [], reportingOptions: [.volatileResults], attributeOptions: []
            )
            try await Self.ensureAssetsInstalled(for: [transcriber], locale: canonical, progress: progress)
        case .dictation:
            guard let canonical = await DictationTranscriber.supportedLocale(equivalentTo: locale) else {
                deliver(1.0, to: progress)
                return
            }
            let transcriber = DictationTranscriber(
                locale: canonical, contentHints: [], transcriptionOptions: [], reportingOptions: [.volatileResults], attributeOptions: []
            )
            try await Self.ensureAssetsInstalled(for: [transcriber], locale: canonical, progress: progress)
        case .legacySF:
            _ = await Self.requestSFAuthorizationIfNeeded()
            deliver(1.0, to: progress)
        case .none:
            deliver(1.0, to: progress)
        }
    }

    private func deliver(_ value: Double, to progress: @escaping @Sendable (Double) -> Void) {
        DispatchQueue.main.async { progress(value) }
    }

    /// Checks/installs on-device assets for the given module. Progress is polled at ~4 Hz
    /// and always forwarded on the main thread; calls progress(1.0) immediately if assets
    /// are already installed.
    private static func ensureAssetsInstalled(
        for modules: [any SpeechModule], locale: Locale, progress: @escaping @Sendable (Double) -> Void
    ) async throws {
        // Asset FILES are system-wide, but usability is gated by a PER-APP locale
        // reservation: without it, bestAvailableAudioFormat returns nil even when
        // another process already installed the files.
        do { try await AssetInventory.reserve(locale: locale) }
        catch { Log.asr.notice("locale reservation failed: \(String(describing: error))") }
        guard let request = try await AssetInventory.assetInstallationRequest(supporting: modules) else {
            DispatchQueue.main.async { progress(1.0) }
            return
        }
        let foundationProgress = request.progress
        let pollTask = Task { @MainActor in
            while !Task.isCancelled {
                progress(foundationProgress.fractionCompleted)
                if foundationProgress.isFinished { break }
                try? await Task.sleep(nanoseconds: 250_000_000)
            }
        }
        defer { pollTask.cancel() }
        try await request.downloadAndInstall()
        DispatchQueue.main.async { progress(1.0) }
    }

    private static func requestSFAuthorizationIfNeeded() async -> Bool {
        let current = SFSpeechRecognizer.authorizationStatus()
        if current == .authorized { return true }
        guard current == .notDetermined else { return false }
        return await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status == .authorized)
            }
        }
    }

    // MARK: - Session lifecycle

    func beginSession(locale: Locale, contextualStrings: [String]) async throws {
        let stale: (any TranscriptionBackendSession)? = {
            sessionLock.lock(); defer { sessionLock.unlock() }
            let previous = activeSession
            activeSession = nil
            cancelledBeforeStart = false
            return previous
        }()
        stale?.cancel() // defensive: the coordinator should always end/cancel before restarting

        let _: Void = {
            sessionLock.lock(); defer { sessionLock.unlock() }
            lastContextualStrings = contextualStrings
        }()

        let session: any TranscriptionBackendSession
        if await engineKind(for: locale) == .cloud {
            guard let cloud = CloudTranscriptionSession(config: currentCloudConfig, locale: locale) else {
                throw DictationError.modelUnavailable(L10n.string("engine.cloud"))
            }
            session = cloud
        } else {
            session = try await makeLocalSession(locale: locale, contextualStrings: contextualStrings)
        }

        session.onPartial = { [weak self] combined in
            guard let self else { return }
            DispatchQueue.main.async { self.onPartial?(combined) }
        }

        let wasCancelled: Bool = {
            sessionLock.lock(); defer { sessionLock.unlock() }
            let cancelled = cancelledBeforeStart
            if !cancelled {
                activeSession = session
            }
            return cancelled
        }()

        if wasCancelled {
            // cancelSession() raced in while we were still constructing the backend.
            session.cancel()
        }
    }

    /// Builds a session on the best available on-device engine for the locale.
    private func makeLocalSession(
        locale: Locale, contextualStrings: [String], allowAssetInstall: Bool = true
    ) async throws -> any TranscriptionBackendSession {
        switch await localEngineKind(for: locale) {
        case .speechAnalyzer:
            guard let canonical = await SpeechTranscriber.supportedLocale(equivalentTo: locale) else {
                throw DictationError.modelUnavailable(locale.identifier)
            }
            let transcriber = SpeechTranscriber(
                locale: canonical, transcriptionOptions: [], reportingOptions: [.volatileResults], attributeOptions: []
            )
            return try await SpeechAnalyzerSession.make(
                module: transcriber,
                engineKind: .speechAnalyzer,
                resolvedLocaleIdentifier: canonical.identifier,
                contextualStrings: contextualStrings,
                allowAssetInstall: allowAssetInstall
            )
        case .dictation:
            guard let canonical = await DictationTranscriber.supportedLocale(equivalentTo: locale) else {
                throw DictationError.modelUnavailable(locale.identifier)
            }
            let transcriber = DictationTranscriber(
                locale: canonical, contentHints: [], transcriptionOptions: [], reportingOptions: [.volatileResults], attributeOptions: []
            )
            return try await SpeechAnalyzerSession.make(
                module: transcriber,
                engineKind: .dictation,
                resolvedLocaleIdentifier: canonical.identifier,
                contextualStrings: contextualStrings,
                allowAssetInstall: allowAssetInstall
            )
        case .legacySF:
            guard let recognizer = SFSpeechRecognizer(locale: locale) else {
                throw DictationError.modelUnavailable(locale.identifier)
            }
            _ = await Self.requestSFAuthorizationIfNeeded()
            return LegacySFSession(
                recognizer: recognizer,
                resolvedLocaleIdentifier: recognizer.locale.identifier,
                contextualStrings: contextualStrings
            )
        case .cloud, .none:
            throw DictationError.modelUnavailable(locale.identifier)
        }
    }

    func acceptBuffer(_ buffer: AVAudioPCMBuffer) {
        sessionLock.lock()
        let session = activeSession
        sessionLock.unlock()
        session?.accept(buffer)
    }

    func endSession() async throws -> TranscriptionOutcome {
        let session: (any TranscriptionBackendSession)? = {
            sessionLock.lock(); defer { sessionLock.unlock() }
            let current = activeSession
            activeSession = nil
            return current
        }()

        guard let session else {
            throw DictationError.transcriptionFailed("no active transcription session")
        }

        let (text, timedOut) = await Self.finishWithTimeout(session)

        // A cloud session yields nothing when the request failed and also when the user
        // recorded silence. Both are worth one on-device retry: it rescues the dictation
        // when the network was the problem, and costs an idle engine spin-up when it was
        // genuinely silent.
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           let cloud = session as? CloudTranscriptionSession,
           let recovered = await replayOnDevice(cloud), !recovered.text.isEmpty {
            Log.asr.notice("cloud transcription produced nothing; recovered locally via \(recovered.engine.rawValue)")
            return recovered
        }

        if timedOut, text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw DictationError.transcriptionFailed("transcription timed out with no output")
        }
        return TranscriptionOutcome(
            text: text, localeIdentifier: session.resolvedLocaleIdentifier,
            engine: session.engineKind, audio: Self.uploadedAudio(from: session)
        )
    }

    /// The audio a cloud session uploaded, for training samples; nil for any
    /// on-device session.
    static func uploadedAudio(from session: any TranscriptionBackendSession) -> [Int16]? {
        guard let cloud = session as? CloudTranscriptionSession else { return nil }
        let samples = cloud.recordedSamples()
        return samples.isEmpty ? nil : samples
    }

    /// Feeds the audio the cloud session already captured through an on-device engine.
    /// Returns nil when no local engine covers the locale, or the replay itself fails.
    private func replayOnDevice(_ cloud: CloudTranscriptionSession) async -> TranscriptionOutcome? {
        let samples = cloud.recordedSamples()
        guard !samples.isEmpty else { return nil }

        let locale = Locale(identifier: cloud.resolvedLocaleIdentifier)
        let contextualStrings: [String] = {
            sessionLock.lock(); defer { sessionLock.unlock() }
            return lastContextualStrings
        }()

        guard let local = try? await makeLocalSession(
            locale: locale, contextualStrings: contextualStrings, allowAssetInstall: false
        ) else {
            // With cloud enabled prepare() is a no-op, so the on-device assets may never
            // have been installed. Downloading them here would hang the dictation, so the
            // cloud failure is reported instead.
            Log.asr.notice("no on-device engine ready to replay the cloud recording into")
            return nil
        }
        for buffer in CloudTranscriptionSession.buffers(from: samples) {
            local.accept(buffer)
        }
        let (text, _) = await Self.finishWithTimeout(local)
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return TranscriptionOutcome(
            text: text, localeIdentifier: local.resolvedLocaleIdentifier, engine: local.engineKind
        )
    }

    func cancelSession() {
        sessionLock.lock()
        cancelledBeforeStart = true
        let session = activeSession
        activeSession = nil
        sessionLock.unlock()
        session?.cancel()
    }

    private enum FinishRace: Sendable {
        case finished(String)
        case timedOut
    }

    /// Races finalization against the session's own timeout. On timeout, forces the
    /// backend to cancel (so it doesn't keep running unattended) and returns whatever
    /// was accumulated.
    private static func finishWithTimeout(_ session: any TranscriptionBackendSession) async -> (String, Bool) {
        let timeout = UInt64(session.finishTimeoutSeconds * 1_000_000_000)
        let result = await withTaskGroup(of: FinishRace.self) { group -> FinishRace in
            group.addTask {
                let text = (try? await session.finish()) ?? session.snapshotText()
                return .finished(text)
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: timeout)
                if !Task.isCancelled {
                    session.cancel()
                }
                return .timedOut
            }
            defer { group.cancelAll() }
            return await group.next() ?? .timedOut
        }
        switch result {
        case .finished(let text):
            return (text, false)
        case .timedOut:
            return (session.snapshotText(), true)
        }
    }
}
