import Foundation
import AVFAudio
import CoreMedia
import ScreenCaptureKit

/// Which side of a meeting a buffer came from.
///
/// ScreenCaptureKit hands microphone and system audio back as two separate output
/// types, so the split is free. Keeping the tracks apart all the way through
/// transcription gives speaker attribution without paying for cloud diarization,
/// which the transcription endpoint does not expose anyway: whatever the mic heard
/// is the user, whatever the system played is everyone else.
enum MeetingTrack: String, Equatable, CaseIterable {
    case microphone
    case system

    /// Label written into the transcript.
    var speakerLabel: String {
        switch self {
        case .microphone: return "You"
        case .system: return "Them"
        }
    }
}

/// Captures microphone and system audio simultaneously for meeting transcription.
///
/// ScreenCaptureKit is the only supported way to read system audio on macOS, and it
/// insists on being a *screen* capture: there is no audio-only stream. The video
/// side is therefore configured down to 2x2 pixels and its frames are dropped. This
/// still requires Screen Recording permission even though no screen content is
/// retained, which is worth saying plainly in the UI that asks for it.
@available(macOS 15.0, *)
final class MeetingAudioCapture: NSObject, @unchecked Sendable {

    /// Called on a private queue with buffers in whatever format that track
    /// arrived in. The two tracks do not share a format: system audio follows
    /// `sampleRate`/`channelCount` below, while the microphone arrives in its
    /// device's native format, so each needs its own converter downstream.
    var onBuffer: ((MeetingTrack, AVAudioPCMBuffer, CMTime) -> Void)?

    private(set) var isCapturing = false

    private var stream: SCStream?
    private let queue = DispatchQueue(label: "co.nozomi.flow.meeting-capture")

    /// System audio is requested at the format we ultimately upload, so the common
    /// case needs no resampling at all. The microphone still will.
    private static let sampleRate = 48_000
    private static let channelCount = 2

    // MARK: - Lifecycle

    func start() async throws {
        guard !isCapturing else { return }

        // A display filter with nothing excluded is the cheapest way to get a
        // stream that carries system audio; the display's pixels are discarded.
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        guard let display = content.displays.first else {
            throw MeetingCaptureError.noDisplayAvailable
        }

        let configuration = SCStreamConfiguration()
        configuration.width = 2
        configuration.height = 2
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        configuration.queueDepth = 6
        configuration.capturesAudio = true
        configuration.sampleRate = Self.sampleRate
        configuration.channelCount = Self.channelCount
        // Without this the app's own output (start/stop chimes, and anything the
        // user plays back) is fed straight back into the recording.
        configuration.excludesCurrentProcessAudio = true
        configuration.captureMicrophone = true

        let filter = SCContentFilter(display: display, excludingWindows: [])
        let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
        try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue)
        try stream.addStreamOutput(self, type: .microphone, sampleHandlerQueue: queue)
        // Screen output is never consumed, but the stream will not start without
        // somewhere for its frames to go.
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)

        try await stream.startCapture()
        self.stream = stream
        isCapturing = true
        Log.audio.info("meeting capture started (mic + system)")
    }

    func stop() async {
        guard let stream else { return }
        self.stream = nil
        isCapturing = false
        do { try await stream.stopCapture() } catch {
            Log.audio.error("meeting capture stop failed: \(error.localizedDescription)")
        }
    }
}

enum MeetingCaptureError: Error, Equatable {
    case noDisplayAvailable
    case screenRecordingDenied
}

// MARK: - Sample delivery

@available(macOS 15.0, *)
extension MeetingAudioCapture: SCStreamOutput {
    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        let track: MeetingTrack
        switch type {
        case .audio: track = .system
        case .microphone: track = .microphone
        case .screen: return          // 2x2 pixels we never look at
        @unknown default: return
        }
        guard sampleBuffer.isValid, let buffer = Self.pcmBuffer(from: sampleBuffer) else { return }
        onBuffer?(track, buffer, sampleBuffer.presentationTimeStamp)
    }

    /// Bridges an audio CMSampleBuffer into an AVAudioPCMBuffer without copying the
    /// samples twice. Returns nil for anything that is not linear PCM, which is what
    /// a screen frame looks like if one ever reaches here.
    static func pcmBuffer(from sampleBuffer: CMSampleBuffer) -> AVAudioPCMBuffer? {
        guard
            let description = sampleBuffer.formatDescription,
            description.mediaType == .audio,
            let streamDescription = description.audioStreamBasicDescription
        else { return nil }

        var asbd = streamDescription
        guard let format = AVAudioFormat(streamDescription: &asbd) else { return nil }

        let frames = AVAudioFrameCount(sampleBuffer.numSamples)
        guard frames > 0, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return nil }
        buffer.frameLength = frames

        // The samples are copied rather than aliased: the source block buffer is only
        // valid for the duration of this closure, while the buffer handed to the
        // callback outlives it.
        do {
            var copied = false
            try sampleBuffer.withAudioBufferList { source, _ in
                let destination = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
                guard source.count == destination.count else { return }
                for index in 0..<source.count {
                    guard let from = source[index].mData, let to = destination[index].mData else { return }
                    let bytes = min(Int(source[index].mDataByteSize), Int(destination[index].mDataByteSize))
                    memcpy(to, from, bytes)
                }
                copied = true
            }
            return copied ? buffer : nil
        } catch {
            return nil
        }
    }
}

// MARK: - Stream lifecycle

@available(macOS 15.0, *)
extension MeetingAudioCapture: SCStreamDelegate {
    func stream(_ stream: SCStream, didStopWithError error: Error) {
        Log.audio.error("meeting capture stopped: \(error.localizedDescription)")
        isCapturing = false
        self.stream = nil
    }
}
