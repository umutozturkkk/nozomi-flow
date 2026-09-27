import SwiftUI

/// Step 2: microphone permission. Status chip mirrors `appState.micPermission`
/// live; granted auto-advances shortly after so the user never has to click
/// "Continue" on a permission they just granted.
struct OnboardingMicrophoneStep: View {
    let appState: AppState
    let permissions: PermissionsService
    var onBack: () -> Void
    var onNext: () -> Void

    var body: some View {
        OnboardingStepScaffold(showBack: true, onBack: onBack, secondary: secondarySpec, primary: primarySpec) {
            VStack(alignment: .leading, spacing: 18) {
                OnboardingStepIcon(systemName: "mic.fill")

                VStack(alignment: .leading, spacing: 6) {
                    Text(L10n.string("onboarding.mic.title"))
                        .font(.system(size: 24, weight: .bold, design: .rounded))
                    Text(L10n.string("onboarding.mic.body"))
                        .font(.body)
                    Text(L10n.string("onboarding.mic.note"))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }

                statusChip
            }
        }
        // Fires immediately on appear (breezing through if already granted)
        // and again whenever permission state changes.
        .task(id: appState.micPermission) {
            guard appState.micPermission == .granted else { return }
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled else { return }
            onNext()
        }
    }

    @ViewBuilder
    private var statusChip: some View {
        switch appState.micPermission {
        case .undetermined:
            OnboardingStatusChip(
                icon: "mic.slash",
                title: L10n.string("onboarding.mic.notGranted"),
                subtitle: L10n.string("onboarding.mic.notGrantedHint"),
                style: .neutral
            )
        case .granted:
            OnboardingStatusChip(
                icon: "checkmark.seal.fill",
                title: L10n.string("onboarding.mic.granted"),
                style: .success,
                bounce: true
            )
        case .denied:
            OnboardingStatusChip(
                icon: "exclamationmark.triangle.fill",
                title: L10n.string("onboarding.mic.denied"),
                subtitle: L10n.string("onboarding.mic.deniedHint"),
                style: .warning
            )
        }
    }

    private var primarySpec: OnboardingButtonSpec? {
        switch appState.micPermission {
        case .undetermined:
            return OnboardingButtonSpec(title: L10n.string("onboarding.mic.allow"), systemImage: "mic.fill") {
                Task {
                    _ = await permissions.requestMicrophone()
                    permissions.refresh()
                }
            }
        case .denied:
            return OnboardingButtonSpec(title: L10n.string("common.openSettings"), systemImage: "gearshape.2") {
                permissions.openMicrophoneSettings()
            }
        case .granted:
            return nil // the checkmark bounce + auto-advance is the feedback
        }
    }

    private var secondarySpec: OnboardingButtonSpec? {
        guard appState.micPermission == .denied else { return nil }
        return OnboardingButtonSpec(title: L10n.string("onboarding.mic.checkAgain")) {
            permissions.refresh()
        }
    }
}
