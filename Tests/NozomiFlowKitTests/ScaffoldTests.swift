import XCTest
@testable import NozomiFlowKit

final class ScaffoldTests: XCTestCase {

    func testHistoryEntryCodableRoundTrip() throws {
        let entry = HistoryEntry(
            date: Date(timeIntervalSince1970: 1_750_000_000),
            rawText: "um hello world",
            finalText: "Hello world.",
            appName: "Notes",
            appBundleID: "com.apple.Notes",
            durationSeconds: 3.2,
            wordCount: 2,
            mode: "dictation",
            engine: "speechAnalyzer"
        )
        let data = try JSONEncoder().encode(entry)
        let decoded = try JSONDecoder().decode(HistoryEntry.self, from: data)
        XCTAssertEqual(entry, decoded)
    }

    func testDictionaryEntryCodableRoundTrip() throws {
        let entry = DictionaryEntry(phrase: "Kernl", variants: ["kernel", "kernal"])
        let data = try JSONEncoder().encode(entry)
        let decoded = try JSONDecoder().decode(DictionaryEntry.self, from: data)
        XCTAssertEqual(entry, decoded)
    }

    func testToneMapping() {
        XCTAssertEqual(AppContextProvider.tone(forBundleID: "com.tinyspeck.slackmacgap"), .casual)
        XCTAssertEqual(AppContextProvider.tone(forBundleID: "com.apple.mail"), .professional)
        XCTAssertEqual(AppContextProvider.tone(forBundleID: "com.apple.dt.Xcode"), .technical)
        XCTAssertEqual(AppContextProvider.tone(forBundleID: "com.example.unknown"), .neutral)
        XCTAssertEqual(AppContextProvider.tone(forBundleID: nil), .neutral)
    }

    func testHotkeyKeyCodes() {
        XCTAssertEqual(HotkeyChoice.fn.keyCode, 63)
        XCTAssertEqual(HotkeyChoice.rightCommand.keyCode, 54)
        XCTAssertEqual(HotkeyChoice.rightOption.keyCode, 61)
        XCTAssertEqual(HotkeyChoice.rightControl.keyCode, 62)
    }

    @MainActor
    func testSettingsStoreDefaults() {
        let suiteName = "co.nozomi.flow.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let settings = SettingsStore(defaults: defaults)
        XCTAssertEqual(settings.dictationKey, .fn)
        XCTAssertEqual(settings.commandKey, .rightCommand)
        XCTAssertEqual(settings.formattingLevel, .full)
        XCTAssertEqual(settings.llmEngine, .auto)
        XCTAssertTrue(settings.removeFillers)
        XCTAssertFalse(settings.hasCompletedOnboarding)
    }

    @MainActor
    func testSettingsStorePersistsAcrossInstances() {
        let suiteName = "co.nozomi.flow.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let first = SettingsStore(defaults: defaults)
        first.dictationKey = .rightOption
        first.formattingLevel = .light
        first.customInstructions = "Prefer bullet lists"

        let second = SettingsStore(defaults: defaults)
        XCTAssertEqual(second.dictationKey, .rightOption)
        XCTAssertEqual(second.formattingLevel, .light)
        XCTAssertEqual(second.customInstructions, "Prefer bullet lists")
    }

    @MainActor
    func testHistoryStatsBasics() {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("murmur-scaffold-tests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = HistoryStore(directory: dir)
        store.add(HistoryEntry(
            date: Date(), rawText: "a", finalText: "one two three",
            appName: nil, appBundleID: nil, durationSeconds: 6,
            wordCount: 3, mode: "dictation", engine: "none"
        ))
        let stats = store.stats
        XCTAssertEqual(stats.totalWords, 3)
        XCTAssertEqual(stats.totalSessions, 1)
        XCTAssertEqual(stats.wordsToday, 3)
        XCTAssertEqual(stats.averageWPM, 30, accuracy: 0.01)
    }
}
