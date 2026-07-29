import SwiftUI
import AppKit

/// Step 6: Screen Recording, needed only to record meetings.
///
/// The permission's name is alarming and its scope here is narrow, so the step says
/// exactly what is read and what is not. macOS offers no way to request audio alone:
/// ScreenCaptureKit is the only route to system audio and it is gated behind screen
/// capture regardless of the fact that no pixels are kept.
///
/// Genuinely skippable. Dictation never touches this, and pushing a permission on
/// someone who only wants to dictate is how an app ends up denied by reflex.
@available(macOS 15.0, *)
struct OnboardingScreenRecordingStep: View {
    var onBack: () -> Void
    var onNext: () -> Void

    @State private var granted = MeetingSessionController.hasScreenRecordingPermission
    @State private var didRequest = false

    var body: some View {
        OnboardingStepScaffold(
            showBack: true,
            onBack: onBack,
            secondary: granted ? nil : OnboardingButtonSpec(title: "Skip", action: onNext),
            primary: OnboardingButtonSpec(
                title: granted ? "Continue" : "Allow",
                systemImage: granted ? "arrow.right" : nil,
                action: { granted ? onNext() : request() }
            )
        ) {
            VStack(alignment: .leading, spacing: 20) {
                OnboardingStepIcon(systemName: "person.2.wave.2")

                VStack(alignment: .leading, spacing: 6) {
                    Text("Meeting recording")
                        .font(.system(size: 24, weight: .bold, design: .rounded))
                    Text("Optional. Dictation works without it.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }

                Text("""
                    To capture the other side of a call, macOS routes system audio \
                    through Screen Recording. Nothing on your screen is read or kept: \
                    the video side of that stream is two pixels wide and thrown away.
                    """)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if granted {
                    OnboardingStatusChip(
                        icon: "checkmark.circle.fill",
                        title: "Ready to record meetings",
                        style: .success,
                        bounce: true
                    )
                } else if didRequest {
                    OnboardingStatusChip(
                        icon: "exclamationmark.triangle.fill",
                        title: "Still not allowed",
                        subtitle: "macOS only asks once. Turn it on in System Settings, then come back.",
                        style: .warning
                    )
                    Button("Open Screen Recording settings") {
                        MeetingSessionController.openScreenRecordingSettings()
                    }
                    .buttonStyle(.bordered)
                }
            }
            .animation(.spring(response: 0.4, dampingFraction: 0.85), value: granted)
            .task { await pollUntilGranted() }
        }
    }

    private func request() {
        didRequest = true
        MeetingSessionController.requestScreenRecordingPermission()
        granted = MeetingSessionController.hasScreenRecordingPermission
    }

    /// Granting happens in System Settings, in another process, with no notification
    /// back. Polling is the only way the step notices; it stops as soon as it sees
    /// the grant or the step goes away.
    private func pollUntilGranted() async {
        while !Task.isCancelled && !granted {
            try? await Task.sleep(nanoseconds: 700_000_000)
            granted = MeetingSessionController.hasScreenRecordingPermission
        }
    }
}
