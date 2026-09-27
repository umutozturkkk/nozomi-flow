import Foundation
import AVFAudio

/// One upload-sized piece of one track, already on disk.
struct MeetingChunk: Equatable {
    let track: MeetingTrack
    let index: Int
    let url: URL
    /// Seconds from the start of the meeting, derived from samples written rather
    /// than a clock, so the two tracks can be interleaved by time afterwards.
    let startOffset: TimeInterval
    let duration: TimeInterval
    /// Who the meeting UI said was talking for most of this chunk, when anything was
    /// reading the meeting UI. Stamped as the chunk closes rather than looked up by
    /// offset afterwards: offsets come from samples written while caption times come
    /// from the wall clock, and the two drift if the capture ever drops a buffer.
    var speaker: String?

    var endOffset: TimeInterval { startOffset + duration }
}

/// Turns the two live capture tracks into chunked WAV files on disk.
///
/// Memory stays flat for a meeting of any length: samples accumulate only until a
/// chunk closes, then they are written out and dropped. Peak usage is both tracks
/// times one chunk, roughly 8 MB, whether the meeting runs ten minutes or three
/// hours.
final class MeetingRecorder: @unchecked Sendable {

    /// Fired as each chunk lands, so transcription can start on early audio while
    /// the meeting is still going rather than waiting for the whole recording.
    var onChunk: ((MeetingChunk) -> Void)?

    private let directory: URL
    private let chunker: MeetingChunker
    private let lock = NSLock()
    private var writers: [MeetingTrack: TrackWriter] = [:]

    init(directory: URL, chunker: MeetingChunker = MeetingChunker()) throws {
        self.directory = directory
        self.chunker = chunker
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    /// Feed a captured buffer. Safe to call from the capture queue.
    func accept(_ track: MeetingTrack, buffer: AVAudioPCMBuffer) {
        guard let samples = PCMConverter.shared.toUploadFormat(buffer, for: track), !samples.isEmpty else { return }

        let finished: MeetingChunk? = {
            lock.lock(); defer { lock.unlock() }
            let writer = writers[track] ?? TrackWriter(track: track, directory: directory)
            writers[track] = writer
            writer.append(samples)
            guard chunker.shouldClose(writer.pending) else { return nil }
            return writer.flush()
        }()

        if let finished { onChunk?(finished) }
    }

    /// The meeting UI reported a new speaker on the far side.
    ///
    /// This is what fixes the two minute blob: instead of cutting the remote track on
    /// a timer and handing the summarizer a monologue, the chunk ends where the
    /// speaker did, so every upload belongs to one person and can be labelled with
    /// their name. A change too early in a chunk is remembered but not acted on, so a
    /// lively exchange does not become one upload per interjection.
    ///
    /// The microphone track ignores this entirely: it already has exactly one speaker.
    func speakerChanged(to name: String?) {
        let finished: MeetingChunk? = {
            lock.lock(); defer { lock.unlock() }
            let writer = writers[.system] ?? TrackWriter(track: .system, directory: directory)
            writers[.system] = writer

            guard let cut = chunker.speakerCutPoint(in: writer.pending) else {
                writer.noteSpeaker(name)
                return nil
            }
            let chunk = writer.flush(upTo: cut)
            // Everything past the cut is the pause and the new speaker's opening
            // words, which the caption engine was still catching up on.
            writer.resetSpeaker(to: name)
            return chunk
        }()

        if let finished { onChunk?(finished) }
    }

    /// Closes whatever is still buffered and hands the trailing chunks back.
    ///
    /// Deliberately does not fire `onChunk` for them: the caller already has them as
    /// the return value, and announcing them as well had the session controller queue
    /// each one for upload twice.
    func finish() -> [MeetingChunk] {
        lock.lock()
        let trailing = writers.values.compactMap { $0.flush() }
        writers.removeAll()
        lock.unlock()
        return trailing.sorted { $0.startOffset < $1.startOffset }
    }
}

// MARK: - Per-track accumulation

/// Accumulates one track and writes each closed chunk as a WAV. Not thread-safe on
/// its own; `MeetingRecorder` serializes access.
private final class TrackWriter {
    let track: MeetingTrack
    private(set) var pending: [Int16] = []

    private let directory: URL
    private var index = 0
    private var framesWritten = 0

    /// Who held the track over each stretch of `pending`, as (name, first sample).
    /// A range rather than a single current name because a chunk can outlive several
    /// speaker changes, and the label belongs to whoever actually filled it.
    private var runs: [(name: String?, start: Int)] = []

    init(track: MeetingTrack, directory: URL) {
        self.track = track
        self.directory = directory
    }

    func append(_ samples: [Int16]) {
        pending.append(contentsOf: samples)
    }

    /// Records a speaker change without cutting. Repeats are collapsed so the run
    /// list stays as short as the conversation actually is.
    func noteSpeaker(_ name: String?) {
        if let last = runs.last, last.name == name { return }
        runs.append((name, pending.count))
    }

    /// Declares that everything still buffered belongs to `name`, used right after a
    /// cut where the remaining tail is the pause and the new speaker's first words.
    func resetSpeaker(to name: String?) {
        runs = [(name, 0)]
    }

    /// Writes the pending samples out and resets. Returns nil when there is nothing
    /// buffered, so finishing an idle track produces no empty file.
    func flush() -> MeetingChunk? {
        flush(upTo: pending.count)
    }

    /// Writes the first `limit` samples as a chunk and keeps the rest as the start of
    /// the next one, so cutting mid-buffer never drops audio.
    func flush(upTo limit: Int) -> MeetingChunk? {
        let cut = min(max(limit, 0), pending.count)
        guard cut > 0 else { return nil }

        let head = Array(pending[..<cut])
        let speaker = dominantSpeaker(within: cut)
        let url = directory.appendingPathComponent(String(format: "%@-%03d.wav", track.rawValue, index))
        let wav = CloudTranscriptionSession.makeWAV(samples: head, sampleRate: MeetingChunker.sampleRate)
        do {
            try wav.write(to: url, options: .atomic)
        } catch {
            Log.audio.error("could not write meeting chunk: \(error.localizedDescription)")
            pending.removeFirst(cut)
            rebaseRuns(after: cut)
            return nil
        }

        let chunk = MeetingChunk(
            track: track,
            index: index,
            url: url,
            startOffset: MeetingChunker.duration(frames: framesWritten),
            duration: MeetingChunker.duration(frames: cut),
            speaker: speaker
        )
        index += 1
        framesWritten += cut
        pending.removeFirst(cut)
        rebaseRuns(after: cut)
        return chunk
    }

    /// Whoever held the most samples before `limit`. Ties and unnamed stretches
    /// simply lose, which leaves the chunk unlabelled and the transcript falling back
    /// to the track's own label.
    private func dominantSpeaker(within limit: Int) -> String? {
        var totals: [String: Int] = [:]
        for (position, run) in runs.enumerated() {
            guard run.start < limit else { break }
            let next = position + 1 < runs.count ? min(runs[position + 1].start, limit) : limit
            guard let name = run.name, next > run.start else { continue }
            totals[name, default: 0] += next - run.start
        }
        return totals.max { $0.value < $1.value }?.key
    }

    /// Shifts the run list into the next chunk's coordinates. The run spanning the
    /// cut becomes that chunk's opening run rather than being dropped.
    private func rebaseRuns(after cut: Int) {
        var rebased: [(name: String?, start: Int)] = []
        for run in runs {
            if run.start <= cut {
                rebased = [(run.name, 0)]
            } else {
                rebased.append((run.name, run.start - cut))
            }
        }
        runs = rebased
    }
}

// MARK: - Format conversion

/// Converts captured audio into the 16 kHz mono PCM16 the transcription endpoints
/// take. One converter is kept per track: the two arrive in different formats, and
/// AVAudioConverter carries resampling state that must not be shared between them.
final class PCMConverter: @unchecked Sendable {
    static let shared = PCMConverter()

    private let lock = NSLock()
    private var converters: [MeetingTrack: (converter: AVAudioConverter, inputFormat: AVAudioFormat)] = [:]

    private static let target = AVAudioFormat(
        commonFormat: .pcmFormatInt16,
        sampleRate: Double(MeetingChunker.sampleRate),
        channels: 1,
        interleaved: true
    )

    func toUploadFormat(_ buffer: AVAudioPCMBuffer, for track: MeetingTrack) -> [Int16]? {
        guard buffer.frameLength > 0, let target = Self.target else { return nil }
        let inputFormat = buffer.format

        lock.lock()
        var entry = converters[track]
        if entry == nil || !Self.formatsMatch(entry?.inputFormat, inputFormat) {
            guard let converter = AVAudioConverter(from: inputFormat, to: target) else {
                lock.unlock()
                Log.audio.error("no converter for \(track.rawValue) input format")
                return nil
            }
            entry = (converter, inputFormat)
            converters[track] = entry
        }
        let converter = entry!.converter
        lock.unlock()

        // AVAudioConverter consumes only as many frames as it asks for per call and
        // discards the rest of whatever buffer the callback returned, so handing it
        // a large capture buffer whole silently truncates the audio. Feeding it in
        // slices no bigger than one pull keeps every frame. Dictation never hit this
        // because its mic tap already delivers 4096 frames at a time; ScreenCaptureKit
        // buffers are not bound to that size.
        var collected: [Int16] = []
        var offset: AVAudioFrameCount = 0
        while offset < buffer.frameLength {
            let count = min(Self.sliceFrames, buffer.frameLength - offset)
            guard let slice = Self.slice(buffer, from: offset, count: count) else { break }
            if let converted = Self.convertOnce(slice, using: converter, to: target) {
                collected.append(contentsOf: converted)
            }
            offset += count
        }
        return collected.isEmpty ? nil : collected
    }

    /// Drops cached converters so a new meeting starts without resampling state
    /// carried over from the previous one.
    func reset() {
        lock.lock(); defer { lock.unlock() }
        converters.removeAll()
    }

    /// One pull's worth of input. Matches the dictation mic tap, which is the size
    /// this conversion path has always been exercised at.
    private static let sliceFrames: AVAudioFrameCount = 4096

    /// Copies a frame range into its own buffer so it can be handed to the converter
    /// as a complete input. Shared with the dictation path, which has the same
    /// truncation hazard.
    static func slice(
        _ buffer: AVAudioPCMBuffer, from offset: AVAudioFrameCount, count: AVAudioFrameCount
    ) -> AVAudioPCMBuffer? {
        if offset == 0 && count == buffer.frameLength { return buffer }
        let format = buffer.format
        guard let slice = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: count) else { return nil }
        slice.frameLength = count

        // Interleaved formats carry every channel in one buffer, non-interleaved one
        // buffer per channel; mBytesPerFrame already accounts for the difference.
        let source = UnsafeMutableAudioBufferListPointer(
            UnsafeMutablePointer(mutating: buffer.audioBufferList))
        let destination = UnsafeMutableAudioBufferListPointer(slice.mutableAudioBufferList)
        guard source.count == destination.count else { return nil }

        let bytesPerFrame = Int(format.streamDescription.pointee.mBytesPerFrame)
        for index in 0..<source.count {
            guard let from = source[index].mData, let to = destination[index].mData else { return nil }
            memcpy(to, from.advanced(by: Int(offset) * bytesPerFrame), Int(count) * bytesPerFrame)
        }
        return slice
    }

    /// A single conversion pass over one fully-formed input buffer.
    private static func convertOnce(
        _ input: AVAudioPCMBuffer, using converter: AVAudioConverter, to target: AVAudioFormat
    ) -> [Int16]? {
        let ratio = target.sampleRate / max(input.format.sampleRate, 1)
        let capacity = AVAudioFrameCount((Double(input.frameLength) * ratio).rounded(.up)) + 32
        guard let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: max(capacity, 32)) else { return nil }

        var delivered = false
        var conversionError: NSError?
        let status = converter.convert(to: output, error: &conversionError) { _, inputStatus in
            if delivered {
                inputStatus.pointee = .noDataNow
                return nil
            }
            delivered = true
            inputStatus.pointee = .haveData
            return input
        }
        guard status != .error else {
            Log.audio.error("meeting convert failed: \(conversionError?.localizedDescription ?? "unknown")")
            return nil
        }
        guard output.frameLength > 0, let channel = output.int16ChannelData else { return nil }
        return Array(UnsafeBufferPointer(start: channel[0], count: Int(output.frameLength)))
    }

    private static func formatsMatch(_ a: AVAudioFormat?, _ b: AVAudioFormat) -> Bool {
        guard let a else { return false }
        return a.sampleRate == b.sampleRate
            && a.channelCount == b.channelCount
            && a.commonFormat == b.commonFormat
            && a.isInterleaved == b.isInterleaved
    }
}
