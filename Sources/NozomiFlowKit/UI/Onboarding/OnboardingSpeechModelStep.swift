import SwiftUI

/// Step 5: on-device speech model readiness. Kicks off `prepare()` itself on
/// appear (so an already-installed model just shows "Ready" immediately
/// instead of making the user click a button for no reason), while
/// `appState.modelDownloadProgress` — fed by AppDelegate's own prepare
/// pipeline — always wins the display priority so we never show "Ready"
/// underneath an active download.
struct OnboardingSpeechModelStep: View {
    let appState: AppState
    let settings: SettingsStore
    let transcriber: TranscriptionServiceProtocol
    var onBack: () -> Void
    var onNext: () -> Void

    @State private var engine: TranscriptionEngineKind = .none
    @State private var isPreparing = false
    @State private var isReady = false
    @State private var prepareFailed = false

    var body: some View {
        OnboardingStepScaffold(showBack: true, onBack: onBack, primary: primarySpec) {
            VStack(alignment: .leading, spacing: 18) {
                OnboardingStepIcon(systemName: "brain.head.profile")

                VStack(alignment: .leading, spacing: 6) {
                    Text("Speech model")
                        .font(.system(size: 24, weight: .bold, design: .rounded))
                    Text(engine.displayName)
                        .font(.body.weight(.semibold))
                    Text(qualityNote)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }

                statusArea

                Text("You can change languages later in Settings.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .task {
            engine = await transcriber.engineKind(for: settings.resolvedLocale)
            guard engine != .none else { return }
            await runPrepare()
        }
    }

    @ViewBuilder
    private var statusArea: some View {
        if let progress = appState.modelDownloadProgress {
            VStack(alignment: .leading, spacing: 8) {
                ProgressView(value: progress) {
                    Text("Downloading speech model…").font(.callout)
                }
                Text("\(Int(progress * 100))%")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(14)
            .glassEffect(.regular, in: .rect(cornerRadius: 14))
        } else if isReady {
            OnboardingStatusChip(icon: "checkmark.seal.fill", title: "Ready to go", style: .success, bounce: true)
        } else if engine == .none {
            OnboardingStatusChip(
                icon: "exclamationmark.triangle.fill",
                title: "No engine for this language",
                subtitle: "Pick another language in Settings once you're set up.",
                style: .warning
            )
        } else if prepareFailed {
            OnboardingStatusChip(
                icon: "exclamationmark.triangle.fill",
                title: "Couldn't prepare the model",
                subtitle: "Check your connection and try again.",
                style: .warning
            )
        } else if isPreparing {
            OnboardingStatusChip(icon: "hourglass", title: "Preparing…", style: .neutral)
        }
    }

    private var qualityNote: String {
        switch engine {
        case .cloud: return "Cloud transcription. Nothing to download."
        case .speechAnalyzer: return "Apple's newest on-device model."
        case .dictation: return "On-device dictation model."
        case .legacySF: return "Compatibility engine."
        case .none: return "No engine for this language - pick another in Settings."
        }
    }

    private func runPrepare() async {
        guard !isPreparing else { return }
        isPreparing = true
        prepareFailed = false
        do {
            try await transcriber.prepare(locale: settings.resolvedLocale, progress: { _ in })
            isReady = true
        } catch {
            prepareFailed = true
        }
        isPreparing = false
    }

    private var primarySpec: OnboardingButtonSpec {
        if appState.modelDownloadProgress != nil {
            return OnboardingButtonSpec(title: "Preparing…", isEnabled: false, action: {})
        }
        if isReady || engine == .none {
            return OnboardingButtonSpec(
                title: engine == .none ? "Continue Anyway" : "Continue",
                systemImage: "arrow.right",
                action: onNext
            )
        }
        if isPreparing {
            return OnboardingButtonSpec(title: "Preparing…", isEnabled: false, action: {})
        }
        return OnboardingButtonSpec(
            title: prepareFailed ? "Try Again" : "Download / Prepare",
            systemImage: "arrow.down.circle.fill",
            action: { Task { await runPrepare() } }
        )
    }
}
