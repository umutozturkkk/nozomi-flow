import Foundation

/// Cloud LLM cleanup/generation via an OpenAI-compatible chat-completions endpoint,
/// using the user's own API key. Every entry point returns `nil` on failure --
/// network error, non-200 status, or malformed body -- so callers can fall back
/// without ever throwing.
final class OpenAIFormatter {

    private static let endpoint = URL(string: "https://api.openai.com/v1/chat/completions")!
    private static let cleanupTimeout: TimeInterval = 15

    /// Cleanup pass used by `FormatterPipeline.format` for `.full` formatting:
    /// same shared instructions as Apple Intelligence, transcript as the user
    /// message, then the shared LLM output sanity checks.
    func cleanup(text: String, instructions: String, apiKey: String, model: String) async -> String? {
        guard !text.isEmpty else { return nil }
        guard let raw = await complete(
            systemInstructions: instructions, userPrompt: text,
            apiKey: apiKey, model: model, timeout: Self.cleanupTimeout
        ) else {
            return nil
        }
        return LLMOutputValidator.validate(raw, rawLength: text.count)
    }

    /// Freeform generation used by `FormatterPipeline.applyCommand`: no rule-output
    /// baseline and no sanity-length ceiling, just a trimmed non-empty result or nil.
    func generate(instructions: String, prompt: String, apiKey: String, model: String, timeout: TimeInterval) async -> String? {
        guard let raw = await complete(
            systemInstructions: instructions, userPrompt: prompt,
            apiKey: apiKey, model: model, timeout: timeout
        ) else {
            return nil
        }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    // MARK: - Chat completions request

    private func complete(
        systemInstructions: String,
        userPrompt: String,
        apiKey: String,
        model: String,
        timeout: TimeInterval
    ) async -> String? {
        guard !apiKey.isEmpty else { return nil }

        var request = URLRequest(url: Self.endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = timeout

        let body: [String: Any] = [
            "model": model,
            "messages": [
                ["role": "system", "content": systemInstructions],
                ["role": "user", "content": userPrompt],
            ],
            "temperature": 0.2,
        ]
        guard let payload = try? JSONSerialization.data(withJSONObject: body) else { return nil }
        request.httpBody = payload

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                Log.format.error("OpenAI request failed with non-200 status")
                return nil
            }
            guard
                let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                let choices = json["choices"] as? [[String: Any]],
                let message = choices.first?["message"] as? [String: Any],
                let content = message["content"] as? String
            else {
                Log.format.error("OpenAI response body was not the expected shape")
                return nil
            }
            return content
        } catch {
            Log.format.error("OpenAI request failed: \(error.localizedDescription)")
            return nil
        }
    }
}
