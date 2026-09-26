import Foundation
import AVFAudio

/// Writes exactly what the mic tap delivered during one dictation to a .caf
/// file, so a transcript that came back short can be checked against the audio
/// the app really heard. Off unless turned on from the terminal:
///
///     defaults write co.nozomi.flow debugAudioCapture -bool true
///
/// Files go to ~/Library/Application Support/Murmur/Debug/ and are never
/// cleaned up automatically; this is a diagnostic, not a feature.
final class DebugAudioRecorder {

    static var isEnabled: Bool {
        UserDefaults.standard.bool(forKey: "debugAudioCapture")
    }

    static var defaultDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Murmur/Debug", isDirectory: true)
    }

    // Touched from the main thread (begin/end) and the audio thread (append).
    private let lock = NSLock()
    private var file: AVAudioFile?

    /// Opens a new timestamped file and returns its URL, or nil if it couldn't
    /// be created (the dictation itself must never fail because of this).
    func begin(format: AVAudioFormat, in directory: URL = DebugAudioRecorder.defaultDirectory) -> URL? {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss-SSS"
        let url = directory.appendingPathComponent("dictation_\(formatter.string(from: Date())).caf")
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let opened = try AVAudioFile(
                forWriting: url, settings: format.settings,
                commonFormat: format.commonFormat, interleaved: format.isInterleaved
            )
            lock.lock(); file = opened; lock.unlock()
            return url
        } catch {
            Log.audio.error("debug audio capture could not open \(url.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        lock.lock(); defer { lock.unlock() }
        try? file?.write(from: buffer)
    }

    func end() {
        lock.lock(); file = nil; lock.unlock()
    }
}
