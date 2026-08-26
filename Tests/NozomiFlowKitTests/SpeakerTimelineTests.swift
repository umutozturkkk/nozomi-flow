import XCTest
@testable import NozomiFlowKit

/// Debounce and staleness, both of which exist to keep the caption engine's noise
/// out of the audio. A confirmed change cuts a chunk, so a false one costs a
/// wrongly labelled turn that nothing downstream can detect.
final class SpeakerTimelineTests: XCTestCase {

    private let start = Date(timeIntervalSince1970: 1_000)

    private func caption(_ speaker: String, _ offset: TimeInterval) -> CaptionObservation {
        CaptionObservation(speaker: speaker, text: "bir şeyler söyledi", observedAt: start + offset)
    }

    // MARK: - Confirming a change

    func testASpeakerIsConfirmedOnlyAfterHoldingTheFloor() {
        var timeline = SpeakerTimeline()
        XCTAssertNil(timeline.record(caption("Ahmet", 0)), "the first sighting is a candidate, not a fact")
        XCTAssertNil(timeline.record(caption("Ahmet", 1.0)), "still inside the hold window")
        XCTAssertEqual(timeline.record(caption("Ahmet", 1.6)), "Ahmet")
    }

    func testAStrayLineDoesNotCutTheAudio() {
        // Crosstalk makes Meet briefly attribute a word to the wrong person. Acting on
        // that single line would slice the chunk and mislabel both halves.
        var timeline = SpeakerTimeline()
        _ = timeline.record(caption("Ahmet", 0))
        _ = timeline.record(caption("Ahmet", 2.0))
        XCTAssertEqual(timeline.confirmed, "Ahmet")

        XCTAssertNil(timeline.record(caption("Ayşe", 2.5)))
        XCTAssertNil(timeline.record(caption("Ahmet", 3.0)))
        XCTAssertEqual(timeline.confirmed, "Ahmet", "one stray line must not change who is speaking")
    }

    func testAGenuineChangeIsConfirmed() {
        var timeline = SpeakerTimeline()
        _ = timeline.record(caption("Ahmet", 0))
        _ = timeline.record(caption("Ahmet", 2.0))
        XCTAssertNil(timeline.record(caption("Ayşe", 3.0)))
        XCTAssertEqual(timeline.record(caption("Ayşe", 4.6)), "Ayşe")
    }

    func testTheSameSpeakerIsNotReportedTwice() {
        var timeline = SpeakerTimeline()
        _ = timeline.record(caption("Ahmet", 0))
        _ = timeline.record(caption("Ahmet", 2.0))
        XCTAssertNil(timeline.record(caption("Ahmet", 4.0)), "no change means no cut")
    }

    // MARK: - Staleness

    func testNobodyIsSpeakingAfterASilence() {
        var timeline = SpeakerTimeline()
        _ = timeline.record(caption("Ahmet", 0))
        _ = timeline.record(caption("Ahmet", 2.0))

        XCTAssertEqual(timeline.speaker(at: start + 4), "Ahmet")
        XCTAssertNil(timeline.speaker(at: start + 30),
                     "the last speaker must not silently own every pause in the meeting")
    }

    // MARK: - Roster

    func testRosterUnionsCaptionsAndThePanelWithoutDuplicating() {
        var timeline = SpeakerTimeline()
        _ = timeline.record(caption("Ahmet", 0))
        _ = timeline.record(caption("Ahmet", 2.0))
        timeline.noteRoster(["Ayşe", "AHMET", "Mehmet"])

        XCTAssertEqual(timeline.roster, ["Ahmet", "Ayşe", "Mehmet"])
    }

    func testRosterIncludesPeopleWhoNeverSpoke() {
        var timeline = SpeakerTimeline()
        timeline.noteRoster(["Ayşe"])
        XCTAssertEqual(timeline.roster, ["Ayşe"])
    }

    func testAnEmptyTimelineHasAnEmptyRoster() {
        let timeline = SpeakerTimeline()
        XCTAssertTrue(timeline.roster.isEmpty)
        XCTAssertNil(timeline.confirmed)
        XCTAssertNil(timeline.speaker(at: start))
    }

    // MARK: - The local participant

    func testTheLocalUserIsRecognizedAndKeptOutOfTheRoster() {
        // Meet captions everyone, including the person at this Mac. Their audio is on
        // the microphone track, so the remote track must never be labelled with it.
        var timeline = SpeakerTimeline()
        timeline.localName = "Umut Öztürk"

        _ = timeline.record(caption("Umut Öztürk", 0))
        _ = timeline.record(caption("Umut Öztürk", 2.0))

        XCTAssertTrue(timeline.isLocal("umut öztürk"))
        XCTAssertFalse(timeline.isLocal("Ahmet"))
        XCTAssertTrue(timeline.roster.isEmpty, "the local user is known separately, not through the roster")
    }

    func testWithNoLocalNameNobodyIsLocal() {
        var timeline = SpeakerTimeline()
        XCTAssertFalse(timeline.isLocal("Ahmet"))
        timeline.localName = ""
        XCTAssertFalse(timeline.isLocal("Ahmet"))
    }
}
