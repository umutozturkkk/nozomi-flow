import SwiftUI
import AppKit

/// Step 4: choose the dictation hotkey. Picking `.fn` surfaces an amber
/// callout, since macOS's own "press 🌐 for emoji" behavior conflicts with it.
struct OnboardingHotkeyStep: View {
    @Bindable var settings: SettingsStore
    var onBack: () -> Void
    var onNext: () -> Void

    var body: some View {
        OnboardingStepScaffold(
            showBack: true,
            onBack: onBack,
            primary: OnboardingButtonSpec(title: "Continue", systemImage: "arrow.right", action: onNext)
        ) {
            VStack(alignment: .leading, spacing: 20) {
                OnboardingStepIcon(systemName: "keyboard")

                VStack(alignment: .leading, spacing: 6) {
                    Text("Your hotkey")
                        .font(.system(size: 24, weight: .bold, design: .rounded))
                    Text("Hold to talk · release to insert · double-tap to lock")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }

                HStack {
                    Spacer(minLength: 0)
                    KeycapView(label: settings.dictationKey.displayName)
                    Spacer(minLength: 0)
                }
                .padding(.vertical, 4)

                VStack(alignment: .leading, spacing: 8) {
                    Text("CHANGE KEY")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .kerning(0.6)
                    Picker("", selection: $settings.dictationKey) {
                        ForEach(HotkeyChoice.allCases, id: \.self) { choice in
                            Text(choice.displayName).tag(choice)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                }

                if settings.dictationKey == .fn {
                    FnKeyCallout()
                        .transition(.asymmetric(insertion: .opacity.combined(with: .scale(scale: 0.96, anchor: .top)), removal: .opacity))
                }
            }
            .animation(.spring(response: 0.4, dampingFraction: 0.85), value: settings.dictationKey)
        }
    }
}

/// Amber warning shown only while the fn key is the active dictation hotkey.
private struct FnKeyCallout: View {
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 10) {
                Text("macOS also uses the 🌐 key. Set 'Press 🌐 key' to 'Do Nothing' in Keyboard settings to avoid the emoji picker popping up.")
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Open Keyboard Settings", action: openKeyboardSettings)
                    .buttonStyle(.bordered)
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .glassEffect(.regular.tint(Color.orange.opacity(0.22)), in: .rect(cornerRadius: 14))
    }

    private func openKeyboardSettings() {
        let preferred = "x-apple.systempreferences:com.apple.Keyboard-Settings.extension"
        if let url = URL(string: preferred) {
            NSWorkspace.shared.open(url)
        } else if let fallback = URL(string: "x-apple.systempreferences:") {
            NSWorkspace.shared.open(fallback)
        }
    }
}
