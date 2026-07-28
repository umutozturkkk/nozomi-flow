import Foundation
import CoreGraphics

// MARK: - Session lifecycle

enum SessionMode: String, Equatable {
    case dictation
    case command
}

enum DictationPhase: Equatable {
    case idle
    case recording(startedAt: Date, handsFree: Bool)
    case processing
    case inserting
    case success(wordCount: Int)
    case failure(DictationError)

    var canStartNewSession: Bool {
        switch self {
        case .idle, .success, .failure: return true
        case .recording, .processing, .inserting: return false
        }
    }

    var isRecording: Bool {
        if case .recording = self { return true }
        return false
    }
}

enum DictationError: Error, Equatable {
    case noSpeechDetected
    case tooShort
    case cancelled
    case micPermissionDenied
    case modelUnavailable(String)
    case transcriptionFailed(String)
    case insertionFailed(String)

    var userMessage: String {
        switch self {
        case .noSpeechDetected: return "Didn't catch that"
        case .tooShort: return "Too short"
        case .cancelled: return "Cancelled"
        case .micPermissionDenied: return "Microphone access needed"
        case .modelUnavailable(let s): return "Speech model: \(s)"
        case .transcriptionFailed: return "Transcription failed"
        case .insertionFailed: return "Couldn't insert text"
        }
    }
}

// MARK: - Transcription

enum TranscriptionEngineKind: String, Equatable {
    case cloud            // OpenAI-compatible cloud endpoint (no partials, needs network)
    case speechAnalyzer   // macOS 26 SpeechTranscriber (highest quality, 30 locales)
    case dictation        // macOS 26 DictationTranscriber (54 locales incl. tr_TR)
    case legacySF         // SFSpeechRecognizer fallback (63 locales)
    case none

    var displayName: String {
        switch self {
        case .cloud: return "Cloud"
        case .speechAnalyzer: return "Apple SpeechAnalyzer"
        case .dictation: return "Apple Dictation"
        case .legacySF: return "Apple Speech (legacy)"
        case .none: return "None"
        }
    }

    /// Cloud sends audio off the machine; the on-device engines never do.
    var isOnDevice: Bool { self != .cloud }
}

struct TranscriptionOutcome: Equatable {
    var text: String
    var localeIdentifier: String?
    var engine: TranscriptionEngineKind
}

// MARK: - Context / tone

enum ToneCategory: String, Codable, CaseIterable, Equatable {
    case casual        // chat apps: relaxed, contractions
    case professional  // email: polished, complete sentences
    case technical     // editors/terminals: preserve identifiers verbatim
    case neutral
}

struct AppContextInfo: Equatable {
    var bundleID: String?
    var appName: String?
    var tone: ToneCategory = .neutral
    /// Up to ~800 chars of the focused text field's existing content (AX), if enabled.
    var focusedText: String?
    var selectedText: String?
}

// MARK: - Formatting

enum FormattingLevel: String, Codable, CaseIterable, Equatable {
    case off    // raw transcript, dictionary replacements only
    case light  // rule-based cleanup (fillers, capitalization, punctuation spacing)
    case full   // light + LLM rewrite (Apple Intelligence or cloud)
}

enum LLMEngineChoice: String, Codable, CaseIterable, Equatable {
    case auto              // Apple Intelligence if available, else rules only
    case appleIntelligence
    case openAI
    case none
}

struct FormattingRequest {
    var raw: String
    var context: AppContextInfo
    var level: FormattingLevel
    var llm: LLMEngineChoice
    var dictionary: [DictionaryEntry]
    var localeIdentifier: String
    var customInstructions: String?
    var removeFillers: Bool = true
    var toneMatching: Bool = true
    var openAIKey: String?
    var openAIModel: String = "gpt-4o-mini"
}

struct FormattedResult: Equatable {
    var text: String
    var usedLLM: Bool
    /// The transcript ended with a spoken "press enter" command (stripped from text).
    var pressEnter: Bool = false
    /// Number of auto-corrections applied (fillers removed, dictionary fixes, backtracks).
    var corrections: Int = 0
}

// MARK: - Insertion

enum InsertionMethod: String, Equatable {
    case accessibility  // AX selected-text insertion (no clipboard touched)
    case paste          // pasteboard swap + synthetic Cmd+V
    case clipboardOnly  // could not insert; text left on clipboard
}

struct InsertionOutcome: Equatable {
    var method: InsertionMethod
    var succeeded: Bool
}

// MARK: - History & stats

struct HistoryEntry: Codable, Identifiable, Equatable {
    var id: UUID = UUID()
    var date: Date
    var rawText: String
    var finalText: String
    var appName: String?
    var appBundleID: String?
    var durationSeconds: Double
    var wordCount: Int
    var mode: String   // SessionMode.rawValue
    var engine: String // TranscriptionEngineKind.rawValue
    var correctionsCount: Int = 0
}

struct UsageStats: Equatable {
    var totalWords: Int = 0
    var totalSessions: Int = 0
    var totalSpokenSeconds: Double = 0
    var averageWPM: Double = 0
    var streakDays: Int = 0
    /// Time saved vs typing the same words at 40 WPM.
    var minutesSaved: Double = 0
    var wordsToday: Int = 0
    /// Total auto-corrections Nozomi Flow made (fillers, dictionary, backtracks).
    var totalCorrections: Int = 0
}

// MARK: - Personal dictionary

struct DictionaryEntry: Codable, Identifiable, Equatable {
    var id: UUID = UUID()
    /// Canonical spelling that should appear in output (e.g. "Kernl", "Nimbus").
    var phrase: String
    /// Misheard variants to replace, case-insensitive, word-boundary (e.g. "kernel" -> "Kernl").
    var variants: [String] = []
    var isEnabled: Bool = true
}

// MARK: - Hotkeys

enum HotkeyChoice: String, Codable, CaseIterable, Equatable {
    case fn
    case rightCommand
    case rightOption
    case rightControl

    var displayName: String {
        switch self {
        case .fn: return "fn 🌐"
        case .rightCommand: return "Right ⌘"
        case .rightOption: return "Right ⌥"
        case .rightControl: return "Right ⌃"
        }
    }

    var keyCode: CGKeyCode {
        switch self {
        case .fn: return 63            // kVK_Function
        case .rightCommand: return 54  // kVK_RightCommand
        case .rightOption: return 61   // kVK_RightOption
        case .rightControl: return 62  // kVK_RightControl
        }
    }

    var eventFlag: CGEventFlags {
        switch self {
        case .fn: return .maskSecondaryFn
        case .rightCommand: return .maskCommand
        case .rightOption: return .maskAlternate
        case .rightControl: return .maskControl
        }
    }
}

// MARK: - Permissions

enum PermissionState: Equatable {
    case granted
    case denied
    case undetermined
}

// MARK: - Notifications

extension Notification.Name {
    static let murmurHotkeyConfigChanged = Notification.Name("murmurHotkeyConfigChanged")
    static let murmurLocaleChanged = Notification.Name("murmurLocaleChanged")
}
