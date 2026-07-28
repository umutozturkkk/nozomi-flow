import XCTest
import AVFAudio
@testable import NozomiFlowKit

/// Live round trip against the real endpoint, skipped unless a key is supplied:
///
///     MURMUR_LIVE_ASR_KEY=sk-or-... swift test --filter CloudTranscriptionLiveTests
///
/// The offline tests prove the WAV header and multipart body are shaped correctly by
/// our own reading of them. Only this one proves a provider agrees, which is the part
/// that silently breaks when an encoding detail is subtly wrong.
final class CloudTranscriptionLiveTests: XCTestCase {

    func testRealEndpointTranscribesGeneratedWAV() async throws {
        let key = ProcessInfo.processInfo.environment["MURMUR_LIVE_ASR_KEY"] ?? ""
        try XCTSkipIf(key.isEmpty, "set MURMUR_LIVE_ASR_KEY to run the live cloud round trip")

        var config = CloudTranscriptionConfig()
        config.isEnabled = true
        config.apiKey = key
        if let model = ProcessInfo.processInfo.environment["MURMUR_LIVE_ASR_MODEL"], !model.isEmpty {
            config.model = model
        }

        guard let session = CloudTranscriptionSession(config: config, locale: Locale(identifier: "tr_TR")) else {
            return XCTFail("could not build a cloud session")
        }

        // A 440 Hz tone carries no speech, so the transcript may well come back empty.
        // The assertion is that finish() does not throw: a malformed WAV or multipart
        // body comes back 4xx, which the session turns into a thrown error.
        for buffer in CloudTranscriptionSession.buffers(from: Self.tone(seconds: 2)) {
            session.accept(buffer)
        }
        _ = try await session.finish()
    }

    func testBadKeyIsReportedRatherThanSwallowed() async throws {
        let key = ProcessInfo.processInfo.environment["MURMUR_LIVE_ASR_KEY"] ?? ""
        try XCTSkipIf(key.isEmpty, "set MURMUR_LIVE_ASR_KEY to run the live cloud round trip")

        var config = CloudTranscriptionConfig()
        config.isEnabled = true
        config.apiKey = "sk-or-v1-definitely-not-a-real-key"

        guard let session = CloudTranscriptionSession(config: config, locale: Locale(identifier: "tr_TR")) else {
            return XCTFail("could not build a cloud session")
        }
        for buffer in CloudTranscriptionSession.buffers(from: Self.tone(seconds: 1)) {
            session.accept(buffer)
        }

        do {
            _ = try await session.finish()
            XCTFail("a rejected key must surface as an error, not as an empty transcript")
        } catch {
            // The engine treats an empty result as "retry on-device", so a silent empty
            // string here would hide the real problem behind a confusing local fallback.
            XCTAssertTrue(error is DictationError)
        }
    }

    /// 16 kHz mono PCM16 sine wave, matching the format the session uploads.
    private static func tone(seconds: Double, frequency: Double = 440) -> [Int16] {
        let rate = 16_000.0
        return (0..<Int(seconds * rate)).map { index in
            let value = sin(2 * .pi * frequency * Double(index) / rate) * 0.3
            return Int16(value * Double(Int16.max))
        }
    }
}
