import Foundation

/// Decides where one upload-sized piece of a meeting ends and the next begins.
///
/// Pure and synchronous so the boundary rules can be tested without audio hardware,
/// permissions or disk: getting them wrong costs a mangled transcript that only
/// shows up an hour into a real meeting.
struct MeetingChunker {

    /// Everything downstream works in the upload format, so a frame is a sample.
    static let sampleRate = 16_000

    /// Aim to close a chunk here. Two minutes is ~3.8 MB as 16 kHz mono PCM16, well
    /// inside the 25 MB the transcription endpoints accept, and short enough that a
    /// failed upload loses little.
    var targetSeconds: Double = 120
    /// Never let a chunk run past this waiting for a pause. Someone who talks
    /// continuously must not produce an unbounded chunk.
    var maximumSeconds: Double = 180
    /// Mean absolute amplitude under which a window counts as a pause. Int16 full
    /// scale is 32767, so this is roughly -54 dBFS: quiet room, not pure digital
    /// silence, which real microphones never produce.
    var silenceThreshold: Double = 60
    /// How much audio the pause has to cover before it is treated as a boundary
    /// rather than the gap between two words.
    var silenceWindowSeconds: Double = 0.4

    /// A speaker change below this much accumulated audio is not worth a chunk. A
    /// lively exchange would otherwise produce one upload per interjection. The cost
    /// is that a very short interjection is absorbed into a neighbouring chunk and
    /// labelled with whoever held most of it.
    var minimumSpeakerSeconds: Double = 5
    /// How far back to hunt for the pause that a speaker change sits in.
    var speakerLookbackSeconds: Double = 4
    /// How far captions trail the audio they describe. Google has to hear the words
    /// before it can render them, so a change announced now happened slightly ago.
    /// Only used when no pause can be found, which means the speakers talked over
    /// each other and no cut is truly right.
    var captionLagSeconds: Double = 1.5

    private var targetFrames: Int { Int(targetSeconds * Double(Self.sampleRate)) }
    private var maximumFrames: Int { Int(maximumSeconds * Double(Self.sampleRate)) }
    private var silenceFrames: Int { Int(silenceWindowSeconds * Double(Self.sampleRate)) }
    private var minimumSpeakerFrames: Int { Int(minimumSpeakerSeconds * Double(Self.sampleRate)) }

    /// Whether `samples` should be closed off as a chunk now.
    ///
    /// Below the target the answer is always no, so a short meeting stays a single
    /// chunk. Past the target it waits for a pause; past the maximum it stops
    /// waiting. The pause is measured over the tail, so the cut lands in the silence
    /// itself rather than at the start of the next word.
    func shouldClose(_ samples: [Int16]) -> Bool {
        guard samples.count >= targetFrames else { return false }
        guard samples.count < maximumFrames else { return true }
        return Self.isQuiet(samples.suffix(silenceFrames), threshold: silenceThreshold)
    }

    /// How many samples to keep when the meeting UI reports a new speaker, or nil to
    /// let the chunk run on.
    ///
    /// The caption change proposes the cut and the audio picks the exact sample: a
    /// speaker change almost always sits in a small pause, and cutting there is both
    /// more accurate than compensating for caption lag and self-correcting when the
    /// lag varies.
    func speakerCutPoint(in samples: [Int16]) -> Int? {
        guard samples.count >= minimumSpeakerFrames else { return nil }
        if let pause = pauseCutPoint(in: samples, lookbackSeconds: speakerLookbackSeconds), pause > 0 {
            return pause
        }
        let compensated = samples.count - Int(captionLagSeconds * Double(Self.sampleRate))
        return compensated > 0 ? compensated : nil
    }

    /// Start of the most recent quiet window within `lookbackSeconds` of the tail,
    /// or nil when the speaker talked straight through the boundary.
    ///
    /// Prefix sums rather than re-measuring every candidate window: the search covers
    /// four seconds of 16 kHz audio and the naive form is quadratic over it.
    func pauseCutPoint(in samples: [Int16], lookbackSeconds: Double) -> Int? {
        let window = silenceFrames
        guard window > 0 else { return nil }

        let lookback = Int(lookbackSeconds * Double(Self.sampleRate))
        let lowerBound = max(0, samples.count - lookback)
        guard samples.count - lowerBound >= window else { return nil }

        let region = Array(samples[lowerBound...])
        var prefix = [Double](repeating: 0, count: region.count + 1)
        for index in 0..<region.count {
            prefix[index + 1] = prefix[index] + Double(abs(Int(region[index])))
        }

        // Latest quiet window wins: the cut belongs at the speaker's most recent
        // pause, not their first one four seconds ago.
        var start = region.count - window
        while start >= 0 {
            let mean = (prefix[start + window] - prefix[start]) / Double(window)
            if mean < silenceThreshold { return lowerBound + start }
            start -= 1
        }
        return nil
    }

    /// Mean absolute amplitude, which is cheap and stable enough for a pause test.
    /// An empty window counts as quiet: no audio is not speech.
    static func isQuiet<S: Sequence>(_ samples: S, threshold: Double) -> Bool where S.Element == Int16 {
        var total = 0.0
        var count = 0
        for sample in samples {
            total += Double(abs(Int(sample)))
            count += 1
        }
        guard count > 0 else { return true }
        return total / Double(count) < threshold
    }

    /// Seconds of audio in a sample count, derived from the count rather than a
    /// clock so the two tracks stay aligned across a long meeting.
    static func duration(frames: Int) -> TimeInterval {
        TimeInterval(frames) / TimeInterval(sampleRate)
    }
}
