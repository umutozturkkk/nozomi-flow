import AppKit
import ApplicationServices
import CoreGraphics

/// Inserts text into the frontmost app: AX selected-text insertion first
/// (native text controls only, doesn't touch the clipboard), pasteboard-swap +
/// synthetic Cmd+V fallback otherwise (restoring the user's prior clipboard
/// afterwards, always -- clipboard clobbering is the #1 Wispr complaint).
@MainActor
final class TextInserter: TextInsertionServiceProtocol {

    /// Native text-control roles where writing `kAXSelectedTextAttribute` reliably
    /// inserts/replaces text. Web content (Safari/Chrome render areas), Electron
    /// apps, and custom-drawn controls frequently report a role from this list
    /// (or an unknown one) while silently ignoring or mishandling the AX write,
    /// so anything outside this set falls through to the paste path instead.
    private static let axInsertableRoles: Set<String> = [
        "AXTextField", "AXTextArea", "AXSearchField", "AXComboBox",
    ]

    private static let keySource = CGEventSource(stateID: .combinedSessionState)

    func insert(_ text: String) async -> InsertionOutcome {
        await performInsertion(text)
    }

    func replaceSelection(with text: String) async -> InsertionOutcome {
        // AX selected-text writes and Cmd+V both replace an active selection
        // naturally, so the same core chain handles command mode too.
        await performInsertion(text)
    }

    func selectedText() -> String? {
        guard AXIsProcessTrusted(), let element = Self.focusedElement() else { return nil }
        // Never surface a password-field selection (e.g. into a command-mode LLM prompt).
        if let subrole = Self.stringAttribute(element, kAXSubroleAttribute as CFString),
           subrole == (kAXSecureTextFieldSubrole as String) {
            return nil
        }
        guard let value = Self.stringAttribute(element, kAXSelectedTextAttribute as CFString),
              !value.isEmpty else { return nil }
        return String(value.suffix(8_000))
    }

    func pressEnter() async {
        postKeyEvent(virtualKey: 36, down: true, flags: []) // kVK_Return
        try? await Task.sleep(nanoseconds: 30_000_000)
        postKeyEvent(virtualKey: 36, down: false, flags: [])
    }

    // MARK: - Core insertion chain

    private func performInsertion(_ text: String) async -> InsertionOutcome {
        guard AXIsProcessTrusted() else {
            setClipboard(text)
            return InsertionOutcome(method: .clipboardOnly, succeeded: true)
        }

        if let element = Self.focusedElement(),
           let role = Self.stringAttribute(element, kAXRoleAttribute as CFString),
           Self.axInsertableRoles.contains(role) {
            let result = AXUIElementSetAttributeValue(element, kAXSelectedTextAttribute as CFString, text as CFTypeRef)
            // Some implementations return .success without inserting; verify by
            // re-reading the field before trusting the AX path.
            if result == .success, Self.verifyAXInsertion(text, element: element) {
                Log.insert.notice("inserted via AX (\(text.count) chars, role \(role, privacy: .public))")
                return InsertionOutcome(method: .accessibility, succeeded: true)
            }
            Log.insert.notice("AX write unverified (\(String(describing: result), privacy: .public)); falling back to paste")
        }

        await pasteViaClipboard(text)
        Log.insert.notice("inserted via paste fallback (\(text.count) chars)")
        return InsertionOutcome(method: .paste, succeeded: true)
    }

    /// Snapshots the whole pasteboard, swaps in the transcript, synthesizes
    /// Cmd+V, waits for the target app to consume it, then ALWAYS restores the
    /// original contents -- even though nothing here can currently throw, the
    /// restore is written to run unconditionally so a future failure path can't
    /// accidentally skip it.
    private func pasteViaClipboard(_ text: String) async {
        let pb = NSPasteboard.general
        let snapshot = snapshotPasteboard()
        setClipboard(text)
        let ourChangeCount = pb.changeCount

        postKeyEvent(virtualKey: 9, down: true, flags: .maskCommand) // kVK_ANSI_V
        try? await Task.sleep(nanoseconds: 20_000_000)
        postKeyEvent(virtualKey: 9, down: false, flags: .maskCommand)

        // Give slow targets (Electron, ANE-busy moments) time to consume the
        // paste before restoring; restoring too early makes them paste the OLD
        // clipboard. Skip the restore entirely if someone else wrote to the
        // pasteboard meanwhile -- never clobber newer content.
        try? await Task.sleep(nanoseconds: 700_000_000)
        if pb.changeCount == ourChangeCount {
            restorePasteboard(snapshot)
        }
    }

    /// Re-reads the field's value and checks the inserted text actually landed.
    /// Unreadable values are trusted (avoids double-insert via a false fallback).
    private static func verifyAXInsertion(_ text: String, element: AXUIElement) -> Bool {
        let probe = String(text.replacingOccurrences(of: "\n", with: " ").prefix(24))
            .trimmingCharacters(in: .whitespaces)
        guard probe.count >= 3 else { return true }
        guard let value = stringAttribute(element, kAXValueAttribute as CFString) else { return true }
        return value.replacingOccurrences(of: "\n", with: " ").contains(probe)
    }

    private func setClipboard(_ text: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
    }

    private func postKeyEvent(virtualKey: CGKeyCode, down: Bool, flags: CGEventFlags) {
        guard let event = CGEvent(keyboardEventSource: Self.keySource, virtualKey: virtualKey, keyDown: down) else { return }
        event.flags = flags
        event.post(tap: .cgSessionEventTap)
    }

    // MARK: - Pasteboard snapshot / restore

    private struct PasteboardSnapshot {
        var items: [[NSPasteboard.PasteboardType: Data]]
    }

    private func snapshotPasteboard() -> PasteboardSnapshot {
        let pb = NSPasteboard.general
        let items: [[NSPasteboard.PasteboardType: Data]] = (pb.pasteboardItems ?? []).map { item in
            var typeData: [NSPasteboard.PasteboardType: Data] = [:]
            for type in item.types {
                if let data = item.data(forType: type) {
                    typeData[type] = data
                }
            }
            return typeData
        }
        return PasteboardSnapshot(items: items)
    }

    private func restorePasteboard(_ snapshot: PasteboardSnapshot) {
        let pb = NSPasteboard.general
        pb.clearContents()
        guard !snapshot.items.isEmpty else { return } // original clipboard was empty too
        let restored: [NSPasteboardItem] = snapshot.items.map { typeData in
            let item = NSPasteboardItem()
            for (type, data) in typeData {
                item.setData(data, forType: type)
            }
            return item
        }
        pb.writeObjects(restored)
    }

    // MARK: - AX helpers (system-wide focused element)

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
