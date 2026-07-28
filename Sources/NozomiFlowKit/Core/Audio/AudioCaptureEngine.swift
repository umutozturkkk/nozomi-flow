import Foundation
import AVFAudio

/// Microphone capture via AVAudioEngine with RMS level metering and automatic
/// recovery from device/route changes (e.g. AirPods connecting mid-session).
/// There is no AVAudioSession on macOS -- the engine talks to Core Audio directly.
final class AudioCaptureEngine: AudioCaptureServiceProtocol {
    var bufferHandler: ((AVAudioPCMBuffer, AVAudioTime) -> Void)?
    var onLevel: ((Float) -> Void)?
    private(set) var isCapturing = false

    private let engine = AVAudioEngine()
    private let tapBus: AVAudioNodeBus = 0
    private let tapBufferSize: AVAudioFrameCount = 4096

    // Touched only from the audio render thread (single serial caller).
    private var smoothedLevel: Float = 0
    private var lastLevelPostAt: CFAbsoluteTime = 0
    private let levelPostInterval: CFAbsoluteTime = 1.0 / 30.0

    private var configChangeObserver: NSObjectProtocol?

    init() {
        configChangeObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: .main
        ) { [weak self] _ in
            self?.scheduleReconfigure()
        }
    }

    deinit {
        if let configChangeObserver {
            NotificationCenter.default.removeObserver(configChangeObserver)
        }
    }

    // MARK: - AudioCaptureServiceProtocol

    func start() throws {
        guard !isCapturing else { return }
        try installTapAndStart()
        isCapturing = true
    }

    func stop() {
        guard isCapturing else { return }
        engine.inputNode.removeTap(onBus: tapBus)
        engine.stop()
        isCapturing = false
        smoothedLevel = 0
    }

    // MARK: - Engine plumbing

    private func installTapAndStart() throws {
        let input = engine.inputNode
        let format = input.outputFormat(forBus: tapBus)
        input.installTap(onBus: tapBus, bufferSize: tapBufferSize, format: format) { [weak self] buffer, time in
            self?.handleBuffer(buffer, time: time)
        }
        engine.prepare()
        try engine.start()
    }

    /// Runs on the audio render thread.
    private func handleBuffer(_ buffer: AVAudioPCMBuffer, time: AVAudioTime) {
        bufferHandler?(buffer, time)
        updateLevel(from: buffer)
    }

    // MARK: - Level metering (audio thread)

    private func updateLevel(from buffer: AVAudioPCMBuffer) {
        guard let channelData = buffer.floatChannelData else { return }
        let frameCount = Int(buffer.frameLength)
        guard frameCount > 0 else { return }
        let channelCount = Int(buffer.format.channelCount)

        var sumOfSquares: Float = 0
        for channel in 0..<channelCount {
            let samples = channelData[channel]
            for i in 0..<frameCount {
                let s = samples[i]
                sumOfSquares += s * s
            }
        }
        let totalSamples = Float(frameCount * max(channelCount, 1))
        let rms = totalSamples > 0 ? sqrt(sumOfSquares / totalSamples) : 0

        let level: Float
        if rms <= 0 {
            level = 0
        } else {
            let db = 20 * log10(rms)
            level = Float(min(1, max(0, (db + 50) / 50)))
        }
        // Fast attack, slower decay so the waveform doesn't flicker on brief dips.
        smoothedLevel = max(level, smoothedLevel * 0.82)

        let now = CFAbsoluteTimeGetCurrent()
        guard now - lastLevelPostAt >= levelPostInterval else { return }
        lastLevelPostAt = now
        let toPost = smoothedLevel
        DispatchQueue.main.async { [weak self] in
            self?.onLevel?(toPost)
        }
    }

    // MARK: - Route/device change recovery

    private func scheduleReconfigure() {
        guard isCapturing else { return }
        // Never rebuild the graph synchronously inside the notification callback --
        // defer to the next run loop turn.
        DispatchQueue.main.async { [weak self] in
            self?.reconfigureAfterRouteChange()
        }
    }

    private func reconfigureAfterRouteChange() {
        guard isCapturing else { return }
        Log.audio.info("audio route changed; reinstalling tap with new native format")
        engine.inputNode.removeTap(onBus: tapBus)
        engine.stop()
        do {
            try installTapAndStart()
        } catch {
            Log.audio.error("failed to restart capture after route change: \(error.localizedDescription)")
            isCapturing = false
        }
    }
}
