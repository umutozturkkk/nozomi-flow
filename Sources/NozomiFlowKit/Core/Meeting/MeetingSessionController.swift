import Foundation
import CoreGraphics
import AppKit

/// Where a meeting recording currently is.
enum MeetingPhase: Equatable {
    case idle
    case recording(startedAt: Date)
    /// Chunks are uploading and the summary is being written.
    case processing
    case failed(String)

    var isRecording: Bool {
        if case .recording = self { return true }
        return false
    }

    var isBusy: Bool {
        if case .idle = self { return false }
        if case .failed = self { return false }
        return true
    }
}

/// Drives one meeting from capture to written notes.
///
/// Transcription starts on chunks as they close rather than after the meeting ends,
/// so stopping a one-hour call does not begin an hour-long wait. Chunks that arrive
/// while recording is still running are already uploading by the time the user hits
/// stop.
@available(macOS 15.0, *)
@MainActor
@Observable
final class MeetingSessionController {
    private(set) var phase: MeetingPhase = .idle
    /// Set once notes are written, so the UI can offer to open them.
    private(set) var lastSaved: MeetingRecord?

    @ObservationIgnored private let settings: SettingsStore
    @ObservationIgnored private let store: MeetingStore

    @ObservationIgnored private var capture: MeetingAudioCapture?
    @ObservationIgnored private var recorder: MeetingRecorder?
    @ObservationIgnored private var transcriber: MeetingTranscriber?
    @ObservationIgnored private var pendingUploads: [Task<MeetingSegment?, Never>] = []
    @ObservationIgnored private var sessionID: String?
    @ObservationIgnored private var startedAt: Date?

    init(settings: SettingsStore, store: MeetingStore) {
        self.settings = settings
        self.store = store
    }

    // MARK: - Permission

    /// ScreenCaptureKit needs Screen Recording even to read audio alone. Preflight
    /// never prompts, so it is safe to call for a UI state.
    static var hasScreenRecordingPermission: Bool {
        CGPreflightScreenCaptureAccess()
    }

    /// Triggers the system prompt. macOS only shows it once per app; afterwards the
    /// user has to go to Settings, so callers should offer that too.
    @discardableResult
    static func requestScreenRecordingPermission() -> Bool {
        CGRequestScreenCaptureAccess()
    }

    static func openScreenRecordingSettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")
        if let url { NSWorkspace.shared.open(url) }
    }

    // MARK: - Lifecycle

    func toggle() {
        if phase.isRecording { Task { await stop() } } else { Task { await start() } }
    }

    func start() async {
        guard case .idle = phase else { return }
        guard settings.cloudTranscriptionConfig.isUsable else {
            phase = .failed("Meetings need cloud transcription turned on in Settings.")
            return
        }
        guard Self.hasScreenRecordingPermission else {
            Self.requestScreenRecordingPermission()
            phase = .failed("Screen Recording permission is needed to hear the other side.")
            return
        }

        let id = MeetingStore.makeID(for: Date())
        let started = Date()
        do {
            let recorder = try MeetingRecorder(directory: store.workingDirectory(for: id))
            let transcriber = MeetingTranscriber(
                config: settings.cloudTranscriptionConfig, locale: settings.resolvedLocale)
            let capture = MeetingAudioCapture()

            PCMConverter.shared.reset()
            recorder.onChunk = { [weak self] chunk in
                Task { @MainActor in self?.enqueue(chunk) }
            }
            capture.onBuffer = { [weak recorder] track, buffer, _ in
                recorder?.accept(track, buffer: buffer)
            }

            try await capture.start()

            self.sessionID = id
            self.startedAt = started
            self.recorder = recorder
            self.transcriber = transcriber
            self.capture = capture
            self.pendingUploads = []
            phase = .recording(startedAt: started)
        } catch {
            Log.audio.error("meeting start failed: \(error.localizedDescription)")
            phase = .failed("Could not start recording.")
        }
    }

    func stop() async {
        guard phase.isRecording, let recorder, let sessionID, let startedAt else { return }
        phase = .processing

        await capture?.stop()
        capture = nil
        for chunk in recorder.finish() { enqueue(chunk) }
        self.recorder = nil

        // Chunks queued while recording have been uploading all along; this only
        // waits on whatever is still outstanding.
        var segments: [MeetingSegment] = []
        for task in pendingUploads {
            if let segment = await task.value { segments.append(segment) }
        }
        pendingUploads = []
        transcriber = nil

        let lines = MeetingTranscript.merge(segments)
        let transcript = MeetingTranscript.markdown(lines)
        let duration = Date().timeIntervalSince(startedAt)

        let summary = await MeetingSummarizer(
            config: settings.cloudTranscriptionConfig,
            model: settings.meetingSummaryModel
        ).summarize(transcript: transcript)

        let record = store.save(
            id: sessionID, startedAt: startedAt, duration: duration,
            transcript: transcript, summary: summary)

        if record != nil { store.discardWorkingFiles(for: sessionID) }
        self.sessionID = nil
        self.startedAt = nil
        lastSaved = record
        phase = record == nil ? .failed("Could not write the meeting notes.") : .idle
    }

    /// Starts a chunk uploading immediately and remembers the task so `stop` can
    /// collect it.
    private func enqueue(_ chunk: MeetingChunk) {
        guard let transcriber else { return }
        pendingUploads.append(Task { await transcriber.transcribe([chunk]).first })
    }
}
