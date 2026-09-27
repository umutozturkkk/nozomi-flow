import XCTest
import AVFAudio
@testable import NozomiFlowKit

/// The debug capture exists to answer "what did the app actually hear?" when a
/// live dictation comes back short, so every buffer has to land in the file
/// unaltered and in order.
final class DebugAudioRecorderTests: XCTestCase {

    private var dir: URL!

    override func setUpWithError() throws {
        dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("debug-audio-tests-\(UUID().uuidString)")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    func testEveryAppendedBufferEndsUpInTheFile() throws {
        let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!
        let recorder = DebugAudioRecorder()

        let url = try XCTUnwrap(recorder.begin(format: format, in: dir))
        recorder.append(buffer(format, value: 0.25, frames: 100))
        recorder.append(buffer(format, value: -0.5, frames: 60))
        recorder.end()

        let file = try AVAudioFile(forReading: url)
        XCTAssertEqual(file.length, 160)
        let read = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 160)!
        try file.read(into: read)
        XCTAssertEqual(read.floatChannelData![0][0], 0.25)
        XCTAssertEqual(read.floatChannelData![0][159], -0.5)
    }

    func testAppendAfterEndIsIgnored() throws {
        let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!
        let recorder = DebugAudioRecorder()

        let url = try XCTUnwrap(recorder.begin(format: format, in: dir))
        recorder.append(buffer(format, value: 0.1, frames: 10))
        recorder.end()
        recorder.append(buffer(format, value: 0.1, frames: 10))

        XCTAssertEqual(try AVAudioFile(forReading: url).length, 10)
    }

    private func buffer(_ format: AVAudioFormat, value: Float, frames: Int) -> AVAudioPCMBuffer {
        let b = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames))!
        b.frameLength = AVAudioFrameCount(frames)
        for i in 0..<frames { b.floatChannelData![0][i] = value }
        return b
    }
}
