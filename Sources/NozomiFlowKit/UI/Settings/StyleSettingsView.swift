import AppKit
import Observation
import SwiftUI

/// Style tab: formatting aggressiveness, AI engine choice (with live
/// availability status), optional OpenAI credentials, and custom instructions.
struct StyleSettingsView: View {
    @Bindable var settings: SettingsStore
    let appState: AppState

    var body: some View {
        Form {
            Section {
                Picker(L10n.string("settings.style.formatting"), selection: $settings.formattingLevel) {
                    ForEach(FormattingLevel.allCases, id: \.self) { level in
                        Text(formattingLabel(level)).tag(level)
                    }
                }
                .pickerStyle(.segmented)
            } footer: {
                Text(formattingFooter)
            }

            Section {
                Picker(L10n.string("settings.style.aiEngine"), selection: $settings.llmEngine) {
                    ForEach(LLMEngineChoice.allCases, id: \.self) { engine in
                        Text(engineLabel(engine)).tag(engine)
                    }
                }
                HStack(spacing: 6) {
                    StatusDot(isGood: aiStatusIsGood)
                    Text(appState.aiAvailability.isEmpty ? L10n.string("settings.checking") : appState.aiAvailability)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }

                if settings.llmEngine == .openAI {
                    SecureField(L10n.string("settings.apiKey"), text: $settings.openAIKey)
                    TextField(L10n.string("settings.model"), text: $settings.openAIModel)
                }
            } footer: {
                if settings.llmEngine == .openAI {
                    Text(L10n.string("settings.style.openAIFooter"))
                }
            }
            .animation(.spring(response: 0.3, dampingFraction: 0.85), value: settings.llmEngine)

            Section {
                Toggle(L10n.string("settings.style.removeFillers"), isOn: $settings.removeFillers)
            }

            Section {
                Toggle(L10n.string("settings.style.toneMatching"), isOn: $settings.toneMatching)
            } footer: {
                Text(L10n.string("settings.style.toneMatchingFooter"))
            }

            Section {
                Toggle(L10n.string("settings.style.fieldContext"), isOn: $settings.captureFieldContext)
            } footer: {
                Text(L10n.string("settings.style.fieldContextFooter"))
            }

            Section {
                TextEditor(text: $settings.customInstructions)
                    .font(.callout)
                    .frame(height: 72)
                    .scrollContentBackground(.hidden)
                    .padding(6)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(Color(nsColor: .textBackgroundColor))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(Color.primary.opacity(0.08))
                    )
            } header: {
                Text(L10n.string("settings.style.customInstructions"))
            } footer: {
                Text(L10n.string("settings.style.customInstructionsFooter"))
            }
        }
        .formStyle(.grouped)
    }

    private var aiStatusIsGood: Bool {
        // The status is localized, so compare against the one "ready" string
        // rather than looking for English words in it.
        appState.aiAvailability == L10n.string("ai.status.ready")
    }

    private var formattingFooter: String {
        switch settings.formattingLevel {
        case .off: return L10n.string("settings.style.formattingFooter.off")
        case .light: return L10n.string("settings.style.formattingFooter.light")
        case .full: return L10n.string("settings.style.formattingFooter.full")
        }
    }

    private func formattingLabel(_ level: FormattingLevel) -> String {
        switch level {
        case .off: return L10n.string("settings.style.formatting.off")
        case .light: return L10n.string("settings.style.formatting.light")
        case .full: return L10n.string("settings.style.formatting.full")
        }
    }

    private func engineLabel(_ choice: LLMEngineChoice) -> String {
        switch choice {
        case .auto: return L10n.string("settings.style.engine.auto")
        case .appleIntelligence: return "Apple Intelligence"
        case .openAI: return "OpenAI"
        case .none: return L10n.string("settings.style.engine.none")
        }
    }
}
