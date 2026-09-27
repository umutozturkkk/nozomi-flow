import Foundation
import Observation
import SwiftUI

/// General tab: hotkeys, hands-free, language, and top-level behavior toggles.
struct GeneralSettingsView: View {
    @Bindable var settings: SettingsStore
    let trainingStore: TrainingSampleStore

    var body: some View {
        Form {
            Section {
                Picker(L10n.string("settings.general.dictationKey"), selection: $settings.dictationKey) {
                    ForEach(HotkeyChoice.allCases, id: \.self) { choice in
                        Text(choice.displayName).tag(choice)
                    }
                }
                Picker(L10n.string("settings.general.commandKey"), selection: $settings.commandKey) {
                    ForEach(HotkeyChoice.allCases, id: \.self) { choice in
                        Text(choice.displayName).tag(choice)
                    }
                }
                if keysCollide {
                    collisionWarning
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }
            } header: {
                Text(L10n.string("settings.general.hotkeys"))
            }
            .animation(.spring(response: 0.35, dampingFraction: 0.8), value: keysCollide)

            Section {
                Toggle(L10n.string("settings.general.handsFree"), isOn: $settings.handsFreeEnabled)
            } footer: {
                Text(L10n.string("settings.general.handsFreeFooter"))
            }

            Section {
                Picker(L10n.string("settings.general.language"), selection: $settings.localeIdentifier) {
                    Text(L10n.string("settings.general.systemLanguage")).tag(nil as String?)
                    ForEach(LocaleCatalog.curated) { option in
                        Text(option.label).tag(option.identifier as String?)
                    }
                }
            } footer: {
                Text(L10n.string("settings.general.languageFooter"))
            }

            Section {
                Toggle(L10n.string("settings.general.cloudTranscription"), isOn: $settings.cloudTranscriptionEnabled)
                if settings.cloudTranscriptionEnabled {
                    SecureField(L10n.string("settings.apiKey"), text: $settings.cloudTranscriptionKey)
                    TextField(L10n.string("settings.model"), text: $settings.cloudTranscriptionModel)
                }
            } header: {
                Text(L10n.string("settings.general.transcription"))
            } footer: {
                if settings.cloudTranscriptionEnabled {
                    Text(L10n.string("settings.general.cloudFooter"))
                } else {
                    Text(L10n.string("settings.general.localFooter"))
                }
            }
            .animation(.spring(response: 0.3, dampingFraction: 0.85), value: settings.cloudTranscriptionEnabled)

            Section {
                Toggle(L10n.string("settings.general.identifySpeakers"), isOn: $settings.meetingSpeakerDetectionEnabled)
                TextField(L10n.string("settings.general.yourName"), text: $settings.userDisplayName, prompt: Text(NSFullUserName()))
            } header: {
                Text(L10n.string("settings.general.meetings"))
            } footer: {
                if settings.meetingSpeakerDetectionEnabled {
                    Text(L10n.string("settings.general.speakersFooter"))
                } else {
                    Text(L10n.string("settings.general.speakersOffFooter"))
                }
            }
            .animation(.spring(response: 0.3, dampingFraction: 0.85),
                       value: settings.meetingSpeakerDetectionEnabled)

            Section {
                Toggle(L10n.string("settings.general.playSounds"), isOn: $settings.playSounds)
                Toggle(L10n.string("settings.general.showLiveTranscript"), isOn: $settings.showLiveTranscript)
                Toggle(L10n.string("settings.general.keepHistory"), isOn: $settings.historyEnabled)
                Toggle(L10n.string("settings.general.launchAtLogin"), isOn: $settings.launchAtLogin)
            } header: {
                Text(L10n.string("settings.general.behavior"))
            }

            PersonalModelSection(settings: settings, store: trainingStore)
        }
        .formStyle(.grouped)
    }

    private var keysCollide: Bool {
        settings.dictationKey == settings.commandKey
    }

    private var collisionWarning: some View {
        Label(L10n.string("settings.general.keyCollision"), systemImage: "exclamationmark.triangle.fill")
            .font(.callout)
            .foregroundStyle(.orange)
    }

}
