import XCTest
import AVFAudio
@testable import NozomiFlowKit

/// The mic now starts on key-down, before the recognizer session exists. Words
/// spoken in that gap used to be lost outright (live dictations came back as
/// their last word), so the handoff has to keep every early buffer, in order,
/// and deliver it once the session is ready.
final class AudioHandoffTests: XCTestCase {

    private let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!

    func testBuffersArrivingBeforeTheSessionAreDeliveredInOrderOnAttach() {
        let handoff = AudioHandoff()
        handoff.accept(buffer(1))
        handoff.accept(buffer(2))

        var received: [Float] = []
        handoff.attach { received.append($0.floatChannelData![0][0]) }

        XCTAssertEqual(received, [1, 2])
    }

    func testBuffersAfterAttachGoStraightThrough() {
        let handoff = AudioHandoff()
        var received: [Float] = []
        handoff.attach { received.append($0.floatChannelData![0][0]) }

        handoff.accept(buffer(3))

        XCTAssertEqual(received, [3])
    }

    func testHeldBuffersAreCopiesBecauseTheTapReusesItsBuffer() {
        let handoff = AudioHandoff()
        let reused = buffer(1)
        handoff.accept(reused)
        reused.floatChannelData![0][0] = 99 // the engine refills it for the next callback

        var received: [Float] = []
        handoff.attach { received.append($0.floatChannelData![0][0]) }

        XCTAssertEqual(received, [1])
    }

    func testResetDropsHeldAudioAndDetaches() {
        let handoff = AudioHandoff()
        var received: [Float] = []
        handoff.attach { received.append($0.floatChannelData![0][0]) }
        handoff.reset()

        handoff.accept(buffer(5))
        XCTAssertEqual(received, [], "a finished session must not receive the next session's audio")

        var next: [Float] = []
        handoff.attach { next.append($0.floatChannelData![0][0]) }
        XCTAssertEqual(next, [5])
    }

    private func buffer(_ value: Float) -> AVAudioPCMBuffer {
        let b = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16)!
        b.frameLength = 16
        for i in 0..<16 { b.floatChannelData![0][i] = value }
        return b
    }
}
