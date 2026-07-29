import SwiftUI
import AppKit

/// Past meetings. Deliberately thin: the notes are markdown files, so the useful
/// actions are opening one in whatever the user reads markdown in and revealing it
/// in Finder, not reimplementing a reader here.
struct MeetingsSettingsView: View {
    @Bindable var store: MeetingStore
    @State private var pendingDeletion: MeetingRecord?

    var body: some View {
        Group {
            if store.meetings.isEmpty {
                emptyState
            } else {
                List(store.meetings) { meeting in
                    row(meeting)
                        .contextMenu {
                            Button("Show in Finder") {
                                NSWorkspace.shared.activateFileViewerSelecting([meeting.url])
                            }
                            Button("Delete", role: .destructive) { pendingDeletion = meeting }
                        }
                }
                .listStyle(.inset)
            }
        }
        .onAppear { store.reload() }
        .confirmationDialog(
            "Delete these notes?",
            isPresented: .init(get: { pendingDeletion != nil }, set: { if !$0 { pendingDeletion = nil } }),
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                if let pendingDeletion { store.delete(pendingDeletion) }
                pendingDeletion = nil
            }
            Button("Cancel", role: .cancel) { pendingDeletion = nil }
        } message: {
            Text("The markdown file is removed from disk. This can't be undone.")
        }
    }

    private func row(_ meeting: MeetingRecord) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(meeting.title)
                    .font(.body.weight(.medium))
                Text(meeting.url.lastPathComponent)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Button("Open") { NSWorkspace.shared.open(meeting.url) }
                .buttonStyle(.bordered)
        }
        .padding(.vertical, 4)
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "person.2.wave.2")
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(.tertiary)
            Text("No meetings yet")
                .font(.title3.weight(.semibold))
            Text("Start one from the menu bar. Both sides of the call are recorded, transcribed and summarised into a markdown file.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 340)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
