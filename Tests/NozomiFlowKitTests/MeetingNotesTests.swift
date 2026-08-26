import XCTest
@testable import NozomiFlowKit

/// Summary validation, endpoint derivation and what actually reaches disk. The
/// theme is the same as the rest of meeting support: every one of these fails by
/// producing a plausible file with something missing from it.
@available(macOS 15.0, *)
final class MeetingNotesTests: XCTestCase {

    // MARK: - Summary validation

    func testTruncatedSummaryIsRejectedRatherThanSaved() {
        // The failure this exists for: a model returned four words of a sentence on
        // the dictation path. Writing that as the notes would look like a summary.
        XCTAssertNil(MeetingSummarizer.validate("## Summary"))
        XCTAssertNil(MeetingSummarizer.validate("Toplantıda"))
        XCTAssertNil(MeetingSummarizer.validate("   \n  "))
        XCTAssertNil(MeetingSummarizer.validate(""))
    }

    func testRealNotesSurviveValidation() {
        let notes = """
            ## Summary

            The team agreed to ship on Monday and postpone the pricing change.
            """
        XCTAssertEqual(MeetingSummarizer.validate(notes), notes)
    }

    func testValidationTrimsWithoutMangling() {
        let notes = "## Summary\n\nA sufficiently long body that should survive intact."
        XCTAssertEqual(MeetingSummarizer.validate("\n\n" + notes + "  \n"), notes)
    }

    // MARK: - Who the model is told was in the room

    func testTheRosterNamesEveryoneAndClosesTheGap() {
        // The exact failure being fixed: given an unidentified speaker and names
        // inside the speech, a model harvests those names and hands them turns.
        let instructions = MeetingSummarizer.instructions(userName: "Umut", roster: ["Ahmet", "Ayşe"])

        XCTAssertTrue(instructions.contains("Umut, Ahmet, Ayşe"))
        XCTAssertTrue(instructions.contains("Nobody else spoke"))
        XCTAssertTrue(instructions.lowercased().contains("referring to a person"))
    }

    func testWithNoRosterTheFarSideStaysAnonymous() {
        // Captions off or an unreadable window. Claiming to know the participants
        // here would be worse than admitting the transcript only has two sides.
        let instructions = MeetingSummarizer.instructions(userName: "Umut", roster: [])

        XCTAssertTrue(instructions.contains("\"Them\""))
        XCTAssertTrue(instructions.contains("\"Umut\""))
        XCTAssertFalse(instructions.contains("Nobody else spoke"))
        XCTAssertTrue(instructions.lowercased().contains("do not work out who"))
    }

    func testWithNoNameAtAllTheOldLabelsSurvive() {
        let instructions = MeetingSummarizer.instructions()
        XCTAssertTrue(instructions.contains("\"You\""))
        XCTAssertTrue(instructions.contains("\"Them\""))
    }

    // MARK: - Endpoint derivation

    func testSummaryFollowsWhicheverProviderIsConfigured() {
        // Hardcoding a second provider would send meeting transcripts somewhere the
        // user never configured, and bill an account they may not have.
        let openRouter = URL(string: "https://openrouter.ai/api/v1/audio/transcriptions")!
        XCTAssertEqual(
            MeetingSummarizer.chatEndpoint(for: openRouter).absoluteString,
            "https://openrouter.ai/api/v1/chat/completions")

        let selfHosted = URL(string: "https://llm.example.com/v1/audio/transcriptions")!
        XCTAssertEqual(
            MeetingSummarizer.chatEndpoint(for: selfHosted).absoluteString,
            "https://llm.example.com/v1/chat/completions")
    }

    // MARK: - Identifiers

    @MainActor
    func testIdentifiersRoundTripAndSortChronologically() throws {
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        let id = MeetingStore.makeID(for: date)
        let parsed = try XCTUnwrap(MeetingStore.date(fromID: id))
        XCTAssertEqual(parsed.timeIntervalSince1970, date.timeIntervalSince1970, accuracy: 1)

        // Lexical order must match chronological order, since that is what the
        // listing and the filenames both rely on.
        let earlier = MeetingStore.makeID(for: date)
        let later = MeetingStore.makeID(for: date.addingTimeInterval(3600))
        XCTAssertLessThan(earlier, later)
    }

    @MainActor
    func testNonMeetingFilenamesDoNotParseAsDates() {
        XCTAssertNil(MeetingStore.date(fromID: "notes"))
        XCTAssertNil(MeetingStore.date(fromID: ""))
    }

    // MARK: - Writing

    @MainActor
    func testNotesKeepTheTranscriptEvenWhenTheSummaryFailed() throws {
        let store = try makeStore()
        let id = MeetingStore.makeID(for: Date())

        let record = try XCTUnwrap(store.save(
            id: id, startedAt: Date(), duration: 754,
            transcript: "**0:00 You:** Merhaba", summary: nil))

        let written = try String(contentsOf: record.url, encoding: .utf8)
        XCTAssertTrue(written.contains("**0:00 You:** Merhaba"),
                      "a failed summary must never cost the transcript")
        XCTAssertTrue(written.contains("Not generated for this meeting."))
        XCTAssertTrue(written.contains("12:34"), "the duration belongs in the header")
    }

    @MainActor
    func testSummaryAndTranscriptBothLandWhenBothExist() throws {
        let store = try makeStore()
        let id = MeetingStore.makeID(for: Date())

        let record = try XCTUnwrap(store.save(
            id: id, startedAt: Date(), duration: 60,
            transcript: "**0:00 Them:** Selam", summary: "## Summary\n\nShort and useful."))

        let written = try String(contentsOf: record.url, encoding: .utf8)
        XCTAssertTrue(written.contains("Short and useful."))
        XCTAssertTrue(written.contains("## Transcript"))
        XCTAssertTrue(written.contains("**0:00 Them:** Selam"))
    }

    @MainActor
    func testAnEmptyMeetingSaysSoInsteadOfLookingEmpty() throws {
        let store = try makeStore()
        let record = try XCTUnwrap(store.save(
            id: MeetingStore.makeID(for: Date()), startedAt: Date(), duration: 5,
            transcript: "", summary: nil))
        XCTAssertTrue(try String(contentsOf: record.url, encoding: .utf8)
            .contains("_Nothing was transcribed._"))
    }

    @MainActor
    func testListingIsNewestFirstAndDeleteRemovesTheFile() throws {
        let store = try makeStore()
        let old = Date(timeIntervalSince1970: 1_700_000_000)
        store.save(id: MeetingStore.makeID(for: old), startedAt: old, duration: 10,
                   transcript: "eski", summary: nil)
        let recent = old.addingTimeInterval(86_400)
        store.save(id: MeetingStore.makeID(for: recent), startedAt: recent, duration: 10,
                   transcript: "yeni", summary: nil)

        XCTAssertEqual(store.meetings.count, 2)
        XCTAssertGreaterThan(try XCTUnwrap(store.meetings.first).date,
                             try XCTUnwrap(store.meetings.last).date,
                             "the most recent meeting must be the one at the top")

        let target = try XCTUnwrap(store.meetings.first)
        store.delete(target)
        XCTAssertEqual(store.meetings.count, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.url.path))
    }

    @MainActor
    func testWorkingFilesLiveOutsideTheNotesAndAreRemovable() throws {
        let store = try makeStore()
        let id = "2026-07-29-120000"
        let working = store.workingDirectory(for: id)
        try FileManager.default.createDirectory(at: working, withIntermediateDirectories: true)
        try Data([0, 1]).write(to: working.appendingPathComponent("mic-000.wav"))

        store.reload()
        XCTAssertTrue(store.meetings.isEmpty, "raw audio must not show up as a meeting")

        store.discardWorkingFiles(for: id)
        XCTAssertFalse(FileManager.default.fileExists(atPath: working.path))
    }

    // MARK: - Helpers

    @MainActor
    private func makeStore() throws -> MeetingStore {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("meeting-notes-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return MeetingStore(directory: directory)
    }
}
