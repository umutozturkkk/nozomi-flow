import XCTest
@testable import NozomiFlowKit

/// The on-device recognizer silently drops words it can't hear: a far or quiet
/// mic produced "Şu anda umarım" where +25 dB of gain on the same recording
/// produced the whole sentence. These pin down the gain stage that closes that
/// gap without turning room noise into speech or clipping a loud voice.
final class InputGainControlTests: XCTestCase {

    private let rate = 48_000.0
    private let block = 4096

    // MARK: - Boosting

    func testQuietSpeechIsBroughtUpToTheTargetLevel() {
        let gain = InputGainControl()
        let out = run(gain, tone(rmsDB: -45, seconds: 3))
        XCTAssertEqual(rmsDB(out.suffix(Int(rate))), InputGainControl.targetDB, accuracy: 3)
    }

    func testGainIsCappedSoAVeryFarVoiceIsNotBoostedWithoutLimit() {
        let gain = InputGainControl()
        let out = run(gain, tone(rmsDB: -58, seconds: 4))
        let expected = -58 + InputGainControl.maxGainDB
        XCTAssertEqual(rmsDB(out.suffix(Int(rate))), expected, accuracy: 1.5)
    }

    func testLearnedGainAppliesFromTheFirstSampleOfTheNextDictation() {
        // Short dictations lose their first words while the gain is still
        // climbing, so what was learned in one session has to carry into the next.
        let gain = InputGainControl()
        _ = run(gain, tone(rmsDB: -45, seconds: 3))
        let next = run(gain, tone(rmsDB: -45, seconds: 0.1))
        XCTAssertEqual(rmsDB(next), InputGainControl.targetDB, accuracy: 3)
    }

    // MARK: - Leaving audio alone

    func testRoomNoiseBelowTheGateIsNotAmplified() {
        let gain = InputGainControl()
        let input = tone(rmsDB: -75, seconds: 3)
        let out = run(gain, input)
        XCTAssertEqual(rmsDB(out), rmsDB(input), accuracy: 0.1)
    }

    func testLoudSpeechIsNeverAttenuated() {
        let gain = InputGainControl()
        let input = tone(rmsDB: -12, seconds: 2)
        let out = run(gain, input)
        XCTAssertEqual(out, input)
    }

    // MARK: - Safety

    func testASuddenLoudBurstAfterBoostingNeverExceedsFullScale() {
        let gain = InputGainControl()
        _ = run(gain, tone(rmsDB: -50, seconds: 3))
        let out = run(gain, tone(rmsDB: -6, seconds: 0.5))
        XCTAssertLessThanOrEqual(out.map(abs).max() ?? 0, 1.0)
    }

    // MARK: - Helpers

    /// Feeds `samples` through in mic-tap sized blocks and returns the result.
    private func run(_ gain: InputGainControl, _ samples: [Float]) -> [Float] {
        var out = samples
        var start = 0
        while start < out.count {
            let end = min(start + block, out.count)
            out[start..<end].withUnsafeMutableBufferPointer { gain.process($0) }
            start = end
        }
        return out
    }

    private func tone(rmsDB: Float, seconds: Double) -> [Float] {
        let amplitude = pow(10, rmsDB / 20) * sqrt(2)
        return (0..<Int(seconds * rate)).map { amplitude * sin(2 * .pi * 220 * Float($0) / Float(rate)) }
    }

    private func rmsDB<C: Collection>(_ samples: C) -> Float where C.Element == Float {
        let mean = samples.reduce(0) { $0 + $1 * $1 } / Float(samples.count)
        return 10 * log10(mean)
    }
}
