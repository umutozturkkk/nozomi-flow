import Foundation

/// One caption line as the meeting UI rendered it: who the platform says is
/// speaking, and the words it attributed to them.
///
/// The text is kept even though the transcript comes from the cloud endpoint. It is
/// what lets the parser tell a line that grew from a line that is genuinely new,
/// which is the difference between one turn and forty duplicates of it.
struct CaptionObservation: Equatable {
    let speaker: String
    let text: String
    let observedAt: Date
}

/// Watches a meeting window and reports who is speaking.
///
/// The whole point of this protocol is that everything downstream of it, the
/// parser, the timeline, the chunk boundaries and the notes, is written once and
/// does not care whether the names came from an accessibility tree, recognized
/// text, or a browser extension. Reading the screen is the uncertain part of this
/// feature, so it is the only part behind an interface.
protocol MeetingSpeakerSource: AnyObject {
    /// Fired for each newly observed caption line, never for a line already seen.
    var onCaption: ((CaptionObservation) -> Void)? { get set }

    /// Fired when the participant roster changes. Separate from captions because the
    /// roster includes people who never say a word, and they still belong in the
    /// notes' vocabulary.
    var onRoster: (([String]) -> Void)? { get set }

    func start() async throws
    func stop()
}

/// Why a speaker source could not attach. Never surfaced to the user: a meeting
/// that records without names is still a good meeting, and an alert as a call
/// begins is worse than a slightly weaker note.
enum MeetingSpeakerSourceError: Error, Equatable {
    case noSupportedBrowser
    case accessibilityDenied
    case noMeetingWindow
}
