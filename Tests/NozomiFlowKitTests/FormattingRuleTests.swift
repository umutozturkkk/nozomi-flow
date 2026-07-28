import XCTest
@testable import NozomiFlowKit

/// Unit tests for `RuleBasedFormatter` -- the pure, deterministic half of the
/// formatting pipeline. `FormatterPipeline`-level (LLM engine selection, command
/// mode) tests live in FormattingPipelineTests.swift.
final class FormattingRuleTests: XCTestCase {

    private func apply(
        _ raw: String,
        level: FormattingLevel = .light,
        tone: ToneCategory = .neutral,
        locale: String = "en_US",
        removeFillers: Bool = true
    ) -> RuleFormattingResult {
        RuleBasedFormatter.apply(to: raw, level: level, tone: tone, localeIdentifier: locale, removeFillers: removeFillers)
    }

    // MARK: - (a) "press enter"

    func testPressEnterStrippedAtEnd() {
        let result = apply("let's meet at 3 press enter")
        XCTAssertTrue(result.pressEnter)
        XCTAssertEqual(result.text, "Let's meet at 3.")
    }

    func testPressEnterWithTrailingPeriodStripped() {
        let result = apply("let's meet at 3. press enter.")
        XCTAssertTrue(result.pressEnter)
        XCTAssertEqual(result.text, "Let's meet at 3.")
    }

    func testPressEnterMidTextNotStripped() {
        let result = apply("press enter and then say hi")
        XCTAssertFalse(result.pressEnter)
        XCTAssertTrue(result.text.lowercased().contains("press enter"))
    }

    // MARK: - (b) layout commands

    func testNewLineCommand() {
        let result = apply("first point new line second point")
        XCTAssertEqual(result.text, "First point\nsecond point.")
        XCTAssertFalse(result.text.lowercased().contains("new line"))
    }

    func testNewParagraphCommand() {
        let result = apply("thanks for the update new paragraph let's discuss next steps")
        XCTAssertEqual(result.text, "Thanks for the update\n\nlet's discuss next steps.")
        XCTAssertFalse(result.text.lowercased().contains("new paragraph"))
    }

    // MARK: - (c) filler removal

    func testFillerRemovalWithArtifactsAndCorrectionsCount() {
        let result = apply("um so basically I think uh we should uh do this")
        XCTAssertEqual(result.text, "So basically I think we should do this.")
        XCTAssertEqual(result.corrections, 3)
    }

    func testActuallyIsPreservedNotRemoved() {
        let result = apply("I actually enjoyed it")
        XCTAssertTrue(result.text.contains("actually"))
        XCTAssertEqual(result.corrections, 0)
    }

    func testTurkishFillersRemoved() {
        let result = apply("ııı ben bugün eee çok yorgunum", locale: "tr_TR")
        XCTAssertEqual(result.text, "Ben bugün çok yorgunum.")
        XCTAssertEqual(result.corrections, 2)
    }

    // MARK: - (d) whitespace normalization

    func testWhitespaceNormalization() {
        let result = apply("hello    world")
        XCTAssertEqual(result.text, "Hello world.")
    }

    // MARK: - (e) sentence capitalization

    func testSentenceCapitalizationPreservesAllCaps() {
        let result = apply("hello NASA is great today")
        XCTAssertEqual(result.text, "Hello NASA is great today.")
    }

    // MARK: - (f) tone-aware terminal punctuation

    func testCasualShortMessageStripsTrailingPeriod() {
        let result = apply("sounds good.", tone: .casual)
        XCTAssertEqual(result.text, "Sounds good")
        XCTAssertFalse(result.text.hasSuffix("."))
    }

    func testProfessionalToneAppendsPeriod() {
        let result = apply("see you tomorrow", tone: .professional)
        XCTAssertEqual(result.text, "See you tomorrow.")
    }

    // MARK: - .off level

    func testOffLevelVerbatimExceptPressEnter() {
        let result = apply("  um hello   world press enter  ", level: .off)
        XCTAssertEqual(result.text, "um hello   world")
        XCTAssertTrue(result.pressEnter)
        XCTAssertEqual(result.corrections, 0)
    }
}
