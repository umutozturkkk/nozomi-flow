import AppKit
import Observation

/// Menu bar presence: animated status icon + control menu.
@MainActor
final class StatusItemController: NSObject, NSMenuDelegate {
    private let appState: AppState
    private let coordinator: DictationCoordinator
    private let settings: SettingsStore
    private let openSettings: () -> Void
    private let openHistory: () -> Void
    private let openOnboarding: () -> Void
    private let toggleMeeting: () -> Void
    private let meetingPhase: () -> MeetingPhase

    /// Quick-switch options surfaced directly in the menu; the full locale
    /// list lives in Settings > General. nil identifier = follow the system.
    private static let languageOptions: [(title: String, identifier: String?)] = [
        (L10n.string("menu.language.systemDefault"), nil),
        ("English (US)", "en_US"),
        ("Türkçe", "tr_TR"),
    ]

    /// Optional usage-stats source for the menu's "words today" header line.
    /// The controller's init signature is a fixed contract (no HistoryStore
    /// parameter), so this stays nil until the integrator wires it, e.g.
    /// `statusItem.historyProvider = { [weak history] in history?.stats ?? UsageStats() }`.
    /// The line is hidden while nil.
    var historyProvider: (() -> UsageStats)?

    private var item: NSStatusItem!

    init(
        appState: AppState,
        coordinator: DictationCoordinator,
        settings: SettingsStore,
        openSettings: @escaping () -> Void,
        openHistory: @escaping () -> Void,
        openOnboarding: @escaping () -> Void,
        toggleMeeting: @escaping () -> Void,
        meetingPhase: @escaping () -> MeetingPhase
    ) {
        self.appState = appState
        self.coordinator = coordinator
        self.settings = settings
        self.openSettings = openSettings
        self.openHistory = openHistory
        self.openOnboarding = openOnboarding
        self.toggleMeeting = toggleMeeting
        self.meetingPhase = meetingPhase
        super.init()

        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.behavior = []
        item.menu = buildMenu()
        observeState()
    }

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()
        menu.delegate = self

        let engineHeader = NSMenuItem(title: "Nozomi Flow", action: nil, keyEquivalent: "")
        engineHeader.isEnabled = false
        engineHeader.tag = MenuTag.engineHeader.rawValue
        menu.addItem(engineHeader)

        let statsHeader = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        statsHeader.isEnabled = false
        statsHeader.isHidden = true
        statsHeader.tag = MenuTag.statsHeader.rawValue
        menu.addItem(statsHeader)

        menu.addItem(.separator())

        let test = NSMenuItem(title: L10n.string("menu.testDictation"), action: #selector(testDictation), keyEquivalent: "")
        test.target = self
        test.tag = MenuTag.testDictation.rawValue
        menu.addItem(test)

        let copyLast = NSMenuItem(title: L10n.string("menu.copyLastTranscript"), action: #selector(copyLastTranscript), keyEquivalent: "")
        copyLast.target = self
        copyLast.tag = MenuTag.copyLast.rawValue
        menu.addItem(copyLast)

        let pause = NSMenuItem(title: L10n.string("menu.pause"), action: #selector(togglePause), keyEquivalent: "")
        pause.target = self
        pause.tag = MenuTag.pause.rawValue
        menu.addItem(pause)

        let meeting = NSMenuItem(title: L10n.string("menu.meeting.record"), action: #selector(toggleMeetingRecording), keyEquivalent: "")
        meeting.target = self
        meeting.tag = MenuTag.meeting.rawValue
        menu.addItem(meeting)

        let language = NSMenuItem(title: L10n.string("menu.language"), action: nil, keyEquivalent: "")
        language.tag = MenuTag.language.rawValue
        let langMenu = NSMenu()
        langMenu.autoenablesItems = false
        for option in Self.languageOptions {
            let item = NSMenuItem(title: option.title, action: #selector(selectLanguage(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = option.identifier ?? ""
            langMenu.addItem(item)
        }
        langMenu.addItem(.separator())
        let moreLanguages = NSMenuItem(title: L10n.string("menu.language.more"), action: #selector(showSettings), keyEquivalent: "")
        moreLanguages.target = self
        langMenu.addItem(moreLanguages)
        language.submenu = langMenu
        menu.addItem(language)

        menu.addItem(.separator())

        let history = NSMenuItem(title: L10n.string("menu.history"), action: #selector(showHistory), keyEquivalent: "")
        history.target = self
        menu.addItem(history)

        let settings = NSMenuItem(title: L10n.string("menu.settings"), action: #selector(showSettings), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)

        let onboarding = NSMenuItem(title: L10n.string("menu.setupAssistant"), action: #selector(showOnboarding), keyEquivalent: "")
        onboarding.target = self
        menu.addItem(onboarding)

        menu.addItem(.separator())

        let quit = NSMenuItem(title: L10n.string("menu.quit"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)
        return menu
    }

    private enum MenuTag: Int {
        case pause = 101
        case copyLast = 102
        case testDictation = 103
        case engineHeader = 104
        case statsHeader = 105
        case language = 106
        case meeting = 107
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.item(withTag: MenuTag.engineHeader.rawValue)?.title = L10n.format("menu.engineHeader", appState.currentEngine.displayName)

        if let statsItem = menu.item(withTag: MenuTag.statsHeader.rawValue) {
            if let stats = historyProvider?() {
                statsItem.title = L10n.format(
                    stats.wordsToday == 1 ? "menu.wordsToday.one" : "menu.wordsToday.other",
                    stats.wordsToday
                )
                statsItem.isHidden = false
            } else {
                statsItem.isHidden = true
            }
        }

        if let langMenu = menu.item(withTag: MenuTag.language.rawValue)?.submenu {
            let current = settings.localeIdentifier ?? ""
            for item in langMenu.items {
                guard let id = item.representedObject as? String else { continue }
                item.state = (id == current) ? .on : .off
            }
        }

        menu.item(withTag: MenuTag.pause.rawValue)?.title = L10n.string(appState.isPaused ? "menu.resume" : "menu.pause")

        // The one control that has to say what it will do next, not what is happening:
        // a meeting runs for an hour and the menu is how it gets stopped.
        if let meetingItem = menu.item(withTag: MenuTag.meeting.rawValue) {
            switch meetingPhase() {
            case .idle:
                meetingItem.title = L10n.string("menu.meeting.record")
                meetingItem.isEnabled = true
            case .recording:
                meetingItem.title = L10n.string("menu.meeting.stop")
                meetingItem.isEnabled = true
            case .processing:
                meetingItem.title = L10n.string("menu.meeting.writingNotes")
                meetingItem.isEnabled = false
            }
        }
        menu.item(withTag: MenuTag.copyLast.rawValue)?.isEnabled = appState.lastFinalText != nil
        // A session in flight can't be interrupted by the debug trigger.
        menu.item(withTag: MenuTag.testDictation.rawValue)?.isEnabled = appState.phase.canStartNewSession
    }

    private func observeState() {
        withObservationTracking { [weak self] in
            self?.render()
        } onChange: { [weak self] in
            Task { @MainActor in self?.observeState() }
        }
    }

    private func render() {
        guard let button = item.button else { return }
        let symbol: String
        var tint: NSColor? = nil
        switch appState.phase {
        case .idle:
            symbol = appState.isPaused ? "waveform.slash" : "waveform"
        case .recording:
            symbol = "record.circle.fill"
            tint = .systemRed
        case .processing, .inserting:
            symbol = "ellipsis.circle"
        case .success:
            symbol = "checkmark.circle"
        case .failure:
            symbol = "exclamationmark.circle"
        }
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: "Nozomi Flow")
        image?.isTemplate = tint == nil
        button.image = image
        // Always assign explicitly (including nil) so a lingering red tint from
        // a previous .recording phase never survives into a template-icon phase.
        button.contentTintColor = tint
    }

    @objc private func selectLanguage(_ sender: NSMenuItem) {
        let id = (sender.representedObject as? String) ?? ""
        settings.localeIdentifier = id.isEmpty ? nil : id
    }

    @objc private func testDictation() { coordinator.debugSimulate() }
    @objc private func togglePause() { coordinator.togglePause() }
    @objc private func showSettings() { openSettings() }
    @objc private func showHistory() { openHistory() }
    @objc private func showOnboarding() { openOnboarding() }

    @objc private func copyLastTranscript() {
        guard let text = appState.lastFinalText else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
    }
}

extension StatusItemController {
    @objc fileprivate func toggleMeetingRecording() {
        toggleMeeting()
    }
}
