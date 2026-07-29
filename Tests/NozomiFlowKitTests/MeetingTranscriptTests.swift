import XCTest
@testable import NozomiFlowKit

/// The merge is where two independently transcribed tracks become one readable
/// conversation. Its failure mode is not a crash: it is a transcript where the
/// answers come before the questions, or where one side is silently missing, and
/// nobody notices until they read the notes for a meeting they cannot recall.
@available(macOS 15.0, *)
final class MeetingTranscriptTests: XCTestCase {

    private func segment(_ track: MeetingTrack, at start: TimeInterval,
                         _ text: String, duration: TimeInterval = 10) -> MeetingSegment {
        MeetingSegment(track: track, startOffset: start, duration: duration, text: text)
    }

    // MARK: - Ordering

    func testTurnsComeOutInTheOrderTheyWereSpoken() {
        let lines = MeetingTranscript.merge([
            segment(.system, at: 20, "İkinci cevap"),
            segment(.microphone, at: 0, "İlk soru"),
            segment(.system, at: 10, "İlk cevap"),
        ])
        XCTAssertEqual(lines.map(\.text), ["İlk soru", "İlk cevap İkinci cevap"])
        XCTAssertEqual(lines.map(\.speaker), ["You", "Them"])
    }

    func testInputOrderDoesNotChangeTheResult() {
        // Uploads finish out of order, so the merge must depend on offsets alone.
        let segments = [
            segment(.microphone, at: 0, "bir"),
            segment(.system, at: 10, "iki"),
            segment(.microphone, at: 20, "uc"),
        ]
        let forward = MeetingTranscript.merge(segments)
        let backward = MeetingTranscript.merge(segments.reversed())
        XCTAssertEqual(forward, backward)
    }

    func testSimultaneousStartsOrderDeterministically() {
        // Both tracks start at zero. Whatever the tie-break is, it must not depend on
        // which upload came back first.
        let a = MeetingTranscript.merge([
            segment(.microphone, at: 0, "mic"), segment(.system, at: 0, "sys"),
        ])
        let b = MeetingTranscript.merge([
            segment(.system, at: 0, "sys"), segment(.microphone, at: 0, "mic"),
        ])
        XCTAssertEqual(a, b)
        XCTAssertEqual(a.count, 2)
    }

    // MARK: - Coalescing

    func testConsecutiveChunksFromOneSpeakerBecomeOneTurn() {
        let lines = MeetingTranscript.merge([
            segment(.microphone, at: 0, "Birinci parca", duration: 120),
            segment(.microphone, at: 120, "ikinci parca", duration: 120),
            segment(.microphone, at: 240, "ucuncu parca", duration: 120),
        ])
        XCTAssertEqual(lines.count, 1, "one person talking across three chunks is one turn")
        XCTAssertEqual(lines.first?.text, "Birinci parca ikinci parca ucuncu parca")
        XCTAssertEqual(lines.first?.startOffset, 0, "a coalesced turn keeps the time it began")
    }

    func testSpeakerChangeStartsANewTurn() {
        let lines = MeetingTranscript.merge([
            segment(.microphone, at: 0, "a"),
            segment(.system, at: 10, "b"),
            segment(.microphone, at: 20, "c"),
        ])
        XCTAssertEqual(lines.count, 3)
        XCTAssertEqual(lines.map(\.speaker), ["You", "Them", "You"])
    }

    // MARK: - Empty and whitespace

    func testSilentChunksDoNotProduceTurns() {
        // A track records continuously, so its chunks over the other person's turn
        // transcribe to nothing. Those must not appear as empty lines, nor split a
        // speaker's turn in two.
        let lines = MeetingTranscript.merge([
            segment(.microphone, at: 0, "Soru"),
            segment(.system, at: 10, "   "),
            segment(.system, at: 20, ""),
            segment(.microphone, at: 30, "Devam"),
        ])
        XCTAssertEqual(lines.count, 1)
        XCTAssertEqual(lines.first?.text, "Soru Devam")
    }

    func testNothingSpokenProducesNoTranscript() {
        XCTAssertTrue(MeetingTranscript.merge([]).isEmpty)
        XCTAssertTrue(MeetingTranscript.merge([segment(.microphone, at: 0, "")]).isEmpty)
    }

    func testSurroundingWhitespaceIsTrimmedNotPreserved() {
        let lines = MeetingTranscript.merge([segment(.microphone, at: 0, "  bosluklu  ")])
        XCTAssertEqual(lines.first?.text, "bosluklu")
    }

    // MARK: - Rendering

    func testTimestampsSwitchToHoursOnlyWhenNeeded() {
        XCTAssertEqual(MeetingTranscript.timestamp(0), "0:00")
        XCTAssertEqual(MeetingTranscript.timestamp(9), "0:09")
        XCTAssertEqual(MeetingTranscript.timestamp(75), "1:15")
        XCTAssertEqual(MeetingTranscript.timestamp(3599), "59:59")
        XCTAssertEqual(MeetingTranscript.timestamp(3600), "1:00:00")
        XCTAssertEqual(MeetingTranscript.timestamp(3725), "1:02:05")
        XCTAssertEqual(MeetingTranscript.timestamp(-5), "0:00", "a negative offset must not render as garbage")
    }

    func testMarkdownLabelsEverySpeakerAndTime() {
        let markdown = MeetingTranscript.markdown(MeetingTranscript.merge([
            segment(.microphone, at: 0, "Merhaba"),
            segment(.system, at: 65, "Merhaba, nasilsin"),
        ]))
        XCTAssertTrue(markdown.contains("**0:00 You:** Merhaba"))
        XCTAssertTrue(markdown.contains("**1:05 Them:** Merhaba, nasilsin"))
    }

    // MARK: - Batching used by the uploader

    func testBatchingCoversEveryElementExactlyOnce() {
        let items = Array(1...10)
        let batches = items.chunked(into: 3)
        XCTAssertEqual(batches.map(\.count), [3, 3, 3, 1])
        XCTAssertEqual(batches.flatMap { $0 }, items, "no chunk may be dropped or uploaded twice")
        XCTAssertEqual([Int]().chunked(into: 3), [])
        XCTAssertEqual(items.chunked(into: 0), [items], "a nonsense batch size must not lose work")
    }
}
