import SwiftUI

/// Settings > General > Personal model: the collection toggle, progress toward
/// the training target, and deleting what was collected.
struct PersonalModelSection: View {
    static let targetMinutes = 90

    @Bindable var settings: SettingsStore
    let store: TrainingSampleStore

    @State private var collectedMinutes = 0
    @State private var hasData = false
    @State private var confirmingDelete = false

    var body: some View {
        Section {
            Toggle(L10n.string("training.toggle"), isOn: $settings.collectTrainingData)
            Text(L10n.format("training.progress", collectedMinutes, Self.targetMinutes))
                .foregroundStyle(.secondary)
            Button(L10n.string("training.deleteAll"), role: .destructive) {
                confirmingDelete = true
            }
            .disabled(!hasData)
        } header: {
            Text(L10n.string("training.header"))
        } footer: {
            Text(L10n.string(settings.cloudTranscriptionEnabled ? "training.footer" : "training.needsCloud"))
        }
        .task { refresh() }
        .confirmationDialog(
            L10n.string("training.deleteConfirm.title"),
            isPresented: $confirmingDelete
        ) {
            Button(L10n.string("common.delete"), role: .destructive) {
                try? store.deleteAll()
                refresh()
            }
            Button(L10n.string("common.cancel"), role: .cancel) {}
        } message: {
            Text(L10n.string("training.deleteConfirm.message"))
        }
    }

    private func refresh() {
        collectedMinutes = Int(store.totalDurationSeconds() / 60)
        hasData = store.hasAnyData()
    }
}
