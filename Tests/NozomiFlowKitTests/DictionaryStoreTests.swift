import XCTest
@testable import NozomiFlowKit

final class DictionaryStoreTests: XCTestCase {
    private var tempDir: URL!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("murmur-dictionary-tests-\(UUID().uuidString)")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
        tempDir = nil
        super.tearDown()
    }

    // MARK: - Persistence round-trip

    @MainActor
    func testAddPersistReload() {
        let store1 = PersonalDictionaryStore(directory: tempDir)
        let entry = DictionaryEntry(phrase: "Kernl", variants: ["kernel", "kernal"])
        store1.add(entry)
        store1.flushNow()

        let store2 = PersonalDictionaryStore(directory: tempDir)
        XCTAssertEqual(store2.entries.count, 1)
        XCTAssertEqual(store2.entries.first, entry)
    }

    @MainActor
    func testFirstRunStartsEmptyNoSeedData() {
        let store = PersonalDictionaryStore(directory: tempDir)
        XCTAssertTrue(store.entries.isEmpty)
    }

    @MainActor
    func testUpdateAndDelete() {
        let store = PersonalDictionaryStore(directory: tempDir)
        var entry = DictionaryEntry(phrase: "Kernl", variants: ["kernel"])
        store.add(entry)

        entry.phrase = "Kernl Inc"
        store.update(entry)
        XCTAssertEqual(store.entries.first?.phrase, "Kernl Inc")

        store.delete(id: entry.id)
        XCTAssertTrue(store.entries.isEmpty)
    }

    // MARK: - enabledEntries / boostWords

    @MainActor
    func testEnabledEntriesAndBoostWordsExcludeDisabled() {
        let store = PersonalDictionaryStore(directory: tempDir)
        store.add(DictionaryEntry(phrase: "Kernl", variants: ["kernel"], isEnabled: true))
        store.add(DictionaryEntry(phrase: "Nimbus", variants: ["nim bus"], isEnabled: false))

        XCTAssertEqual(store.enabledEntries.count, 1)
        XCTAssertEqual(store.boostWords, ["Kernl"])
    }

    // MARK: - apply(): word boundaries

    @MainActor
    func testApplyWordBoundaryDoesNotMatchSubstring() {
        let store = PersonalDictionaryStore(directory: tempDir)
        store.add(DictionaryEntry(phrase: "Kernl", variants: ["kernel"]))

        XCTAssertEqual(store.apply(to: "I read one kernel."), "I read one Kernl.")
        // "kernel" must NOT match inside "kernels".
        XCTAssertEqual(store.apply(to: "I read many kernels."), "I read many kernels.")
    }

    @MainActor
    func testApplyCaseInsensitiveVariantMatch() {
        let store = PersonalDictionaryStore(directory: tempDir)
        store.add(DictionaryEntry(phrase: "Kernl", variants: ["kernel"]))

        XCTAssertEqual(store.apply(to: "KERNEL is a company."), "Kernl is a company.")
        XCTAssertEqual(store.apply(to: "kErNeL"), "Kernl")
    }

    // MARK: - apply(): capitalization preservation

    @MainActor
    func testApplyCapitalizationPreservationAtSentenceStart() {
        let store = PersonalDictionaryStore(directory: tempDir)
        // Lowercase canonical phrase: only the first letter is ever uppercased, and
        // only when forced by context.
        store.add(DictionaryEntry(phrase: "kernl", variants: ["kernel"]))

        // Start of text -> forced capital even though the spoken variant was lowercase.
        XCTAssertEqual(store.apply(to: "kernel is a great company."), "Kernl is a great company.")
        // Mid-sentence, lowercase context -> phrase stays lowercase.
        XCTAssertEqual(store.apply(to: "I love this kernel a lot."), "I love this kernl a lot.")
        // After a sentence-ending period -> forced capital.
        XCTAssertEqual(store.apply(to: "Hi there. kernel is great."), "Hi there. Kernl is great.")
        // Matched text itself was capitalized -> stays capitalized regardless of position.
        XCTAssertEqual(store.apply(to: "I love this Kernel a lot."), "I love this Kernl a lot.")
    }

    @MainActor
    func testApplyPreservesIntentionalPhraseCasingWhenNotForced() {
        let store = PersonalDictionaryStore(directory: tempDir)
        store.add(DictionaryEntry(phrase: "iPhone", variants: ["aiphone"]))

        // Mid-sentence, lowercase variant -> phrase used exactly as stored (not re-lowercased).
        XCTAssertEqual(store.apply(to: "I bought a new aiphone yesterday."), "I bought a new iPhone yesterday.")
    }

    // MARK: - apply(): multi-word variants

    @MainActor
    func testApplyMultiWordVariant() {
        let store = PersonalDictionaryStore(directory: tempDir)
        store.add(DictionaryEntry(phrase: "as soon as possible", variants: ["a s a p"]))

        XCTAssertEqual(
            store.apply(to: "Please send it a s a p today."),
            "Please send it as soon as possible today."
        )
    }

    // MARK: - apply(): disabled entries

    @MainActor
    func testApplyDisabledEntryIgnored() {
        let store = PersonalDictionaryStore(directory: tempDir)
        store.add(DictionaryEntry(phrase: "Kernl", variants: ["kernel"], isEnabled: false))

        XCTAssertEqual(store.apply(to: "one kernel here"), "one kernel here")
    }

    // MARK: - apply(): longer-variant-first ordering

    @MainActor
    func testApplyLongerVariantWinsOverShorterOverlapping() {
        let store = PersonalDictionaryStore(directory: tempDir)
        store.add(DictionaryEntry(phrase: "Kernl", variants: ["kernel"]))
        store.add(DictionaryEntry(phrase: "Kernl Labs", variants: ["kernel labs"]))

        // Without longer-first ordering, the shorter "kernel" rule would fire first
        // and leave "labs" untouched, producing "Kernl labs" instead of "Kernl Labs".
        XCTAssertEqual(
            store.apply(to: "Welcome to kernel labs today."),
            "Welcome to Kernl Labs today."
        )
    }

    @MainActor
    func testApplyIgnoresBlankVariants() {
        let store = PersonalDictionaryStore(directory: tempDir)
        store.add(DictionaryEntry(phrase: "Kernl", variants: ["", "   ", "kernel"]))
        XCTAssertEqual(store.apply(to: "one kernel here"), "one Kernl here")
    }

    @MainActor
    func testApplyWithNoEnabledEntriesIsPassthrough() {
        let store = PersonalDictionaryStore(directory: tempDir)
        XCTAssertEqual(store.apply(to: "unchanged text"), "unchanged text")
    }

    // MARK: - Corrupt file recovery

    @MainActor
    func testCorruptFileIsQuarantinedAndStoreStartsEmpty() throws {
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let fileURL = tempDir.appendingPathComponent("dictionary.json")
        try Data("not json at all {{{".utf8).write(to: fileURL)

        let store = PersonalDictionaryStore(directory: tempDir)
        XCTAssertTrue(store.entries.isEmpty)

        let contents = try FileManager.default.contentsOfDirectory(atPath: tempDir.path)
        XCTAssertTrue(contents.contains { $0.hasPrefix("dictionary.json.corrupt-") })
    }
}
