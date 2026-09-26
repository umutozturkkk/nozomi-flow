import XCTest
@testable import NozomiFlowKit

/// The on-disk sample set. It has to survive the app being killed mid-write
/// without leaving anything that later reads as a sample.
final class TrainingSampleStoreTests: XCTestCase {

    private var dir: URL!
    private var store: TrainingSampleStore!

    override func setUp() {
        super.setUp()
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("training-tests-\(UUID().uuidString)")
        store = TrainingSampleStore(directory: dir)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: dir)
        super.tearDown()
    }

    private func sample(seconds: Double = 2, text: String = "selam") -> (TrainingSample, [Int16]) {
        let audio = [Int16](repeating: 7, count: Int(seconds * 16_000))
        return (TrainingSample.make(rawLabel: text, audioSampleCount: audio.count, appBundleID: nil, labelSource: "m"), audio)
    }

    func testSavedSampleRoundTripsWithItsAudio() throws {
        let (s, audio) = sample()
        try store.save(s, audio: audio)

        XCTAssertEqual(store.loadAll(), [s])
        let wav = try Data(contentsOf: store.audioURL(for: s.id))
        XCTAssertEqual(wav, CloudTranscriptionSession.makeWAV(samples: audio, sampleRate: 16_000))
    }

    func testSamplesListOldestFirst() throws {
        var (a, audio) = sample(text: "a")
        var (b, _) = sample(text: "b")
        a.createdAt = Date(timeIntervalSince1970: 200)
        b.createdAt = Date(timeIntervalSince1970: 100)
        try store.save(a, audio: audio)
        try store.save(b, audio: audio)

        XCTAssertEqual(store.loadAll().map(\.rawLabel), ["b", "a"])
    }

    func testUpdateReplacesTheLabelAndStatus() throws {
        var (s, audio) = sample()
        try store.save(s, audio: audio)
        s.label = "selam dünya"
        s.status = .corrected
        try store.update(s)

        XCTAssertEqual(store.loadAll().first?.label, "selam dünya")
        XCTAssertEqual(store.loadAll().first?.status, .corrected)
    }

    func testTotalDurationAddsUpEverySample() throws {
        let (a, audioA) = sample(seconds: 2)
        let (b, audioB) = sample(seconds: 3.5)
        try store.save(a, audio: audioA)
        try store.save(b, audio: audioB)

        XCTAssertEqual(store.totalDurationSeconds(), 5.5, accuracy: 0.001)
    }

    func testSampleWithoutJSONIsNotListed() throws {
        let (s, audio) = sample()
        try store.save(s, audio: audio)
        try FileManager.default.removeItem(at: dir.appendingPathComponent("\(s.id.uuidString).json"))

        XCTAssertEqual(store.loadAll(), [])
    }

    func testIncompleteSamplesAreRemoved() throws {
        let (s, audio) = sample()
        try store.save(s, audio: audio)
        // Killed after the WAV was written, before the JSON rename:
        let orphan = dir.appendingPathComponent("\(UUID().uuidString).wav")
        try Data([1, 2, 3]).write(to: orphan)
        let tmp = dir.appendingPathComponent("\(UUID().uuidString).json.tmp")
        try Data("{".utf8).write(to: tmp)

        store.removeIncomplete()

        XCTAssertFalse(FileManager.default.fileExists(atPath: orphan.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: tmp.path))
        XCTAssertEqual(store.loadAll(), [s], "a complete sample must survive the cleanup")
    }

    func testCorruptJSONIsSkippedNotFatal() throws {
        let (s, audio) = sample()
        try store.save(s, audio: audio)
        try Data("not json".utf8).write(to: dir.appendingPathComponent("\(UUID().uuidString).json"))

        XCTAssertEqual(store.loadAll(), [s])
    }

    func testDeleteAllEmptiesTheStore() throws {
        let (s, audio) = sample()
        try store.save(s, audio: audio)
        try store.deleteAll()

        XCTAssertEqual(store.loadAll(), [])
        XCTAssertEqual(store.totalDurationSeconds(), 0)
    }

    func testSaveIntoUnwritableDirectoryThrowsInsteadOfCrashing() throws {
        let blocker = FileManager.default.temporaryDirectory.appendingPathComponent("blocker-\(UUID().uuidString)")
        try Data().write(to: blocker) // a file where the directory should be
        defer { try? FileManager.default.removeItem(at: blocker) }
        let broken = TrainingSampleStore(directory: blocker)
        let (s, audio) = sample()

        XCTAssertThrowsError(try broken.save(s, audio: audio))
    }
}
