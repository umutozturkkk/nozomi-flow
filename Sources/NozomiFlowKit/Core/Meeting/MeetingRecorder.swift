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

    init(track: MeetingTrack, directory: URL) {
        self.track = track
        self.directory = directory
    }

    func append(_ samples: [Int16]) {
        pending.append(contentsOf: samples)
    }

    /// Writes the pending samples out and resets. Returns nil when there is nothing
    /// buffered, so finishing an idle track produces no empty file.
    func flush() -> MeetingChunk? {
        guard !pending.isEmpty else { return nil }

        let frames = pending.count
        let url = directory.appendingPathComponent(String(format: "%@-%03d.wav", track.rawValue, index))
        let wav = CloudTranscriptionSession.makeWAV(samples: pending, sampleRate: MeetingChunker.sampleRate)
        do {
            try wav.write(to: url, options: .atomic)
        } catch {
            Log.audio.error("could not write meeting chunk: \(error.localizedDescription)")
            pending.removeAll(keepingCapacity: true)
            return nil
        }

        let chunk = MeetingChunk(
            track: track,
            index: index,
            url: url,
            startOffset: MeetingChunker.duration(frames: framesWritten),
            duration: MeetingChunker.duration(frames: frames)
        )
        index += 1
        framesWritten += frames
        pending.removeAll(keepingCapacity: true)
        return chunk
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
