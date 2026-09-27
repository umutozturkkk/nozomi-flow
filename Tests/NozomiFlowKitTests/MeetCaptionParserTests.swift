import XCTest
@testable import NozomiFlowKit

/// The caption region is a rolling buffer, not an event stream, so every one of
/// these failures produces a plausible transcript with the wrong person's name on
/// it. That is worse than no name at all, which is why the guards are this fussy.
final class MeetCaptionParserTests: XCTestCase {

    private let moment = Date(timeIntervalSince1970: 1_000)

    // MARK: - Line shape

    func testNameAndTextSplitOnTheFirstColon() {
        let parsed = MeetCaptionParser.parseLine("Ahmet: bugün toplantıda konuşacağız")
        XCTAssertEqual(parsed?.speaker, "Ahmet")
        XCTAssertEqual(parsed?.text, "bugün toplantıda konuşacağız")
    }

    func testSpeechContainingAColonDoesNotBecomeASpeaker() {
        // The whole failure this feature exists to stop is a name being invented from
        // the words. A sentence that happens to contain a colon must not become one.
        XCTAssertNil(MeetCaptionParser.parseLine("so the deal is this: we ship Monday"))
        XCTAssertNil(MeetCaptionParser.parseLine("Sonuç şu: pazartesi çıkıyoruz"))
    }

    func testOverLongOrPunctuatedPrefixesAreNotNames() {
        XCTAssertNil(MeetCaptionParser.parseLine(String(repeating: "a", count: 70) + ": merhaba"))
        XCTAssertNil(MeetCaptionParser.parseLine("Bunu yaptık. Sonra: devam ettik"))
    }

    func testRealNamesSurviveTheGuards() {
        XCTAssertEqual(MeetCaptionParser.parseLine("Ayşe Kaya: merhaba")?.speaker, "Ayşe Kaya")
        XCTAssertEqual(MeetCaptionParser.parseLine("Mehmet Ali Kaya Demir: merhaba")?.speaker,
                       "Mehmet Ali Kaya Demir")
        XCTAssertEqual(MeetCaptionParser.parseLine("Jan van Dijk: merhaba")?.speaker, "Jan van Dijk")
    }

    func testCapitalizationSeparatesANameFromAPhrase() {
        // A sentence capitalizes only its first word; a display name capitalizes all
        // of them. Without this, "Sonuç şu:" clears every other guard.
        XCTAssertTrue(MeetCaptionParser.looksLikeName("Ayşe Kaya"))
        XCTAssertFalse(MeetCaptionParser.looksLikeName("Sonuç şu"))
        XCTAssertFalse(MeetCaptionParser.looksLikeName("bir şey"))
    }

    func testLinesWithNothingWorthAttributingAreDropped() {
        XCTAssertNil(MeetCaptionParser.parseLine("Ahmet: ok"))
        XCTAssertNil(MeetCaptionParser.parseLine(": merhaba"))
        XCTAssertNil(MeetCaptionParser.parseLine("no colon here at all"))
    }

    // MARK: - Reconciliation

    func testAGrowingLineEmitsOnlyWhatIsNew() {
        var parser = MeetCaptionParser()
        XCTAssertEqual(parser.ingest("Ahmet: bugün toplantıda", at: moment).map(\.text),
                       ["bugün toplantıda"])
        XCTAssertEqual(parser.ingest("Ahmet: bugün toplantıda konuşacağımız", at: moment).map(\.text),
                       ["konuşacağımız"])
    }

    func testAnUnchangedLineEmitsNothing() {
        var parser = MeetCaptionParser()
        _ = parser.ingest("Ahmet: bugün toplantıda", at: moment)
        XCTAssertTrue(parser.ingest("Ahmet: bugün toplantıda", at: moment).isEmpty)
        XCTAssertTrue(parser.ingest("Ahmet: bugün toplantıda", at: moment).isEmpty)
    }

    func testANewSentenceFromTheSameSpeakerIsEmittedWhole() {
        var parser = MeetCaptionParser()
        _ = parser.ingest("Ahmet: bugün toplantıda", at: moment)
        XCTAssertEqual(parser.ingest("Ahmet: peki o zaman devam edelim", at: moment).map(\.text),
                       ["peki o zaman devam edelim"])
    }

    func testAChangedSpeakerOpensItsOwnObservation() {
        var parser = MeetCaptionParser()
        _ = parser.ingest("Ahmet: bugün toplantıda", at: moment)
        let fresh = parser.ingest("Ayşe: evet katılıyorum", at: moment)
        XCTAssertEqual(fresh.map(\.speaker), ["Ayşe"])
    }

    func testEachSpeakerIsTrackedSeparately() {
        // Two lines are visible at once, and Ahmet's has not changed. Re-emitting it
        // because someone else spoke would double every turn in the meeting.
        var parser = MeetCaptionParser()
        _ = parser.ingest("Ahmet: bugün toplantıda", at: moment)
        let fresh = parser.ingest("Ahmet: bugün toplantıda\nAyşe: evet katılıyorum", at: moment)
        XCTAssertEqual(fresh.map(\.speaker), ["Ayşe"])
    }

    func testOneSpellingIsKeptForOnePerson() {
        var parser = MeetCaptionParser()
        _ = parser.ingest("Ayşe: merhaba arkadaşlar", at: moment)
        let fresh = parser.ingest("AYŞE: merhaba arkadaşlar nasılsınız", at: moment)
        XCTAssertEqual(fresh.map(\.speaker), ["Ayşe"], "the first spelling seen is the one to display")
    }

    func testEmptyInputEmitsNothing() {
        var parser = MeetCaptionParser()
        XCTAssertTrue(parser.ingest("", at: moment).isEmpty)
        XCTAssertTrue(parser.ingest("   \n  \n ", at: moment).isEmpty)
    }

    // MARK: - Folding

    func testFoldingMakesOnePersonOnePerson() {
        XCTAssertEqual(MeetCaptionParser.fold("Ayşe"), MeetCaptionParser.fold("AYŞE"))
        XCTAssertEqual(MeetCaptionParser.fold("Ümit"), MeetCaptionParser.fold("umit"))
        XCTAssertNotEqual(MeetCaptionParser.fold("Ahmet"), MeetCaptionParser.fold("Mehmet"))
    }
}
