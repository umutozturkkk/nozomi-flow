import Foundation
import Observation

/// UI-facing observable state. Mutated only on the main actor
/// (by DictationCoordinator, PermissionsService and AppDelegate).
@MainActor
@Observable
final class AppState {
    var phase: DictationPhase = .idle
    var sessionMode: SessionMode = .dictation
    /// Smoothed mic level 0...1 while recording.
    var audioLevel: Float = 0
    /// Volatile transcript while speaking.
    var liveTranscript: String = ""
    /// Last finalized+formatted text (for menu "copy last").
    var lastFinalText: String?
    var lastInsertionOutcome: InsertionOutcome?

    // Permissions
    var micPermission: PermissionState = .undetermined
    var axTrusted: Bool = false

    // Engine / model status
    var currentEngine: TranscriptionEngineKind = .none
    /// Non-nil while speech model assets are downloading (0...1).
    var modelDownloadProgress: Double? = nil
    var aiAvailability: String = ""

    /// User toggled "pause" from the menu bar.
    var isPaused: Bool = false
}
