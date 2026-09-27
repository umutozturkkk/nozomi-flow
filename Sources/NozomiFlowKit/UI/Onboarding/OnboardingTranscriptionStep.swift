import SwiftUI
import AppKit

/// Step 5: language and where transcription runs.
///
/// This has to come before the model step, which prepares assets for whichever
/// locale is chosen, and cannot be left to Settings: picking the wrong language
/// makes the app look broken on first use, and the cloud path is unusable until
/// a key exists.
struct OnboardingTranscriptionStep: View {
    @Bindable var settings: SettingsStore
    var onBack: () -> Void
    var onNext: () -> Void

    private var needsKey: Bool {
        settings.cloudTranscriptionEnabled && settings.cloudTranscriptionKey.isEmpty
    }

    var body: some View {
        OnboardingStepScaffold(
            showBack: true,
            onBack: onBack,
            primary: OnboardingButtonSpec(
                title: L10n.string("common.continue"),
                systemImage: "arrow.right",
                action: onNext
            )
        ) {
            VStack(alignment: .leading, spacing: 20) {
                OnboardingStepIcon(systemName: "waveform")

                VStack(alignment: .leading, spacing: 6) {
                    Text(L10n.string("onboarding.transcription.title"))
                        .font(.system(size: 24, weight: .bold, design: .rounded))
                    Text(L10n.string("onboarding.transcription.subtitle"))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text(L10n.string("onboarding.transcription.language"))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .kerning(0.6)
                    Picker("", selection: $settings.localeIdentifier) {
                        Text(L10n.string("onboarding.transcription.systemLanguage")).tag(nil as String?)
                        ForEach(LocaleCatalog.curated) { option in
                            Text(option.label).tag(option.identifier as String?)
                        }
                    }
                    .labelsHidden()
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text(L10n.string("onboarding.transcription.transcription"))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .kerning(0.6)
                    Picker("", selection: $settings.cloudTranscriptionEnabled) {
                        Text(L10n.string("onboarding.transcription.onDevice")).tag(false)
                        Text(L10n.string("onboarding.transcription.cloud")).tag(true)
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)

                    Text(L10n.string(settings.cloudTranscriptionEnabled
                         ? "onboarding.transcription.cloudNote"
                         : "onboarding.transcription.onDeviceNote"))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if settings.cloudTranscriptionEnabled {
                    CloudKeyField(settings: settings)
                        .transition(.asymmetric(
                            insertion: .opacity.combined(with: .scale(scale: 0.96, anchor: .top)),
                            removal: .opacity
                        ))
                }
            }
            .animation(.spring(response: 0.4, dampingFraction: 0.85), value: settings.cloudTranscriptionEnabled)
        }
    }
}

/// API key entry, plus the amber nudge shown while the field is still empty:
/// continuing without one leaves cloud selected but non-functional, and the app
/// would quietly fall back on-device with no explanation.
private struct CloudKeyField: View {
    @Bindable var settings: SettingsStore

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SecureField(L10n.string("onboarding.transcription.apiKey"), text: $settings.cloudTranscriptionKey)
                .textFieldStyle(.roundedBorder)

            if settings.cloudTranscriptionKey.isEmpty {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.orange)
                    VStack(alignment: .leading, spacing: 10) {
                        Text(L10n.string("onboarding.transcription.noKeyWarning"))
                            .font(.callout)
                            .fixedSize(horizontal: false, vertical: true)
                        Button(L10n.string("onboarding.transcription.getKey")) {
                            if let url = URL(string: "https://openrouter.ai/keys") {
                                NSWorkspace.shared.open(url)
                            }
                        }
                        .buttonStyle(.bordered)
                    }
                    Spacer(minLength: 0)
                }
                .padding(14)
                .glassEffect(.regular.tint(Color.orange.opacity(0.22)), in: .rect(cornerRadius: 14))
            }
        }
    }
}
