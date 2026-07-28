import XCTest
import FoundationModels
@testable import NozomiFlowKit

/// `FormatterPipeline`-level tests: engine selection, command mode, and one real
/// on-device Apple Intelligence integration test. Pure rule-pipeline behavior is
/// covered in FormattingRuleTests.swift.
final class FormattingPipelineTests: XCTestCase {

    private func request(
        raw: String,
        level: FormattingLevel,
        llm: LLMEngineChoice,
        tone: ToneCategory = .neutral
    ) -> FormattingRequest {
        FormattingRequest(
            raw: raw,
            context: AppContextInfo(tone: tone),
            level: level,
            llm: llm,
            dictionary: [],
            localeIdentifier: "en_US"
        )
    }

    // MARK: - format(): level gating

    func testFormatOffLevelViaPipeline() async {
        let pipeline = FormatterPipeline()
        let result = await pipeline.format(request(raw: "um hello press enter", level: .off, llm: .auto))
        XCTAssertEqual(result.text, "um hello")
        XCTAssertTrue(result.pressEnter)
        XCTAssertFalse(result.usedLLM)
        XCTAssertEqual(result.corrections, 0)
    }

    func testFormatFullLevelWithNoLLMFallsBackToRules() async {
        let pipeline = FormatterPipeline()
        let result = await pipeline.format(request(raw: "um I think uh this is correct", level: .full, llm: .none))
        XCTAssertEqual(result.text, "I think this is correct.")
        XCTAssertFalse(result.usedLLM)
        XCTAssertEqual(result.corrections, 2)
    }

    func testFormatLightLevelNeverInvokesLLMRegardlessOfEngine() async {
        let pipeline = FormatterPipeline()
        // .light should never touch an LLM, even if .auto could resolve to one.
        let result = await pipeline.format(request(raw: "hello world", level: .light, llm: .auto))
        XCTAssertEqual(result.text, "Hello world.")
        XCTAssertFalse(result.usedLLM)
    }

    // MARK: - applyCommand(): engine resolution

    func testApplyCommandThrowsWhenNoEngineAvailable() async {
        let pipeline = FormatterPipeline()
        do {
            _ = try await pipeline.applyCommand(
                instruction: "make this shorter",
                selectedText: "some text",
                context: AppContextInfo(),
                llm: .none,
                openAIKey: nil,
                openAIModel: "gpt-4o-mini"
            )
            XCTFail("Expected DictationError.modelUnavailable to be thrown")
        } catch DictationError.modelUnavailable(let message) {
            XCTAssertEqual(message, "Enable Apple Intelligence or add an OpenAI key in Settings")
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    // MARK: - Availability

    func testAvailabilityDescriptionIsNonEmpty() async {
        let pipeline = FormatterPipeline()
        let description = await pipeline.availabilityDescription()
        XCTAssertFalse(description.isEmpty)
    }

    // MARK: - Real Apple Intelligence integration (skips if unavailable)

    func testAppleIntelligenceIntegrationCleansFillersRealistically() async throws {
        try XCTSkipUnless(
            SystemLanguageModel.default.availability == .available,
            "Apple Intelligence not available on this machine"
        )

        let pipeline = FormatterPipeline()
        let result = await pipeline.format(request(
            raw: "um so basically I think uh we should launch on friday",
            level: .full,
            llm: .appleIntelligence
        ))

        XCTAssertFalse(result.text.isEmpty)
        XCTAssertFalse(result.text.lowercased().contains(" um "))
        XCTAssertFalse(result.text.lowercased().contains(" uh "))
    }
}
