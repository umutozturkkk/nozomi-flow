import Foundation
import Observation
import SwiftUI

/// General tab: hotkeys, hands-free, language, and top-level behavior toggles.
struct GeneralSettingsView: View {
    @Bindable var settings: SettingsStore

    var body: some View {
        Form {
            Section {
                Picker("Dictation key", selection: $settings.dictationKey) {
                    ForEach(HotkeyChoice.allCases, id: \.self) { choice in
                        Text(choice.displayName).tag(choice)
                    }
                }
                Picker("Command key", selection: $settings.commandKey) {
                    ForEach(HotkeyChoice.allCases, id: \.self) { choice in
                        Text(choice.displayName).tag(choice)
                    }
                }
                if keysCollide {
                    collisionWarning
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }
            } header: {
                Text("Hotkeys")
            }
            .animation(.spring(response: 0.35, dampingFraction: 0.8), value: keysCollide)

            Section {
                Toggle("Hands-free mode", isOn: $settings.handsFreeEnabled)
            } footer: {
                Text("Double-tap the dictation key to lock recording; tap again to stop.")
            }

            Section {
                Picker("Language", selection: $settings.localeIdentifier) {
                    Text("System language").tag(nil as String?)
                    ForEach(LocaleCatalog.curated) { option in
                        Text(option.label).tag(option.identifier as String?)
                    }
                }
            } footer: {
                Text("On-device engine is chosen automatically per language.")
            }

            Section {
                Toggle("Cloud transcription", isOn: $settings.cloudTranscriptionEnabled)
                if settings.cloudTranscriptionEnabled {
                    SecureField("API key", text: $settings.cloudTranscriptionKey)
                    TextField("Model", text: $settings.cloudTranscriptionModel)
                }
            } header: {
                Text("Transcription")
            } footer: {
                if settings.cloudTranscriptionEnabled {
                    Text("""
                        Recorded audio is uploaded when you release the key. \
                        Much more accurate on Turkish mixed with English terms, \
                        but there is no live transcript while you speak, and Nozomi Flow \
                        falls back to the on-device engine if the request fails.
                        """)
                } else {
                    Text("Everything stays on this Mac.")
                }
            }
            .animation(.spring(response: 0.3, dampingFraction: 0.85), value: settings.cloudTranscriptionEnabled)

            Section {
                Toggle("Identify who is speaking", isOn: $settings.meetingSpeakerDetectionEnabled)
                TextField("Your name", text: $settings.userDisplayName, prompt: Text(NSFullUserName()))
            } header: {
                Text("Meetings")
            } footer: {
                if settings.meetingSpeakerDetectionEnabled {
                    Text("""
                        Nozomi Flow reads the meeting window's captions and participant \
                        list so notes can say who said what. This happens on this Mac, \
                        and nothing from your screen is saved or sent anywhere. \
                        Turn captions on in the meeting for this to work, and use the \
                        name you appear under there so your own turns are not counted twice.
                        """)
                } else {
                    Text("Notes will label the two sides of the call as You and Them.")
                }
            }
            .animation(.spring(response: 0.3, dampingFraction: 0.85),
                       value: settings.meetingSpeakerDetectionEnabled)

            Section {
                Toggle("Play sounds", isOn: $settings.playSounds)
                Toggle("Show live transcript in HUD", isOn: $settings.showLiveTranscript)
                Toggle("Keep history", isOn: $settings.historyEnabled)
                Toggle("Launch at login", isOn: $settings.launchAtLogin)
            } header: {
                Text("Behavior")
            }
        }
        .formStyle(.grouped)
    }

    private var keysCollide: Bool {
        settings.dictationKey == settings.commandKey
    }

    private var collisionWarning: some View {
        Label("Both actions share a key — dictation wins", systemImage: "exclamationmark.triangle.fill")
            .font(.callout)
            .foregroundStyle(.orange)
    }

}
