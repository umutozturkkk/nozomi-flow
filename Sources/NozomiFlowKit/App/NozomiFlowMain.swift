import AppKit

public enum NozomiFlowMain {
    @MainActor
    public static func run() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.mainMenu = makeMainMenu()
        app.run()
    }

    /// An accessory app never shows a menu bar, but AppKit still routes ⌘X/⌘C/⌘V
    /// through the main menu's key equivalents. Without this menu those shortcuts do
    /// nothing in any text field, which is why an API key could only be typed by hand.
    @MainActor
    private static func makeMainMenu() -> NSMenu {
        let mainMenu = NSMenu()

        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(
            withTitle: "Quit \(Self.displayName)",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )
        appItem.submenu = appMenu
        mainMenu.addItem(appItem)

        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        // Targets stay nil so each command travels the responder chain to whichever
        // field is focused, rather than being bound to one control.
        editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = editMenu
        mainMenu.addItem(editItem)

        return mainMenu
    }

    static let displayName = "Nozomi Flow"
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let appState = AppState()
    private var settings: SettingsStore!
    private var permissions: PermissionsService!
    private var dictionary: PersonalDictionaryStore!
    private var history: HistoryStore!
    private var audio: AudioCaptureEngine!
    private var transcriber: TranscriptionEngine!
    private var formatter: FormatterPipeline!
    private var inserter: TextInserter!
    private var contextProvider: AppContextProvider!
    private var hotkeys: HotkeyMonitor!
    private var sounds: SoundPlayer!
    private var coordinator: DictationCoordinator!
    private var statusItem: StatusItemController!
    private var hud: HUDController!
    private var settingsWindow: SettingsWindowController!
    private var onboarding: OnboardingController!

    func applicationDidFinishLaunching(_ notification: Notification) {
        settings = SettingsStore()
        permissions = PermissionsService(appState: appState)
        dictionary = PersonalDictionaryStore()
        history = HistoryStore()
        audio = AudioCaptureEngine()
        transcriber = TranscriptionEngine()
        formatter = FormatterPipeline()
        inserter = TextInserter()
        contextProvider = AppContextProvider()
        hotkeys = HotkeyMonitor(settings: settings)
        sounds = SoundPlayer(settings: settings)

        coordinator = DictationCoordinator(
            appState: appState,
            settings: settings,
            audio: audio,
            transcriber: transcriber,
            formatter: formatter,
            inserter: inserter,
            contextProvider: contextProvider,
            dictionary: dictionary,
            history: history,
            permissions: permissions,
            hotkeys: hotkeys,
            sounds: sounds
        )

        hud = HUDController(appState: appState, settings: settings)
        settingsWindow = SettingsWindowController(
            appState: appState,
            settings: settings,
            dictionary: dictionary,
            history: history,
            permissions: permissions
        )
        onboarding = OnboardingController(
            appState: appState,
            settings: settings,
            permissions: permissions,
            transcriber: transcriber,
            coordinator: coordinator
        )
        statusItem = StatusItemController(
            appState: appState,
            coordinator: coordinator,
            settings: settings,
            openSettings: { [weak self] in self?.settingsWindow.show(tab: .general) },
            openHistory: { [weak self] in self?.settingsWindow.show(tab: .history) },
            openOnboarding: { [weak self] in self?.onboarding.show() }
        )
        coordinator.onNeedsPermissions = { [weak self] in self?.onboarding.show() }
        onboarding.onAccessibilityGranted = { [weak self] in self?.accessibilityMayHaveChanged() }
        statusItem.historyProvider = { [weak history] in history?.stats ?? UsageStats() }

        permissions.refresh()
        if permissions.accessibility {
            do { try hotkeys.start() } catch {
                Log.hotkey.error("hotkey start failed: \(error.localizedDescription)")
            }
        }
        hud.activate()
        formatter.prewarm()

        Task { [weak self] in
            guard let self else { return }
            self.appState.aiAvailability = await self.formatter.availabilityDescription()
        }
        prepareTranscriber()

        NotificationCenter.default.addObserver(
            forName: .murmurLocaleChanged, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.prepareTranscriber() }
        }

        if !settings.hasCompletedOnboarding {
            onboarding.show()
        }
        Log.app.info("Nozomi Flow launched")
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationWillTerminate(_ notification: Notification) {
        hotkeys.stop()
    }

    /// Re-check accessibility after the user grants it (called by onboarding).
    func accessibilityMayHaveChanged() {
        permissions.refresh()
        if permissions.accessibility && !hotkeys.isRunning {
            try? hotkeys.start()
        }
    }

    private func prepareTranscriber() {
        Task { [weak self] in
            guard let self else { return }
            let locale = self.settings.resolvedLocale
            // Without this the engine still thinks it is on-device at launch, so the
            // onboarding model step would download assets the user opted out of.
            (self.transcriber as? CloudConfigurableTranscriber)?
                .updateCloudConfig(self.settings.cloudTranscriptionConfig)
            self.appState.currentEngine = await self.transcriber.engineKind(for: locale)
            do {
                try await self.transcriber.prepare(locale: locale) { progress in
                    Task { @MainActor [weak self] in
                        self?.appState.modelDownloadProgress = progress >= 1.0 ? nil : progress
                    }
                }
            } catch {
                Log.asr.error("model prepare failed: \(error.localizedDescription)")
            }
            self.appState.modelDownloadProgress = nil
        }
    }
}
