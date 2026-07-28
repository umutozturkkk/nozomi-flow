import SwiftUI

/// Step 3: Accessibility trust. macOS only flips this after a trip to System
/// Settings, so this step polls in the background instead of making the user
/// come back and click "check again". The poll is a plain `.task` with no
/// `id:`, which SwiftUI cancels automatically the moment this view leaves
/// the hierarchy (Back, forward auto-advance, or the window closing).
struct OnboardingAccessibilityStep: View {
    let appState: AppState
    let permissions: PermissionsService
    var onAccessibilityGranted: () -> Void
    var onBack: () -> Void
    var onNext: () -> Void

    var body: some View {
        OnboardingStepScaffold(showBack: true, onBack: onBack, primary: primarySpec) {
            VStack(alignment: .leading, spacing: 18) {
                OnboardingStepIcon(systemName: "accessibility")

                VStack(alignment: .leading, spacing: 6) {
                    Text("Accessibility access")
                        .font(.system(size: 24, weight: .bold, design: .rounded))
                    Text("To type into other apps and hear your hotkey, macOS requires Accessibility access.")
                        .font(.body)
                    Text("It's a standard macOS permission — Nozomi Flow only ever types what you dictate.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }

                statusChip

                if !appState.axTrusted {
                    Label("We're watching for it automatically — no need to come back.", systemImage: "arrow.triangle.2.circlepath")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .task {
            // Cancelled by SwiftUI when this view disappears (step change or window close).
            while !Task.isCancelled && !appState.axTrusted {
                permissions.refresh()
                if appState.axTrusted { break }
                try? await Task.sleep(for: .seconds(1))
            }
        }
        .task(id: appState.axTrusted) {
            guard appState.axTrusted else { return }
            onAccessibilityGranted()
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled else { return }
            onNext()
        }
    }

    @ViewBuilder
    private var statusChip: some View {
        if appState.axTrusted {
            OnboardingStatusChip(icon: "checkmark.seal.fill", title: "Accessibility enabled", style: .success, bounce: true)
        } else {
            OnboardingStatusChip(
                icon: "hourglass",
                title: "Waiting for permission",
                subtitle: "Grant it below, or in System Settings \u{203A} Privacy & Security \u{203A} Accessibility.",
                style: .neutral
            )
        }
    }

    private var primarySpec: OnboardingButtonSpec? {
        guard !appState.axTrusted else { return nil }
        return OnboardingButtonSpec(title: "Grant Access", systemImage: "lock.open") {
            permissions.promptAccessibility()
            permissions.openAccessibilitySettings()
        }
    }
}
