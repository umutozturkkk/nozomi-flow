import Foundation
import SwiftUI

/// Add/Edit sheet for a personal dictionary entry, shared by the Dictionary
/// tab's Add (+) button and its edit flow (double-click / context menu).
/// `existing == nil` means "add".
struct DictionaryEntrySheet: View {
    let existing: DictionaryEntry?
    let onSave: (DictionaryEntry) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var phrase: String
    @State private var variantsText: String
    @State private var isEnabled: Bool
    @FocusState private var phraseFocused: Bool

    init(existing: DictionaryEntry?, onSave: @escaping (DictionaryEntry) -> Void) {
        self.existing = existing
        self.onSave = onSave
        _phrase = State(initialValue: existing?.phrase ?? "")
        _variantsText = State(initialValue: existing?.variants.joined(separator: ", ") ?? "")
        _isEnabled = State(initialValue: existing?.isEnabled ?? true)
    }

    private var trimmedPhrase: String {
        phrase.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    private var isValid: Bool { !trimmedPhrase.isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(existing == nil ? "Add Word" : "Edit Word")
                .font(.title3.weight(.semibold))
                .padding(.horizontal, 20)
                .padding(.top, 20)
                .padding(.bottom, 4)

            Form {
                TextField("Phrase", text: $phrase)
                    .focused($phraseFocused)
                TextField("Variants", text: $variantsText, prompt: Text("misheard forms, comma-separated"))
                Toggle("Enabled", isOn: $isEnabled)
            }
            .formStyle(.grouped)
            .frame(height: 180)

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save") { save() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(!isValid)
            }
            .padding(20)
        }
        .frame(width: 380)
        .onAppear { phraseFocused = true }
    }

    private func save() {
        let variants = variantsText
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        var entry = existing ?? DictionaryEntry(phrase: trimmedPhrase)
        entry.phrase = trimmedPhrase
        entry.variants = variants
        entry.isEnabled = isEnabled
        onSave(entry)
        dismiss()
    }
}
