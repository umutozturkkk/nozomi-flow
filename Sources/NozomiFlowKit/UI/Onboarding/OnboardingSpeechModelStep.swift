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
                    Text(L10n.string("onboarding.model.title"))
                        .font(.system(size: 24, weight: .bold, design: .rounded))
                    Text(engine.displayName)
                        .font(.body.weight(.semibold))
                    Text(qualityNote)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }

                statusArea

                Text(L10n.string("onboarding.model.changeLater"))
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
                    Text(L10n.string("onboarding.model.downloading")).font(.callout)
                }
                Text(L10n.format("onboarding.model.percent", Int(progress * 100)))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(14)
            .glassEffect(.regular, in: .rect(cornerRadius: 14))
        } else if isReady {
            OnboardingStatusChip(icon: "checkmark.seal.fill", title: L10n.string("onboarding.model.ready"), style: .success, bounce: true)
        } else if engine == .none {
            OnboardingStatusChip(
                icon: "exclamationmark.triangle.fill",
                title: L10n.string("onboarding.model.noEngine"),
                subtitle: L10n.string("onboarding.model.noEngineHint"),
                style: .warning
            )
        } else if prepareFailed {
            OnboardingStatusChip(
                icon: "exclamationmark.triangle.fill",
                title: L10n.string("onboarding.model.failed"),
                subtitle: L10n.string("onboarding.model.failedHint"),
                style: .warning
            )
        } else if isPreparing {
            OnboardingStatusChip(icon: "hourglass", title: L10n.string("onboarding.model.preparing"), style: .neutral)
        }
    }

    private var qualityNote: String {
        switch engine {
        case .cloud: return L10n.string("onboarding.model.note.cloud")
        case .speechAnalyzer: return L10n.string("onboarding.model.note.speechAnalyzer")
        case .dictation: return L10n.string("onboarding.model.note.dictation")
        case .legacySF: return L10n.string("onboarding.model.note.legacy")
        case .none: return L10n.string("onboarding.model.note.none")
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
            return OnboardingButtonSpec(title: L10n.string("onboarding.model.preparing"), isEnabled: false, action: {})
        }
        if isReady || engine == .none {
            return OnboardingButtonSpec(
                title: L10n.string(engine == .none ? "onboarding.model.continueAnyway" : "common.continue"),
                systemImage: "arrow.right",
                action: onNext
            )
        }
        if isPreparing {
            return OnboardingButtonSpec(title: L10n.string("onboarding.model.preparing"), isEnabled: false, action: {})
        }
        return OnboardingButtonSpec(
            title: L10n.string(prepareFailed ? "onboarding.model.tryAgain" : "onboarding.model.prepare"),
            systemImage: "arrow.down.circle.fill",
            action: { Task { await runPrepare() } }
        )
    }
}
