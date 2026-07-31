import Foundation
import CoreGraphics
import AppKit

/// Where a meeting recording currently is.
///
/// There is no failure state on purpose: a meeting that could not start is reported
/// through `onFailure` and leaves the controller idle. A phase the controller could
/// not leave would look identical to idle in the menu while silently swallowing
/// every later attempt.
enum MeetingPhase: Equatable {
    case idle
    case recording(startedAt: Date)
    /// Chunks are uploading and the summary is being written.
    case processing

    var isRecording: Bool {
        if case .recording = self { return true }
        return false
    }

    var isBusy: Bool {
        if case .idle = self { return false }
        return true
    }
}

/// Why a meeting was refused or lost, in a form the UI can act on: a permission
/// problem needs a different button from a configuration one.
enum MeetingFailure: Equatable {
    case cloudTranscriptionOff
    case screenRecordingDenied
    case couldNotStart
    case couldNotSaveNotes

    var title: String {
        switch self {
        case .cloudTranscriptionOff, .screenRecordingDenied, .couldNotStart:
            return "Meeting not started"
        case .couldNotSaveNotes:
            return "Meeting notes not saved"
        }
    }

    var message: String {
        switch self {
        case .cloudTranscriptionOff:
            return "Meetings are transcribed in the cloud. Turn on cloud transcription and add your API key in Settings."
        case .screenRecordingDenied:
            return "Nozomi Flow needs Screen Recording permission to hear the other side of the call. Nothing on your screen is recorded or kept. Quit and reopen the app after granting it."
        case .couldNotStart:
            return "The recording could not be started. Check that another app is not already capturing audio, then try again."
        case .couldNotSaveNotes:
            return "The meeting was recorded but its notes could not be written to disk."
        }
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

    /// Called when a meeting is refused or its notes are lost. The controller is idle
    /// again by then, so the handler reports the problem rather than clearing a state.
    @ObservationIgnored var onFailure: ((MeetingFailure) -> Void)?
    /// Called once notes are on disk, so the UI can offer to open them. Nothing else
    /// marks the end of a meeting: the work finishes minutes after the user stopped it.
    @ObservationIgnored var onNotesReady: ((MeetingRecord) -> Void)?

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
            onFailure?(.cloudTranscriptionOff)
            return
        }
        guard Self.hasScreenRecordingPermission else {
            // macOS only shows this prompt once per app; afterwards the alert's
            // button to System Settings is the only way through.
            Self.requestScreenRecordingPermission()
            onFailure?(.screenRecordingDenied)
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
            onFailure?(.couldNotStart)
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
        phase = .idle

        if let record { onNotesReady?(record) } else { onFailure?(.couldNotSaveNotes) }
    }

    /// Starts a chunk uploading immediately and remembers the task so `stop` can
    /// collect it.
    private func enqueue(_ chunk: MeetingChunk) {
        guard let transcriber else { return }
        pendingUploads.append(Task { await transcriber.transcribe([chunk]).first })
    }
}
