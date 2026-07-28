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
                Picker("Formatting", selection: $settings.formattingLevel) {
                    ForEach(FormattingLevel.allCases, id: \.self) { level in
                        Text(formattingLabel(level)).tag(level)
                    }
                }
                .pickerStyle(.segmented)
            } footer: {
                Text(formattingFooter)
            }

            Section {
                Picker("AI engine", selection: $settings.llmEngine) {
                    ForEach(LLMEngineChoice.allCases, id: \.self) { engine in
                        Text(engineLabel(engine)).tag(engine)
                    }
                }
                HStack(spacing: 6) {
                    StatusDot(isGood: aiStatusIsGood)
                    Text(appState.aiAvailability.isEmpty ? "Checking…" : appState.aiAvailability)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }

                if settings.llmEngine == .openAI {
                    SecureField("API key", text: $settings.openAIKey)
                    TextField("Model", text: $settings.openAIModel)
                }
            } footer: {
                if settings.llmEngine == .openAI {
                    Text("Sent to OpenAI only when you dictate with this engine.")
                }
            }
            .animation(.spring(response: 0.3, dampingFraction: 0.85), value: settings.llmEngine)

            Section {
                Toggle("Remove filler words", isOn: $settings.removeFillers)
            }

            Section {
                Toggle("Match tone to app", isOn: $settings.toneMatching)
            } footer: {
                Text("Casual in Slack and Messages, polished in Mail.")
            }

            Section {
                Toggle("Use on-screen context", isOn: $settings.captureFieldContext)
            } footer: {
                Text("Reads the focused text field to improve formatting. Password fields are never read.")
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
                Text("Custom instructions")
            } footer: {
                Text("Extra guidance for the AI pass, e.g. \"Prefer bullet lists\" or \"Keep my Turkish slang as-is.\"")
            }
        }
        .formStyle(.grouped)
    }

    private var aiStatusIsGood: Bool {
        let s = appState.aiAvailability.lowercased()
        // "unavailable" itself contains "available" -- exclude it so a bad
        // status string never reads as green.
        return s.contains("ready") || (s.contains("available") && !s.contains("unavailable"))
    }

    private var formattingFooter: String {
        switch settings.formattingLevel {
        case .off: return "Verbatim transcript — nothing is changed after transcription."
        case .light: return "Removes filler words and fixes capitalization."
        case .full: return "AI cleanup — self-corrections, lists, and tone."
        }
    }

    private func formattingLabel(_ level: FormattingLevel) -> String {
        switch level {
        case .off: return "Off"
        case .light: return "Light"
        case .full: return "Full"
        }
    }

    private func engineLabel(_ choice: LLMEngineChoice) -> String {
        switch choice {
        case .auto: return "Auto (Apple Intelligence)"
        case .appleIntelligence: return "Apple Intelligence"
        case .openAI: return "OpenAI"
        case .none: return "None"
        }
    }
}
