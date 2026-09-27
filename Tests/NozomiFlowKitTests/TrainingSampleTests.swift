import XCTest
@testable import NozomiFlowKit

/// Which dictations become training data. A wrong "yes" teaches the model a bad
/// label; the worst case is an on-device rescue of a failed cloud request.
final class TrainingSampleTests: XCTestCase {

    private func cloudOutcome(seconds: Double = 3, text: String = "merhaba dünya") -> TranscriptionOutcome {
        TranscriptionOutcome(text: text, localeIdentifier: "tr_TR", engine: .cloud,
                             audio: Array(repeating: 1, count: Int(seconds * 16_000)))
    }

    func testCloudDictationIsASample() {
        XCTAssertTrue(TrainingSampleEligibility.accepts(enabled: true, mode: .dictation, outcome: cloudOutcome()))
    }

    func testNothingIsCollectedWhileDisabled() {
        XCTAssertFalse(TrainingSampleEligibility.accepts(enabled: false, mode: .dictation, outcome: cloudOutcome()))
    }

    func testCommandModeIsNotASample() {
        XCTAssertFalse(TrainingSampleEligibility.accepts(enabled: true, mode: .command, outcome: cloudOutcome()))
    }

    func testLocalEngineOutcomeIsNotASample() {
        var outcome = cloudOutcome()
        outcome.engine = .dictation // e.g. the on-device rescue after a failed upload
        XCTAssertFalse(TrainingSampleEligibility.accepts(enabled: true, mode: .dictation, outcome: outcome))
    }

    func testOutcomeWithoutAudioIsNotASample() {
        var outcome = cloudOutcome()
        outcome.audio = nil
        XCTAssertFalse(TrainingSampleEligibility.accepts(enabled: true, mode: .dictation, outcome: outcome))
    }

    func testUnderOneSecondIsNotASample() {
        XCTAssertFalse(TrainingSampleEligibility.accepts(enabled: true, mode: .dictation, outcome: cloudOutcome(seconds: 0.9)))
    }

    func testBlankTranscriptIsNotASample() {
        XCTAssertFalse(TrainingSampleEligibility.accepts(enabled: true, mode: .dictation, outcome: cloudOutcome(text: "  \n")))
    }

    func testNewSampleStartsUncheckedWithLabelEqualToRaw() {
        let sample = TrainingSample.make(rawLabel: "selam", audioSampleCount: 32_000,
                                         appBundleID: "com.apple.TextEdit", labelSource: "m")
        XCTAssertEqual(sample.status, .unchecked)
        XCTAssertEqual(sample.label, "selam")
        XCTAssertEqual(sample.durationSeconds, 2, accuracy: 0.001)
    }

    @MainActor
    func testCollectionSettingIsOffByDefaultAndPersists() throws {
        let suite = "training-settings-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let first = SettingsStore(defaults: defaults)
        XCTAssertFalse(first.collectTrainingData)
        first.collectTrainingData = true

        XCTAssertTrue(SettingsStore(defaults: defaults).collectTrainingData)
    }
}
