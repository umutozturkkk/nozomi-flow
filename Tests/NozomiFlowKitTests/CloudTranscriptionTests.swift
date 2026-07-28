import XCTest
import AVFAudio
@testable import NozomiFlowKit

/// Encoding and configuration tests for the cloud backend. Nothing here touches the
/// network or the microphone: the pieces under test are the ones that would corrupt a
/// request silently, which is exactly the failure a live smoke test hides.
final class CloudTranscriptionTests: XCTestCase {

    // MARK: - Configuration

    func testConfigIsUnusableUntilEnabledAndKeyed() {
        var config = CloudTranscriptionConfig()
        XCTAssertFalse(config.isUsable, "default config must not divert audio off-device")

        config.isEnabled = true
        XCTAssertFalse(config.isUsable, "enabling without a key must not divert audio off-device")

        config.apiKey = "sk-or-test"
        XCTAssertTrue(config.isUsable)

        config.model = ""
        XCTAssertFalse(config.isUsable, "a blank model would produce a request the provider rejects")
    }

    func testCloudIsTheOnlyEngineKindThatLeavesTheMachine() {
        XCTAssertFalse(TranscriptionEngineKind.cloud.isOnDevice)
        for kind in [TranscriptionEngineKind.speechAnalyzer, .dictation, .legacySF, .none] {
            XCTAssertTrue(kind.isOnDevice, "\(kind.rawValue) must not be reported as leaving the machine")
        }
    }

    // MARK: - WAV encoding

    func testWAVHeaderDescribesThePayload() {
        let samples: [Int16] = [0, 1000, -1000, 32767, -32768]
        let wav = CloudTranscriptionSession.makeWAV(samples: samples, sampleRate: 16_000)

        XCTAssertEqual(wav.count, 44 + samples.count * 2)
        XCTAssertEqual(String(data: wav[0..<4], encoding: .ascii), "RIFF")
        XCTAssertEqual(String(data: wav[8..<12], encoding: .ascii), "WAVE")
        XCTAssertEqual(String(data: wav[12..<16], encoding: .ascii), "fmt ")
        XCTAssertEqual(String(data: wav[36..<40], encoding: .ascii), "data")

        XCTAssertEqual(readUInt32(wav, 4), UInt32(36 + samples.count * 2), "RIFF size excludes the first 8 bytes")
        XCTAssertEqual(readUInt16(wav, 20), 1, "format tag must be PCM")
        XCTAssertEqual(readUInt16(wav, 22), 1, "must be mono")
        XCTAssertEqual(readUInt32(wav, 24), 16_000)
        XCTAssertEqual(readUInt32(wav, 28), 32_000, "byte rate = rate * channels * bytesPerSample")
        XCTAssertEqual(readUInt16(wav, 32), 2, "block align = channels * bytesPerSample")
        XCTAssertEqual(readUInt16(wav, 34), 16, "bits per sample")
        XCTAssertEqual(readUInt32(wav, 40), UInt32(samples.count * 2))
    }

    func testWAVPayloadIsLittleEndianAndPreservesExtremes() {
        let samples: [Int16] = [0, 256, -2, 32767, -32768]
        let wav = CloudTranscriptionSession.makeWAV(samples: samples, sampleRate: 16_000)
        let decoded: [Int16] = stride(from: 44, to: wav.count, by: 2).map { offset in
            Int16(littleEndian: Int16(wav[offset]) | (Int16(bitPattern: UInt16(wav[offset + 1]) << 8)))
        }
        XCTAssertEqual(decoded, samples)
    }

    func testEmptySamplesStillProduceAValidHeader() {
        let wav = CloudTranscriptionSession.makeWAV(samples: [], sampleRate: 16_000)
        XCTAssertEqual(wav.count, 44)
        XCTAssertEqual(readUInt32(wav, 40), 0)
    }

    // MARK: - Multipart encoding

    func testMultipartCarriesEveryFieldAndTheAudioBytes() {
        let audio = Data([0xDE, 0xAD, 0xBE, 0xEF])
        let (body, contentType) = CloudTranscriptionSession.multipart(
            fields: ["model": "microsoft/mai-transcribe-1.5", "language": "tr"],
            filename: "audio.wav",
            audio: audio
        )

        XCTAssertTrue(contentType.hasPrefix("multipart/form-data; boundary="))
        let boundary = String(contentType.dropFirst("multipart/form-data; boundary=".count))
        XCTAssertFalse(boundary.isEmpty)

        guard let text = String(data: body, encoding: .isoLatin1) else {
            return XCTFail("body was not decodable for inspection")
        }
        XCTAssertTrue(text.contains("name=\"model\""))
        XCTAssertTrue(text.contains("microsoft/mai-transcribe-1.5"))
        XCTAssertTrue(text.contains("name=\"language\""))
        XCTAssertTrue(text.contains("name=\"file\"; filename=\"audio.wav\""))
        XCTAssertTrue(text.contains("Content-Type: audio/wav"))
        XCTAssertTrue(text.hasSuffix("--\(boundary)--\r\n"), "body must be closed with the terminating boundary")

        XCTAssertTrue(bytesContain(body, audio), "raw audio bytes must survive the encoding")
    }

    func testEveryBoundaryIsUniquePerRequest() {
        let (_, first) = CloudTranscriptionSession.multipart(fields: [:], filename: "a.wav", audio: Data())
        let (_, second) = CloudTranscriptionSession.multipart(fields: [:], filename: "a.wav", audio: Data())
        XCTAssertNotEqual(first, second, "a reused boundary can collide with payload bytes across requests")
    }

    // MARK: - Local replay

    func testSamplesRoundTripThroughReplayBuffers() {
        let samples: [Int16] = (0..<10_000).map { Int16(truncatingIfNeeded: $0 * 7) }
        let buffers = CloudTranscriptionSession.buffers(from: samples, chunkFrames: 1024)

        XCTAssertEqual(buffers.count, 10, "10000 frames at 1024 per chunk is 9 full chunks plus a remainder")
        XCTAssertEqual(buffers.reduce(0) { $0 + Int($1.frameLength) }, samples.count)

        var flattened: [Int16] = []
        for buffer in buffers {
            guard let channel = buffer.int16ChannelData else { return XCTFail("replay buffer lost its channel data") }
            flattened.append(contentsOf: UnsafeBufferPointer(start: channel[0], count: Int(buffer.frameLength)))
        }
        XCTAssertEqual(flattened, samples, "the local engine must receive exactly the audio the cloud got")
    }

    func testReplayBuffersUseTheUploadFormat() {
        guard let buffer = CloudTranscriptionSession.buffers(from: [1, 2, 3]).first else {
            return XCTFail("expected one buffer")
        }
        XCTAssertEqual(buffer.format.sampleRate, 16_000)
        XCTAssertEqual(buffer.format.channelCount, 1)
        XCTAssertEqual(buffer.format.commonFormat, .pcmFormatInt16)
    }

    func testNoSamplesProducesNoReplayBuffers() {
        XCTAssertTrue(CloudTranscriptionSession.buffers(from: []).isEmpty)
    }

    // MARK: - Timeout budget

    func testCloudGetsALongerFinishBudgetThanOnDeviceEngines() {
        guard let session = CloudTranscriptionSession(
            config: CloudTranscriptionConfig(), locale: Locale(identifier: "tr_TR")
        ) else { return XCTFail("session init failed for a standard PCM format") }
        XCTAssertGreaterThan(session.finishTimeoutSeconds, 10, "a network round trip needs more than the on-device budget")
        XCTAssertEqual(session.engineKind, .cloud)
        XCTAssertEqual(session.resolvedLocaleIdentifier, "tr_TR")
        XCTAssertEqual(session.snapshotText(), "", "batch transcription has nothing partial to salvage")
    }

    // MARK: - Helpers

    private func readUInt16(_ data: Data, _ offset: Int) -> UInt16 {
        UInt16(data[offset]) | (UInt16(data[offset + 1]) << 8)
    }

    private func readUInt32(_ data: Data, _ offset: Int) -> UInt32 {
        (0..<4).reduce(UInt32(0)) { $0 | (UInt32(data[offset + $1]) << (8 * UInt32($1))) }
    }

    private func bytesContain(_ haystack: Data, _ needle: Data) -> Bool {
        guard !needle.isEmpty, haystack.count >= needle.count else { return false }
        return haystack.range(of: needle) != nil
    }
}
