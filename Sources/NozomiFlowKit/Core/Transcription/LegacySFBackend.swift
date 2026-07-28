import Foundation
import AVFAudio
import Speech

/// SFSpeechRecognizer streaming session (63 locales, last-resort fallback). Buffers are fed
/// directly via `request.append(_:)` -- SF converts internally, unlike the new Speech API.
/// SF imposes a historical ~1 minute ceiling per recognition request; this session detects
/// an unrequested final result, accumulates it, and transparently starts a fresh
/// request/task so the logical dictation session keeps going, stitching legs with a space.
final class LegacySFSession: TranscriptionBackendSession, @unchecked Sendable {

    var onPartial: (@Sendable (String) -> Void)?
    let engineKind: TranscriptionEngineKind = .legacySF
    let resolvedLocaleIdentifier: String

    private let recognizer: SFSpeechRecognizer
    /// SFSpeechRecognitionRequest caps contextual strings at 100.
    private let contextualStrings: [String]

    private let lock = NSLock()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var finalizedText = ""
    private var volatileText = ""
    /// Set once the caller asks us to stop (finish/cancel), so a subsequent final result
    /// is treated as the real end rather than SF's internal per-request ceiling.
    private var endRequested = false
    private var torndown = false
    private var finishContinuation: CheckedContinuation<String, Never>?

    init(recognizer: SFSpeechRecognizer, resolvedLocaleIdentifier: String, contextualStrings: [String]) {
        self.recognizer = recognizer
        self.resolvedLocaleIdentifier = resolvedLocaleIdentifier
        self.contextualStrings = Array(contextualStrings.prefix(100))
        beginLeg()
    }

    // MARK: - TranscriptionBackendSession

    func accept(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        let req = request
        lock.unlock()
        req?.append(buffer)
    }

    func finish() async throws -> String {
        let alreadyDone: Bool = {
            lock.lock(); defer { lock.unlock() }
            if torndown { return true }
            endRequested = true
            return false
        }()
        guard !alreadyDone else { return snapshotText() }

        return await withCheckedContinuation { (continuation: CheckedContinuation<String, Never>) in
            var resumeNow: String?
            var requestToEnd: SFSpeechAudioBufferRecognitionRequest?

            lock.lock()
            if torndown {
                resumeNow = finalizedText
            } else {
                finishContinuation = continuation
                requestToEnd = request
            }
            lock.unlock()

            if let resumeNow {
                continuation.resume(returning: resumeNow)
            } else {
                requestToEnd?.endAudio()
            }
        }
    }

    func cancel() {
        var continuationToResume: CheckedContinuation<String, Never>?
        var finalText = ""

        lock.lock()
        if !torndown {
            torndown = true
            endRequested = true
            continuationToResume = finishContinuation
            finishContinuation = nil
            finalText = finalizedText
        }
        let activeTask = task
        lock.unlock()

        activeTask?.cancel()
        continuationToResume?.resume(returning: finalText)
    }

    func snapshotText() -> String {
        lock.lock(); defer { lock.unlock() }
        return finalizedText
    }

    // MARK: - Internal

    private func beginLeg() {
        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults = true
        if !contextualStrings.isEmpty {
            req.contextualStrings = contextualStrings
        }
        if recognizer.supportsOnDeviceRecognition {
            req.requiresOnDeviceRecognition = true
        }

        lock.lock()
        request = req
        lock.unlock()

        let newTask = recognizer.recognitionTask(with: req) { [weak self] result, error in
            self?.handle(result: result, error: error)
        }
        lock.lock()
        task = newTask
        lock.unlock()
    }

    private func handle(result: SFSpeechRecognitionResult?, error: Error?) {
        if let result {
            let text = result.bestTranscription.formattedString
            if result.isFinal {
                handleFinal(text: text)
            } else {
                lock.lock()
                volatileText = text
                lock.unlock()
                emitPartial()
            }
        } else if let error {
            handleLegEnded(error: error)
        }
    }

    private func handleFinal(text: String) {
        var shouldRestart = false
        var continuationToResume: CheckedContinuation<String, Never>?
        var finalText = ""

        lock.lock()
        if !text.isEmpty {
            finalizedText = finalizedText.isEmpty ? text : finalizedText + " " + text
        }
        volatileText = ""
        if endRequested || torndown {
            torndown = true
            continuationToResume = finishContinuation
            finishContinuation = nil
            finalText = finalizedText
        } else {
            shouldRestart = true
        }
        lock.unlock()

        emitPartial()
        if shouldRestart {
            // Hit SF's internal per-request ceiling; keep the logical session going.
            beginLeg()
        } else {
            continuationToResume?.resume(returning: finalText)
        }
    }

    private func handleLegEnded(error: Error) {
        var shouldRestart = false
        var continuationToResume: CheckedContinuation<String, Never>?
        var finalText = ""

        lock.lock()
        if endRequested || torndown {
            torndown = true
            continuationToResume = finishContinuation
            finishContinuation = nil
            finalText = finalizedText
        } else {
            shouldRestart = true
        }
        lock.unlock()

        if shouldRestart {
            Log.asr.error("legacy SF leg ended, restarting: \(error.localizedDescription)")
            beginLeg()
        } else {
            continuationToResume?.resume(returning: finalText)
        }
    }

    private func emitPartial() {
        let combined: String = {
            lock.lock(); defer { lock.unlock() }
            if volatileText.isEmpty { return finalizedText }
            if finalizedText.isEmpty { return volatileText }
            return finalizedText + " " + volatileText
        }()
        onPartial?(combined)
    }
}
