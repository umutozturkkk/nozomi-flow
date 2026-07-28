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
                    ForEach(Self.curatedLocales) { option in
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

    // MARK: - Curated locale list

    private struct LocaleOption: Identifiable {
        let identifier: String
        let label: String
        var id: String { identifier }
    }

    /// The on-device DictationTranscriber locale set (see SPEC.md ground truth).
    private static let curatedLocaleIdentifiers = [
        "en_US", "en_GB", "en_AU", "en_CA", "en_IN",
        "de_DE", "de_AT", "de_CH",
        "es_ES", "es_MX", "es_US", "es_CL",
        "fr_FR", "fr_CA", "fr_BE", "fr_CH",
        "it_IT", "it_CH",
        "pt_BR", "pt_PT",
        "ja_JP", "ko_KR",
        "zh_CN", "zh_TW", "zh_HK", "yue_CN",
        "tr_TR", "ar_SA", "ru_RU", "uk_UA", "pl_PL",
        "nl_NL", "nl_BE",
        "sv_SE", "da_DK", "nb_NO", "fi_FI",
        "cs_CZ", "sk_SK", "hu_HU", "ro_RO",
        "el_GR", "he_IL", "hi_IN", "th_TH", "vi_VN",
        "id_ID", "ms_MY", "ca_ES", "hr_HR",
    ]

    private static let curatedLocales: [LocaleOption] = curatedLocaleIdentifiers
        .map { id in
            LocaleOption(identifier: id, label: Locale.current.localizedString(forIdentifier: id) ?? id)
        }
        .sorted { $0.label.localizedStandardCompare($1.label) == .orderedAscending }
}
