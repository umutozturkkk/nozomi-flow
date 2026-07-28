import Foundation
import AVFAudio

// Service contracts. These are the coordination backbone between modules —
// do not change signatures without updating DictationCoordinator and all
// implementations together.

// MARK: - Hotkeys

@MainActor
protocol HotkeyServiceProtocol: AnyObject {
    var onDictationKeyDown: (() -> Void)? { get set }
    var onDictationKeyUp: (() -> Void)? { get set }
    var onCommandKeyDown: (() -> Void)? { get set }
    var onCommandKeyUp: (() -> Void)? { get set }
    /// Fired on Escape keydown; coordinator ignores it unless a session is active.
    var onEscape: (() -> Void)? { get set }
    var isRunning: Bool { get }
    func start() throws
    func stop()
}

// MARK: - Audio capture

protocol AudioCaptureServiceProtocol: AnyObject {
    /// Called on an internal audio thread with mic buffers in the engine's native input format.
    var bufferHandler: ((AVAudioPCMBuffer, AVAudioTime) -> Void)? { get set }
    /// Smoothed 0...1 input level for waveform UI. Always called on the main thread.
    var onLevel: ((Float) -> Void)? { get set }
    var isCapturing: Bool { get }
    func start() throws
    func stop()
}

// MARK: - Transcription

protocol TranscriptionServiceProtocol: AnyObject {
    /// Volatile (partial) transcript callback. Always called on the main thread.
    var onPartial: ((String) -> Void)? { get set }
    /// Engine that will be used for the given locale right now.
    func engineKind(for locale: Locale) async -> TranscriptionEngineKind
    /// Ensure on-device model assets are installed for the locale. progress is 0...1, main thread.
    func prepare(locale: Locale, progress: @escaping @Sendable (Double) -> Void) async throws
    /// Begin a streaming session. contextualStrings are dictionary boost words.
    func beginSession(locale: Locale, contextualStrings: [String]) async throws
    /// Feed a mic buffer (called from the audio thread; implementations must be thread-safe).
    func acceptBuffer(_ buffer: AVAudioPCMBuffer)
    /// Stop the stream and return the final transcript.
    func endSession() async throws -> TranscriptionOutcome
    func cancelSession()
}

// MARK: - Formatting

protocol FormattingServiceProtocol: AnyObject {
    /// Clean up a raw transcript. Never throws — falls back to rule-based internally.
    func format(_ request: FormattingRequest) async -> FormattedResult
    /// Command mode: apply a spoken instruction to selected text (or generate text if selection is nil).
    func applyCommand(
        instruction: String,
        selectedText: String?,
        context: AppContextInfo,
        llm: LLMEngineChoice,
        openAIKey: String?,
        openAIModel: String
    ) async throws -> String
    func prewarm()
    /// Fast path: pre-build and prewarm the LLM session for an upcoming request.
    /// Called at record start so instruction prefill overlaps with speaking.
    func prepareSession(for request: FormattingRequest)
    /// Human-readable availability of the on-device LLM ("Apple Intelligence ready", etc.).
    func availabilityDescription() async -> String
}

// MARK: - Insertion

@MainActor
protocol TextInsertionServiceProtocol: AnyObject {
    /// Insert text at the caret of the frontmost app. AX first, paste fallback, clipboard last resort.
    func insert(_ text: String) async -> InsertionOutcome
    /// Replace the current selection (command mode).
    func replaceSelection(with text: String) async -> InsertionOutcome
    /// Read the currently selected text via AX, if any.
    func selectedText() -> String?
    /// Synthesize a Return keypress (spoken "press enter" command).
    func pressEnter() async
}

// MARK: - App context

@MainActor
protocol AppContextProviderProtocol: AnyObject {
    func snapshot(includeFieldText: Bool) -> AppContextInfo
}
