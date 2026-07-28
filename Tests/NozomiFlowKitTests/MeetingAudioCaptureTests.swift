import XCTest
import AVFAudio
import CoreMedia
@testable import NozomiFlowKit

/// Covers the sample-buffer bridge, which is the part of meeting capture that fails
/// silently: a wrong pointer walk still compiles, still runs, and simply yields
/// silence or noise that only shows up as an empty transcript much later.
@available(macOS 15.0, *)
final class MeetingAudioCaptureTests: XCTestCase {

    // MARK: - Track identity

    func testTracksMapToDistinctSpeakers() {
        XCTAssertEqual(MeetingTrack.microphone.speakerLabel, "You")
        XCTAssertEqual(MeetingTrack.system.speakerLabel, "Them")
        XCTAssertEqual(Set(MeetingTrack.allCases.map(\.speakerLabel)).count, MeetingTrack.allCases.count,
                       "two tracks sharing a label would erase the attribution the split exists for")
    }

    // MARK: - CMSampleBuffer bridge

    func testInterleavedInt16SurvivesTheBridge() throws {
        let format = try XCTUnwrap(AVAudioFormat(
            commonFormat: .pcmFormatInt16, sampleRate: 48_000, channels: 2, interleaved: true))
        let samples: [Int16] = (0..<960).map { Int16(truncatingIfNeeded: $0 &* 31 &- 16_000) }
        let source = try makeBuffer(format: format, int16: samples)

        let bridged = try XCTUnwrap(
            MeetingAudioCapture.pcmBuffer(from: try sampleBuffer(from: source)),
            "an interleaved int16 buffer must survive the bridge")

        XCTAssertEqual(bridged.frameLength, source.frameLength)
        XCTAssertEqual(bridged.format.sampleRate, 48_000)
        XCTAssertEqual(bridged.format.channelCount, 2)
        XCTAssertEqual(readInt16(bridged), samples, "samples must arrive unmodified, not silent or shifted")
    }

    func testNonInterleavedFloatSurvivesTheBridge() throws {
        // The microphone arrives in its device's native format, which on this
        // hardware is non-interleaved float: a different AudioBufferList shape than
        // the system track, and the case a single-buffer assumption would break on.
        let format = try XCTUnwrap(AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: 44_100, channels: 2, interleaved: false))
        let left: [Float] = (0..<512).map { sin(Float($0) * 0.05) }
        let right: [Float] = (0..<512).map { cos(Float($0) * 0.05) }
        let source = try makeBuffer(format: format, channels: [left, right])

        let bridged = try XCTUnwrap(
            MeetingAudioCapture.pcmBuffer(from: try sampleBuffer(from: source)),
            "a non-interleaved float buffer must survive the bridge")

        XCTAssertEqual(bridged.frameLength, 512)
        let channelData = try XCTUnwrap(bridged.floatChannelData)
        XCTAssertEqual(Array(UnsafeBufferPointer(start: channelData[0], count: 512)), left, accuracy: 1e-6)
        XCTAssertEqual(Array(UnsafeBufferPointer(start: channelData[1], count: 512)), right, accuracy: 1e-6)
    }

    func testSamplesAreCopiedNotAliased() throws {
        // The source block buffer dies with the closure. If the bridge aliased it
        // instead of copying, the data would be garbage by the time a consumer read
        // it, which is exactly the bug that produces a silent recording.
        let format = try XCTUnwrap(AVAudioFormat(
            commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: true))
        let samples: [Int16] = (0..<256).map { Int16($0 * 100 - 12_800) }

        let bridged: AVAudioPCMBuffer = try {
            let source = try makeBuffer(format: format, int16: samples)
            return try XCTUnwrap(MeetingAudioCapture.pcmBuffer(from: try sampleBuffer(from: source)))
        }()

        // Force the allocator to hand out memory again before reading back.
        _ = (0..<64).map { _ in [Int16](repeating: 0x5A5A, count: 1024) }
        XCTAssertEqual(readInt16(bridged), samples)
    }

    func testNonAudioBufferIsRejected() throws {
        var timing = CMSampleTimingInfo()
        var description: CMFormatDescription?
        CMVideoFormatDescriptionCreate(
            allocator: kCFAllocatorDefault, codecType: kCMVideoCodecType_H264,
            width: 2, height: 2, extensions: nil, formatDescriptionOut: &description)
        var buffer: CMSampleBuffer?
        CMSampleBufferCreate(
            allocator: kCFAllocatorDefault, dataBuffer: nil, dataReady: false,
            makeDataReadyCallback: nil, refcon: nil,
            formatDescription: try XCTUnwrap(description), sampleCount: 0,
            sampleTimingEntryCount: 0, sampleTimingArray: &timing,
            sampleSizeEntryCount: 0, sampleSizeArray: nil, sampleBufferOut: &buffer)

        XCTAssertNil(MeetingAudioCapture.pcmBuffer(from: try XCTUnwrap(buffer)),
                     "a screen frame reaching the audio path must be dropped, not misread as PCM")
    }

    // MARK: - Helpers

    private func makeBuffer(format: AVAudioFormat, int16 samples: [Int16]) throws -> AVAudioPCMBuffer {
        let frames = AVAudioFrameCount(samples.count / Int(format.channelCount))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
        buffer.frameLength = frames
        let channel = try XCTUnwrap(buffer.int16ChannelData)
        samples.withUnsafeBufferPointer { channel[0].update(from: $0.baseAddress!, count: samples.count) }
        return buffer
    }

    private func makeBuffer(format: AVAudioFormat, channels: [[Float]]) throws -> AVAudioPCMBuffer {
        let frames = AVAudioFrameCount(channels[0].count)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
        buffer.frameLength = frames
        let data = try XCTUnwrap(buffer.floatChannelData)
        for (index, samples) in channels.enumerated() {
            samples.withUnsafeBufferPointer { data[index].update(from: $0.baseAddress!, count: samples.count) }
        }
        return buffer
    }

    /// The inverse of what ScreenCaptureKit hands us, so the bridge can be exercised
    /// without a live stream or Screen Recording permission.
    private func sampleBuffer(from buffer: AVAudioPCMBuffer) throws -> CMSampleBuffer {
        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: CMTimeScale(buffer.format.sampleRate)),
            presentationTimeStamp: .zero,
            decodeTimeStamp: .invalid)

        var sampleBuffer: CMSampleBuffer?
        let status = CMSampleBufferCreate(
            allocator: kCFAllocatorDefault, dataBuffer: nil, dataReady: false,
            makeDataReadyCallback: nil, refcon: nil,
            formatDescription: buffer.format.formatDescription,
            sampleCount: CMItemCount(buffer.frameLength),
            sampleTimingEntryCount: 1, sampleTimingArray: &timing,
            sampleSizeEntryCount: 0, sampleSizeArray: nil,
            sampleBufferOut: &sampleBuffer)
        XCTAssertEqual(status, noErr)

        let created = try XCTUnwrap(sampleBuffer)
        XCTAssertEqual(
            CMSampleBufferSetDataBufferFromAudioBufferList(
                created, blockBufferAllocator: kCFAllocatorDefault,
                blockBufferMemoryAllocator: kCFAllocatorDefault,
                flags: 0, bufferList: buffer.audioBufferList),
            noErr)
        return created
    }

    private func readInt16(_ buffer: AVAudioPCMBuffer) -> [Int16] {
        guard let channel = buffer.int16ChannelData else { return [] }
        let count = Int(buffer.frameLength) * Int(buffer.format.channelCount)
        return Array(UnsafeBufferPointer(start: channel[0], count: count))
    }
}

private func XCTAssertEqual(
    _ lhs: [Float], _ rhs: [Float], accuracy: Float, file: StaticString = #filePath, line: UInt = #line
) {
    XCTAssertEqual(lhs.count, rhs.count, file: file, line: line)
    for (a, b) in zip(lhs, rhs) {
        XCTAssertEqual(a, b, accuracy: accuracy, file: file, line: line)
    }
}
