import XCTest
import AVFAudio
@testable import NozomiFlowKit

/// The mic starts on key-down, before the recognizer session exists. When that
/// setup is slow (a model download, a cold engine) the mic must still go off the
/// moment the key is released: audio after key-up is never used, and a live mic
/// indicator the user didn't ask for is a privacy regression.
@MainActor
final class CoordinatorAudioLifecycleTests: XCTestCase {

    private var dir: URL!
    private var suite: String!
    private var audio: FakeAudio!
    private var transcriber: FakeTranscriber!
    private var coordinator: DictationCoordinator!
    private var hotkeys: FakeHotkeys!
    private var appState: AppState!

    override func setUp() async throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("coordinator-tests-\(UUID().uuidString)")
        suite = "coordinator-tests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let settings = SettingsStore(defaults: defaults)
        settings.playSounds = false
        appState = AppState()
        hotkeys = FakeHotkeys()
        audio = FakeAudio()
        transcriber = FakeTranscriber()
        coordinator = DictationCoordinator(
            appState: appState,
            settings: settings,
            audio: audio,
            transcriber: transcriber,
            formatter: FakeFormatter(),
            inserter: FakeInserter(),
            contextProvider: FakeContext(),
            dictionary: PersonalDictionaryStore(directory: dir.appendingPathComponent("dict")),
            history: HistoryStore(directory: dir.appendingPathComponent("history")),
            permissions: PermissionsService(appState: appState, microphoneStatus: { .authorized }),
            hotkeys: hotkeys,
            sounds: SoundPlayer(settings: settings),
            trainingStore: TrainingSampleStore(directory: dir.appendingPathComponent("training"))
        )
    }

    override func tearDown() async throws {
        transcriber.releaseStartup()
        UserDefaults.standard.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: dir)
    }

    func testMicStartsOnKeyDownBeforeTheSessionIsReady() {
        coordinator.keyDown(mode: .dictation)
        XCTAssertTrue(audio.isCapturing)
    }

    func testMicStopsAtKeyUpEvenWhileStartupIsStillRunning() async throws {
        coordinator.keyDown(mode: .dictation)
        try await Task.sleep(for: .milliseconds(450)) // past the quick-tap threshold
        coordinator.keyUp(mode: .dictation)

        XCTAssertFalse(audio.isCapturing, "the mic must not stay live while a slow startup finishes")
    }
}

extension CoordinatorAudioLifecycleTests {
    /// A cold mic blocks the main thread at key-down, so the key-up is handled
    /// late; what counts is when the keys were actually pressed and released.
    func testQuickTapIsJudgedByEventTimesNotByWhenItWasHandled() async throws {
        hotkeys.lastEventUptime = 100.0
        coordinator.keyDown(mode: .dictation)
        try await Task.sleep(for: .milliseconds(450)) // handled late, as after a cold start
        hotkeys.lastEventUptime = 100.1               // but released 0.1 s after pressing
        coordinator.keyUp(mode: .dictation)

        XCTAssertEqual(appState.phase, .idle, "a 0.1 s tap is a quick tap and must be discarded")
        XCTAssertFalse(audio.isCapturing)
    }
}

// MARK: - Fakes

private final class FakeAudio: AudioCaptureServiceProtocol {
    var bufferHandler: ((AVAudioPCMBuffer, AVAudioTime) -> Void)?
    var onLevel: ((Float) -> Void)?
    var onFirstBuffer: (() -> Void)?
    private(set) var isCapturing = false
    func start() throws { isCapturing = true }
    func stop() { isCapturing = false }
    func prewarm() {}
}

/// `beginSession` suspends until the test releases it, standing in for a slow
/// model download or engine start.
private final class FakeTranscriber: TranscriptionServiceProtocol {
    var onPartial: ((String) -> Void)?
    private var gate: CheckedContinuation<Void, Never>?
    private var released = false

    func releaseStartup() {
        released = true
        gate?.resume()
        gate = nil
    }

    func engineKind(for locale: Locale) async -> TranscriptionEngineKind { .dictation }
    func prepare(locale: Locale, progress: @escaping @Sendable (Double) -> Void) async throws {}
    func beginSession(locale: Locale, contextualStrings: [String]) async throws {
        guard !released else { return }
        await withCheckedContinuation { gate = $0 }
    }
    func acceptBuffer(_ buffer: AVAudioPCMBuffer) {}
    func endSession() async throws -> TranscriptionOutcome {
        TranscriptionOutcome(text: "", localeIdentifier: "tr_TR", engine: .dictation)
    }
    func cancelSession() {}
}

private final class FakeFormatter: FormattingServiceProtocol {
    func format(_ request: FormattingRequest) async -> FormattedResult {
        FormattedResult(text: request.raw, usedLLM: false, pressEnter: false, corrections: 0)
    }
    func applyCommand(instruction: String, selectedText: String?, context: AppContextInfo,
                      llm: LLMEngineChoice, openAIKey: String?, openAIModel: String) async throws -> String { instruction }
    func prewarm() {}
    func prepareSession(for request: FormattingRequest) {}
    func availabilityDescription() async -> String { "" }
}

@MainActor
private final class FakeInserter: TextInsertionServiceProtocol {
    func insert(_ text: String) async -> InsertionOutcome { InsertionOutcome(method: .accessibility, succeeded: true) }
    func replaceSelection(with text: String) async -> InsertionOutcome { InsertionOutcome(method: .accessibility, succeeded: true) }
    func selectedText() -> String? { nil }
    func pressEnter() async {}
}

@MainActor
private final class FakeContext: AppContextProviderProtocol {
    func snapshot(includeFieldText: Bool) -> AppContextInfo { AppContextInfo() }
}

@MainActor
private final class FakeHotkeys: HotkeyServiceProtocol {
    var onDictationKeyDown: (() -> Void)?
    var onDictationKeyUp: (() -> Void)?
    var onCommandKeyDown: (() -> Void)?
    var onCommandKeyUp: (() -> Void)?
    var onEscape: (() -> Void)?
    var lastEventUptime: TimeInterval?
    var isRunning = false
    func start() throws {}
    func stop() {}
}
