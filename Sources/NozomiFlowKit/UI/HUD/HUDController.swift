import AppKit
import SwiftUI
import Observation

/// Owns the floating "flow bar" panel at the bottom-center of the screen.
/// The panel is a fixed-size, click-through, non-activating NSPanel; all
/// visible motion (entrance, width morphs, exit) is SwiftUI inside HUDView.
@MainActor
final class HUDController {
    private let appState: AppState
    private let settings: SettingsStore
    private var panel: NSPanel!
    private var hideTask: Task<Void, Never>?

    /// Generous fixed canvas: pill (~52pt tall, up to ~380pt wide) plus room
    /// for its soft shadow and the 12pt slide-down exit.
    private static let panelSize = NSSize(width: 420, height: 76)
    /// How long to keep the panel on screen after the phase returns to idle
    /// so the SwiftUI exit transition can play before we order out.
    private static let hideDelay: TimeInterval = 0.25

    init(appState: AppState, settings: SettingsStore) {
        self.appState = appState
        self.settings = settings
        makePanel()
    }

    func activate() {
        observeState()
    }

    private func makePanel() {
        panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: Self.panelSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = true
        // NSPanel defaults this to true; left alone the HUD would vanish
        // the moment another app is frontmost -- which is always our case.
        panel.hidesOnDeactivate = false
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false // shadow is drawn in SwiftUI, shaped to the pill
        panel.ignoresMouseEvents = true // pure display; Esc is the cancel path
        panel.isMovableByWindowBackground = false
        panel.animationBehavior = .none // don't fight the SwiftUI transitions

        let host = NSHostingView(rootView: HUDView(appState: appState, settings: settings))
        host.sizingOptions = [] // SwiftUI must never drive the panel's frame
        host.frame = NSRect(origin: .zero, size: Self.panelSize)
        host.autoresizingMask = [.width, .height]
        panel.contentView = host
    }

    private func observeState() {
        withObservationTracking { [weak self] in
            guard let self else { return }
            let visible = !(self.appState.phase == .idle)
            self.setVisible(visible)
        } onChange: { [weak self] in
            Task { @MainActor in self?.observeState() }
        }
    }

    private func setVisible(_ visible: Bool) {
        if visible {
            hideTask?.cancel()
            hideTask = nil
            position()
            if !panel.isVisible { panel.orderFrontRegardless() }
        } else if panel.isVisible {
            scheduleHide()
        }
    }

    /// Order out only after the exit transition has had time to play; a new
    /// session starting inside the window cancels the hide and reuses the
    /// already-visible panel.
    private func scheduleHide() {
        hideTask?.cancel()
        hideTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Self.hideDelay * 1_000_000_000))
            guard let self, !Task.isCancelled else { return }
            self.hideTask = nil
            if self.appState.phase == .idle {
                self.panel.orderOut(nil)
            }
        }
    }

    /// Bottom-center of the main screen, 24pt above the visible-frame bottom.
    /// Re-run at every show so the HUD follows the active display setup.
    private func position() {
        guard let screen = NSScreen.main else { return }
        let frame = screen.visibleFrame
        let size = panel.frame.size
        let x = (frame.midX - size.width / 2).rounded()
        let y = frame.minY + 24
        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }
}
