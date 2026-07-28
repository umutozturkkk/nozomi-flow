import AppKit
import ApplicationServices

/// Captures which app is frontmost and maps it to a formatting tone.
/// Also reads the focused field's text via Accessibility when asked, so the
/// formatter can use surrounding context -- privacy-aware: password fields are
/// never read.
@MainActor
final class AppContextProvider: AppContextProviderProtocol {

    func snapshot(includeFieldText: Bool) -> AppContextInfo {
        let app = NSWorkspace.shared.frontmostApplication
        let bundleID = app?.bundleIdentifier
        var info = AppContextInfo(
            bundleID: bundleID,
            appName: app?.localizedName,
            tone: Self.tone(forBundleID: bundleID)
        )
        if includeFieldText && AXIsProcessTrusted() {
            let (focused, selected) = Self.readFocusedFieldText()
            info.focusedText = focused
            info.selectedText = selected
        }
        return info
    }

    nonisolated static func tone(forBundleID bundleID: String?) -> ToneCategory {
        guard let id = bundleID?.lowercased() else { return .neutral }
        if casualApps.contains(where: { id.contains($0) }) { return .casual }
        if professionalApps.contains(where: { id.contains($0) }) { return .professional }
        if technicalApps.contains(where: { id.contains($0) }) { return .technical }
        return .neutral
    }

    private nonisolated static let casualApps: [String] = [
        "slack", "com.apple.mobilesms", "messages", "whatsapp", "telegram",
        "discord", "signal", "messenger",
    ]

    private nonisolated static let professionalApps: [String] = [
        "com.apple.mail", "outlook", "superhuman", "spark", "hey.app",
        "notion", "linear", "craft", "missiveapp",
    ]

    private nonisolated static let technicalApps: [String] = [
        "com.apple.dt.xcode", "vscode", "com.microsoft.vscode", "cursor",
        "terminal", "iterm", "warp", "ghostty", "zed", "sublime", "jetbrains",
        "com.apple.terminal",
    ]

    // MARK: - AX field text (privacy-aware)

    /// Reads the system-wide focused element's value/selection. Never reads
    /// secure (password) fields. Returns (nil, nil) on any AX error, missing
    /// trust, or missing focus -- must never throw or block noticeably, since
    /// this runs synchronously at the start of every dictation session.
    private static func readFocusedFieldText() -> (focusedText: String?, selectedText: String?) {
        guard let element = focusedElement() else { return (nil, nil) }

        if let subrole = stringAttribute(element, kAXSubroleAttribute as CFString),
           subrole == (kAXSecureTextFieldSubrole as String) {
            return (nil, nil)
        }

        let focused = nilIfEmpty(stringAttribute(element, kAXValueAttribute as CFString).map { String($0.suffix(800)) })
        let selected = nilIfEmpty(stringAttribute(element, kAXSelectedTextAttribute as CFString).map { String($0.suffix(8_000)) })
        return (focused, selected)
    }

    private static func nilIfEmpty(_ text: String?) -> String? {
        guard let text, !text.isEmpty else { return nil }
        return text
    }

    private static func focusedElement() -> AXUIElement? {
        var value: CFTypeRef?
        let systemWide = AXUIElementCreateSystemWide()
        guard AXUIElementCopyAttributeValue(systemWide, kAXFocusedUIElementAttribute as CFString, &value) == .success,
              let value else { return nil }
        guard CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    private static func stringAttribute(_ element: AXUIElement, _ attribute: CFString) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success else { return nil }
        return value as? String
    }
}
