import Foundation

/// Turns the raw text of a meeting's caption region into speaker observations.
///
/// Pure and synchronous so the rules can be tested without a browser, a call or
/// permissions, which is the only practical way to test them at all.
///
/// The region is a rolling buffer, not an event stream. Two reads a second apart
/// mostly overlap and the newest line grows word by word:
///
///     read at t+0:  Ahmet: bugün toplantıda
///     read at t+1:  Ahmet: bugün toplantıda konuşacağımız
///
/// So this reconciles rather than accumulates: it remembers what it last saw from
/// each speaker and emits only what is new.
///
/// Sources hand it one line per caption in `Name: text` form. A source whose UI
/// exposes the name and the words as separate elements joins them itself, which
/// keeps the platform's layout out of these rules.
struct MeetCaptionParser {

    /// Longer than this and the text before the colon is a sentence, not a name.
    static let maximumNameLength = 60
    /// Nor do names run to five words. This is what rejects "so the deal is this:",
    /// which the length and punctuation guards both let through.
    static let maximumNameWords = 4
    /// Shorter than this and there is nothing worth attributing.
    static let minimumTextLength = 3

    /// Last text seen from each speaker, keyed by folded name. Bounded by the number
    /// of people on the call, so a three hour meeting costs no more than a three
    /// minute one.
    private var lastText: [String: String] = [:]
    /// First spelling seen for each folded name, so display keeps the platform's
    /// capitalization rather than whichever variant arrived last.
    private var displayName: [String: String] = [:]

    /// Reconciles one read of the caption region against the previous one.
    mutating func ingest(_ raw: String, at moment: Date) -> [CaptionObservation] {
        var fresh: [CaptionObservation] = []
        for line in raw.split(whereSeparator: \.isNewline) {
            guard let parsed = Self.parseLine(String(line)) else { continue }

            let key = Self.fold(parsed.speaker)
            let name = displayName[key] ?? parsed.speaker
            displayName[key] = name

            guard let addition = Self.newContent(previous: lastText[key], current: parsed.text) else {
                continue
            }
            lastText[key] = parsed.text
            fresh.append(CaptionObservation(speaker: name, text: addition, observedAt: moment))
        }
        return fresh
    }

    /// Splits `Name: text`, or returns nil when the line is not a caption.
    ///
    /// The guards exist for speech that merely contains a colon: "so the deal is
    /// this: we ship Monday" must not create a speaker called "so the deal is this".
    static func parseLine(_ line: String) -> (speaker: String, text: String)? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard let colon = trimmed.firstIndex(of: ":") else { return nil }

        let speaker = String(trimmed[trimmed.startIndex..<colon]).trimmingCharacters(in: .whitespaces)
        let text = String(trimmed[trimmed.index(after: colon)...]).trimmingCharacters(in: .whitespaces)

        guard !speaker.isEmpty, speaker.count <= maximumNameLength else { return nil }
        guard speaker.rangeOfCharacter(from: Self.notInNames) == nil else { return nil }
        guard looksLikeName(speaker) else { return nil }
        guard text.count >= minimumTextLength else { return nil }
        return (speaker, text)
    }

    /// Whether a colon-prefixed phrase is plausibly somebody's display name.
    ///
    /// Length and punctuation are not enough on their own: "Sonuç şu: pazartesi
    /// çıkıyoruz" is short, unpunctuated, two words, and would otherwise put a
    /// speaker called "Sonuç şu" in the notes. Capitalization is what separates a
    /// name from a phrase, since display names capitalize every word and sentences
    /// only capitalize the first.
    ///
    /// The known cost: a display name written entirely in lower case is not
    /// recognized, and that person's turns fall back to the track label. A missing
    /// name is a far better failure than an invented one.
    static func looksLikeName(_ candidate: String) -> Bool {
        let words = candidate.split(separator: " ")
        guard !words.isEmpty, words.count <= maximumNameWords else { return false }
        guard words[0].first?.isUppercase == true else { return false }

        return words.dropFirst().allSatisfy { word in
            word.first?.isUppercase == true || nameParticles.contains(word.lowercased())
        }
    }

    /// The parts of a name that are conventionally lower case.
    private static let nameParticles: Set<String> = [
        "van", "von", "de", "del", "della", "di", "da", "dos", "du",
        "la", "le", "bin", "bint", "ibn", "al", "ter", "ten", "op",
    ]

    /// What is new in `current` given `previous`, or nil when nothing is.
    ///
    /// Exactness is not critical here. The text drives change detection, not the
    /// transcript, so a caption the platform silently revised may be emitted twice.
    /// That costs one redundant observation of a speaker who is already speaking,
    /// which the timeline absorbs. Emitting the wrong *speaker* would matter; this
    /// does not.
    static func newContent(previous: String?, current: String) -> String? {
        guard let previous, !previous.isEmpty else { return current }

        let shared = commonPrefixLength(previous, current)
        // Nothing beyond what was already reported.
        if current.count <= shared { return nil }
        // Enough overlap that this is the same utterance still being typed out.
        if shared >= max(8, previous.count / 2) {
            let tail = String(Array(current)[shared...]).trimmingCharacters(in: .whitespaces)
            return tail.isEmpty ? nil : tail
        }
        // Too little overlap to be the same sentence: the speaker started a new one.
        return current
    }

    static func commonPrefixLength(_ a: String, _ b: String) -> Int {
        var count = 0
        for (left, right) in zip(a, b) {
            guard left == right else { break }
            count += 1
        }
        return count
    }

    /// Case and diacritic insensitive, so one person is one person across reads.
    /// A fixed locale rather than the user's: this compares two strings the same UI
    /// produced, and locale-sensitive folding would make that depend on where the
    /// Mac happens to be.
    static func fold(_ name: String) -> String {
        name.folding(
            options: [.caseInsensitive, .diacriticInsensitive],
            locale: Locale(identifier: "en_US_POSIX"))
    }

    /// Sentence punctuation never appears in a name, and reliably appears in speech.
    private static let notInNames = CharacterSet(charactersIn: ".!?\n\t")
}
