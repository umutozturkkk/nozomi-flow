import Foundation

/// One transcribed chunk, still attached to the track and moment it came from.
struct MeetingSegment: Equatable {
    let track: MeetingTrack
    let startOffset: TimeInterval
    let duration: TimeInterval
    let text: String

    var endOffset: TimeInterval { startOffset + duration }
}

/// A speaker's turn in the merged transcript.
struct TranscriptLine: Equatable {
    let speaker: String
    let startOffset: TimeInterval
    let text: String
}

/// Weaves the two independently transcribed tracks back into one ordered transcript.
///
/// Granularity is the chunk, not the sentence. The transcription endpoint returns
/// only text: `response_format=verbose_json` is rejected and plain json carries no
/// segments, so there are no word or phrase timestamps to interleave on. A turn is
/// therefore as precise as the chunk that contains it, which is enough for a summary
/// to attribute points correctly but will not reproduce rapid back-and-forth
/// verbatim. Shortening the chunk target trades transcription context for finer
/// turns; splitting on every utterance would be finer still at the cost of many more
/// requests, each billed at the provider's ten second minimum.
enum MeetingTranscript {

    /// Orders segments by when they were spoken and coalesces consecutive turns from
    /// the same speaker, so one person talking across three chunks reads as one turn
    /// rather than three.
    static func merge(_ segments: [MeetingSegment]) -> [TranscriptLine] {
        let spoken = segments
            .filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            // Track breaks the tie so a mic and system chunk starting together always
            // order the same way, rather than depending on which upload finished first.
            .sorted { ($0.startOffset, $0.track.rawValue) < ($1.startOffset, $1.track.rawValue) }

        var lines: [TranscriptLine] = []
        for segment in spoken {
            let text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if let last = lines.last, last.speaker == segment.track.speakerLabel {
                lines[lines.count - 1] = TranscriptLine(
                    speaker: last.speaker,
                    startOffset: last.startOffset,
                    text: last.text + " " + text
                )
            } else {
                lines.append(TranscriptLine(
                    speaker: segment.track.speakerLabel,
                    startOffset: segment.startOffset,
                    text: text
                ))
            }
        }
        return lines
    }

    /// Renders the transcript as markdown, which is what gets written to disk and
    /// handed to the summarizer.
    static func markdown(_ lines: [TranscriptLine]) -> String {
        lines
            .map { "**\(timestamp($0.startOffset)) \($0.speaker):** \($0.text)" }
            .joined(separator: "\n\n")
    }

    /// mm:ss, or h:mm:ss once a meeting runs past an hour.
    static func timestamp(_ offset: TimeInterval) -> String {
        let total = max(0, Int(offset.rounded(.down)))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let seconds = total % 60
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, seconds)
            : String(format: "%d:%02d", minutes, seconds)
    }
}
