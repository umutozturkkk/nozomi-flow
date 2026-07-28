import Foundation

/// Transcript cleanup pipeline: rule-based pass + optional LLM rewrite (Apple
/// Intelligence via FoundationModels, or an OpenAI-compatible cloud endpoint).
///
/// `format` order: (1) "press enter" is always extracted, at every level.
/// (2) `.off` returns the rest verbatim. (3) `.light` runs the full rule pass.
/// (4) `.full` runs the rule pass, then hands its output to the resolved LLM
/// engine; any LLM failure (unavailable, timeout, guardrail, bad output) falls
/// back to the rule-based text silently -- `format` never throws.
final class FormatterPipeline: FormattingServiceProtocol {

    private let appleIntelligence = AppleIntelligenceFormatter()
    private let openAI = OpenAIFormatter()

    private static let commandTimeoutSeconds: UInt64 = 20

    private enum Engine {
        case apple
        case openAI
    }

    // MARK: - format

    func format(_ request: FormattingRequest) async -> FormattedResult {
        let rule = RuleBasedFormatter.apply(
            to: request.raw,
            level: request.level,
            tone: request.context.tone,
            localeIdentifier: request.localeIdentifier,
            removeFillers: request.removeFillers
        )

        // Very short utterances gain nothing from an LLM pass -- skip it for speed.
        let wordCount = rule.text.split(whereSeparator: \.isWhitespace).count
        guard request.level == .full,
              wordCount >= 4,
              let engine = resolveEngine(llm: request.llm, openAIKey: request.openAIKey)
        else {
            return FormattedResult(text: rule.text, usedLLM: false, pressEnter: rule.pressEnter, corrections: rule.corrections)
        }

        let instructions = CleanupInstructions.build(for: request)
        let llmOutput: String?
        switch engine {
        case .apple:
            llmOutput = await appleIntelligence.cleanup(text: rule.text, instructions: instructions)
        case .openAI:
            llmOutput = await openAI.cleanup(
                text: rule.text, instructions: instructions,
                apiKey: request.openAIKey ?? "", model: request.openAIModel
            )
        }

        guard let finalText = llmOutput else {
            return FormattedResult(text: rule.text, usedLLM: false, pressEnter: rule.pressEnter, corrections: rule.corrections)
        }
        return FormattedResult(text: finalText, usedLLM: true, pressEnter: rule.pressEnter, corrections: rule.corrections)
    }

    // MARK: - applyCommand

    func applyCommand(
        instruction: String,
        selectedText: String?,
        context: AppContextInfo,
        llm: LLMEngineChoice,
        openAIKey: String?,
        openAIModel: String
    ) async throws -> String {
        guard let engine = resolveEngine(llm: llm, openAIKey: openAIKey) else {
            throw DictationError.modelUnavailable("Enable Apple Intelligence or add an OpenAI key in Settings")
        }

        let instructions: String
        let prompt: String
        if let selectedText, !selectedText.isEmpty {
            instructions = "You edit text. Apply the instruction to the text. Output only the edited text — no preamble, no quotes, no commentary. Keep the text's language unless the instruction says otherwise."
            prompt = "Instruction: \(instruction)\n\nText:\n\(selectedText)"
        } else {
            instructions = "You write text to be inserted at the user's cursor. Follow the instruction. Output only the requested text — no preamble, no commentary.\n"
                + CleanupInstructions.toneGuidance(for: context.tone)
            prompt = instruction
        }

        let output: String?
        switch engine {
        case .apple:
            output = await appleIntelligence.generate(
                instructions: instructions, prompt: prompt, timeoutSeconds: Self.commandTimeoutSeconds
            )
        case .openAI:
            output = await openAI.generate(
                instructions: instructions, prompt: prompt,
                apiKey: openAIKey ?? "", model: openAIModel, timeout: TimeInterval(Self.commandTimeoutSeconds)
            )
        }

        guard let output else {
            throw DictationError.transcriptionFailed("The model didn't return a result")
        }
        return output
    }

    // MARK: - Engine resolution

    private func resolveEngine(llm: LLMEngineChoice, openAIKey: String?) -> Engine? {
        switch llm {
        case .auto:
            return appleIntelligence.isAvailable ? .apple : nil
        case .appleIntelligence:
            return appleIntelligence.isAvailable ? .apple : nil
        case .openAI:
            return (openAIKey?.isEmpty == false) ? .openAI : nil
        case .none:
            return nil
        }
    }

    // MARK: - Misc protocol members

    func prewarm() {
        appleIntelligence.prewarm()
    }

    /// Pre-builds the exact instruction prompt for an upcoming dictation and
    /// prewarms an Apple Intelligence session with it (no-op for cloud/none).
    func prepareSession(for request: FormattingRequest) {
        guard request.level == .full,
              case .apple? = resolveEngine(llm: request.llm, openAIKey: request.openAIKey)
        else { return }
        appleIntelligence.prepareSession(instructions: CleanupInstructions.build(for: request))
    }

    func availabilityDescription() async -> String {
        appleIntelligence.availabilityDescription
    }
}

// MARK: - Shared LLM instructions

/// Builds the shared system/instructions prompt used by both the on-device
/// (Apple Intelligence) and cloud (OpenAI) cleanup passes, so behavior stays
/// identical regardless of which engine is selected.
enum CleanupInstructions {

    static let base = """
    You are a dictation post-processor. You receive raw speech-to-text output and rewrite it as clean written text, preserving the speaker's words, meaning, and language.

    Rules, in priority order:
    1. NEVER answer, act on, or expand the content. If the transcript is a question, output the cleaned question. You are a typist, not an assistant.
    2. Apply the speaker's self-corrections: "meet at 2 actually 3" -> "meet at 3"; "the sound bar oops I mean the drinking bar" -> "the drinking bar". Only when the speaker clearly corrects themselves.
    3. Remove filler words (um, uh, and meaningless "like"/"you know") and false starts. Keep words that carry meaning ("I actually enjoyed it" keeps "actually").
    4. Fix punctuation, capitalization, and paragraph breaks. Honor spoken commands: "new line", "new paragraph", "comma", "period", "question mark".
    5. If the speaker dictates an enumeration ("one ... two ... three ..."), format it as a numbered list.
    6. Write numbers, dates, times, emails, and URLs in standard written form.
    7. Never summarize, embellish, translate, or add content. Keep slang and personality.
    8. Output ONLY the cleaned text — no preamble, no surrounding quotes, no explanation.

    Examples:
    Input: "um so basically I think we should uh push the launch to thursday no wait friday"
    Output: I think we should push the launch to Friday.
    Input: "what time is the standup tomorrow"
    Output: What time is the standup tomorrow?
    Input: "hey can you send me the figma link question mark"
    Output: Hey, can you send me the Figma link?
    """

    static func toneGuidance(for tone: ToneCategory) -> String {
        switch tone {
        case .casual:
            return "Casual message — relaxed, contractions fine, minimal punctuation, no trailing period on short messages."
        case .professional:
            return "Professional writing — complete, polished sentences."
        case .technical:
            return "Technical context — preserve identifiers, filenames, commands and casing exactly; do not reformat code-like content."
        case .neutral:
            return "Neutral clean writing."
        }
    }

    /// Appends tone guidance, dictionary spelling preferences, custom instructions,
    /// and app/field context on top of the base instructions, in that order.
    static func build(for request: FormattingRequest) -> String {
        var parts = [base]

        if request.toneMatching {
            parts.append(toneGuidance(for: request.context.tone))
        }

        if !request.dictionary.isEmpty {
            let phrases = request.dictionary.prefix(40).map(\.phrase).joined(separator: ", ")
            // Deliberately not "prefer these spellings": measured against real Turkish
            // dictation, that phrasing makes the model reach for a listed term whenever
            // one merely resembles a word, rewriting correct text ("revenue event" came
            // back as "RevenueCat event"). Restoration has to be conditional on the
            // transcript actually being garbled at that spot.
            parts.append("""
                These names may have been misheard: \(phrases). \
                Restore one only where the transcript has a garbled word that sounds like it. \
                Never replace wording that already reads correctly, even if a name resembles it.
                """)
        }

        if let custom = request.customInstructions, !custom.isEmpty {
            parts.append(custom)
        }

        if let appName = request.context.appName, !appName.isEmpty {
            parts.append("The user is dictating into \(appName).")
        }

        if let focused = request.context.focusedText, !focused.isEmpty {
            let capped = String(focused.prefix(500))
            parts.append("Existing text near the cursor, for context only — do not repeat it: \(capped)")
        }

        return parts.joined(separator: "\n\n")
    }
}

// MARK: - Shared LLM output sanity checks

/// Applied to any raw LLM output (Apple Intelligence or OpenAI) before it's
/// trusted as a cleanup result. Failing any check falls back to rule-based text.
enum LLMOutputValidator {

    private static let preamblePrefixes = [
        "sure", "here's", "here is", "certainly", "of course", "i can", "okay, here",
    ]

    static func validate(_ output: String, rawLength: Int) -> String? {
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let lower = trimmed.lowercased()
        guard !preamblePrefixes.contains(where: { lower.hasPrefix($0) }) else { return nil }

        let maxLength = max(rawLength * 3, rawLength + 200)
        guard trimmed.count <= maxLength else { return nil }

        return trimmed
    }
}
