import XCTest
@testable import NozomiFlowKit

/// Regression tests for the key-up/startup race that left the HUD stuck on
/// "Polishing..." forever.
///
/// The sequence: press the key (phase becomes .recording, startup begins), release it
/// before `beginSession` returns (stopAndProcess sets .processing and then awaits the
/// startup task), startup finally resumes and finds the phase is no longer .recording.
/// Returning quietly there left nobody to move the phase off .processing.
final class StartupRaceTests: XCTestCase {

    func testStillRecordingProceeds() {
        XCTAssertEqual(
            StartupRace.resolve(generationMatches: true, stillRecording: true),
            .proceed
        )
    }

    func testKeyUpBeatingStartupMustBeReportedNotIgnored() {
        // The regression: same session, but the phase already moved on. Startup is the
        // only thing left that can resolve it.
        XCTAssertEqual(
            StartupRace.resolve(generationMatches: true, stillRecording: false),
            .keyUpBeatStartup
        )
    }

    func testNewerSessionTakesOverRegardlessOfPhase() {
        // A bumped generation means cancel/fail/a newer session already set the phase,
        // so startup must stay silent or it would clobber their state.
        for stillRecording in [true, false] {
            XCTAssertEqual(
                StartupRace.resolve(generationMatches: false, stillRecording: stillRecording),
                .supersededByNewerSession,
                "a superseded startup must never resolve the phase itself"
            )
        }
    }

    func testEveryOutcomeIsReachable() {
        // Guards against a future refactor collapsing two branches into one and
        // silently reintroducing the stuck phase.
        let outcomes = Set(
            [(true, true), (true, false), (false, true), (false, false)]
                .map { StartupRace.resolve(generationMatches: $0.0, stillRecording: $0.1) }
        )
        XCTAssertEqual(outcomes, [.proceed, .keyUpBeatStartup, .supersededByNewerSession])
    }

    func testOnlyProceedKeepsTheSessionAlive() {
        // Anything other than .proceed must tear the transcriber session down, so the
        // switch in the coordinator can never fall through to wiring up audio.
        for (matches, recording) in [(true, false), (false, true), (false, false)] {
            XCTAssertNotEqual(
                StartupRace.resolve(generationMatches: matches, stillRecording: recording),
                .proceed
            )
        }
    }

    // MARK: - The phase flag the decision reads

    func testOnlyRecordingCountsAsStillRecording() {
        XCTAssertTrue(DictationPhase.recording(startedAt: Date(), handsFree: false).isRecording)
        XCTAssertTrue(DictationPhase.recording(startedAt: Date(), handsFree: true).isRecording)
        for phase in [DictationPhase.idle, .processing, .inserting, .success(wordCount: 3)] {
            XCTAssertFalse(phase.isRecording, "\(phase) must not read as still recording")
        }
        XCTAssertFalse(DictationPhase.failure(.tooShort).isRecording)
    }
}
