import XCTest
@testable import NozomiFlowKit

/// The controller's refusal path. A meeting can only be started from a menu item
/// that looks the same whether the last attempt worked or not, so a refusal has to
/// say why and has to leave the controller startable again.
@available(macOS 15.0, *)
@MainActor
final class MeetingSessionTests: XCTestCase {

    private var suiteName: String!
    private var defaults: UserDefaults!
    private var tempDir: URL!

    override func setUpWithError() throws {
        suiteName = "co.nozomi.flow.meeting-tests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("meeting-session-tests-\(UUID().uuidString)")
    }

    override func tearDownWithError() throws {
        defaults.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: tempDir)
    }

    /// Cloud transcription is off in a fresh suite, which is the one refusal that can
    /// be provoked without a microphone, a display or a real API key.
    private func makeController() -> (MeetingSessionController, MeetingStore) {
        let store = MeetingStore(directory: tempDir)
        return (MeetingSessionController(settings: SettingsStore(defaults: defaults), store: store), store)
    }

    func testStartWithoutCloudTranscriptionReportsWhy() async {
        let (controller, _) = makeController()
        var failures: [MeetingFailure] = []
        controller.onFailure = { failures.append($0) }

        await controller.start()

        XCTAssertEqual(failures, [.cloudTranscriptionOff])
    }

    func testARefusedStartCanBeRetried() async {
        let (controller, _) = makeController()
        var failures: [MeetingFailure] = []
        controller.onFailure = { failures.append($0) }

        await controller.start()
        await controller.start()

        XCTAssertEqual(
            failures.count, 2,
            "a refused start must not leave the controller in a state that swallows every later attempt"
        )
        XCTAssertFalse(controller.phase.isBusy)
    }

    func testNothingIsRecordedWhenTheStartIsRefused() async {
        let (controller, store) = makeController()
        await controller.start()

        XCTAssertFalse(controller.phase.isRecording)
        XCTAssertTrue(store.meetings.isEmpty)
    }
}
