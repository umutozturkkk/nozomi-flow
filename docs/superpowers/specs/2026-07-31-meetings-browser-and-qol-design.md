# Meetings browser and quality-of-life pass

Date: 2026-07-31
Status: approved, not yet implemented

## Problem

Meetings record, transcribe and summarize correctly, but the app gives almost
nothing back. Notes can only be read by launching an external markdown app,
there is no way to send one to anyone, and the menu bar looks idle through an
hour-long recording. The feature works; it does not yet feel like part of the
app.

A Meetings tab already exists in Settings with a list, an Open button, Show in
Finder, and a confirmed Delete. Deletion is therefore not missing, only hard to
find. What is missing is reading a note in the app and sharing it.

## Scope

One combined change covering the meetings browser plus four quality-of-life
items agreed alongside it: menu bar state, list parity with History, a gentler
completion signal, and settings and copy cleanup.

Out of scope: an in-app markdown editor, meeting playback (chunk audio is
deleted after transcription by design), tags or folders, and any change to how
meetings are captured or transcribed.

## Design

### 1. Meetings tab becomes a browser

The tab splits into a fixed 200pt list on the left and the selected note on the
right, with a control row above holding a search field, a share button and a
delete button. The search field matches the one in History.

The settings window grows from 760x540 to 860x580, and its minimum from 680x480
to 760x520. With a 200pt sidebar and a 200pt list, that leaves roughly 460pt for
the note, which is 65 to 70 characters per line at the system body size. A
larger window gives the note more room; the list stays fixed.

Each row shows the meeting time on the first line (relative for recent ones,
"Today 14:05") and `42 min · <first sentence of the summary>` on the second. The
current filename subtitle is dropped: it repeats the title and says nothing.
The most recent meeting is selected when the tab appears.

Search matches the row's title and summary snippet, both already in memory. It
deliberately does not search transcript bodies: that means reading every note in
full on each keystroke, and the summary is where the searchable substance of a
meeting is. If searching what was actually said turns out to matter, it needs an
index, not a wider loop.

Deleting the selected note keeps the existing confirmation dialog and then
selects the next meeting in the list, or the previous one if the deleted note was
last. An empty list shows the empty state and no reader.

Rationale for keeping this inside Settings rather than opening a dedicated
window: a second window controller is real plumbing, and the reading width at
860pt is adequate. If notes later need side-by-side comparison or a persistent
window position, promoting the browser to its own window is a contained follow-up
because the list and reader views are already separate from the tab shell.

### 2. MeetingStore reads its own files

`reload()` currently lists the directory without opening anything, which is why
every record carries `duration: 0` and no preview text.

- `MeetingRecord` gains a real `duration` and a `summarySnippet`.
- `reload()` reads the first 1 KB of each note. Duration comes from the metadata
  line the store itself writes, `_<long date> · 42:13_`, by taking the last
  `·`-separated component and parsing `mm:ss` or `h:mm:ss`. This is locale
  independent and works on notes already on disk. An unparseable line yields 0,
  which is today's behavior, so there is no regression.
- The snippet is the first paragraph that is neither a heading nor the italic
  metadata line. The placeholder "Not generated for this meeting." is not used as
  a snippet; those records show none.
- A new `content(of:)` reads a whole note, called only for the selected record.

Reading every file head is a few milliseconds for dozens of meetings. If a user
ever accumulates hundreds, the fix is a separate index file, which is not worth
building now.

### 3. Markdown reader

A new `MeetingNoteRenderer` is a pure function from the note's text to a list of
blocks: heading with level, paragraph, bullet, and the italic metadata line.
Inline `**bold**` and `*italic*` are resolved per block with
`AttributedString(markdown:)`. Being pure keeps it testable without a window,
audio or permissions.

A SwiftUI `MeetingNoteView` renders the blocks inside a `ScrollView` and a
`LazyVStack`, since an hour-long meeting produces hundreds of transcript lines.
Transcript lines are already written as `**0:12 You:** ...`, so the speaker label
renders bold without special handling.

Rejected alternatives: passing the whole document to
`Text(AttributedString(markdown:))` flattens headings into body text and the
note reads as one wall; a `WebView` pulls in WebKit and a stylesheet to render
markdown this app generates itself.

### 4. Share and copy

- A `ShareLink(item: record.url)` in the control row. It hands the markdown file
  to the system share sheet, so Mail attaches it, AirDrop sends it and Notes
  imports it. `ShareLink` rather than `NSSharingServicePicker` because SwiftUI
  handles the anchoring.
- "Copy as Markdown" puts the note's text on the pasteboard, for pasting into
  Slack or a ticket.
- The row context menu holds Open, Show in Finder, Copy as Markdown, Share and
  Delete.
- Delete also becomes a swipe action, matching History.

### 5. Menu bar reflects the meeting

- `render()` takes the meeting phase into account. While a meeting records, the
  status icon is a red `person.2.wave.2`. A dictation in flight wins over it,
  because dictation lasts seconds and its feedback is needed at that moment,
  whereas a meeting lasts an hour. `MeetingSessionController` is already
  `@Observable` and the controller already holds a `meetingPhase` closure, so
  the existing `withObservationTracking` picks the change up with no new wiring.
- While recording, the menu item reads `Stop Recording (12:34)`. The elapsed time
  is computed in `menuNeedsUpdate`, when the menu opens. It does not tick while
  the menu is open. A timer to animate a number nobody is watching is not worth
  the wakeups, and a stale-but-honest number beats none.
- A `Meetings…` item joins `History…` and opens the settings window on the
  meetings tab through the existing `show(tab:)` path.

### 6. Notification when notes are ready

The success path moves from a modal `NSAlert` to a user notification whose
default action opens the note. Notes land minutes after the user stopped
recording, by which time they are doing something else; stealing focus then is
the wrong shape of feedback.

Failure keeps the modal alert. A failure asks for a decision (open Settings,
grant permission) and must not be missed.

This adds a fourth permission alongside microphone, accessibility and screen
recording. Authorization is requested lazily, the first time a meeting finishes,
so onboarding is untouched. If authorization is denied or unavailable, the code
falls back to today's modal alert, which also covers ad-hoc signed builds where
notification delivery is unreliable.

### 7. Settings and copy cleanup

- `meetingSummaryModel` becomes editable in General, directly under the cloud
  transcription model. It is a cloud setting and belongs with the others; the
  meetings tab is now a browser, not a settings surface.
- The Transcription section's footer says that meetings depend on this setting.
- Em dashes are removed from UI strings, per the project's writing rule. Known
  occurrences: the History disabled banner, the History empty state, the status
  menu's engine header, and the hotkey collision warning. `summarised` in the
  meetings empty state becomes `summarized`.

## Testing

Pure layers only, matching the existing suite, which has no UI tests.

- `MeetingStore`: duration parsed from `mm:ss` and `h:mm:ss` metadata lines; a
  malformed line yields 0; the snippet skips headings and the metadata line; the
  "not generated" placeholder produces no snippet; delete removes the file and
  the record.
- `MeetingNoteRenderer`: headings by level, bullets, inline bold, a transcript
  speaker line, the italic metadata line, and an empty file.

Manual check before shipping: record a short meeting, confirm the menu bar turns
red for its duration, the menu shows elapsed time, the notification arrives and
opens the note, the note renders with headings, and share and delete both work.

## Files

Changed:

- `Sources/NozomiFlowKit/Core/Meeting/MeetingStore.swift`
- `Sources/NozomiFlowKit/UI/Settings/MeetingsSettingsView.swift` (rewritten)
- `Sources/NozomiFlowKit/UI/Settings/SettingsWindowController.swift`
- `Sources/NozomiFlowKit/UI/Settings/GeneralSettingsView.swift`
- `Sources/NozomiFlowKit/UI/Settings/HistorySettingsView.swift` (copy only)
- `Sources/NozomiFlowKit/UI/StatusItem/StatusItemController.swift`
- `Sources/NozomiFlowKit/UI/MeetingAlert.swift`
- `Sources/NozomiFlowKit/App/NozomiFlowMain.swift`
- `Tests/NozomiFlowKitTests/MeetingNotesTests.swift`

Added:

- `Sources/NozomiFlowKit/Core/Meeting/MeetingNoteRenderer.swift`
- `Sources/NozomiFlowKit/UI/Settings/MeetingNoteView.swift`
- `Tests/NozomiFlowKitTests/MeetingNoteRendererTests.swift`
