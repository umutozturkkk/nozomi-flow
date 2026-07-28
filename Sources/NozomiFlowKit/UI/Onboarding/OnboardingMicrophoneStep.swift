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
                    Text("Microphone access")
                        .font(.system(size: 24, weight: .bold, design: .rounded))
                    Text("Nozomi Flow listens only while you hold the key.")
                        .font(.body)
                    Text("No always-on recording, no cloud upload — audio stays on this Mac.")
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
                title: "Not granted yet",
                subtitle: "We'll ask once you continue.",
                style: .neutral
            )
        case .granted:
            OnboardingStatusChip(
                icon: "checkmark.seal.fill",
                title: "You're all set",
                style: .success,
                bounce: true
            )
        case .denied:
            OnboardingStatusChip(
                icon: "exclamationmark.triangle.fill",
                title: "Microphone access is off",
                subtitle: "Turn it on in System Settings, then check again.",
                style: .warning
            )
        }
    }

    private var primarySpec: OnboardingButtonSpec? {
        switch appState.micPermission {
        case .undetermined:
            return OnboardingButtonSpec(title: "Allow Microphone", systemImage: "mic.fill") {
                Task {
                    _ = await permissions.requestMicrophone()
                    permissions.refresh()
                }
            }
        case .denied:
            return OnboardingButtonSpec(title: "Open System Settings", systemImage: "gearshape.2") {
                permissions.openMicrophoneSettings()
            }
        case .granted:
            return nil // the checkmark bounce + auto-advance is the feedback
        }
    }

    private var secondarySpec: OnboardingButtonSpec? {
        guard appState.micPermission == .denied else { return nil }
        return OnboardingButtonSpec(title: "Check Again") {
            permissions.refresh()
        }
    }
}
