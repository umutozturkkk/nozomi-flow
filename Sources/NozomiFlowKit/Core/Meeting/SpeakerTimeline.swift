import Foundation

/// Accumulates caption observations and decides who is speaking.
///
/// Pure, so the debounce and staleness rules are testable without a call. Both
/// exist to protect the recorder from the caption engine's noise: a stray line
/// during crosstalk must not slice the audio, and a long silence must not keep
/// attributing the room to whoever last spoke.
struct SpeakerTimeline {

    /// How long a new name has to keep appearing before it is believed. Meet's
    /// caption engine briefly misattributes on crosstalk, and every confirmed change
    /// cuts a chunk, so a false one costs a wrongly labelled turn.
    var minimumHoldSeconds: TimeInterval = 1.5

    /// With no caption for this long, nobody is speaking. Without it the last
    /// speaker would silently own every pause in the meeting.
    var staleAfter: TimeInterval = 6

    /// What the meeting UI calls the person at this Mac.
    ///
    /// Meet captions everyone on the call, including the local participant, so
    /// without this the app would cut and label the *remote* track every time its own
    /// user spoke, attributing their audio to a track that never carried it. Matching
    /// depends on the name in Settings matching the one in the meeting app, which is
    /// what that setting's help text asks for. A mismatch costs a mislabelled turn,
    /// not a broken recording.
    var localName: String?

    private(set) var confirmed: String?
    /// Remote participants only. The local user is known separately and would
    /// otherwise be listed twice under two spellings.
    private(set) var roster: [String] = []

    private var rosterKeys: Set<String> = []
    private var candidate: String?
    private var candidateSince: Date?
    private var lastObservedAt: Date?

    /// Records an observation and returns the newly confirmed speaker, or nil when
    /// nothing changed. A return value is a boundary: the caller cuts audio on it.
    mutating func record(_ observation: CaptionObservation) -> String? {
        lastObservedAt = observation.observedAt
        remember(observation.speaker)

        let key = MeetCaptionParser.fold(observation.speaker)
        if let confirmed, MeetCaptionParser.fold(confirmed) == key {
            // Still the same person; whatever was building loses its case.
            candidate = nil
            candidateSince = nil
            return nil
        }

        guard let candidate, MeetCaptionParser.fold(candidate) == key, let candidateSince else {
            self.candidate = observation.speaker
            self.candidateSince = observation.observedAt
            return nil
        }

        guard observation.observedAt.timeIntervalSince(candidateSince) >= minimumHoldSeconds else {
            return nil
        }
        confirmed = candidate
        self.candidate = nil
        self.candidateSince = nil
        return confirmed
    }

    /// Names from the participant panel. They belong in the roster even though they
    /// never produce a caption: someone who sat silent is still in the room, and the
    /// summarizer's job is easier when it knows the whole cast.
    mutating func noteRoster(_ names: [String]) {
        for name in names { remember(name) }
    }

    /// Who is speaking as of `moment`, or nil once the captions have gone quiet.
    func speaker(at moment: Date) -> String? {
        guard let lastObservedAt, moment.timeIntervalSince(lastObservedAt) < staleAfter else {
            return nil
        }
        return confirmed
    }

    /// Whether a caption names the person at this Mac rather than someone on the far
    /// side of the call. Their audio is on the microphone track, so the remote track
    /// must not be labelled with it.
    func isLocal(_ name: String) -> Bool {
        guard let localName, !localName.isEmpty else { return false }
        return MeetCaptionParser.fold(localName) == MeetCaptionParser.fold(name)
    }

    private mutating func remember(_ name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !isLocal(trimmed) else { return }
        let key = MeetCaptionParser.fold(trimmed)
        guard !rosterKeys.contains(key) else { return }
        rosterKeys.insert(key)
        roster.append(trimmed)
    }
}
