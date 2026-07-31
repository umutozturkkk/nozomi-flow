import AppKit

/// The meeting flow's only user-visible feedback.
///
/// Everything else about a meeting happens out of sight: the menu item reads the
/// same whether a start was refused or is about to work, and notes land on disk
/// minutes after the user stopped recording. Without these two alerts a refusal and
/// a finished meeting are indistinguishable from nothing happening at all.
@available(macOS 15.0, *)
@MainActor
enum MeetingAlert {

    /// - Parameter openSettings: shows the settings window, where cloud transcription
    ///   is configured. Passed in rather than reached for so this file stays free of
    ///   the window plumbing.
    static func presentFailure(_ failure: MeetingFailure, openSettings: () -> Void) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = failure.title
        alert.informativeText = failure.message

        switch failure {
        case .cloudTranscriptionOff:
            alert.addButton(withTitle: "Open Settings")
            alert.addButton(withTitle: "Cancel")
        case .screenRecordingDenied:
            alert.addButton(withTitle: "Open System Settings")
            alert.addButton(withTitle: "Cancel")
        case .couldNotStart, .couldNotSaveNotes:
            alert.addButton(withTitle: "OK")
        }

        guard run(alert) == .alertFirstButtonReturn else { return }
        switch failure {
        case .cloudTranscriptionOff: openSettings()
        case .screenRecordingDenied: MeetingSessionController.openScreenRecordingSettings()
        case .couldNotStart, .couldNotSaveNotes: break
        }
    }

    static func presentNotes(_ record: MeetingRecord) {
        let alert = NSAlert()
        alert.messageText = "Meeting notes are ready"
        alert.informativeText = record.title
        alert.addButton(withTitle: "Open Notes")
        alert.addButton(withTitle: "Show in Finder")
        alert.addButton(withTitle: "Close")

        switch run(alert) {
        case .alertFirstButtonReturn: NSWorkspace.shared.open(record.url)
        case .alertSecondButtonReturn: NSWorkspace.shared.activateFileViewerSelecting([record.url])
        default: break
        }
    }

    /// An accessory app is not an activation target, so a modal alert would open
    /// behind whatever the user is looking at. Same promotion the settings window uses.
    private static func run(_ alert: NSAlert) -> NSApplication.ModalResponse {
        WindowActivation.beginWindowSession()
        defer { WindowActivation.endWindowSession() }
        return alert.runModal()
    }
}
