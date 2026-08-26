import Foundation

/// Uploads recorded meeting chunks and returns them as transcribed segments.
///
/// Chunks are independent, so they go up concurrently, but only a few at a time:
/// a long meeting can produce dozens and firing them all at once earns rate limits
/// rather than speed. Results are gathered by chunk identity rather than completion
/// order, since the transcript's correctness depends entirely on offsets.
final class MeetingTranscriber {

    /// Fired as each chunk comes back, so a transcript can fill in while a meeting
    /// is still running.
    var onSegment: ((MeetingSegment) -> Void)?

    private let config: CloudTranscriptionConfig
    private let languageCode: String?
    private let maximumConcurrent: Int

    init(config: CloudTranscriptionConfig, locale: Locale, maximumConcurrent: Int = 3) {
        self.config = config
        self.languageCode = locale.language.languageCode?.identifier
        self.maximumConcurrent = max(1, maximumConcurrent)
    }

    /// Transcribes every chunk. Chunks that fail are dropped from the result rather
    /// than failing the meeting: losing two minutes of one track still leaves a
    /// usable transcript, whereas throwing away the whole recording does not.
    func transcribe(_ chunks: [MeetingChunk]) async -> [MeetingSegment] {
        guard config.isUsable else {
            Log.asr.error("meeting transcription needs a configured cloud endpoint")
            return []
        }

        var segments: [MeetingSegment] = []
        for batch in chunks.chunked(into: maximumConcurrent) {
            await withTaskGroup(of: MeetingSegment?.self) { group in
                for chunk in batch {
                    group.addTask { [weak self] in await self?.transcribe(chunk) ?? nil }
                }
                for await segment in group {
                    guard let segment else { continue }
                    segments.append(segment)
                    onSegment?(segment)
                }
            }
        }
        return segments.sorted { ($0.startOffset, $0.track.rawValue) < ($1.startOffset, $1.track.rawValue) }
    }

    private func transcribe(_ chunk: MeetingChunk) async -> MeetingSegment? {
        guard let audio = try? Data(contentsOf: chunk.url) else {
            Log.asr.error("meeting chunk unreadable: \(chunk.url.lastPathComponent)")
            return nil
        }

        var fields = ["model": config.model]
        if let languageCode { fields["language"] = languageCode }
        let (body, contentType) = CloudTranscriptionSession.multipart(
            fields: fields, filename: chunk.url.lastPathComponent, audio: audio)

        var request = URLRequest(url: config.endpoint)
        request.httpMethod = "POST"
        request.setValue("Bearer \(config.apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        // Generous: a two minute chunk on a slow link still has to land.
        request.timeoutInterval = 180

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                let status = (response as? HTTPURLResponse)?.statusCode ?? -1
                Log.asr.error("meeting chunk \(chunk.url.lastPathComponent) returned \(status)")
                return nil
            }
            guard
                let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                let text = json["text"] as? String
            else { return nil }

            return MeetingSegment(
                track: chunk.track,
                startOffset: chunk.startOffset,
                duration: chunk.duration,
                text: text.trimmingCharacters(in: .whitespacesAndNewlines),
                speaker: chunk.speaker
            )
        } catch {
            Log.asr.error("meeting chunk upload failed: \(error.localizedDescription)")
            return nil
        }
    }
}

extension Array {
    /// Fixed-size batches, used to bound how many uploads are in flight at once.
    func chunked(into size: Int) -> [[Element]] {
        guard size > 0 else { return [self] }
        return stride(from: 0, to: count, by: size).map { Array(self[$0..<Swift.min($0 + size, count)]) }
    }
}
