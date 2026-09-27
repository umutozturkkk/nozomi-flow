import AppKit
import SwiftUI

/// About tab: identity header, live permission/engine status, and the
/// privacy blurb explaining what stays on-device.
struct AboutSettingsView: View {
    let appState: AppState
    let permissions: PermissionsService

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(.top, 30)
                .padding(.bottom, 22)

            Form {
                Section {
                    statusRow(
                        title: L10n.string("settings.about.microphone"),
                        isGood: appState.micPermission == .granted,
                        detail: microphoneDetail,
                        action: permissions.openMicrophoneSettings
                    )
                    statusRow(
                        title: L10n.string("settings.about.accessibility"),
                        isGood: appState.axTrusted,
                        detail: L10n.string(appState.axTrusted ? "settings.about.granted" : "settings.about.notGranted"),
                        action: permissions.openAccessibilitySettings
                    )
                    LabeledContent(L10n.string("settings.about.speechEngine"), value: appState.currentEngine.displayName)
                    LabeledContent("Apple Intelligence", value: appState.aiAvailability.isEmpty ? L10n.string("settings.checking") : appState.aiAvailability)
                    if let progress = appState.modelDownloadProgress {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(L10n.string("settings.about.downloadingModel"))
                                .font(.callout)
                            ProgressView(value: progress)
                        }
                        .padding(.vertical, 2)
                    }
                } header: {
                    Text(L10n.string("settings.about.status"))
                } footer: {
                    Text(L10n.string("settings.about.footer"))
                }
            }
            .formStyle(.grouped)
        }
    }

    private var header: some View {
        VStack(spacing: 6) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 72, height: 72)
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            Text("Nozomi Flow")
                .font(.system(size: 22, weight: .semibold))
                .padding(.top, 4)
            Text("1.0.0")
                .font(.callout)
                .foregroundStyle(.secondary)
            Text(L10n.string("settings.about.tagline"))
                .font(.callout)
                .italic()
                .foregroundStyle(.secondary)
                .padding(.top, 2)
        }
    }

    private var microphoneDetail: String {
        switch appState.micPermission {
        case .granted: return L10n.string("settings.about.granted")
        case .denied: return L10n.string("settings.about.denied")
        case .undetermined: return L10n.string("settings.about.notRequested")
        }
    }

    private func statusRow(title: String, isGood: Bool, detail: String, action: @escaping () -> Void) -> some View {
        HStack {
            StatusDot(isGood: isGood, badColor: .red)
            Text(title)
            Spacer()
            Text(detail)
                .foregroundStyle(.secondary)
            Button(L10n.string("settings.about.openSettings"), action: action)
                .controlSize(.small)
        }
    }
}
