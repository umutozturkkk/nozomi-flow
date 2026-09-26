import Foundation
import AppKit

/// How session startup ends once `beginSession` returns and the key-up race is known.
/// Extracted as a pure decision, in the same spirit as `EngineSelector`, because the
/// consequence of getting it wrong is a HUD stuck on "Polishing..." with no owner left
/// to resolve the phase, and that is not reachable from a unit test otherwise.
enum StartupRace: Equatable {
    /// Recording is still live; wire up audio and run.
    case proceed
    /// A newer session already owns the phase and will resolve it itself.
    case supersededByNewerSession
    /// Key-up ran first on a quick tap. `stopAndProcess` has already moved the phase to
    /// `.processing` and is awaiting this task, so startup owns resolving it: returning
    /// quietly here would leave the phase stuck forever.
    case keyUpBeatStartup

    static func resolve(generationMatches: Bool, stillRecording: Bool) -> StartupRace {
        guard generationMatches else { return .supersededByNewerSession }
        return stillRecording ? .proceed : .keyUpBeatStartup
    }
}

/// The state machine driving a dictation/command session:
/// idle -> recording -> processing -> inserting -> success/failure -> idle.
/// All entry points run on the main actor; audio buffers flow off-main into the transcriber.
@MainActor
final class DictationCoordinator {
    private let appState: AppState
    private let settings: SettingsStore
    private let audio: AudioCaptureServiceProtocol
    private let transcriber: TranscriptionServiceProtocol
    private let formatter: FormattingServiceProtocol
    private let inserter: TextInsertionServiceProtocol
    private let contextProvider: AppContextProviderProtocol
    private let dictionary: PersonalDictionaryStore
    private let history: HistoryStore
    private let permissions: PermissionsService
    private let sounds: SoundPlayer

    /// Set by AppDelegate to open the onboarding/permissions window.
    var onNeedsPermissions: (() -> Void)?

    private var sessionMode: SessionMode = .dictation
    private var sessionStart: Date?
    private var pendingContext: AppContextInfo?
    private var capturedSelection: String?
    private var startupTask: Task<Bool, Never>?
    /// Monotonic session id. Bumped on every begin/cancel/fail so in-flight
    /// tasks from a superseded session can detect they're stale and bail out
    /// (e.g. Esc during .processing must never reach insertion).
    private var sessionGeneration = 0
    private var lastQuickTapAt: Date?
    private var maxTimer: Timer?
    private var idleTimer: Timer?
    /// Holds mic audio captured before the recognizer session is ready.
    private let handoff = AudioHandoff()

    init(
        appState: AppState,
        settings: SettingsStore,
        audio: AudioCaptureServiceProtocol,
        transcriber: TranscriptionServiceProtocol,
        formatter: FormattingServiceProtocol,
        inserter: TextInsertionServiceProtocol,
        contextProvider: AppContextProviderProtocol,
        dictionary: PersonalDictionaryStore,
        history: HistoryStore,
        permissions: PermissionsService,
        hotkeys: HotkeyServiceProtocol,
        sounds: SoundPlayer
    ) {
        self.appState = appState
        self.settings = settings
        self.audio = audio
        self.transcriber = transcriber
        self.formatter = formatter
        self.inserter = inserter
        self.contextProvider = contextProvider
        self.dictionary = dictionary
        self.history = history
        self.permissions = permissions
        self.sounds = sounds

        hotkeys.onDictationKeyDown = { [weak self] in self?.keyDown(mode: .dictation) }
        hotkeys.onDictationKeyUp = { [weak self] in self?.keyUp(mode: .dictation) }
        hotkeys.onCommandKeyDown = { [weak self] in self?.keyDown(mode: .command) }
        hotkeys.onCommandKeyUp = { [weak self] in self?.keyUp(mode: .command) }
        hotkeys.onEscape = { [weak self] in self?.escapePressed() }
    }

    // MARK: - Hotkey entry points

    func keyDown(mode: SessionMode) {
        // A tap while a hands-free recording is running stops and processes it.
        if case .recording(_, let handsFree) = appState.phase {
            if handsFree { stopAndProcess() }
            return
        }
        guard appState.phase.canStartNewSession, !appState.isPaused else { return }
        beginSession(mode: mode)
    }

    func keyUp(mode: SessionMode) {
        guard case .recording(let startedAt, let handsFree) = appState.phase, mode == sessionMode else { return }
        if handsFree { return } // hands-free sessions ignore key-up; stopped by tap/esc/timeout

        let duration = Date().timeIntervalSince(startedAt)
        if duration < settings.minRecordingSeconds {
            // Quick tap: possibly the second tap of a double-tap -> hands-free lock.
            let now = Date()
            if settings.handsFreeEnabled,
               let last = lastQuickTapAt,
               now.timeIntervalSince(last) < settings.doubleTapWindow {
                lastQuickTapAt = nil
                appState.phase = .recording(startedAt: startedAt, handsFree: true)
                Log.app.info("hands-free lock engaged")
                return
            }
            lastQuickTapAt = now
            cancelSession(reason: nil) // silent discard
            return
        }
        lastQuickTapAt = nil
        stopAndProcess()
    }

    func escapePressed() {
        switch appState.phase {
        case .recording, .processing:
            cancelSession(reason: .cancelled)
        default:
            break
        }
    }

    /// Menu-bar triggered test session (also useful before hotkeys are granted).
    func debugSimulate(seconds: TimeInterval = 2.0) {
        keyDown(mode: .dictation)
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in
            guard let self, case .recording = self.appState.phase else { return }
            self.stopAndProcess()
        }
    }

    func togglePause() {
        appState.isPaused.toggle()
        if appState.isPaused, case .recording = appState.phase {
            cancelSession(reason: .cancelled)
        }
    }

    // MARK: - Session lifecycle

    private func beginSession(mode: SessionMode) {
        idleTimer?.invalidate()
        sessionGeneration += 1
        let gen = sessionGeneration
        sessionMode = mode
        sessionStart = Date()
        capturedSelection = nil
        appState.sessionMode = mode
        appState.liveTranscript = ""
        appState.audioLevel = 0
        appState.phase = .recording(startedAt: sessionStart!, handsFree: false)

        if mode == .command {
            capturedSelection = inserter.selectedText()
        }
        pendingContext = contextProvider.snapshot(
            includeFieldText: settings.captureFieldContext && mode == .dictation
        )

        // Pre-build and prewarm the LLM session while the user is speaking, so
        // the instruction prefill cost overlaps recording instead of following it.
        if mode == .dictation, settings.formattingLevel == .full {
            formatter.prepareSession(for: makeFormattingRequest(raw: ""))
        }

        transcriber.onPartial = { [weak self] text in
            self?.appState.liveTranscript = text
        }
        audio.onLevel = { [weak self] level in
            self?.appState.audioLevel = level
        }
        // The start sound is the cue to speak, so it waits until the mic is really
        // hearing: on a cold device that is up to two seconds after key-down, and
        // anything said before it was lost.
        audio.onFirstBuffer = { [weak self] in
            guard let self, self.sessionGeneration == gen, self.appState.phase.isRecording else { return }
            if let keyDownAt = self.sessionStart {
                let ms = Int(Date().timeIntervalSince(keyDownAt) * 1000)
                Log.app.notice("mic live \(ms, privacy: .public) ms after key down")
            }
            self.sounds.playStart()
        }

        // Start the mic now rather than after the recognizer is set up, so nothing
        // said during setup is lost; the handoff holds it until the session attaches.
        handoff.reset()
        if permissions.microphone == .granted {
            guard startCapture() else { return }
        }

        // Chain onto the previous startup so TranscriptionEngine.beginSession is
        // never entered concurrently (rapid re-taps would otherwise orphan a session).
        let previousStartup = startupTask
        startupTask = Task { [weak self] in
            _ = await previousStartup?.value
            guard let self, self.sessionGeneration == gen else { return false }
            // Microphone permission (first run prompts here).
            if self.permissions.microphone != .granted {
                let granted = await self.permissions.requestMicrophone()
                self.permissions.refresh()
                guard self.sessionGeneration == gen else { return false }
                guard granted else {
                    self.fail(.micPermissionDenied)
                    self.onNeedsPermissions?()
                    return false
                }
                guard self.startCapture() else { return false }
            }
            do {
                let locale = self.settings.resolvedLocale
                // Pushed before engineKind, which now depends on it to decide between
                // the cloud endpoint and the on-device chain.
                (self.transcriber as? CloudConfigurableTranscriber)?
                    .updateCloudConfig(self.settings.cloudTranscriptionConfig)
                self.appState.currentEngine = await self.transcriber.engineKind(for: locale)
                guard self.sessionGeneration == gen else { return false }
                try await self.transcriber.beginSession(
                    locale: locale,
                    contextualStrings: self.dictionary.boostWords
                )
                // Startups are serialized, so the active transcriber session here is
                // ours to kill whichever way the race went.
                switch StartupRace.resolve(
                    generationMatches: self.sessionGeneration == gen,
                    stillRecording: self.appState.phase.isRecording
                ) {
                case .proceed:
                    break
                case .supersededByNewerSession:
                    self.transcriber.cancelSession()
                    return false
                case .keyUpBeatStartup:
                    self.transcriber.cancelSession()
                    self.fail(.tooShort)
                    return false
                }
                self.handoff.attach { [weak transcriber = self.transcriber] buffer in
                    transcriber?.acceptBuffer(buffer)
                }
                self.startMaxTimer()
                return true
            } catch {
                Log.app.error("session start failed: \(String(describing: error))")
                if self.sessionGeneration == gen {
                    self.fail(Self.startupError(from: error, downloadProgress: self.appState.modelDownloadProgress))
                    if case DictationError.modelUnavailable = error {
                        // Usually means the language model isn't downloaded yet --
                        // nudge the prepare pipeline (idempotent, observed by AppDelegate).
                        NotificationCenter.default.post(name: .murmurLocaleChanged, object: nil)
                    }
                }
                return false
            }
        }
    }

    /// Starts the mic feeding the handoff. On failure the session is failed and
    /// false is returned, so callers just bail out.
    private func startCapture() -> Bool {
        audio.bufferHandler = { [handoff] buffer, _ in handoff.accept(buffer) }
        do {
            try audio.start()
            return true
        } catch {
            Log.app.error("mic start failed: \(String(describing: error))")
            fail(.transcriptionFailed(error.localizedDescription))
            return false
        }
    }

    /// Maps a session-startup failure to the most informative user-facing error:
    /// a missing model with a download in flight becomes a progress message
    /// instead of a generic "transcription failed".
    private static func startupError(from error: Error, downloadProgress: Double?) -> DictationError {
        guard let dictationError = error as? DictationError else {
            return .transcriptionFailed(error.localizedDescription)
        }
        if case .modelUnavailable = dictationError {
            if let progress = downloadProgress {
                return .modelUnavailable(String(format: "downloading %.0f%%", progress * 100))
            }
            return .modelUnavailable("preparing — try again shortly")
        }
        return dictationError
    }

    /// Builds a FormattingRequest from current settings/context. `raw` is empty
    /// for the prewarm path; the real transcript is substituted at format time.
    private func makeFormattingRequest(raw: String, localeIdentifier: String? = nil) -> FormattingRequest {
        FormattingRequest(
            raw: raw,
            context: pendingContext ?? AppContextInfo(),
            level: settings.formattingLevel,
            llm: settings.llmEngine,
            dictionary: dictionary.enabledEntries,
            localeIdentifier: localeIdentifier ?? settings.resolvedLocale.identifier,
            customInstructions: settings.customInstructions.isEmpty ? nil : settings.customInstructions,
            removeFillers: settings.removeFillers,
            toneMatching: settings.toneMatching,
            openAIKey: settings.openAIKey.isEmpty ? nil : settings.openAIKey,
            openAIModel: settings.openAIModel
        )
    }

    private func stopAndProcess() {
        guard case .recording = appState.phase else { return }
        let mode = sessionMode
        let gen = sessionGeneration
        let startedAt = sessionStart ?? Date()
        appState.phase = .processing
        sounds.playStop()
        maxTimer?.invalidate()

        Task { [weak self] in
            guard let self else { return }
            let started = await self.startupTask?.value ?? false
            guard self.sessionGeneration == gen else { return } // superseded/cancelled
            self.audio.stop()
            self.appState.audioLevel = 0
            guard started else { return } // fail() already ran inside startupTask

            do {
                let outcome = try await self.transcriber.endSession()
                // Esc during .processing bumps the generation; never insert then.
                guard self.sessionGeneration == gen else { return }
                let raw = outcome.text.trimmingCharacters(in: .whitespacesAndNewlines)
                if DebugAudioRecorder.isEnabled {
                    Log.app.notice("raw transcript: \(raw, privacy: .public)")
                }
                guard !raw.isEmpty else { throw DictationError.noSpeechDetected }
                let duration = Date().timeIntervalSince(startedAt)

                switch mode {
                case .dictation:
                    try await self.finishDictation(raw: raw, outcome: outcome, duration: duration, gen: gen)
                case .command:
                    try await self.finishCommand(instruction: raw, outcome: outcome, duration: duration, gen: gen)
                }
            } catch let error as DictationError {
                guard self.sessionGeneration == gen else { return }
                self.fail(error)
            } catch {
                guard self.sessionGeneration == gen else { return }
                self.fail(.transcriptionFailed(error.localizedDescription))
            }
        }
    }

    private func finishDictation(raw: String, outcome: TranscriptionOutcome, duration: TimeInterval, gen: Int) async throws {
        var text = dictionary.apply(to: raw)
        let request = makeFormattingRequest(raw: text, localeIdentifier: outcome.localeIdentifier)
        let formatted = await formatter.format(request)
        guard sessionGeneration == gen else { return } // cancelled during formatting
        text = dictionary.apply(to: formatted.text)

        appState.phase = .inserting
        let insertion = await inserter.insert(text)
        if formatted.pressEnter, insertion.succeeded, insertion.method != .clipboardOnly {
            await inserter.pressEnter()
        }
        appState.lastInsertionOutcome = insertion
        appState.lastFinalText = text

        recordHistory(
            raw: raw, final: text, duration: duration, mode: .dictation,
            engine: outcome.engine, corrections: formatted.corrections
        )
        succeed(with: text)
    }

    private func finishCommand(instruction: String, outcome: TranscriptionOutcome, duration: TimeInterval, gen: Int) async throws {
        let result = try await formatter.applyCommand(
            instruction: instruction,
            selectedText: capturedSelection,
            context: pendingContext ?? AppContextInfo(),
            llm: settings.llmEngine,
            openAIKey: settings.openAIKey.isEmpty ? nil : settings.openAIKey,
            openAIModel: settings.openAIModel
        )
        guard sessionGeneration == gen else { return } // cancelled during the command
        appState.phase = .inserting
        let insertion: InsertionOutcome
        if capturedSelection != nil {
            insertion = await inserter.replaceSelection(with: result)
        } else {
            insertion = await inserter.insert(result)
        }
        appState.lastInsertionOutcome = insertion
        appState.lastFinalText = result

        recordHistory(raw: instruction, final: result, duration: duration, mode: .command, engine: outcome.engine, corrections: 0)
        succeed(with: result)
    }

    private func succeed(with text: String) {
        let words = text.split(whereSeparator: \.isWhitespace).count
        appState.phase = .success(wordCount: words)
        scheduleIdle(after: 1.2)
    }

    private func fail(_ error: DictationError) {
        Log.app.warning("session failed: \(String(describing: error))")
        sessionGeneration += 1
        transcriber.cancelSession()
        audio.stop()
        maxTimer?.invalidate()
        appState.audioLevel = 0
        if error == .cancelled || error == .noSpeechDetected {
            appState.phase = .failure(error)
            scheduleIdle(after: 1.4)
        } else {
            sounds.playError()
            appState.phase = .failure(error)
            scheduleIdle(after: 2.2)
        }
    }

    private func cancelSession(reason: DictationError?) {
        sessionGeneration += 1
        startupTask?.cancel()
        transcriber.cancelSession()
        audio.stop()
        maxTimer?.invalidate()
        appState.audioLevel = 0
        appState.liveTranscript = ""
        if let reason {
            appState.phase = .failure(reason)
            scheduleIdle(after: 1.2)
        } else {
            appState.phase = .idle
        }
    }

    private func recordHistory(raw: String, final: String, duration: TimeInterval, mode: SessionMode, engine: TranscriptionEngineKind, corrections: Int) {
        guard settings.historyEnabled else { return }
        let entry = HistoryEntry(
            date: Date(),
            rawText: raw,
            finalText: final,
            appName: pendingContext?.appName,
            appBundleID: pendingContext?.bundleID,
            durationSeconds: duration,
            wordCount: final.split(whereSeparator: \.isWhitespace).count,
            mode: mode.rawValue,
            engine: engine.rawValue,
            correctionsCount: corrections
        )
        history.add(entry)
    }

    private func startMaxTimer() {
        maxTimer?.invalidate()
        maxTimer = Timer.scheduledTimer(withTimeInterval: settings.maxRecordingSeconds, repeats: false) { [weak self] _ in
            Task { @MainActor in
                guard let self, case .recording = self.appState.phase else { return }
                self.stopAndProcess()
            }
        }
    }

    private func scheduleIdle(after delay: TimeInterval) {
        idleTimer?.invalidate()
        idleTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                if self.appState.phase.canStartNewSession {
                    self.appState.phase = .idle
                    self.appState.liveTranscript = ""
                }
            }
        }
    }
}
