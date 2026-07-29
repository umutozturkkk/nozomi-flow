import XCTest
import AVFAudio
@testable import NozomiFlowKit

/// The chunk boundary rules and the offsets that let two tracks be interleaved
/// later. Both fail quietly in production: a bad boundary only shows up as a
/// sentence cut in half, and a bad offset as a transcript where the replies come
/// before the questions.
@available(macOS 15.0, *)
final class MeetingRecorderTests: XCTestCase {

    private let rate = MeetingChunker.sampleRate
    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("meeting-tests-\(UUID().uuidString)")
        PCMConverter.shared.reset()
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    // MARK: - Boundary rules

    func testShortRecordingStaysOneChunk() {
        let chunker = MeetingChunker()
        // A minute of silence is well under the two-minute target: closing here
        // would split a short meeting for no reason.
        XCTAssertFalse(chunker.shouldClose(quiet(seconds: 60)))
    }

    func testClosesOnAPauseOncePastTheTarget() {
        let chunker = MeetingChunker()
        var samples = loud(seconds: 121)
        XCTAssertFalse(chunker.shouldClose(samples), "no pause yet, so it must keep going")
        samples += quiet(seconds: 0.5)
        XCTAssertTrue(chunker.shouldClose(samples), "a pause past the target is the boundary we want")
    }

    func testKeepsWaitingWhileSomeoneTalksThroughTheTarget() {
        let chunker = MeetingChunker()
        // Deliberately between target and maximum with no pause: cutting here would
        // land mid-sentence.
        XCTAssertFalse(chunker.shouldClose(loud(seconds: 150)))
    }

    func testStopsWaitingAtTheMaximum() {
        let chunker = MeetingChunker()
        XCTAssertTrue(chunker.shouldClose(loud(seconds: 181)),
                      "continuous speech must not produce an unbounded chunk")
    }

    func testBriefGapsBetweenWordsAreNotBoundaries() {
        let chunker = MeetingChunker()
        // 150ms is a gap between words, not a pause; the window is 400ms.
        let samples = loud(seconds: 121) + quiet(seconds: 0.15)
        XCTAssertFalse(chunker.shouldClose(samples))
    }

    func testQuietTestTreatsEmptyAsSilent() {
        XCTAssertTrue(MeetingChunker.isQuiet([Int16](), threshold: 60))
        XCTAssertTrue(MeetingChunker.isQuiet([0, 1, -1, 2], threshold: 60))
        XCTAssertFalse(MeetingChunker.isQuiet([9000, -9000], threshold: 60))
    }

    func testDurationComesFromFrameCount() {
        XCTAssertEqual(MeetingChunker.duration(frames: rate), 1.0, accuracy: 1e-9)
        XCTAssertEqual(MeetingChunker.duration(frames: rate * 90), 90.0, accuracy: 1e-9)
    }

    // MARK: - Writing

    func testChunksLandOnDiskWithContiguousOffsets() throws {
        var chunker = MeetingChunker()
        chunker.targetSeconds = 1
        chunker.maximumSeconds = 1.5
        chunker.silenceWindowSeconds = 0.1

        let recorder = try MeetingRecorder(directory: tempDir, chunker: chunker)
        var chunks: [MeetingChunk] = []
        recorder.onChunk = { chunks.append($0) }

        // Three bursts, each followed by a pause long enough to be a boundary.
        for _ in 0..<3 {
            recorder.accept(.microphone, buffer: buffer(loud(seconds: 1.1)))
            recorder.accept(.microphone, buffer: buffer(quiet(seconds: 0.2)))
        }
        chunks += recorder.finish()

        XCTAssertGreaterThanOrEqual(chunks.count, 3)
        for (position, chunk) in chunks.enumerated() {
            XCTAssertEqual(chunk.index, position, "indices must run in order for stable filenames")
            XCTAssertTrue(FileManager.default.fileExists(atPath: chunk.url.path))
        }
        // Offsets must tile the recording exactly: a gap or an overlap would shift
        // every later line of the transcript.
        for (previous, next) in zip(chunks, chunks.dropFirst()) {
            XCTAssertEqual(previous.endOffset, next.startOffset, accuracy: 1e-6)
        }
        XCTAssertEqual(chunks.first?.startOffset, 0)
    }

    func testTracksAreNumberedAndTimedIndependently() throws {
        var chunker = MeetingChunker()
        chunker.targetSeconds = 0.5
        chunker.maximumSeconds = 0.6

        let recorder = try MeetingRecorder(directory: tempDir, chunker: chunker)
        var chunks: [MeetingChunk] = []
        recorder.onChunk = { chunks.append($0) }

        recorder.accept(.microphone, buffer: buffer(loud(seconds: 0.7)))
        recorder.accept(.system, buffer: buffer(loud(seconds: 0.7)))
        chunks += recorder.finish()

        let mic = chunks.filter { $0.track == .microphone }
        let system = chunks.filter { $0.track == .system }
        XCTAssertFalse(mic.isEmpty)
        XCTAssertFalse(system.isEmpty)
        XCTAssertEqual(mic.first?.startOffset, 0)
        XCTAssertEqual(system.first?.startOffset, 0, "each track's clock starts at the meeting start")
        XCTAssertNotEqual(mic.first?.url, system.first?.url, "tracks must not overwrite each other")
    }

    func testIdleTrackWritesNothing() throws {
        let recorder = try MeetingRecorder(directory: tempDir, chunker: MeetingChunker())
        recorder.accept(.microphone, buffer: buffer(loud(seconds: 0.2)))

        let trailing = recorder.finish()
        XCTAssertEqual(trailing.count, 1, "only the track that received audio should produce a file")
        XCTAssertEqual(trailing.first?.track, .microphone)
    }

    func testWrittenChunkIsAReadableWAVOfTheRightLength() throws {
        let recorder = try MeetingRecorder(directory: tempDir, chunker: MeetingChunker())
        let samples = loud(seconds: 0.5)
        recorder.accept(.system, buffer: buffer(samples))
        let chunk = try XCTUnwrap(recorder.finish().first)

        let data = try Data(contentsOf: chunk.url)
        XCTAssertEqual(String(data: data[0..<4], encoding: .ascii), "RIFF")
        XCTAssertEqual(data.count, 44 + samples.count * 2, "payload must match what was captured")
        XCTAssertEqual(chunk.duration, 0.5, accuracy: 1e-6)
    }

    // MARK: - Helpers

    private func loud(seconds: Double) -> [Int16] {
        (0..<Int(seconds * Double(rate))).map { index in
            Int16(sin(Double(index) * 0.05) * 8000)
        }
    }

    private func quiet(seconds: Double) -> [Int16] {
        [Int16](repeating: 0, count: Int(seconds * Double(rate)))
    }

    /// Already in the upload format, so the converter passes it through untouched
    /// and the test measures chunking rather than resampling.
    private func buffer(_ samples: [Int16]) -> AVAudioPCMBuffer {
        let format = AVAudioFormat(
            commonFormat: .pcmFormatInt16, sampleRate: Double(rate), channels: 1, interleaved: true)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count))!
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer {
            buffer.int16ChannelData![0].update(from: $0.baseAddress!, count: samples.count)
        }
        return buffer
    }
}
