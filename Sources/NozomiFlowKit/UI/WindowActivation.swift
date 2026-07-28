import AppKit

/// Keeps real windows usable in a menu-bar app.
///
/// The app runs as `.accessory` so it owns no Dock tile and no menu bar. That is
/// right while only the HUD is on screen, but an accessory app is not a first
/// class activation target: its windows lose focus to whatever the user clicks
/// next and sink behind other apps, and its main menu is never installed, so
/// Cmd+V does nothing in a text field.
///
/// Onboarding and Settings therefore promote the app to `.regular` while they are
/// open and demote it again once the last one closes. The HUD is a borderless
/// non-activating panel and deliberately does not count, so dictation alone never
/// makes a Dock tile appear.
@MainActor
enum WindowActivation {

    /// Call just before ordering a titled window front.
    static func beginWindowSession() {
        if NSApp.activationPolicy() != .regular {
            NSApp.setActivationPolicy(.regular)
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Call after a titled window closes. Demotes only once none are left, so
    /// closing Settings while onboarding is still up does not strand onboarding
    /// behind another app.
    static func endWindowSession() {
        // AppKit clears `isVisible` after the close notification on some paths,
        // so let the run loop settle before counting.
        DispatchQueue.main.async {
            guard !hasVisibleWindow else { return }
            NSApp.setActivationPolicy(.accessory)
        }
    }

    /// Titled windows only: the HUD panel is borderless and must not keep the app
    /// promoted for as long as it happens to be on screen.
    private static var hasVisibleWindow: Bool {
        NSApp.windows.contains { $0.isVisible && $0.styleMask.contains(.titled) }
    }
}
