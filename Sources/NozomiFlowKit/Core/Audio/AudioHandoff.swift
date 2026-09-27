import AVFAudio

/// Bridges the gap between the mic going live on key-down and the recognizer
/// session being ready. Buffers that arrive before `attach` are held (as copies:
/// the tap refills its buffer for the next callback) and flushed in order when
/// the session attaches; after that, buffers go straight through.
///
/// `accept` runs on the audio thread, `attach`/`reset` on the main thread.
final class AudioHandoff: @unchecked Sendable {
    /// Held audio beyond this is dropped (newest first), so a setup that hangs
    /// (a model download) can't grow memory without limit. Far longer than any
    /// normal startup.
    static let maxHeldSeconds: Double = 30

    private let lock = NSLock()
    private var pending: [AVAudioPCMBuffer] = []
    private var pendingFrames: Double = 0
    private var target: ((AVAudioPCMBuffer) -> Void)?

    func accept(_ buffer: AVAudioPCMBuffer) {
        lock.lock(); defer { lock.unlock() }
        if let target {
            target(buffer)
            return
        }
        guard pendingFrames < Self.maxHeldSeconds * buffer.format.sampleRate,
              let copy = Self.copy(buffer)
        else { return }
        pending.append(copy)
        pendingFrames += Double(copy.frameLength)
    }

    /// Delivers everything held so far, in order, then forwards live. Done under
    /// the lock so a buffer arriving mid-flush can't overtake the held ones.
    func attach(_ target: @escaping (AVAudioPCMBuffer) -> Void) {
        lock.lock(); defer { lock.unlock() }
        for buffer in pending { target(buffer) }
        pending = []
        pendingFrames = 0
        self.target = target
    }

    /// Drops held audio and detaches, ready for the next session.
    func reset() {
        lock.lock(); defer { lock.unlock() }
        pending = []
        pendingFrames = 0
        target = nil
    }

    private static func copy(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let copy = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: buffer.frameLength),
              let src = buffer.floatChannelData, let dst = copy.floatChannelData
        else { return nil }
        copy.frameLength = buffer.frameLength
        let bytes = Int(buffer.frameLength) * MemoryLayout<Float>.size
        for channel in 0..<Int(buffer.format.channelCount) {
            memcpy(dst[channel], src[channel], bytes)
        }
        return copy
    }
}
