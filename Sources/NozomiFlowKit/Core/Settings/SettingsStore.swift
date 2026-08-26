import Foundation
import Observation
import ServiceManagement

/// UserDefaults-backed app settings. Every property persists on write.
@MainActor
@Observable
final class SettingsStore {
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var isLoading = true

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        load()
        isLoading = false
    }

    // MARK: - Hotkeys

    var dictationKey: HotkeyChoice = .fn {
        didSet { persist(dictationKey.rawValue, "dictationKey"); notifyHotkeys() }
    }
    var commandKey: HotkeyChoice = .rightCommand {
        didSet { persist(commandKey.rawValue, "commandKey"); notifyHotkeys() }
    }
    var handsFreeEnabled: Bool = true {
        didSet { persist(handsFreeEnabled, "handsFreeEnabled") }
    }

    // MARK: - Language

    /// nil = follow system language.
    var localeIdentifier: String? = nil {
        didSet {
            persist(localeIdentifier, "localeIdentifier")
            if !isLoading { NotificationCenter.default.post(name: .murmurLocaleChanged, object: nil) }
        }
    }

    var resolvedLocale: Locale {
        if let id = localeIdentifier, !id.isEmpty { return Locale(identifier: id) }
        return Locale.current
    }

    // MARK: - Formatting

    var formattingLevel: FormattingLevel = .full {
        didSet { persist(formattingLevel.rawValue, "formattingLevel") }
    }
    var llmEngine: LLMEngineChoice = .auto {
        didSet { persist(llmEngine.rawValue, "llmEngine") }
    }
    var removeFillers: Bool = true {
        didSet { persist(removeFillers, "removeFillers") }
    }
    var toneMatching: Bool = true {
        didSet { persist(toneMatching, "toneMatching") }
    }
    var customInstructions: String = "" {
        didSet { persist(customInstructions, "customInstructions") }
    }
    /// Read the focused text field's content via AX as LLM context.
    var captureFieldContext: Bool = true {
        didSet { persist(captureFieldContext, "captureFieldContext") }
    }

    // MARK: - Cloud LLM (optional)

    var openAIModel: String = "gpt-4o-mini" {
        didSet { persist(openAIModel, "openAIModel") }
    }
    /// Stored in the Keychain, not UserDefaults.
    var openAIKey: String = "" {
        didSet {
            guard !isLoading else { return }
            if openAIKey.isEmpty { KeychainHelper.delete(account: "openai_api_key") }
            else { KeychainHelper.set(openAIKey, account: "openai_api_key") }
        }
    }

    // MARK: - Cloud transcription (optional)

    /// Sends recorded audio to a cloud endpoint instead of transcribing on-device.
    /// Far more accurate on Turkish mixed with English technical terms, at the cost of
    /// the audio leaving the machine and there being no live partial transcript.
    var cloudTranscriptionEnabled: Bool = false {
        didSet {
            persist(cloudTranscriptionEnabled, "cloudTranscriptionEnabled")
            // Same signal as a locale change: which engine will run has changed, so
            // whoever prepares the transcriber needs to look again.
            if !isLoading { NotificationCenter.default.post(name: .murmurLocaleChanged, object: nil) }
        }
    }
    var cloudTranscriptionModel: String = "microsoft/mai-transcribe-1.5" {
        didSet { persist(cloudTranscriptionModel, "cloudTranscriptionModel") }
    }
    /// Stored in the Keychain, not UserDefaults.
    var cloudTranscriptionKey: String = "" {
        didSet {
            guard !isLoading else { return }
            if cloudTranscriptionKey.isEmpty { KeychainHelper.delete(account: "cloud_asr_api_key") }
            else { KeychainHelper.set(cloudTranscriptionKey, account: "cloud_asr_api_key") }
        }
    }

    /// Chat model that writes meeting notes. Separate from the cleanup model: a
    /// summary is worth a stronger model than a per-dictation tidy-up, and it runs
    /// once per meeting rather than once per sentence.
    var meetingSummaryModel: String = "google/gemini-2.5-flash-lite" {
        didSet { persist(meetingSummaryModel, "meetingSummaryModel") }
    }

    /// Reads the meeting window's captions and participant list to label who is
    /// speaking. On by default because a transcript that cannot name anyone is the
    /// problem this solves, and off is a single switch away for anyone who would
    /// rather nothing read their screen.
    var meetingSpeakerDetectionEnabled: Bool = true {
        didSet { persist(meetingSpeakerDetectionEnabled, "meetingSpeakerDetectionEnabled") }
    }

    /// What to call the microphone's owner in a meeting transcript. Real names on
    /// both sides make notes readable by someone who was not on the call, and give
    /// the summarizer one consistent vocabulary instead of "You" against a name.
    var userDisplayName: String = "" {
        didSet { persist(userDisplayName, "userDisplayName") }
    }

    /// The name to actually write, falling back to the account's full name so the
    /// setting can stay empty and still produce something better than "You".
    var resolvedUserDisplayName: String {
        let trimmed = userDisplayName.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? NSFullUserName() : trimmed
    }

    var cloudTranscriptionConfig: CloudTranscriptionConfig {
        CloudTranscriptionConfig(
            isEnabled: cloudTranscriptionEnabled,
            model: cloudTranscriptionModel,
            apiKey: cloudTranscriptionKey
        )
    }

    // MARK: - Behavior

    var playSounds: Bool = true {
        didSet { persist(playSounds, "playSounds") }
    }
    var showLiveTranscript: Bool = true {
        didSet { persist(showLiveTranscript, "showLiveTranscript") }
    }
    var historyEnabled: Bool = true {
        didSet { persist(historyEnabled, "historyEnabled") }
    }
    var hasCompletedOnboarding: Bool = false {
        didSet { persist(hasCompletedOnboarding, "hasCompletedOnboarding") }
    }

    var launchAtLogin: Bool = false {
        didSet {
            persist(launchAtLogin, "launchAtLogin")
            guard !isLoading else { return }
            do {
                if launchAtLogin { try SMAppService.mainApp.register() }
                else { try SMAppService.mainApp.unregister() }
            } catch {
                Log.app.error("launch-at-login toggle failed: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Constants (not user-facing)

    @ObservationIgnored let minRecordingSeconds: TimeInterval = 0.35
    @ObservationIgnored let doubleTapWindow: TimeInterval = 0.6
    @ObservationIgnored let maxRecordingSeconds: TimeInterval = 600

    // MARK: - Persistence plumbing

    private func persist(_ value: Any?, _ key: String) {
        guard !isLoading else { return }
        if let value { defaults.set(value, forKey: key) }
        else { defaults.removeObject(forKey: key) }
    }

    private func notifyHotkeys() {
        guard !isLoading else { return }
        NotificationCenter.default.post(name: .murmurHotkeyConfigChanged, object: nil)
    }

    private func load() {
        if let raw = defaults.string(forKey: "dictationKey"), let v = HotkeyChoice(rawValue: raw) { dictationKey = v }
        if let raw = defaults.string(forKey: "commandKey"), let v = HotkeyChoice(rawValue: raw) { commandKey = v }
        if defaults.object(forKey: "handsFreeEnabled") != nil { handsFreeEnabled = defaults.bool(forKey: "handsFreeEnabled") }
        localeIdentifier = defaults.string(forKey: "localeIdentifier")
        if let raw = defaults.string(forKey: "formattingLevel"), let v = FormattingLevel(rawValue: raw) { formattingLevel = v }
        if let raw = defaults.string(forKey: "llmEngine"), let v = LLMEngineChoice(rawValue: raw) { llmEngine = v }
        if defaults.object(forKey: "removeFillers") != nil { removeFillers = defaults.bool(forKey: "removeFillers") }
        if defaults.object(forKey: "toneMatching") != nil { toneMatching = defaults.bool(forKey: "toneMatching") }
        customInstructions = defaults.string(forKey: "customInstructions") ?? ""
        if defaults.object(forKey: "captureFieldContext") != nil { captureFieldContext = defaults.bool(forKey: "captureFieldContext") }
        openAIModel = defaults.string(forKey: "openAIModel") ?? "gpt-4o-mini"
        openAIKey = KeychainHelper.get(account: "openai_api_key") ?? ""
        if defaults.object(forKey: "cloudTranscriptionEnabled") != nil {
            cloudTranscriptionEnabled = defaults.bool(forKey: "cloudTranscriptionEnabled")
        }
        cloudTranscriptionModel = defaults.string(forKey: "cloudTranscriptionModel") ?? "microsoft/mai-transcribe-1.5"
        cloudTranscriptionKey = KeychainHelper.get(account: "cloud_asr_api_key") ?? ""
        meetingSummaryModel = defaults.string(forKey: "meetingSummaryModel") ?? "google/gemini-2.5-flash-lite"
        if defaults.object(forKey: "meetingSpeakerDetectionEnabled") != nil {
            meetingSpeakerDetectionEnabled = defaults.bool(forKey: "meetingSpeakerDetectionEnabled")
        }
        userDisplayName = defaults.string(forKey: "userDisplayName") ?? ""
        if defaults.object(forKey: "playSounds") != nil { playSounds = defaults.bool(forKey: "playSounds") }
        if defaults.object(forKey: "showLiveTranscript") != nil { showLiveTranscript = defaults.bool(forKey: "showLiveTranscript") }
        if defaults.object(forKey: "historyEnabled") != nil { historyEnabled = defaults.bool(forKey: "historyEnabled") }
        hasCompletedOnboarding = defaults.bool(forKey: "hasCompletedOnboarding")
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }
}
