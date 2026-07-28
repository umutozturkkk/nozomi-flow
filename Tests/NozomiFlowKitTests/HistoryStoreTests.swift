import XCTest
@testable import NozomiFlowKit

final class HistoryStoreTests: XCTestCase {
    private var tempDir: URL!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("murmur-history-tests-\(UUID().uuidString)")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
        tempDir = nil
        super.tearDown()
    }

    private func makeEntry(
        date: Date = Date(),
        rawText: String = "raw text",
        finalText: String = "final text",
        appName: String? = "TestApp",
        duration: Double = 2.0,
        wordCount: Int = 2,
        corrections: Int = 0
    ) -> HistoryEntry {
        HistoryEntry(
            date: date, rawText: rawText, finalText: finalText,
            appName: appName, appBundleID: "com.test.app",
            durationSeconds: duration, wordCount: wordCount,
            mode: "dictation", engine: "speechAnalyzer", correctionsCount: corrections
        )
    }

    // MARK: - Persistence round-trip

    @MainActor
    func testAddPersistReloadRoundTrip() {
        let store1 = HistoryStore(directory: tempDir)
        let entry = makeEntry(rawText: "hello there", finalText: "Hello there.", wordCount: 2)
        store1.add(entry)
        store1.flushNow()

        let store2 = HistoryStore(directory: tempDir)
        XCTAssertEqual(store2.entries.count, 1)
        XCTAssertEqual(store2.entries.first, entry)
    }

    @MainActor
    func testEmptyStoreCreatesDirectoryAndStartsEmpty() {
        let store = HistoryStore(directory: tempDir)
        XCTAssertTrue(store.entries.isEmpty)
        var isDir: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: tempDir.path, isDirectory: &isDir))
        XCTAssertTrue(isDir.boolValue)
    }

    // MARK: - Cap enforcement

    @MainActor
    func testCapEnforcementDropsOldest() {
        let store = HistoryStore(directory: tempDir)
        let total = HistoryStore.capacity + 10
        for i in 0..<total {
            store.add(makeEntry(date: Date(timeIntervalSince1970: Double(i)), rawText: "e\(i)", finalText: "entry \(i)"))
        }
        XCTAssertEqual(store.entries.count, HistoryStore.capacity)
        // Newest-first; the 10 oldest (entry 0...9) should have been dropped.
        XCTAssertEqual(store.entries.first?.finalText, "entry \(total - 1)")
        XCTAssertEqual(store.entries.last?.finalText, "entry 10")
    }

    // MARK: - Search

    @MainActor
    func testSearchMatchesFinalRawAndAppNameCaseInsensitively() {
        let store = HistoryStore(directory: tempDir)
        store.add(makeEntry(rawText: "raw alpha", finalText: "Final Alpha.", appName: "Notes"))
        store.add(makeEntry(rawText: "raw beta", finalText: "Final Beta.", appName: "Slack"))

        XCTAssertEqual(store.search("alpha").count, 1)
        XCTAssertEqual(store.search("ALPHA").count, 1)
        XCTAssertEqual(store.search("raw beta").count, 1)
        XCTAssertEqual(store.search("slack").count, 1)
        XCTAssertEqual(store.search("").count, 2)
        XCTAssertEqual(store.search("nonexistent").count, 0)
    }

    // MARK: - Stats

    @MainActor
    func testStatsMath() {
        let store = HistoryStore(directory: tempDir)
        store.add(makeEntry(duration: 60, wordCount: 40, corrections: 2))
        store.add(makeEntry(duration: 60, wordCount: 60, corrections: 3))

        let stats = store.stats
        XCTAssertEqual(stats.totalSessions, 2)
        XCTAssertEqual(stats.totalWords, 100)
        XCTAssertEqual(stats.totalSpokenSeconds, 120, accuracy: 0.001)
        // averageWPM = totalWords / (totalSpokenSeconds/60) = 100 / 2 = 50
        XCTAssertEqual(stats.averageWPM, 50, accuracy: 0.001)
        XCTAssertEqual(stats.totalCorrections, 5)
        // minutesSaved = totalWords/40 - totalSpokenSeconds/60 = 2.5 - 2.0 = 0.5
        XCTAssertEqual(stats.minutesSaved, 0.5, accuracy: 0.001)
        XCTAssertEqual(stats.wordsToday, 100)
    }

    @MainActor
    func testStatsMinutesSavedNeverNegative() {
        let store = HistoryStore(directory: tempDir)
        // Few words over a long spoken duration would go negative without the clamp.
        store.add(makeEntry(duration: 600, wordCount: 1))
        XCTAssertEqual(store.stats.minutesSaved, 0)
    }

    @MainActor
    func testStatsWithNoEntries() {
        let store = HistoryStore(directory: tempDir)
        let stats = store.stats
        XCTAssertEqual(stats.totalWords, 0)
        XCTAssertEqual(stats.totalSessions, 0)
        XCTAssertEqual(stats.averageWPM, 0)
        XCTAssertEqual(stats.minutesSaved, 0)
        XCTAssertEqual(stats.streakDays, 0)
        XCTAssertEqual(stats.totalCorrections, 0)
    }

    // MARK: - Streak pure function

    @MainActor
    func testStreakEmpty() {
        let cal = Calendar(identifier: .gregorian)
        XCTAssertEqual(HistoryStore.streak(days: [], today: Date(), calendar: cal), 0)
    }

    @MainActor
    func testStreakTodayOnly() {
        let cal = Calendar(identifier: .gregorian)
        let today = Date()
        let todayStart = cal.startOfDay(for: today)
        XCTAssertEqual(HistoryStore.streak(days: [todayStart], today: today, calendar: cal), 1)
    }

    @MainActor
    func testStreakTodayAndYesterday() {
        let cal = Calendar(identifier: .gregorian)
        let today = Date()
        let todayStart = cal.startOfDay(for: today)
        let yesterday = cal.date(byAdding: .day, value: -1, to: todayStart)!
        XCTAssertEqual(HistoryStore.streak(days: [todayStart, yesterday], today: today, calendar: cal), 2)
    }

    @MainActor
    func testStreakGapBreaksIt() {
        let cal = Calendar(identifier: .gregorian)
        let today = Date()
        let todayStart = cal.startOfDay(for: today)
        let twoDaysAgo = cal.date(byAdding: .day, value: -2, to: todayStart)!
        // Yesterday is missing, so the streak is only today, even though an older day exists.
        XCTAssertEqual(HistoryStore.streak(days: [todayStart, twoDaysAgo], today: today, calendar: cal), 1)
    }

    @MainActor
    func testStreakTodayEmptyButYesterdayAndBeforeAlive() {
        let cal = Calendar(identifier: .gregorian)
        let today = Date()
        let todayStart = cal.startOfDay(for: today)
        let yesterday = cal.date(byAdding: .day, value: -1, to: todayStart)!
        let twoDaysAgo = cal.date(byAdding: .day, value: -2, to: todayStart)!
        // Today has no entry yet, but yesterday + the day before do -> streak alive, counts 2.
        XCTAssertEqual(HistoryStore.streak(days: [yesterday, twoDaysAgo], today: today, calendar: cal), 2)
    }

    @MainActor
    func testStreakTodayAndYesterdayBothEmptyIsDead() {
        let cal = Calendar(identifier: .gregorian)
        let today = Date()
        let todayStart = cal.startOfDay(for: today)
        let threeDaysAgo = cal.date(byAdding: .day, value: -3, to: todayStart)!
        // Both today and yesterday are empty -> streak is dead, regardless of older history.
        XCTAssertEqual(HistoryStore.streak(days: [threeDaysAgo], today: today, calendar: cal), 0)
    }

    // MARK: - wordsByDay

    @MainActor
    func testWordsByDayZeroFillsGapsOldestToNewest() {
        let store = HistoryStore(directory: tempDir)
        let cal = Calendar.current
        let todayStart = cal.startOfDay(for: Date())
        let twoDaysAgo = cal.date(byAdding: .day, value: -2, to: todayStart)!

        store.add(makeEntry(date: todayStart, wordCount: 10))
        store.add(makeEntry(date: twoDaysAgo, wordCount: 5))

        let series = store.wordsByDay(lastNDays: 3)
        XCTAssertEqual(series.count, 3)
        XCTAssertEqual(series[0].date, twoDaysAgo)
        XCTAssertEqual(series[0].words, 5)
        XCTAssertEqual(series[1].words, 0) // yesterday: zero-filled
        XCTAssertEqual(series[2].date, todayStart)
        XCTAssertEqual(series[2].words, 10)
    }

    // MARK: - Mutations

    @MainActor
    func testDeleteAndClear() {
        let store = HistoryStore(directory: tempDir)
        let e1 = makeEntry(rawText: "one")
        let e2 = makeEntry(rawText: "two")
        store.add(e1)
        store.add(e2)

        store.delete(id: e1.id)
        XCTAssertEqual(store.entries.count, 1)
        XCTAssertEqual(store.entries.first?.id, e2.id)

        store.clear()
        XCTAssertTrue(store.entries.isEmpty)
    }

    // MARK: - Corrupt file recovery

    @MainActor
    func testCorruptFileIsQuarantinedAndStoreStartsEmpty() throws {
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let fileURL = tempDir.appendingPathComponent("history.json")
        try Data("{ this is not valid json ]]]".utf8).write(to: fileURL)

        let store = HistoryStore(directory: tempDir)
        XCTAssertTrue(store.entries.isEmpty)

        let contents = try FileManager.default.contentsOfDirectory(atPath: tempDir.path)
        XCTAssertTrue(contents.contains { $0.hasPrefix("history.json.corrupt-") })
    }
}
