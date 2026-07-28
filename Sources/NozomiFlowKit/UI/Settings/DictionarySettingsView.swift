import Symbols
import SwiftUI

/// Personal dictionary tab: canonical phrase -> misheard-variant rules, with
/// an add/edit sheet and an empty state that sells the feature.
struct DictionarySettingsView: View {
    let dictionary: PersonalDictionaryStore

    @State private var sheetMode: SheetMode?
    @State private var bounceTrigger = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if dictionary.entries.isEmpty {
                emptyState
            } else {
                list
            }
        }
        .sheet(item: $sheetMode) { mode in
            DictionaryEntrySheet(existing: mode.existingEntry) { saved in
                switch mode {
                case .add: dictionary.add(saved)
                case .edit: dictionary.update(saved)
                }
            }
        }
    }

    private var header: some View {
        HStack {
            Spacer()
            Button {
                sheetMode = .add
            } label: {
                Label("Add", systemImage: "plus")
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var list: some View {
        List {
            ForEach(dictionary.entries) { entry in
                row(entry)
            }
        }
        .listStyle(.inset)
        .alternatingRowBackgrounds()
    }

    private func row(_ entry: DictionaryEntry) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.phrase)
                    .fontWeight(.semibold)
                if !entry.variants.isEmpty {
                    Text(entry.variants.joined(separator: " · "))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer()
            Toggle("", isOn: Binding(
                get: { entry.isEnabled },
                set: { newValue in
                    var updated = entry
                    updated.isEnabled = newValue
                    dictionary.update(updated)
                }
            ))
            .labelsHidden()
            .toggleStyle(.switch)
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { sheetMode = .edit(entry) }
        .contextMenu {
            Button("Edit") { sheetMode = .edit(entry) }
            Button("Delete", role: .destructive) { dictionary.delete(id: entry.id) }
        }
        .swipeActions {
            Button("Delete", role: .destructive) { dictionary.delete(id: entry.id) }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "character.book.closed.fill")
                .font(.system(size: 46))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.orange)
                .symbolEffect(.bounce, value: bounceTrigger)
                .onAppear { bounceTrigger.toggle() }
            VStack(spacing: 4) {
                Text("Teach Nozomi Flow your words")
                    .font(.title3.weight(.semibold))
                Text("Names, brands, jargon — add the words Nozomi Flow should always get right.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 300)
            }
            Button {
                sheetMode = .add
            } label: {
                Label("Add Word", systemImage: "plus")
            }
            .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    private enum SheetMode: Identifiable {
        case add
        case edit(DictionaryEntry)

        var id: String {
            switch self {
            case .add: return "add"
            case .edit(let entry): return entry.id.uuidString
            }
        }

        var existingEntry: DictionaryEntry? {
            if case .edit(let entry) = self { return entry }
            return nil
        }
    }
}
