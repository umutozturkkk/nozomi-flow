import XCTest
@testable import NozomiFlowKit

/// Pure decision-chain tests for `EngineSelector.select`. No live Speech framework calls,
/// no mic/ASR access, no asset downloads, no TCC prompts -- availability is entirely
/// injected so the chain's ordering/short-circuit behavior can be verified deterministically.
final class TranscriptionSelectionTests: XCTestCase {

    private let sampleLocale = Locale(identifier: "en_US")

    func testExactMatchOnSpeechTranscriberWins() {
        var dictationCalled = false
        var sfCalled = false
        let result = EngineSelector.select(
            locale: sampleLocale,
            speechTranscriberAvailable: { _ in true },
            dictationTranscriberAvailable: { _ in dictationCalled = true; return true },
            legacySFAvailable: { _ in sfCalled = true; return true }
        )
        XCTAssertEqual(result, .speechAnalyzer)
        XCTAssertFalse(dictationCalled, "chain must short-circuit once SpeechTranscriber matches")
        XCTAssertFalse(sfCalled, "chain must short-circuit once SpeechTranscriber matches")
    }

    func testTurkishRoutesToDictationTranscriber() {
        // tr_TR: not in SpeechTranscriber's 30 locales, but is in DictationTranscriber's 54.
        let trTR = Locale(identifier: "tr_TR")
        var sfCalled = false
        let result = EngineSelector.select(
            locale: trTR,
            speechTranscriberAvailable: { _ in false },
            dictationTranscriberAvailable: { _ in true },
            legacySFAvailable: { _ in sfCalled = true; return true }
        )
        XCTAssertEqual(result, .dictation)
        XCTAssertFalse(sfCalled, "chain must short-circuit once DictationTranscriber matches")
    }

    func testLegacySFIsLastResort() {
        let result = EngineSelector.select(
            locale: sampleLocale,
            speechTranscriberAvailable: { _ in false },
            dictationTranscriberAvailable: { _ in false },
            legacySFAvailable: { _ in true }
        )
        XCTAssertEqual(result, .legacySF)
    }

    func testUnsupportedEverywhereReturnsNone() {
        let result = EngineSelector.select(
            locale: Locale(identifier: "xx_XX"),
            speechTranscriberAvailable: { _ in false },
            dictationTranscriberAvailable: { _ in false },
            legacySFAvailable: { _ in false }
        )
        XCTAssertEqual(result, .none)
    }

    func testChainEvaluatesPredicatesInOrderWhenNothingMatchesUntilTheEnd() {
        var callOrder: [String] = []
        let result = EngineSelector.select(
            locale: sampleLocale,
            speechTranscriberAvailable: { _ in callOrder.append("st"); return false },
            dictationTranscriberAvailable: { _ in callOrder.append("dt"); return false },
            legacySFAvailable: { _ in callOrder.append("sf"); return true }
        )
        XCTAssertEqual(result, .legacySF)
        XCTAssertEqual(callOrder, ["st", "dt", "sf"], "predicates must be evaluated in ST -> DT -> SF order")
    }

    func testSameLocaleInstancePassedToEveryPredicate() {
        // Chain ordering must not depend on re-deriving or mutating the locale --
        // whatever the caller resolved (e.g. via supportedLocale(equivalentTo:)
        // upstream) is what every predicate in the chain sees.
        let locale = Locale(identifier: "en_TR")
        var seenLocales: [Locale] = []
        _ = EngineSelector.select(
            locale: locale,
            speechTranscriberAvailable: { seenLocales.append($0); return false },
            dictationTranscriberAvailable: { seenLocales.append($0); return false },
            legacySFAvailable: { seenLocales.append($0); return false }
        )
        XCTAssertEqual(seenLocales, [locale, locale, locale])
    }
}
