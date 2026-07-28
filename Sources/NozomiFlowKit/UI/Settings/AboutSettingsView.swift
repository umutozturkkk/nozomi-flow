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
                        title: "Microphone",
                        isGood: appState.micPermission == .granted,
                        detail: microphoneDetail,
                        action: permissions.openMicrophoneSettings
                    )
                    statusRow(
                        title: "Accessibility",
                        isGood: appState.axTrusted,
                        detail: appState.axTrusted ? "Granted" : "Not granted",
                        action: permissions.openAccessibilitySettings
                    )
                    LabeledContent("Speech engine", value: appState.currentEngine.displayName)
                    LabeledContent("Apple Intelligence", value: appState.aiAvailability.isEmpty ? "Checking…" : appState.aiAvailability)
                    if let progress = appState.modelDownloadProgress {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Downloading speech model…")
                                .font(.callout)
                            ProgressView(value: progress)
                        }
                        .padding(.vertical, 2)
                    }
                } header: {
                    Text("Status")
                } footer: {
                    Text("Nozomi Flow listens only while you hold the key. Speech is transcribed on this Mac; nothing leaves your machine unless you choose a cloud engine.")
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
            Text("Don't type. Just murmur.")
                .font(.callout)
                .italic()
                .foregroundStyle(.secondary)
                .padding(.top, 2)
        }
    }

    private var microphoneDetail: String {
        switch appState.micPermission {
        case .granted: return "Granted"
        case .denied: return "Denied"
        case .undetermined: return "Not requested"
        }
    }

    private func statusRow(title: String, isGood: Bool, detail: String, action: @escaping () -> Void) -> some View {
        HStack {
            StatusDot(isGood: isGood, badColor: .red)
            Text(title)
            Spacer()
            Text(detail)
                .foregroundStyle(.secondary)
            Button("Open Settings", action: action)
                .controlSize(.small)
        }
    }
}
