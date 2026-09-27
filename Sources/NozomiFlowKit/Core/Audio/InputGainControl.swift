import Foundation

/// Automatic gain for the dictation mic, applied before audio reaches any
/// recognizer. The on-device engine drops words it can't hear clearly: a quiet
/// or distant mic turned a whole sentence into two words, and the same audio
/// with +25 dB came back complete.
///
/// Only boosts, never cuts: a mic that is already loud enough is passed through
/// untouched. Blocks quieter than `gateDB` are treated as room noise and don't
/// move the gain, so silence isn't pumped up into hiss. The gain drops at once
/// when speech gets louder and rises slowly when it gets quieter, and it is kept
/// between dictations so the first words of the next one are already boosted.
///
/// Not thread-safe: call `process` from a single thread (the audio tap).
final class InputGainControl {
    static let targetDB: Float = -20
    static let maxGainDB: Float = 30
    static let gateDB: Float = -60
    /// Upward adaptation per block. At 4096 frames / 48 kHz this is roughly
    /// 25 dB per second, fast enough to settle within the first second of speech.
    static let riseDBPerBlock: Float = 2

    private(set) var gainDB: Float = 0

    func process(_ samples: UnsafeMutableBufferPointer<Float>) {
        process(channels: [samples])
    }

    /// Multi-channel input: the level is measured on the first channel and the
    /// same gain is applied to every channel, so they stay balanced.
    func process(channels: [UnsafeMutableBufferPointer<Float>]) {
        guard let first = channels.first, !first.isEmpty else { return }
        let previousDB = gainDB
        adapt(toBlockLevel: Self.rmsDB(first))
        guard previousDB > 0 || gainDB > 0 else { return }

        // Ramp across the block so a gain change never lands as a click.
        let from = Self.linear(previousDB)
        let step = (Self.linear(gainDB) - from) / Float(first.count)
        for samples in channels {
            for i in samples.indices {
                let boosted = samples[i] * (from + step * Float(i))
                samples[i] = min(1, max(-1, boosted))
            }
        }
    }

    private func adapt(toBlockLevel levelDB: Float) {
        guard levelDB > Self.gateDB else { return }
        let desired = min(Self.maxGainDB, max(0, Self.targetDB - levelDB))
        gainDB = desired < gainDB ? desired : min(desired, gainDB + Self.riseDBPerBlock)
    }

    private static func rmsDB(_ samples: UnsafeMutableBufferPointer<Float>) -> Float {
        var sum: Float = 0
        for s in samples { sum += s * s }
        let mean = sum / Float(samples.count)
        return mean > 0 ? 10 * log10(mean) : -.infinity
    }

    private static func linear(_ db: Float) -> Float {
        pow(10, db / 20)
    }
}
