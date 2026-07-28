import AppKit
import SwiftUI

enum SettingsTab: String, CaseIterable {
    case general = "General"
    case style = "Style"
    case dictionary = "Dictionary"
    case history = "History"
    case about = "About"
}

/// Settings window host: builds the SwiftUI tab shell once and reuses the
/// window across `show(tab:)` calls, driving tab selection through the
/// shared `SettingsTabSelection` observable so callers (menu bar, onboarding)
/// can jump straight to a given tab without tearing the window down.
@MainActor
final class SettingsWindowController {
    private let appState: AppState
    private let settings: SettingsStore
    private let dictionary: PersonalDictionaryStore
    private let history: HistoryStore
    private let permissions: PermissionsService
    private let tabSelection = SettingsTabSelection()
    private var window: NSWindow?

    init(
        appState: AppState,
        settings: SettingsStore,
        dictionary: PersonalDictionaryStore,
        history: HistoryStore,
        permissions: PermissionsService
    ) {
        self.appState = appState
        self.settings = settings
        self.dictionary = dictionary
        self.history = history
        self.permissions = permissions
    }

    func show(tab: SettingsTab = .general) {
        tabSelection.tab = tab
        if window == nil {
            let root = SettingsRootView(
                tabSelection: tabSelection,
                appState: appState,
                settings: settings,
                dictionary: dictionary,
                history: history,
                permissions: permissions
            )
            let w = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 760, height: 540),
                styleMask: [.titled, .closable, .miniaturizable, .resizable],
                backing: .buffered,
                defer: false
            )
            w.title = "Nozomi Flow Settings"
            w.contentView = NSHostingView(rootView: root)
            w.minSize = NSSize(width: 680, height: 480)
            w.center()
            w.isReleasedWhenClosed = false
            window = w
        }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
