import Foundation
import Observation
import AppKit

/// Personal dictionary: canonical spellings + misheard variants, persisted as JSON
/// at `~/Library/Application Support/Murmur/dictionary.json`.
/// On first run (no file on disk yet) entries start empty -- no seed samples.
@MainActor
@Observable
final class PersonalDictionaryStore {
    private(set) var entries: [DictionaryEntry] = []

    @ObservationIgnored private let fileURL: URL
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private var terminationObserver: NSObjectProtocol?

    var enabledEntries: [DictionaryEntry] {
        entries.filter(\.isEnabled)
    }

    /// Words fed to the transcriber as contextual/boost vocabulary.
    var boostWords: [String] {
        enabledEntries.map(\.phrase)
    }

    /// - Parameter directory: Backing directory for `dictionary.json`. `nil` uses the
    ///   default per-user Application Support directory; tests inject a temp directory.
    init(directory: URL? = nil) {
        let dir = directory ?? Self.defaultDirectory()
        fileURL = dir.appendingPathComponent("dictionary.json")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        entries = Self.load(from: fileURL)

        terminationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: nil
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.flushNow()
            }
        }
    }

    deinit {
        if let terminationObserver {
            NotificationCenter.default.removeObserver(terminationObserver)
        }
    }

    private static func defaultDirectory() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        // Still "Murmur" after the rename to Nozomi Flow, on purpose: this path is
        // where existing dictionaries already live. Changing it would silently start
        // from an empty folder and strand the user's saved words.
        return base.appendingPathComponent("Murmur", isDirectory: true)
    }

    // MARK: - Mutations

    func add(_ entry: DictionaryEntry) {
        entries.append(entry)
        scheduleSave()
    }

    func update(_ entry: DictionaryEntry) {
        guard let idx = entries.firstIndex(where: { $0.id == entry.id }) else { return }
        entries[idx] = entry
        scheduleSave()
    }

    func delete(id: UUID) {
        let before = entries.count
        entries.removeAll { $0.id == id }
        guard entries.count != before else { return }
        scheduleSave()
    }

    // MARK: - Replacement engine

    /// Replaces misheard variants with their canonical phrase: case-insensitive,
    /// word-boundary matching (multi-word variants are boundary-anchored at both
    /// ends, not internally), longest-variant-first across all enabled entries so
    /// overlapping variants behave predictably, with light capitalization
    /// preservation at sentence starts / capitalized matches.
    func apply(to text: String) -> String {
        guard !text.isEmpty else { return text }

        var rules: [(variant: String, phrase: String)] = []
        for entry in entries where entry.isEnabled {
            for variant in entry.variants {
                let trimmed = variant.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { continue }
                rules.append((variant: trimmed, phrase: entry.phrase))
            }
        }
        guard !rules.isEmpty else { return text }
        // Longer variants first so e.g. "kernel panic" wins over "kernel" instead
        // of the shorter rule partially consuming the longer one first.
        rules.sort { $0.variant.count > $1.variant.count }

        var result = text
        for rule in rules {
            result = Self.applyRule(variant: rule.variant, phrase: rule.phrase, in: result)
        }
        return result
    }

    private static func applyRule(variant: String, phrase: String, in input: String) -> String {
        let escaped = NSRegularExpression.escapedPattern(for: variant)
        guard let regex = try? NSRegularExpression(pattern: "\\b\(escaped)\\b", options: [.caseInsensitive]) else {
            return input
        }
        let nsInput = input as NSString
        let matches = regex.matches(in: input, options: [], range: NSRange(location: 0, length: nsInput.length))
        guard !matches.isEmpty else { return input }

        var output = ""
        var cursor = 0
        for match in matches {
            let range = match.range
            guard range.location >= cursor else { continue } // defensive; matches are non-overlapping
            output += nsInput.substring(with: NSRange(location: cursor, length: range.location - cursor))
            let matched = nsInput.substring(with: range)
            output += replacement(matched: matched, phrase: phrase, in: nsInput, at: range.location)
            cursor = range.location + range.length
        }
        output += nsInput.substring(from: cursor)
        return output
    }

    /// Uppercases just the phrase's first letter when the matched text was itself
    /// capitalized, or the match sits at a sentence start, and the phrase's stored
    /// first letter is lowercase. Otherwise the phrase is used exactly as stored,
    /// which preserves intentional casing like "Kernl" or "iPhone".
    private static func replacement(matched: String, phrase: String, in text: NSString, at location: Int) -> String {
        guard let firstPhraseChar = phrase.first, firstPhraseChar.isLowercase else { return phrase }
        let matchedStartsUpper = matched.first?.isUppercase ?? false
        if matchedStartsUpper || isSentenceStart(in: text, before: location) {
            return firstPhraseChar.uppercased() + phrase.dropFirst()
        }
        return phrase
    }

    /// Walks backward from `location`, skipping whitespace, to see whether the match
    /// begins a sentence (start of text, or preceded by `.`/`!`/`?`).
    private static func isSentenceStart(in text: NSString, before location: Int) -> Bool {
        var i = location - 1
        while i >= 0 {
            guard let scalar = Unicode.Scalar(text.character(at: i)) else { return false }
            if CharacterSet.whitespacesAndNewlines.contains(scalar) {
                i -= 1
                continue
            }
            return scalar == "." || scalar == "!" || scalar == "?"
        }
        return true // reached the start of the text
    }

    // MARK: - Persistence

    private static func load(from url: URL) -> [DictionaryEntry] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        do {
            let data = try Data(contentsOf: url)
            return try JSONDecoder().decode([DictionaryEntry].self, from: data)
        } catch {
            Log.app.error("dictionary.json unreadable, quarantining: \(error.localizedDescription)")
            quarantineCorruptFile(at: url)
            return []
        }
    }

    private static func quarantineCorruptFile(at url: URL) {
        let suffix = Int(Date().timeIntervalSince1970 * 1000)
        let corruptURL = url.deletingLastPathComponent()
            .appendingPathComponent("\(url.lastPathComponent).corrupt-\(suffix)")
        try? FileManager.default.removeItem(at: corruptURL)
        try? FileManager.default.moveItem(at: url, to: corruptURL)
    }

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard !Task.isCancelled else { return }
            self?.performSave()
        }
    }

    /// Cancels any pending debounced save and writes synchronously right now.
    func flushNow() {
        saveTask?.cancel()
        saveTask = nil
        performSave()
    }

    private func performSave() {
        do {
            let data = try JSONEncoder().encode(entries)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            Log.app.error("failed to save dictionary.json: \(error.localizedDescription)")
        }
    }
}
