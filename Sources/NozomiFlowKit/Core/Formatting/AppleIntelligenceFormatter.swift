import Foundation
import FoundationModels

/// On-device LLM cleanup/generation via Apple's FoundationModels `SystemLanguageModel`.
/// Every entry point returns `nil` on failure -- unavailable model, guardrail
/// rejection, timeout, or malformed output -- so callers can fall back to the
/// rule-based result without ever throwing.
final class AppleIntelligenceFormatter {

    private static let cleanupTimeoutSeconds: UInt64 = 7

    /// One prewarmed session, keyed by its exact instructions. Consumed by the
    /// next matching cleanup request (sessions stay single-use so no transcript
    /// history accumulates across dictations).
    private var preparedSession: (instructions: String, session: LanguageModelSession)?

    var isAvailable: Bool {
        SystemLanguageModel.default.availability == .available
    }

    /// Human-readable status for Settings UI.
    var availabilityDescription: String {
        switch SystemLanguageModel.default.availability {
        case .available:
            return L10n.string("ai.status.ready")
        case .unavailable(let reason):
            switch reason {
            case .appleIntelligenceNotEnabled:
                return L10n.string("ai.status.off")
            case .deviceNotEligible:
                return L10n.string("ai.status.notEligible")
            case .modelNotReady:
                return L10n.string("ai.status.downloading")
            @unknown default:
                return L10n.string("ai.status.unavailable")
            }
        }
    }

    /// Warms up a session ahead of the first real request, if the model is available.
    func prewarm() {
        guard isAvailable else { return }
        let session = LanguageModelSession(instructions: CleanupInstructions.base)
        session.prewarm()
    }

    /// Builds + prewarms the session for a specific upcoming request (called at
    /// record start). If the eventual cleanup call carries the same instructions,
    /// it reuses this session and skips the instruction-prefill latency.
    func prepareSession(instructions: String) {
        guard isAvailable else { return }
        let session = LanguageModelSession(instructions: instructions)
        session.prewarm()
        preparedSession = (instructions, session)
    }

    /// Cleanup pass used by `FormatterPipeline.format` for `.full` formatting:
    /// rewrites `text` (already rule-cleaned) per `instructions`, then runs it
    /// through the shared LLM output sanity checks.
    func cleanup(text: String, instructions: String) async -> String? {
        guard !text.isEmpty else { return nil }
        guard let raw = await runSession(instructions: instructions, prompt: text, timeoutSeconds: Self.cleanupTimeoutSeconds) else {
            return nil
        }
        return LLMOutputValidator.validate(raw, rawLength: text.count)
    }

    /// Freeform generation used by `FormatterPipeline.applyCommand`: no rule-output
    /// baseline and no sanity-length ceiling, just a trimmed non-empty result or nil.
    func generate(instructions: String, prompt: String, timeoutSeconds: UInt64) async -> String? {
        guard let raw = await runSession(instructions: instructions, prompt: prompt, timeoutSeconds: timeoutSeconds) else {
            return nil
        }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    // MARK: - Session plumbing

    private func runSession(instructions: String, prompt: String, timeoutSeconds: UInt64) async -> String? {
        guard isAvailable else { return nil }
        // Take the prewarmed session when its instructions match; single-use.
        let session: LanguageModelSession
        if let prepared = preparedSession, prepared.instructions == instructions {
            session = prepared.session
            preparedSession = nil
        } else {
            session = LanguageModelSession(instructions: instructions)
        }
        return await race(timeoutSeconds: timeoutSeconds) {
            do {
                let response = try await session.respond(
                    to: prompt,
                    options: GenerationOptions(temperature: 0.2)
                )
                return response.content
            } catch {
                Log.format.error("Apple Intelligence request failed: \(error.localizedDescription)")
                return nil
            }
        }
    }

    /// Races `operation` against a `timeoutSeconds` sleep; whichever finishes first
    /// wins, and the loser is cancelled (best-effort -- FoundationModels calls are
    /// not guaranteed to observe cancellation instantly).
    private func race(timeoutSeconds: UInt64, operation: @escaping @Sendable () async -> String?) async -> String? {
        await withTaskGroup(of: String?.self) { group in
            group.addTask { await operation() }
            group.addTask {
                try? await Task.sleep(for: .seconds(timeoutSeconds))
                Log.format.notice("Apple Intelligence request exceeded \(timeoutSeconds)s timeout")
                return nil
            }
            let first = await group.next()
            group.cancelAll()
            if let first {
                return first
            }
            return nil
        }
    }
}
