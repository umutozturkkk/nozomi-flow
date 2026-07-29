import Foundation

/// Turns a merged transcript into meeting notes via a chat model.
///
/// Deliberately returns the model's markdown rather than parsing it into fields:
/// every parser here is another way to lose the notes entirely when a model
/// phrases a heading differently, and the notes are read by a person, not code.
struct MeetingSummarizer {

    /// The transcript already carries speaker labels, so the model is told what they
    /// mean rather than being left to guess that "Them" is one or many people. The
    /// instruction to leave gaps alone matters: a chunk that failed to upload shows
    /// up as missing conversation, and inventing the bridge would be worse than
    /// admitting it.
    static let instructions = """
        You write meeting notes from a transcript.

        The transcript labels two sides. "You" is the person whose microphone was
        recording. "Them" is everyone else on the call, possibly several people on
        one channel. Timestamps mark when each turn began.

        Write, in the language the meeting was held in:

        ## Summary
        A short paragraph on what the meeting was about and where it landed.

        ## Decisions
        What was actually settled. Omit the section entirely if nothing was.

        ## Action items
        One line each, naming who owns it when the transcript says so. Omit the
        section entirely if there are none.

        ## Open questions
        Anything raised and left unresolved. Omit the section if there is nothing.

        Ground every line in the transcript. Do not invent owners, dates or numbers
        that were not said. If part of the conversation is clearly missing, say so
        plainly rather than filling the gap. Reply with the notes and nothing else.
        """

    /// A summary far shorter than this is a truncated response, not a concise one,
    /// and would silently replace real notes with a fragment.
    static let minimumUsefulCharacters = 40

    private let config: CloudTranscriptionConfig
    private let model: String

    init(config: CloudTranscriptionConfig, model: String) {
        self.config = config
        self.model = model
    }

    /// Returns nil rather than throwing: a meeting whose summary failed is still
    /// worth keeping for its transcript.
    func summarize(transcript: String) async -> String? {
        guard config.isUsable, !model.isEmpty else { return nil }
        let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let body: [String: Any] = [
            "model": model,
            "messages": [
                ["role": "system", "content": Self.instructions],
                ["role": "user", "content": trimmed],
            ],
            "temperature": 0.2,
        ]
        guard let payload = try? JSONSerialization.data(withJSONObject: body) else { return nil }

        var request = URLRequest(url: Self.chatEndpoint(for: config.endpoint))
        request.httpMethod = "POST"
        request.setValue("Bearer \(config.apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = payload
        request.timeoutInterval = 180

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                let status = (response as? HTTPURLResponse)?.statusCode ?? -1
                Log.format.error("meeting summary returned \(status)")
                return nil
            }
            guard
                let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                let choices = json["choices"] as? [[String: Any]],
                let message = choices.first?["message"] as? [String: Any],
                let content = message["content"] as? String
            else { return nil }

            return Self.validate(content)
        } catch {
            Log.format.error("meeting summary failed: \(error.localizedDescription)")
            return nil
        }
    }

    /// Rejects a response too short to be notes. The same guard exists on the
    /// dictation cleanup path, where a model once returned four words of a sentence.
    static func validate(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= minimumUsefulCharacters else { return nil }
        return trimmed
    }

    /// The transcription and chat endpoints share a host, so the summary follows
    /// whatever base the user configured instead of hardcoding a second provider.
    static func chatEndpoint(for transcription: URL) -> URL {
        transcription
            .deletingLastPathComponent()   // .../audio
            .deletingLastPathComponent()   // .../v1
            .appendingPathComponent("chat")
            .appendingPathComponent("completions")
    }
}
