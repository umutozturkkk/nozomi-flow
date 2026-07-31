# Meetings Browser and Quality-of-Life Pass Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make meeting notes readable, shareable and deletable inside the app, and make the rest of the meeting flow visible while it runs.

**Architecture:** `MeetingStore` learns to read the header of each note so a listing can show a real duration and a preview. A pure `MeetingNoteRenderer` turns a note into blocks that a small SwiftUI reader lays out, so the parsing is testable without a window. The Meetings settings tab becomes a split of list and reader with share, copy and delete. The status item and a user notification make a running meeting and a finished one visible outside Settings.

**Tech Stack:** Swift 6 toolchain in language mode 5, SwiftPM, SwiftUI + AppKit, XCTest, UserNotifications.

**Spec:** `docs/superpowers/specs/2026-07-31-meetings-browser-and-qol-design.md`

---

## File Structure

Created:

- `Sources/NozomiFlowKit/Core/Meeting/MeetingNoteRenderer.swift` - pure markdown to blocks. No UIKit, no AppKit, no file system.
- `Sources/NozomiFlowKit/UI/Settings/MeetingNoteView.swift` - renders blocks. Knows nothing about stores or selection.
- `Tests/NozomiFlowKitTests/MeetingNoteRendererTests.swift`

Modified:

- `Sources/NozomiFlowKit/Core/Meeting/MeetingStore.swift` - header parsing, snippet, whole-note read.
- `Sources/NozomiFlowKit/UI/Settings/MeetingsSettingsView.swift` - rewritten as list plus reader plus actions.
- `Sources/NozomiFlowKit/UI/Settings/SettingsWindowController.swift` - window size.
- `Sources/NozomiFlowKit/UI/Settings/GeneralSettingsView.swift` - summary model field, footer, em dash.
- `Sources/NozomiFlowKit/UI/StatusItem/StatusItemController.swift` - meeting icon, elapsed time, Meetings item, em dash.
- `Sources/NozomiFlowKit/UI/MeetingAlert.swift` - adds `MeetingNotifier` beside the existing alerts.
- `Sources/NozomiFlowKit/App/NozomiFlowMain.swift` - wiring and notification delegate.
- `Tests/NozomiFlowKitTests/MeetingNotesTests.swift` - header parsing tests.
- Five view files for the em dash sweep (Task 9).

Why `MeetingNotifier` lives in `MeetingAlert.swift`: that file already declares itself "the meeting flow's only user-visible feedback". A notification is the same responsibility, and the file stays around 130 lines.

---

## Task 1: MeetingStore reads duration and a preview out of each note

**Files:**
- Modify: `Sources/NozomiFlowKit/Core/Meeting/MeetingStore.swift`
- Test: `Tests/NozomiFlowKitTests/MeetingNotesTests.swift`

Today `reload()` only lists the directory, so every record carries `duration: 0` and the list has nothing to preview. The duration is already written into each note as `_<long date> · 12:34_`, so it is read back from there rather than kept in a sidecar file: one source of truth, and it works on notes already on disk.

- [ ] **Step 1: Write the failing tests**

Add to `Tests/NozomiFlowKitTests/MeetingNotesTests.swift`, before the `// MARK: - Helpers` section:

```swift
    // MARK: - Listing metadata

    @MainActor
    func testDurationIsRecoveredFromTheHeaderTheStoreItselfWrote() {
        let short = MeetingStore.parseHead("# Meeting\n\n_Friday, July 31, 2026 at 14:05 · 12:34_\n")
        XCTAssertEqual(short.duration, 754, accuracy: 0.5)

        let long = MeetingStore.parseHead("# Meeting\n\n_Friday · 1:02:03_\n")
        XCTAssertEqual(long.duration, 3723, accuracy: 0.5)
    }

    @MainActor
    func testAnUnreadableHeaderCostsTheDurationAndNothingElse() {
        // The listing must survive a note written by an older build or edited by hand.
        let head = MeetingStore.parseHead("# Meeting\n\n_no duration here_\n\nThe team shipped.")
        XCTAssertEqual(head.duration, 0)
        XCTAssertEqual(head.snippet, "The team shipped.")
    }

    @MainActor
    func testSnippetSkipsHeadingsAndTheMetadataLine() {
        let head = MeetingStore.parseHead("""
            # Meeting on Jul 31

            _Friday, July 31, 2026 at 14:05 · 42:13_

            ## Summary

            The team agreed to ship on Friday.
            """)
        XCTAssertEqual(head.snippet, "The team agreed to ship on Friday.")
        XCTAssertEqual(head.duration, 2533, accuracy: 0.5)
    }

    @MainActor
    func testTheMissingSummaryPlaceholderIsNotUsedAsAPreview() {
        // Otherwise every summary-less meeting previews as "Not generated for this
        // meeting.", which tells the user nothing and fills the list with noise.
        let head = MeetingStore.parseHead("""
            # Meeting

            _Friday · 0:30_

            ## Summary

            \(MeetingStore.missingSummaryText)

            ## Transcript

            **0:00 You:** Merhaba
            """)
        XCTAssertTrue(head.snippet.isEmpty)
    }

    @MainActor
    func testListingCarriesDurationAndPreviewAfterAReload() throws {
        let store = try makeStore()
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        store.save(id: MeetingStore.makeID(for: date), startedAt: date, duration: 754,
                   transcript: "**0:00 You:** Merhaba",
                   summary: "## Summary\n\nWe agreed on the pricing change.")

        store.reload()
        let record = try XCTUnwrap(store.meetings.first)
        XCTAssertEqual(record.duration, 754, accuracy: 0.5)
        XCTAssertEqual(record.summarySnippet, "We agreed on the pricing change.")
    }

    @MainActor
    func testTurkishTextSurvivesTheTruncatedHeaderRead() throws {
        // The head is read as bytes and can be cut inside a multi-byte character.
        // Decoding must degrade that one character, not lose the whole listing.
        let store = try makeStore()
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let long = String(repeating: "şğüöçİ ", count: 400)
        store.save(id: MeetingStore.makeID(for: date), startedAt: date, duration: 60,
                   transcript: "**0:00 You:** \(long)", summary: "## Summary\n\nToplantı iyi geçti.")

        store.reload()
        let record = try XCTUnwrap(store.meetings.first)
        XCTAssertEqual(record.summarySnippet, "Toplantı iyi geçti.")
    }

    @MainActor
    func testWholeNoteIsReadOnlyWhenAsked() throws {
        let store = try makeStore()
        let record = try XCTUnwrap(store.save(
            id: MeetingStore.makeID(for: Date()), startedAt: Date(), duration: 60,
            transcript: "**0:00 You:** Merhaba", summary: "## Summary\n\nShort and useful."))

        let text = store.content(of: record)
        XCTAssertTrue(text.contains("Short and useful."))
        XCTAssertTrue(text.contains("**0:00 You:** Merhaba"))
    }
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --filter MeetingNotesTests 2>&1 | tail -20`
Expected: compile failure, `type 'MeetingStore' has no member 'parseHead'` (and the same for `missingSummaryText`, `content(of:)`, `summarySnippet`).

- [ ] **Step 3: Add the snippet field to the record**

In `Sources/NozomiFlowKit/Core/Meeting/MeetingStore.swift`, replace the `MeetingRecord` struct:

```swift
/// A recorded meeting on disk.
struct MeetingRecord: Identifiable, Equatable {
    let id: String
    let title: String
    let date: Date
    let duration: TimeInterval
    let url: URL
    /// First line of the summary, for the listing. Empty when the summary failed.
    var summarySnippet: String = ""

    var durationText: String { MeetingTranscript.timestamp(duration) }
}
```

- [ ] **Step 4: Add the header parser**

In the same file, add above `// MARK: - Writing`:

```swift
    /// What a note's opening lines can tell a listing without reading an hour of
    /// transcript into memory.
    struct NoteHead: Equatable {
        var duration: TimeInterval = 0
        var snippet: String = ""
    }

    /// Written into every note whose summary failed, and never shown as a preview.
    static let missingSummaryText = "Not generated for this meeting."

    /// Recovers the listing metadata from a note's opening lines.
    ///
    /// The metadata line is `_<localized long date> · 12:34_`. Only the duration is
    /// read: the date half is localized and cannot be parsed back in general, while
    /// the duration is the same in every locale.
    static func parseHead(_ text: String) -> NoteHead {
        var head = NoteHead()
        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            if line.hasPrefix("_") && line.hasSuffix("_") {
                if head.duration == 0, let seconds = duration(fromMetadataLine: line) {
                    head.duration = seconds
                }
                continue
            }
            if head.snippet.isEmpty {
                let body = line.hasPrefix("- ") ? String(line.dropFirst(2)) : line
                if body != missingSummaryText { head.snippet = String(body.prefix(200)) }
            }
            if head.duration > 0 && !head.snippet.isEmpty { break }
        }
        return head
    }

    /// `_Friday, July 31, 2026 at 14:05 · 12:34_` -> 754 seconds.
    private static func duration(fromMetadataLine line: String) -> TimeInterval? {
        let trimmed = line.trimmingCharacters(in: CharacterSet(charactersIn: "_"))
        guard let tail = trimmed.components(separatedBy: "·").last else { return nil }
        let parts = tail.trimmingCharacters(in: .whitespaces).components(separatedBy: ":")
        guard (2...3).contains(parts.count) else { return nil }
        var seconds = 0
        for part in parts {
            guard let value = Int(part), value >= 0 else { return nil }
            seconds = seconds * 60 + value
        }
        return TimeInterval(seconds)
    }

    /// Only the opening bytes: a listing needs the header, not the transcript.
    private static func readHead(_ url: URL, limit: Int = 1024) -> String {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return "" }
        defer { try? handle.close() }
        let data = (try? handle.read(upToCount: limit)) ?? Data()
        // A byte-count cut can land inside a multi-byte character. Decoding leniently
        // costs that one character; failing would cost the whole row.
        return String(decoding: data, as: UTF8.self)
    }
```

- [ ] **Step 5: Use the placeholder constant in `save` and parse in `reload`**

In `save(id:startedAt:duration:transcript:summary:)`, replace this line:

```swift
            body += "## Summary\n\nNot generated for this meeting.\n\n"
```

with:

```swift
            body += "## Summary\n\n\(Self.missingSummaryText)\n\n"
```

In `reload()`, replace the `compactMap` body:

```swift
            .compactMap { url in
                let date = Self.date(fromID: url.deletingPathExtension().lastPathComponent)
                    ?? (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
                    ?? Date()
                let head = Self.parseHead(Self.readHead(url))
                return MeetingRecord(
                    id: url.deletingPathExtension().lastPathComponent,
                    title: Self.title(for: date),
                    date: date,
                    duration: head.duration,
                    url: url,
                    summarySnippet: head.snippet
                )
            }
```

- [ ] **Step 6: Add the whole-note read**

In the same file, under `// MARK: - Reading`, above `func reload()`:

```swift
    /// The whole note, read only for the one being displayed. Returns an empty
    /// string if the file went away, which the reader shows as an empty state
    /// rather than a crash.
    func content(of record: MeetingRecord) -> String {
        (try? String(contentsOf: record.url, encoding: .utf8)) ?? ""
    }
```

- [ ] **Step 7: Run the tests to verify they pass**

Run: `swift test --filter MeetingNotesTests 2>&1 | tail -10`
Expected: PASS, no failures.

- [ ] **Step 8: Commit**

```bash
git add Sources/NozomiFlowKit/Core/Meeting/MeetingStore.swift Tests/NozomiFlowKitTests/MeetingNotesTests.swift
git commit -m "feat(meeting): recover duration and a preview line from each note"
```

---

## Task 2: Pure markdown renderer

**Files:**
- Create: `Sources/NozomiFlowKit/Core/Meeting/MeetingNoteRenderer.swift`
- Test: `Tests/NozomiFlowKitTests/MeetingNoteRendererTests.swift`

- [ ] **Step 1: Write the failing tests**

Create `Tests/NozomiFlowKitTests/MeetingNoteRendererTests.swift`:

```swift
import XCTest
@testable import NozomiFlowKit

/// The note is the only thing a meeting leaves behind, so the reader has to show
/// all of it. Every test here fails by silently dropping a piece.
final class MeetingNoteRendererTests: XCTestCase {

    func testHeadingsKeepTheirLevel() {
        XCTAssertEqual(
            MeetingNoteRenderer.blocks(from: "# Meeting on Jul 31"),
            [.heading(level: 1, text: "Meeting on Jul 31")])
        XCTAssertEqual(
            MeetingNoteRenderer.blocks(from: "## Summary"),
            [.heading(level: 2, text: "Summary")])
    }

    func testAHashWithoutASpaceIsProseNotAHeading() {
        XCTAssertEqual(
            MeetingNoteRenderer.blocks(from: "#1 priority is the migration"),
            [.paragraph("#1 priority is the migration")])
    }

    func testBulletsLoseTheirMarkerAndKeepTheirText() {
        XCTAssertEqual(
            MeetingNoteRenderer.blocks(from: "- Ship on Friday\n* Cut the export flow"),
            [.bullet("Ship on Friday"), .bullet("Cut the export flow")])
    }

    func testTheItalicHeaderLineIsItsOwnKindOfBlock() {
        XCTAssertEqual(
            MeetingNoteRenderer.blocks(from: "_Friday, July 31, 2026 at 14:05 · 42:13_"),
            [.meta("Friday, July 31, 2026 at 14:05 · 42:13")])
    }

    func testWrappedProseBecomesOneParagraphAndABlankLineStartsAnother() {
        // A model that hard-wraps its summary must not read as one paragraph per line.
        let blocks = MeetingNoteRenderer.blocks(from: """
            The team agreed to ship
            on Friday.

            Pricing was deferred.
            """)
        XCTAssertEqual(blocks, [
            .paragraph("The team agreed to ship on Friday."),
            .paragraph("Pricing was deferred."),
        ])
    }

    func testTranscriptLinesStayInOrderWithTheirSpeakerLabels() {
        let blocks = MeetingNoteRenderer.blocks(from: """
            ## Transcript

            **0:00 You:** Merhaba

            **0:12 Them:** Hello
            """)
        XCTAssertEqual(blocks, [
            .heading(level: 2, text: "Transcript"),
            .paragraph("**0:00 You:** Merhaba"),
            .paragraph("**0:12 Them:** Hello"),
        ])
    }

    func testEmptyInputRendersNothingRatherThanABlankBlock() {
        XCTAssertTrue(MeetingNoteRenderer.blocks(from: "").isEmpty)
        XCTAssertTrue(MeetingNoteRenderer.blocks(from: "\n\n   \n").isEmpty)
    }

    func testInlineMarkersAreResolvedRatherThanShown() {
        // The speaker label is written as **0:12 You:** and must read as bold text,
        // not as literal asterisks in the middle of the transcript.
        let attributed = MeetingNoteRenderer.inline("**0:12 You:** Hello")
        XCTAssertEqual(String(attributed.characters), "0:12 You: Hello")
    }

    func testUnparseableInlineMarkupFallsBackToTheRawText() {
        let attributed = MeetingNoteRenderer.inline("a [broken](markdown")
        XCTAssertEqual(String(attributed.characters), "a [broken](markdown")
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --filter MeetingNoteRendererTests 2>&1 | tail -20`
Expected: compile failure, `cannot find 'MeetingNoteRenderer' in scope`.

- [ ] **Step 3: Write the renderer**

Create `Sources/NozomiFlowKit/Core/Meeting/MeetingNoteRenderer.swift`:

```swift
import Foundation

/// One renderable piece of a meeting note.
enum MeetingNoteBlock: Equatable {
    case heading(level: Int, text: String)
    /// The italic date and duration line under the title.
    case meta(String)
    case bullet(String)
    case paragraph(String)
}

/// Turns a meeting note into blocks a view can lay out.
///
/// Purpose-built rather than handing the whole document to
/// `AttributedString(markdown:)`, which flattens headings into body text and makes
/// an hour of notes read as one wall. Only the constructs this app produces are
/// supported: the transcript is generated here, and the summarizer is instructed to
/// return headings, paragraphs and bullets. Anything else renders as a paragraph,
/// which shows the text rather than losing it.
enum MeetingNoteRenderer {

    static func blocks(from text: String) -> [MeetingNoteBlock] {
        var blocks: [MeetingNoteBlock] = []
        var paragraph: [String] = []

        func flush() {
            guard !paragraph.isEmpty else { return }
            blocks.append(.paragraph(paragraph.joined(separator: " ")))
            paragraph = []
        }

        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty {
                flush()
            } else if let heading = heading(from: line) {
                flush()
                blocks.append(heading)
            } else if line.hasPrefix("- ") || line.hasPrefix("* ") {
                flush()
                blocks.append(.bullet(String(line.dropFirst(2))))
            } else if line.count > 2, line.hasPrefix("_"), line.hasSuffix("_") {
                flush()
                blocks.append(.meta(String(line.dropFirst().dropLast())))
            } else {
                paragraph.append(line)
            }
        }
        flush()
        return blocks
    }

    /// Resolves `**bold**` and `*italic*` inside one block. Falls back to the raw
    /// text: markup that will not parse is worth showing verbatim, never dropping.
    static func inline(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text)) ?? AttributedString(text)
    }

    /// A run of hashes is only a heading when a space follows it, so "#1 priority"
    /// stays prose.
    private static func heading(from line: String) -> MeetingNoteBlock? {
        let hashes = line.prefix { $0 == "#" }.count
        guard (1...3).contains(hashes), line.dropFirst(hashes).hasPrefix(" ") else { return nil }
        return .heading(level: hashes, text: String(line.dropFirst(hashes + 1)))
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `swift test --filter MeetingNoteRendererTests 2>&1 | tail -10`
Expected: PASS, 9 tests.

- [ ] **Step 5: Commit**

```bash
git add Sources/NozomiFlowKit/Core/Meeting/MeetingNoteRenderer.swift Tests/NozomiFlowKitTests/MeetingNoteRendererTests.swift
git commit -m "feat(meeting): parse a note into renderable blocks"
```

---

## Task 3: The note reader view

**Files:**
- Create: `Sources/NozomiFlowKit/UI/Settings/MeetingNoteView.swift`

No unit test: this project has no UI tests, and the parsing this view depends on is already covered by Task 2. It is verified by building and by the manual pass in Task 10.

- [ ] **Step 1: Write the view**

Create `Sources/NozomiFlowKit/UI/Settings/MeetingNoteView.swift`:

```swift
import SwiftUI

/// Renders one meeting note.
///
/// Read-only on purpose: the markdown file is the document, and an editor here
/// would be a second source of truth for something the user can already open in
/// any editor. Text is selectable so a decision can be copied out of a paragraph
/// without exporting the whole note.
struct MeetingNoteView: View {
    let text: String

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 10) {
                ForEach(Array(MeetingNoteRenderer.blocks(from: text).enumerated()), id: \.offset) { _, block in
                    view(for: block)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .textSelection(.enabled)
            .padding(.horizontal, 20)
            .padding(.vertical, 16)
        }
    }

    @ViewBuilder
    private func view(for block: MeetingNoteBlock) -> some View {
        switch block {
        case .heading(let level, let text):
            Text(text)
                .font(level == 1 ? .title2.weight(.semibold) : .headline)
                .padding(.top, level == 1 ? 0 : 8)
        case .meta(let text):
            Text(text)
                .font(.callout)
                .italic()
                .foregroundStyle(.secondary)
        case .bullet(let text):
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("•").foregroundStyle(.secondary)
                Text(MeetingNoteRenderer.inline(text))
            }
        case .paragraph(let text):
            Text(MeetingNoteRenderer.inline(text))
        }
    }
}
```

- [ ] **Step 2: Verify it compiles**

Run: `swift build 2>&1 | tail -5`
Expected: `Build complete!` with no warnings about this file.

- [ ] **Step 3: Commit**

```bash
git add Sources/NozomiFlowKit/UI/Settings/MeetingNoteView.swift
git commit -m "feat(meeting): render a note as headings, bullets and prose"
```

---

## Task 4: Meetings tab becomes a browser

**Files:**
- Modify: `Sources/NozomiFlowKit/UI/Settings/MeetingsSettingsView.swift` (rewritten)

- [ ] **Step 1: Rewrite the view**

Replace the entire contents of `Sources/NozomiFlowKit/UI/Settings/MeetingsSettingsView.swift`:

```swift
import SwiftUI
import AppKit

/// Past meetings: a searchable list on the left, the selected note on the right.
///
/// The notes stay markdown files on disk and Open and Show in Finder are still
/// here, but reading one should not require leaving the app, and sending one to
/// someone should not require finding it in Finder first.
struct MeetingsSettingsView: View {
    @Bindable var store: MeetingStore

    @State private var selection: MeetingRecord.ID?
    @State private var query = ""
    @State private var noteText = ""
    @State private var pendingDeletion: MeetingRecord?

    /// Search covers the title and the summary preview, both already in memory.
    /// Searching transcript bodies means reading every note on each keystroke; if
    /// that is ever wanted it needs an index, not a wider loop.
    private var filtered: [MeetingRecord] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return store.meetings }
        return store.meetings.filter {
            $0.title.localizedCaseInsensitiveContains(trimmed)
                || $0.summarySnippet.localizedCaseInsensitiveContains(trimmed)
        }
    }

    /// Falls back to the first row, which covers both the initial appearance and a
    /// search that no longer contains the previous selection.
    private var selected: MeetingRecord? {
        filtered.first { $0.id == selection } ?? filtered.first
    }

    var body: some View {
        Group {
            if store.meetings.isEmpty {
                emptyState
            } else {
                HStack(spacing: 0) {
                    listColumn.frame(width: 200)
                    Divider()
                    reader
                }
            }
        }
        .onAppear {
            store.reload()
            loadNote()
        }
        .onChange(of: selected?.id) { _, _ in loadNote() }
        .confirmationDialog(
            "Delete these notes?",
            isPresented: .init(get: { pendingDeletion != nil }, set: { if !$0 { pendingDeletion = nil } }),
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                if let pendingDeletion { delete(pendingDeletion) }
                pendingDeletion = nil
            }
            Button("Cancel", role: .cancel) { pendingDeletion = nil }
        } message: {
            Text("The markdown file is removed from disk. This can't be undone.")
        }
    }

    // MARK: - List

    private var listColumn: some View {
        VStack(spacing: 0) {
            searchField
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
            Divider()
            if filtered.isEmpty {
                noResultsState
            } else {
                List(filtered, selection: $selection) { meeting in
                    row(meeting)
                        .contextMenu { menu(for: meeting) }
                        .swipeActions {
                            Button("Delete", role: .destructive) { pendingDeletion = meeting }
                        }
                }
                .listStyle(.inset)
            }
        }
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Search meetings", text: $query)
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
    }

    private func row(_ meeting: MeetingRecord) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(rowTitle(meeting))
                .font(.callout.weight(.medium))
            Text(rowSubtitle(meeting))
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
        .padding(.vertical, 3)
    }

    /// A meeting is identified by when it happened, so the time stays even once the
    /// day becomes a word.
    private func rowTitle(_ meeting: MeetingRecord) -> String {
        let time = meeting.date.formatted(date: .omitted, time: .shortened)
        if Calendar.current.isDateInToday(meeting.date) { return "Today \(time)" }
        if Calendar.current.isDateInYesterday(meeting.date) { return "Yesterday \(time)" }
        return meeting.date.formatted(.dateTime.day().month(.abbreviated)) + " " + time
    }

    private func rowSubtitle(_ meeting: MeetingRecord) -> String {
        [
            meeting.duration > 0 ? meeting.durationText : nil,
            meeting.summarySnippet.isEmpty ? nil : meeting.summarySnippet,
        ]
        .compactMap { $0 }
        .joined(separator: " · ")
    }

    @ViewBuilder
    private func menu(for meeting: MeetingRecord) -> some View {
        Button("Open") { NSWorkspace.shared.open(meeting.url) }
        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([meeting.url]) }
        Button("Copy as Markdown") { copyMarkdown(meeting) }
        ShareLink("Share", item: meeting.url)
        Divider()
        Button("Delete", role: .destructive) { pendingDeletion = meeting }
    }

    // MARK: - Reader

    @ViewBuilder
    private var reader: some View {
        if let selected {
            VStack(spacing: 0) {
                actionsRow(for: selected)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                Divider()
                MeetingNoteView(text: noteText)
            }
        } else {
            noResultsState
        }
    }

    private func actionsRow(for meeting: MeetingRecord) -> some View {
        HStack(spacing: 8) {
            Spacer()
            ShareLink(item: meeting.url) {
                Image(systemName: "square.and.arrow.up")
            }
            .help("Share these notes")

            Button {
                copyMarkdown(meeting)
            } label: {
                Image(systemName: "doc.on.doc")
            }
            .help("Copy as Markdown")

            Button {
                NSWorkspace.shared.open(meeting.url)
            } label: {
                Image(systemName: "arrow.up.forward.app")
            }
            .help("Open in your markdown editor")

            Button(role: .destructive) {
                pendingDeletion = meeting
            } label: {
                Image(systemName: "trash")
            }
            .help("Delete these notes")
        }
    }

    // MARK: - Actions

    private func loadNote() {
        noteText = selected.map { store.content(of: $0) } ?? ""
    }

    private func copyMarkdown(_ meeting: MeetingRecord) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(store.content(of: meeting), forType: .string)
    }

    /// Selection moves to whatever took the deleted row's place, or to the new last
    /// row when the deleted one was at the end. Leaving a dangling selection would
    /// blank the reader while a list is still on screen.
    private func delete(_ record: MeetingRecord) {
        let index = filtered.firstIndex { $0.id == record.id }
        store.delete(record)
        let remaining = filtered
        if let index, !remaining.isEmpty {
            selection = remaining.indices.contains(index) ? remaining[index].id : remaining.last?.id
        } else {
            selection = remaining.first?.id
        }
        loadNote()
    }

    // MARK: - Empty states

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "person.2.wave.2")
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(.tertiary)
            Text("No meetings yet")
                .font(.title3.weight(.semibold))
            Text("Start one from the menu bar. Both sides of the call are recorded, transcribed and summarized into a markdown file.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 340)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var noResultsState: some View {
        VStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 24))
                .foregroundStyle(.secondary)
            Text("No matches for \"\(query)\"")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }
}
```

- [ ] **Step 2: Verify it compiles**

Run: `swift build 2>&1 | tail -5`
Expected: `Build complete!`

- [ ] **Step 3: Run the full suite to check nothing regressed**

Run: `swift test 2>&1 | tail -5`
Expected: `Executed 1XX tests, with 3 tests skipped and 0 failures`.

- [ ] **Step 4: Commit**

```bash
git add Sources/NozomiFlowKit/UI/Settings/MeetingsSettingsView.swift
git commit -m "feat(meeting): read, search, share and delete notes in the app"
```

---

## Task 5: Give the reader room

**Files:**
- Modify: `Sources/NozomiFlowKit/UI/Settings/SettingsWindowController.swift:57,64`

With a 200pt sidebar and a 200pt meeting list, a 760pt window leaves about 360pt for the note. 860pt leaves roughly 460pt, which is 65 to 70 characters per line at the system body size.

- [ ] **Step 1: Widen the window**

In `Sources/NozomiFlowKit/UI/Settings/SettingsWindowController.swift`, replace:

```swift
                contentRect: NSRect(x: 0, y: 0, width: 760, height: 540),
```

with:

```swift
                contentRect: NSRect(x: 0, y: 0, width: 860, height: 580),
```

and replace:

```swift
            w.minSize = NSSize(width: 680, height: 480)
```

with:

```swift
            // The meetings tab spends 200pt on the sidebar and 200pt on the list, so
            // anything narrower than this leaves a note column too tight to read.
            w.minSize = NSSize(width: 760, height: 520)
```

- [ ] **Step 2: Verify it compiles**

Run: `swift build 2>&1 | tail -5`
Expected: `Build complete!`

- [ ] **Step 3: Commit**

```bash
git add Sources/NozomiFlowKit/UI/Settings/SettingsWindowController.swift
git commit -m "feat(settings): widen the window so a meeting note is readable"
```

---

## Task 6: Menu bar shows a running meeting

**Files:**
- Modify: `Sources/NozomiFlowKit/UI/StatusItem/StatusItemController.swift`
- Modify: `Sources/NozomiFlowKit/App/NozomiFlowMain.swift:119-128`

- [ ] **Step 1: Add the openMeetings dependency**

In `StatusItemController`, add a stored property after `openHistory`:

```swift
    private let openMeetings: () -> Void
```

Add the parameter to `init`, after `openHistory`:

```swift
        openMeetings: @escaping () -> Void,
```

and assign it in the body, after `self.openHistory = openHistory`:

```swift
        self.openMeetings = openMeetings
```

- [ ] **Step 2: Add the menu item and its action**

In `buildMenu()`, after the `history` item is added to the menu:

```swift
        let meetings = NSMenuItem(title: "Meetings…", action: #selector(showMeetings), keyEquivalent: "")
        meetings.target = self
        menu.addItem(meetings)
```

And with the other `@objc` actions, next to `showHistory`:

```swift
    @objc private func showMeetings() { openMeetings() }
```

- [ ] **Step 3: Show elapsed time on the stop item**

In `menuNeedsUpdate(_:)`, replace the `.recording` case of the meeting switch:

```swift
            case .recording:
                meetingItem.title = "Stop Recording"
                meetingItem.isEnabled = true
```

with:

```swift
            // Computed as the menu opens. It does not tick while the menu is up: a
            // timer to animate a number nobody is looking at is not worth the wakeups,
            // and a number that is a few seconds old still answers "how long has this
            // been running".
            case .recording(let startedAt):
                let elapsed = MeetingTranscript.timestamp(Date().timeIntervalSince(startedAt))
                meetingItem.title = "Stop Recording (\(elapsed))"
                meetingItem.isEnabled = true
```

- [ ] **Step 4: Tint the status icon while a meeting records**

In `render()`, replace:

```swift
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: "Nozomi Flow")
```

with:

```swift
        // A meeting outlasts every dictation phase but must not hide one: a dictation
        // lasts seconds and its feedback is needed in that moment, whereas a meeting
        // runs for an hour and only needs to say it is still running.
        if case .idle = appState.phase, meetingPhase().isRecording {
            symbol = "person.2.wave.2"
            tint = .systemRed
        }
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: "Nozomi Flow")
```

and change the declaration of `symbol` in the same function from `let symbol: String` to:

```swift
        var symbol: String
```

- [ ] **Step 5: Wire it up**

In `Sources/NozomiFlowKit/App/NozomiFlowMain.swift`, in the `StatusItemController(...)` call, after the `openHistory` line:

```swift
            openMeetings: { [weak self] in self?.settingsWindow.show(tab: .meetings) },
```

- [ ] **Step 6: Verify it compiles and the suite is green**

Run: `swift build 2>&1 | tail -5 && swift test 2>&1 | tail -5`
Expected: `Build complete!` then `0 failures`.

- [ ] **Step 7: Commit**

```bash
git add Sources/NozomiFlowKit/UI/StatusItem/StatusItemController.swift Sources/NozomiFlowKit/App/NozomiFlowMain.swift
git commit -m "feat(meeting): show a running meeting in the menu bar"
```

---

## Task 7: Notify instead of interrupting when notes are ready

**Files:**
- Modify: `Sources/NozomiFlowKit/UI/MeetingAlert.swift`
- Modify: `Sources/NozomiFlowKit/App/NozomiFlowMain.swift`

Notes land minutes after the user stopped recording, by which time they are doing something else. Failure keeps its modal alert, because a failure asks for a decision and must not be missed.

`UNUserNotificationCenter.current()` raises if the process has no bundle identifier, which is the case under `swift test` and `swift run`. Nothing here is unit tested and nothing calls it outside the app; verify with `scripts/bundle.sh`.

- [ ] **Step 1: Add the notifier**

At the top of `Sources/NozomiFlowKit/UI/MeetingAlert.swift`, add to the imports:

```swift
import UserNotifications
```

Then append to the same file, after the `MeetingAlert` enum's closing brace:

```swift
/// Tells the user their notes are ready without taking the screen away from them.
///
/// The work finishes minutes after they stopped recording, so a modal alert lands
/// in the middle of something else. Failures stay modal: those ask for a decision.
@available(macOS 15.0, *)
@MainActor
enum MeetingNotifier {
    /// Carries the note's path through the notification and back on the tap.
    static let notePathKey = "notePath"

    /// Authorization is requested here, the first time a meeting finishes, rather
    /// than at launch: an app that asks before it has anything to say gets refused.
    /// Anything that goes wrong falls back to the alert, so the notes are never
    /// finished silently.
    static func presentNotes(_ record: MeetingRecord) {
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound]) { granted, error in
            if let error {
                Log.app.error("notification authorization failed: \(error.localizedDescription)")
            }
            guard granted else {
                Task { @MainActor in MeetingAlert.presentNotes(record) }
                return
            }

            let content = UNMutableNotificationContent()
            content.title = "Meeting notes are ready"
            content.body = record.title
            content.sound = .default
            content.userInfo = [notePathKey: record.url.path]

            let request = UNNotificationRequest(
                identifier: record.id, content: content, trigger: nil)
            center.add(request) { error in
                guard let error else { return }
                Log.app.error("could not post notification: \(error.localizedDescription)")
                Task { @MainActor in MeetingAlert.presentNotes(record) }
            }
        }
    }
}
```

- [ ] **Step 2: Handle the tap and post through the notifier**

In `Sources/NozomiFlowKit/App/NozomiFlowMain.swift`, add to the imports:

```swift
import UserNotifications
```

Change the class declaration:

```swift
final class AppDelegate: NSObject, NSApplicationDelegate {
```

to:

```swift
final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
```

Replace this line in `applicationDidFinishLaunching`:

```swift
        meetings.onNotesReady = { MeetingAlert.presentNotes($0) }
```

with:

```swift
        meetings.onNotesReady = { MeetingNotifier.presentNotes($0) }
        UNUserNotificationCenter.current().delegate = self
```

Then add these methods to `AppDelegate`, after `applicationWillTerminate`:

```swift
    /// An accessory app is rarely frontmost, but the settings window can be key when
    /// a meeting finishes, and the banner has to show then too.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }

    /// The path is read out here, on whatever queue the callback arrives on, so only
    /// a String crosses to the main actor.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let path = response.notification.request.content.userInfo[MeetingNotifier.notePathKey] as? String
        Task { @MainActor in
            guard let path else { return }
            NSWorkspace.shared.open(URL(fileURLWithPath: path))
        }
        completionHandler()
    }
```

- [ ] **Step 3: Verify it compiles and the suite is green**

Run: `swift build 2>&1 | tail -5 && swift test 2>&1 | tail -5`
Expected: `Build complete!` then `0 failures`.

- [ ] **Step 4: Commit**

```bash
git add Sources/NozomiFlowKit/UI/MeetingAlert.swift Sources/NozomiFlowKit/App/NozomiFlowMain.swift
git commit -m "feat(meeting): notify when notes are ready instead of interrupting"
```

---

## Task 8: Expose the meeting summary model

**Files:**
- Modify: `Sources/NozomiFlowKit/UI/Settings/GeneralSettingsView.swift:47-68`

`meetingSummaryModel` is editable nowhere in the UI today. It belongs with the other cloud settings, not in the meetings tab, which is now a browser.

- [ ] **Step 1: Add the field and mention meetings in the footer**

In `Sources/NozomiFlowKit/UI/Settings/GeneralSettingsView.swift`, replace this block:

```swift
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
```

with:

```swift
            Section {
                Toggle("Cloud transcription", isOn: $settings.cloudTranscriptionEnabled)
                if settings.cloudTranscriptionEnabled {
                    SecureField("API key", text: $settings.cloudTranscriptionKey)
                    TextField("Model", text: $settings.cloudTranscriptionModel)
                    TextField("Meeting notes model", text: $settings.meetingSummaryModel)
                }
            } header: {
                Text("Transcription")
            } footer: {
                if settings.cloudTranscriptionEnabled {
                    Text("""
                        Recorded audio is uploaded when you release the key. \
                        Much more accurate on Turkish mixed with English terms, \
                        but there is no live transcript while you speak, and Nozomi Flow \
                        falls back to the on-device engine if the request fails. \
                        Meetings always use this endpoint: they are not transcribed on-device.
                        """)
                } else {
                    Text("Everything stays on this Mac. Meetings need this turned on.")
                }
            }
```

- [ ] **Step 2: Verify it compiles**

Run: `swift build 2>&1 | tail -5`
Expected: `Build complete!`

- [ ] **Step 3: Commit**

```bash
git add Sources/NozomiFlowKit/UI/Settings/GeneralSettingsView.swift
git commit -m "feat(settings): make the meeting notes model editable"
```

---

## Task 9: Em dash sweep in user-visible strings

**Files:**
- Modify: `Sources/NozomiFlowKit/UI/Settings/GeneralSettingsView.swift:87`
- Modify: `Sources/NozomiFlowKit/UI/StatusItem/StatusItemController.swift:145`
- Modify: `Sources/NozomiFlowKit/UI/Settings/StyleSettingsView.swift:96,98`
- Modify: `Sources/NozomiFlowKit/UI/Settings/DictionarySettingsView.swift:102`
- Modify: `Sources/NozomiFlowKit/UI/Settings/HistorySettingsView.swift:102,189`
- Modify: `Sources/NozomiFlowKit/UI/Onboarding/OnboardingAccessibilityStep.swift:25,33`
- Modify: `Sources/NozomiFlowKit/UI/Onboarding/OnboardingMicrophoneStep.swift:22`
- Modify: `Sources/NozomiFlowKit/App/DictationCoordinator.swift:263`

The spec listed four occurrences; there are eleven user-visible ones. Deliberately left alone: six prompt strings in `Core/Formatting/FormatterPipeline.swift`, because editing a model's instructions changes its output and that is a separate decision, and five source comments, which are a mechanical follow-up.

- [ ] **Step 1: Replace each string**

`GeneralSettingsView.swift:87`

```swift
        Label("Both actions share a key: dictation wins", systemImage: "exclamationmark.triangle.fill")
```

`StatusItemController.swift:145`

```swift
        menu.item(withTag: MenuTag.engineHeader.rawValue)?.title = "Nozomi Flow: \(appState.currentEngine.displayName)"
```

`StyleSettingsView.swift:96,98`

```swift
        case .off: return "Verbatim transcript. Nothing is changed after transcription."
```

```swift
        case .full: return "AI cleanup: self-corrections, lists, and tone."
```

`DictionarySettingsView.swift:102`

```swift
                Text("Names, brands, jargon: add the words Nozomi Flow should always get right.")
```

`HistorySettingsView.swift:102,189`

```swift
            Text("History is off. New dictations aren't being saved.")
```

```swift
            Text("Nothing yet. Hold your dictation key and just talk.")
```

`OnboardingAccessibilityStep.swift:25,33`

```swift
                    Text("It's a standard macOS permission. Nozomi Flow only ever types what you dictate.")
```

```swift
                    Label("We're watching for it automatically, no need to come back.", systemImage: "arrow.triangle.2.circlepath")
```

`OnboardingMicrophoneStep.swift:22`

```swift
                    Text("No always-on recording, no cloud upload: audio stays on this Mac.")
```

`DictationCoordinator.swift:263`

```swift
            return .modelUnavailable("preparing, try again shortly")
```

- [ ] **Step 2: Verify none are left in user-visible strings**

Run: `grep -rn '"[^"]*—[^"]*"' Sources/ | grep -v FormatterPipeline`
Expected: no output.

- [ ] **Step 3: Verify it compiles and the suite is green**

Run: `swift build 2>&1 | tail -5 && swift test 2>&1 | tail -5`
Expected: `Build complete!` then `0 failures`.

- [ ] **Step 4: Commit**

```bash
git add Sources/NozomiFlowKit
git commit -m "style(ui): drop em dashes from user-visible strings"
```

---

## Task 10: Manual verification on a real build

**Files:** none

Everything above is unit tested or compiled, but nothing has proved the feature works on screen. This task ships nothing; it either passes or produces bugs to fix before the branch is done.

- [ ] **Step 1: Build and launch the real app**

Run: `scripts/bundle.sh release --open`
Expected: `build/Nozomi Flow.app` launches. The bundle matters: notifications need a bundle identifier and will not work under `swift run`.

- [ ] **Step 2: Check the browser against existing notes**

Open Settings from the menu bar, then the Meetings tab. Confirm:
- The most recent meeting is selected and its note renders with headings, bullets and bold speaker labels.
- Rows show a duration and a preview line, not a filename.
- Typing in the search field narrows the list.
- Selecting text in the note works.

- [ ] **Step 3: Check the actions**

- Share opens the system share sheet with the markdown file attached.
- Copy as Markdown pastes the full note into any text field.
- Delete asks first, removes the file, and selects a neighbouring meeting.

- [ ] **Step 4: Check a live meeting**

Start a meeting from the menu bar with any audio playing. Confirm:
- The status icon turns red for the duration.
- The menu reads `Stop Recording (m:ss)` with a plausible elapsed time.
- Stopping it leads to a notification, and clicking the notification opens the note.

- [ ] **Step 5: Record what failed**

If any step failed, fix it and re-run the affected task's tests before continuing. If everything passed, the branch is ready for review.

---

## Notes for whoever executes this

- Run `swift test` (not just `--filter`) before the final commit: 133 tests pass today and none of them should start failing.
- Two deliberate departures from the spec, both in Task 4:
  - The spec put search, share and delete together in one control row above the
    split. The plan puts search at the top of the list column and the actions above
    the note, so each control sits next to what it acts on. A share button floating
    over a list of ten meetings does not say which one it will send.
  - `MeetingRecord.durationText` renders `42:13`, not the spec's `42 min`. The
    existing formatter is reused rather than adding a second one.
- Tasks 1 through 4 are the feature and depend on each other in order. Tasks 5 through 9 are independent of each other and of 1 through 4, so they can be reordered or split out if review gets long.
