import AppKit
import SwiftUI

/// First-run onboarding: welcome -> mic -> accessibility -> hotkey -> speech
/// model -> try it. Hosts `OnboardingRootView` (the springy six-step wizard)
/// in a small, chrome-light window that the user can reopen anytime from the
/// menu bar's "Setup Assistant…" item.
@MainActor
final class OnboardingController: NSObject {
    private let appState: AppState
    private let settings: SettingsStore
    private let permissions: PermissionsService
    private let transcriber: TranscriptionServiceProtocol
    private let coordinator: DictationCoordinator
    private var window: NSWindow?

    /// Set by AppDelegate: called when the user grants Accessibility so the
    /// hotkey tap can start without relaunching.
    var onAccessibilityGranted: (() -> Void)?

    init(
        appState: AppState,
        settings: SettingsStore,
        permissions: PermissionsService,
        transcriber: TranscriptionServiceProtocol,
        coordinator: DictationCoordinator
    ) {
        self.appState = appState
        self.settings = settings
        self.permissions = permissions
        self.transcriber = transcriber
        self.coordinator = coordinator
        super.init()
    }

    /// Shows the assistant, always starting fresh at Welcome. Steps whose
    /// permission/state is already satisfied (e.g. re-running after a
    /// completed setup) breeze through their own auto-advance almost
    /// instantly, so re-opening never feels like repeating work.
    func show() {
        let win = window ?? makeWindow()
        window = win
        let host = NSHostingView(rootView: makeRootView())
        // SwiftUI must never drive the window's frame -- without this, a step
        // whose ideal height exceeds 620pt balloons the whole window.
        host.sizingOptions = []
        win.contentView = host
        win.setContentSize(Self.windowSize)
        win.center()
        WindowActivation.beginWindowSession()
        win.makeKeyAndOrderFront(nil)
    }

    private static let windowSize = NSSize(width: 560, height: 620)

    /// Hides the window and tears down its SwiftUI content so any in-flight
    /// work tied to a step's `.task` (namely the Accessibility poll) stops
    /// immediately rather than idling in the background until the app quits.
    /// Never touches `hasCompletedOnboarding` — only Finish does that.
    func close() {
        window?.orderOut(nil)
        window?.contentView = nil
        WindowActivation.endWindowSession()
    }

    private func makeWindow() -> NSWindow {
        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 620),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        win.title = L10n.string("onboarding.windowTitle")
        win.titlebarAppearsTransparent = true
        win.titleVisibility = .hidden
        win.isMovableByWindowBackground = true
        win.isReleasedWhenClosed = false
        win.isRestorable = false
        win.center()
        win.delegate = self
        return win
    }

    private func makeRootView() -> some View {
        OnboardingRootView(
            appState: appState,
            settings: settings,
            permissions: permissions,
            transcriber: transcriber,
            coordinator: coordinator,
            onAccessibilityGranted: { [weak self] in self?.onAccessibilityGranted?() },
            onFinish: { [weak self] in self?.close() }
        )
        .frame(
            width: Self.windowSize.width,
            height: Self.windowSize.height
        )
    }
}

extension OnboardingController: NSWindowDelegate {
    /// Route the red-button close through our own `close()` (hide + content
    /// teardown) instead of AppKit's default, so the Accessibility poll task
    /// can't outlive the window regardless of how it was dismissed.
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        close()
        return false
    }
}
