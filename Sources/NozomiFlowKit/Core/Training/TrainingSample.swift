import Foundation

/// One dictation kept for training: the uploaded audio (stored beside this as
/// `<id>.wav`) and its transcript. `rawLabel` is what the cloud returned, before
/// dictionary rules and AI cleanup; `label` is the current best transcript, which
/// the review flow (phase 2) corrects.
struct TrainingSample: Codable, Equatable, Identifiable {
    enum Status: String, Codable {
        case unchecked, agreed, pending, corrected, verified, uncertain
    }

    static let sampleRate = 16_000

    var id: UUID
    var createdAt: Date
    var durationSeconds: Double
    var appBundleID: String?
    var labelSource: String
    /// Dictation locale (e.g. "tr_TR"); fine-tuning needs the language token. nil
    /// in samples saved before this field existed.
    var localeIdentifier: String?
    var rawLabel: String
    var label: String
    var status: Status

    static func make(
        rawLabel: String, audioSampleCount: Int, appBundleID: String?, labelSource: String,
        localeIdentifier: String? = nil
    ) -> TrainingSample {
        TrainingSample(
            id: UUID(),
            // Whole seconds: ISO-8601 in the JSON has no fraction, so a sample read
            // back from disk equals the one that was saved.
            createdAt: Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded(.down)),
            durationSeconds: Double(audioSampleCount) / Double(sampleRate),
            appBundleID: appBundleID, labelSource: labelSource, localeIdentifier: localeIdentifier,
            rawLabel: rawLabel, label: rawLabel, status: .unchecked
        )
    }
}

/// Which finished dictations become samples. Pure, so the rule is testable
/// without a coordinator.
enum TrainingSampleEligibility {
    static let minimumSeconds = 1.0

    static func accepts(enabled: Bool, mode: SessionMode, outcome: TranscriptionOutcome) -> Bool {
        guard enabled, mode == .dictation, outcome.engine == .cloud, let audio = outcome.audio else { return false }
        guard Double(audio.count) / Double(TrainingSample.sampleRate) >= minimumSeconds else { return false }
        return !outcome.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
