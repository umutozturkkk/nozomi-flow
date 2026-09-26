import AVFAudio

/// Bridges the gap between the mic going live on key-down and the recognizer
/// session being ready. Buffers that arrive before `attach` are held (as copies:
/// the tap refills its buffer for the next callback) and flushed in order when
/// the session attaches; after that, buffers go straight through.
///
/// `accept` runs on the audio thread, `attach`/`reset` on the main thread.
final class AudioHandoff: @unchecked Sendable {
    private let lock = NSLock()
    private var pending: [AVAudioPCMBuffer] = []
    private var target: ((AVAudioPCMBuffer) -> Void)?

    func accept(_ buffer: AVAudioPCMBuffer) {
        lock.lock(); defer { lock.unlock() }
        if let target {
            target(buffer)
        } else if let copy = Self.copy(buffer) {
            pending.append(copy)
        }
    }

    /// Delivers everything held so far, in order, then forwards live. Done under
    /// the lock so a buffer arriving mid-flush can't overtake the held ones.
    func attach(_ target: @escaping (AVAudioPCMBuffer) -> Void) {
        lock.lock(); defer { lock.unlock() }
        for buffer in pending { target(buffer) }
        pending = []
        self.target = target
    }

    /// Drops held audio and detaches, ready for the next session.
    func reset() {
        lock.lock(); defer { lock.unlock() }
        pending = []
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
