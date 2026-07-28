import AppKit
import Foundation
import Symbols
import SwiftUI

/// History tab: usage-stats strip, search, and the dictation list. Reads
/// `history.stats` / `history.entries` directly each render -- cheap at this
/// scale, and keeps the view auto-tracked by @Observable.
struct HistorySettingsView: View {
    let settings: SettingsStore
    let history: HistoryStore

    @State private var query = ""
    @State private var isPresentingClearConfirm = false
    @State private var emptyBounce = false

    var body: some View {
        VStack(spacing: 0) {
            statsStrip
                .padding(.horizontal, 16)
                .padding(.top, 14)
                .padding(.bottom, 10)

            if !settings.historyEnabled {
                disabledBanner
                    .padding(.horizontal, 16)
                    .padding(.bottom, 10)
            }

            controlsRow
                .padding(.horizontal, 16)
                .padding(.bottom, 10)

            Divider()

            content
        }
        .confirmationDialog(
            "Clear All History?",
            isPresented: $isPresentingClearConfirm,
            titleVisibility: .visible
        ) {
            Button("Clear All", role: .destructive) { history.clear() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This deletes \(history.entries.count) dictation\(history.entries.count == 1 ? "" : "s"). This can't be undone.")
        }
    }

    // MARK: - Stats strip

    private var statsStrip: some View {
        let stats = history.stats
        return HStack(spacing: 10) {
            StatCard(icon: "textformat", tint: .blue, value: "\(stats.totalWords)", label: "Total words")
            StatCard(icon: "speedometer", tint: .green, value: String(format: "%.1f", stats.averageWPM), label: "Avg WPM")
            StatCard(icon: "flame.fill", tint: stats.streakDays > 0 ? .orange : .secondary, value: "\(stats.streakDays)", label: "Streak")
            StatCard(icon: "clock.badge.checkmark", tint: .purple, value: "\(Int(stats.minutesSaved.rounded()))", label: "Minutes saved")
            StatCard(icon: "checkmark.seal", tint: .pink, value: "\(stats.totalCorrections)", label: "Corrections")
        }
    }

    // MARK: - Controls

    private var controlsRow: some View {
        HStack(spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Search dictations", text: $query)
                    .textFieldStyle(.plain)
                if !query.isEmpty {
                    Button {
                        query = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 7))
            .frame(maxWidth: 260)

            Spacer()

            Button(role: .destructive) {
                isPresentingClearConfirm = true
            } label: {
                Label("Clear All", systemImage: "trash")
            }
            .disabled(history.entries.isEmpty)
        }
    }

    private var disabledBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "info.circle.fill")
                .foregroundStyle(.secondary)
            Text("History is off — new dictations aren't being saved.")
                .font(.callout)
                .foregroundStyle(.secondary)
            Spacer()
            Button("Enable") { settings.historyEnabled = true }
                .controlSize(.small)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
    }

    // MARK: - List

    private var filteredEntries: [HistoryEntry] {
        history.search(query)
    }

    @ViewBuilder
    private var content: some View {
        if history.entries.isEmpty {
            emptyState
        } else if filteredEntries.isEmpty {
            noResultsState
        } else {
            List {
                ForEach(filteredEntries) { entry in
                    row(entry)
                }
            }
            .listStyle(.inset)
            .alternatingRowBackgrounds()
        }
    }

    private func row(_ entry: HistoryEntry) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(entry.finalText)
                .font(.callout)
                .lineLimit(2)
            HStack(spacing: 4) {
                if entry.mode == SessionMode.command.rawValue {
                    Image(systemName: "wand.and.stars")
                        .font(.system(size: 9))
                        .foregroundStyle(.purple)
                }
                Text(subLine(entry))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 3)
        .contentShape(Rectangle())
        .contextMenu {
            Button("Copy") { copy(entry.finalText) }
            Button("Copy Raw Transcript") { copy(entry.rawText) }
            Divider()
            Button("Delete", role: .destructive) { history.delete(id: entry.id) }
        }
        .swipeActions {
            Button("Delete", role: .destructive) { history.delete(id: entry.id) }
        }
    }

    private func subLine(_ entry: HistoryEntry) -> String {
        let app = entry.appName ?? "Unknown app"
        let time = entry.date.formatted(.relative(presentation: .named))
        let words = "\(entry.wordCount) word\(entry.wordCount == 1 ? "" : "s")"
        return "\(app) · \(time) · \(words)"
    }

    private func copy(_ text: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
    }

    // MARK: - Empty states

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "waveform")
                .font(.system(size: 40))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.blue)
                .symbolEffect(.bounce, value: emptyBounce)
                .onAppear { emptyBounce.toggle() }
            Text("Nothing yet — hold your dictation key and just talk.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 320)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    private var noResultsState: some View {
        VStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 28))
                .foregroundStyle(.secondary)
            Text("No matches for \"\(query)\"")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }
}

private struct StatCard: View {
    let icon: String
    let tint: Color
    let value: String
    let label: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // The label owns the full width; sharing a row with the icon left so
            // little room that "Corrections" wrapped mid-word. Two lines are always
            // reserved so every card is the same height whether its label wraps or
            // not, which also keeps the glass material reading identically across
            // the row.
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(2, reservesSpace: true)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 5) {
                Image(systemName: icon)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(tint)
                Text(value)
                    .font(.system(size: 19, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .contentTransition(.numericText())
                    .animation(.smooth, value: value)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 12))
    }
}
