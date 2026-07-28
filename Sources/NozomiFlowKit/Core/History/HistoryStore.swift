import Foundation
import Observation
import AppKit

/// Dictation history + usage stats, persisted as JSON at
/// `~/Library/Application Support/Murmur/history.json`.
///
/// Mutations schedule a debounced save (~0.5s after the last change); `flushNow()`
/// writes synchronously and is used both on app termination and by tests so
/// persistence assertions aren't racy.
@MainActor
@Observable
final class HistoryStore {
    /// Newest-first.
    private(set) var entries: [HistoryEntry] = []

    /// Hard retention cap; oldest entries beyond this are dropped on `add`.
    static let capacity = 5_000

    @ObservationIgnored private let fileURL: URL
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private var terminationObserver: NSObjectProtocol?

    /// - Parameter directory: Backing directory for `history.json`. `nil` uses the
    ///   default per-user Application Support directory; tests inject a temp directory.
    init(directory: URL? = nil) {
        let dir = directory ?? Self.defaultDirectory()
        fileURL = dir.appendingPathComponent("history.json")
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
        // where existing history already lives. Changing it would silently start from
        // an empty folder and strand the user's past transcripts.
        return base.appendingPathComponent("Murmur", isDirectory: true)
    }

    // MARK: - Mutations

    func add(_ entry: HistoryEntry) {
        entries.insert(entry, at: 0)
        if entries.count > Self.capacity {
            entries.removeLast(entries.count - Self.capacity)
        }
        scheduleSave()
    }

    func delete(id: UUID) {
        let before = entries.count
        entries.removeAll { $0.id == id }
        guard entries.count != before else { return }
        scheduleSave()
    }

    func clear() {
        guard !entries.isEmpty else { return }
        entries.removeAll()
        scheduleSave()
    }

    func search(_ query: String) -> [HistoryEntry] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return entries }
        return entries.filter {
            $0.finalText.lowercased().contains(q)
                || $0.rawText.lowercased().contains(q)
                || ($0.appName?.lowercased().contains(q) ?? false)
        }
    }

    // MARK: - Stats

    var stats: UsageStats {
        var s = UsageStats()
        s.totalSessions = entries.count
        s.totalWords = entries.reduce(0) { $0 + $1.wordCount }
        s.totalSpokenSeconds = entries.reduce(0) { $0 + $1.durationSeconds }
        if s.totalSpokenSeconds > 0 {
            s.averageWPM = Double(s.totalWords) / (s.totalSpokenSeconds / 60)
        }
        s.minutesSaved = max(0, Double(s.totalWords) / 40.0 - s.totalSpokenSeconds / 60)
        s.totalCorrections = entries.reduce(0) { $0 + $1.correctionsCount }

        let cal = Calendar.current
        s.wordsToday = entries.filter { cal.isDateInToday($0.date) }.reduce(0) { $0 + $1.wordCount }
        let days = Set(entries.map { cal.startOfDay(for: $0.date) })
        s.streakDays = Self.streak(days: days, today: Date(), calendar: cal)
        return s
    }

    /// Pure, unit-testable streak calculation. `days` holds one `startOfDay` value per
    /// calendar day with >=1 entry. Counts consecutive days backward from `today`'s
    /// start: an empty today does not yet break an in-progress streak (it just doesn't
    /// extend it), but an empty yesterday does -- unless today itself has an entry.
    static func streak(days: Set<Date>, today: Date, calendar: Calendar) -> Int {
        var cursor = calendar.startOfDay(for: today)
        if !days.contains(cursor) {
            guard let yesterday = calendar.date(byAdding: .day, value: -1, to: cursor),
                  days.contains(yesterday) else { return 0 }
            cursor = yesterday
        }
        var count = 0
        while days.contains(cursor) {
            count += 1
            guard let previous = calendar.date(byAdding: .day, value: -1, to: cursor) else { break }
            cursor = previous
        }
        return count
    }

    /// Zero-filled daily word counts for the last `lastNDays` days (oldest -> newest),
    /// keyed by `startOfDay`. Feeds a future heatmap UI.
    func wordsByDay(lastNDays: Int) -> [(date: Date, words: Int)] {
        guard lastNDays > 0 else { return [] }
        let cal = Calendar.current
        let todayStart = cal.startOfDay(for: Date())
        var buckets: [Date: Int] = [:]
        for entry in entries {
            let day = cal.startOfDay(for: entry.date)
            buckets[day, default: 0] += entry.wordCount
        }
        return (0..<lastNDays).map { i in
            let offset = lastNDays - 1 - i
            let day = cal.date(byAdding: .day, value: -offset, to: todayStart) ?? todayStart
            return (date: day, words: buckets[day] ?? 0)
        }
    }

    // MARK: - Persistence

    private static func load(from url: URL) -> [HistoryEntry] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        do {
            let data = try Data(contentsOf: url)
            return try JSONDecoder().decode([HistoryEntry].self, from: data)
        } catch {
            Log.app.error("history.json unreadable, quarantining: \(error.localizedDescription)")
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
            Log.app.error("failed to save history.json: \(error.localizedDescription)")
        }
    }
}
