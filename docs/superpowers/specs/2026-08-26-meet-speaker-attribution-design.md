# Speaker attribution for Google Meet

Date: 2026-08-26
Status: implemented, pending verification on a live call

## Problem

Meeting notes cannot say who said what, and the summarizer invents speakers.

Two independent causes, both in the recording path rather than the prompt.

**Turns are two minutes wide.** `MeetingChunker` closes a chunk at 120 seconds of
accumulated audio, and each track closes on its own schedule. `MeetingTranscript.merge`
then orders chunks by start offset and coalesces consecutive same-speaker chunks.
A forty minute call therefore renders as a sequence of two minute monologues with
the real back and forth erased: if the user speaks for thirty seconds and the other
side answers, both halves sit inside their own track's chunk and the exchange never
appears. The model receives two parallel monologues, not a conversation.

**Every remote participant shares one label.** `MeetingTrack.speakerLabel` returns
`"Them"` for the whole system track. `MeetingSummarizer.instructions` tells the model
that "Them" may be several people and leaves it there. Given an unidentified speaker
and names occurring inside the speech, the model resolves the gap by harvesting those
names: a transcript containing "we should ask Ahmet" produces notes in which Ahmet
spoke and owns an action item. This is not a prompt defect that stronger wording
fixes. It is what an unidentified label invites.

## Insight

The app already holds Screen Recording permission and already runs an `SCStream`
for the whole session. `MeetingAudioCapture` requests a 2x2 pixel video feed purely
because `SCStream` refuses to start without somewhere to send frames, and discards
every frame it receives. Reading the screen therefore costs no new permission, no
new user consent, and no new provider.

Google Meet renders two things worth reading:

- **Captions**, which are already labelled with the speaker's name. Google has
  already solved diarization and is displaying the answer.
- **The participant panel**, which is the authoritative roster for the call.

Neither requires detecting a highlighted tile border, which is the fragile approach:
tile geometry changes with grid view, speaker view, screen sharing and window size,
and the highlight colour changes with theme. Caption text sits in a fixed region,
is high contrast, and is prefixed with the speaker's name.

## Scope

Google Meet only, in a Chromium browser or Safari. Zoom and Teams are out of scope:
they are native applications with no caption region to read, and covering them means
a different source implementation behind the same protocol, as a later phase.

Also out of scope: replacing cloud transcription with the caption text (Meet's
captions are lower quality than the transcription endpoint and are used only for
attribution), meeting playback, and Google Workspace's server side transcripts,
which are rejected below.

## Design

### Degradation ladder

The design has three levels and each is independently valuable. This matters because
the strongest signal depends on an unverified assumption about what Chrome exposes
through the accessibility tree, and because users can turn captions off.

1. **Captions readable.** Turns carry real names, and chunk boundaries follow speaker
   changes. Full fix for both problems.
2. **Only the roster readable.** Turns stay `You` and `Them`, but the summarizer
   receives the real participant list and is told these are the only speakers. Fixes
   the invented-speaker problem alone.
3. **Nothing readable.** Today's behaviour exactly, with no new failure mode.

Level 3 is the tested default, not an afterthought. A user with no Meet window, an
unsupported browser, captions disabled, or a denied accessibility prompt must get a
meeting identical to the one they get today.

### Component boundary

The unverified assumption is isolated behind one protocol, so its resolution decides
which implementation ships first and nothing else.

```swift
/// One caption line as Meet rendered it: who Google says is speaking, and the words
/// it attributed to them.
struct CaptionObservation: Equatable {
    let speaker: String
    let text: String
    let observedAt: Date
}

/// Watches a meeting window and reports who is speaking.
protocol MeetingSpeakerSource: AnyObject {
    /// Fired for each newly observed caption line.
    var onCaption: ((CaptionObservation) -> Void)? { get set }
    /// Fired when the participant roster changes.
    var onRoster: (([String]) -> Void)? { get set }

    func start() async throws
    func stop()
}
```

Two implementations are designed. Only the first is built in this phase:

- `MeetAccessibilitySpeakerSource` reads the browser's accessibility tree. No pixels,
  no OCR, no video stream, low CPU. Built now.
- `MeetCaptionOCRSpeakerSource` opens a second low frame rate `SCStream` filtered to
  the Meet window, crops the caption strip and runs `VNRecognizeTextRequest`. Specified
  in a section below, built only if the accessibility path proves empty.

Everything downstream of the protocol is source agnostic: parser, timeline, chunk
cutting, transcript labelling and the summarizer prompt are written once and work
with either source.

### 1. `MeetCaptionParser` (pure)

Turns raw caption region text into observations. Pure and synchronous, so the rules
are testable without a browser, a call, or permissions, which is the only practical
way to test them at all.

Meet's caption region is a rolling buffer of a few lines. Two consecutive reads a
second apart mostly overlap, and the newest line grows word by word:

```
read at t+0:  Ahmet: bugün toplantıda
read at t+1:  Ahmet: bugün toplantıda konuşacağımız
```

The parser therefore reconciles rather than accumulates. Rules:

- A line splits on the first colon. Everything before it is the speaker, provided it
  is short (at most 60 characters), contains no sentence-ending punctuation, and is
  not empty. This rejects speech that merely contains a colon.
- A line whose speaker matches the previous observation and whose text extends the
  previous text by prefix is treated as growth: the parser emits only the new tail.
- A line identical to the previous observation emits nothing.
- A line whose speaker differs from the previous observation opens a new observation.
- Lines shorter than three characters after the speaker are ignored as noise.
- A name is at most four words, and every word after the first is capitalized or a
  known lower case particle (van, de, bin). This rule was added during
  implementation, after a test showed that length and punctuation alone let
  "Sonuç şu: pazartesi çıkıyoruz" through as a speaker called "Sonuç şu". Its cost
  is that an all lower case display name is not recognized, and that person's turns
  fall back to the track label. A missing name is a far better failure than an
  invented one, which is the whole point of the feature.
- Speaker names are trimmed and compared case and diacritic insensitively, so
  `Ahmet` and `AHMET` are one person, but the first spelling seen is the one kept
  for display.

The parser holds only the last observation per speaker, so memory is bounded no
matter how long the meeting runs.

### 2. `SpeakerTimeline` (pure)

Accumulates observations and answers who was speaking. Also pure.

- `record(_ observation: CaptionObservation)` appends to the timeline.
- `current` returns the most recent speaker, or nil once
  `staleAfter` seconds (default 6) have passed with no observation, so a silent
  stretch does not keep attributing audio to whoever last spoke.
- `roster` is the union of every speaker seen, plus any names supplied by
  `onRoster`. The union matters: the participant panel lists people who never speak,
  and captions surface people who joined late.
- Debouncing: a speaker change is only reported after
  `minimumHoldSeconds` (default 1.5) of consecutive observations naming the same new
  speaker. Meet's caption engine briefly misattributes on crosstalk and a single
  stray line must not slice a chunk.

### 3. Chunk boundaries follow the speaker

This is what fixes the two minute blob, and it is the reason the design touches the
recorder at all.

`MeetingRecorder` gains `speakerChanged(to:)`, called from the session controller
when `SpeakerTimeline` reports a debounced change. It closes the system track's
pending chunk and stamps it with the speaker who held it.

Two corrections keep the cut honest:

**Caption lag.** Meet's captions trail the audio by roughly one to three seconds,
because Google has to hear the words before rendering them. Cutting the audio at the
moment the caption changes therefore cuts one to three seconds into the new speaker's
audio, leaving their opening words on the end of the previous speaker's chunk.

**Pause seeking.** Rather than compensating with a fixed offset, the caption change
proposes a cut and the audio picks the exact sample. `MeetingChunker` gains:

```swift
/// The best place to end a chunk near the tail: the start of the most recent quiet
/// window inside `lookbackSeconds`, or nil when the speaker talked straight through.
func cutPoint(in samples: [Int16], lookbackSeconds: Double) -> Int?
```

It scans backwards over the last `lookbackSeconds` (default 4) for a
`silenceWindowSeconds` run below `silenceThreshold`, reusing the existing `isQuiet`.
Speaker changes almost always sit in a small pause, so this lands the cut on the real
boundary. When no pause is found the speakers genuinely overlapped, and the recorder
falls back to cutting `captionLagSeconds` (default 1.5) before the tail. The samples
after the cut stay in the pending buffer and open the next chunk, so no audio is lost.

**Minimum chunk.** A change is ignored while the pending chunk holds less than
`minimumSpeakerSeconds` (default 5) of audio. Without this, a lively exchange produces
a chunk per interjection. The cost of the floor is that a very short interjection is
absorbed into a neighbouring chunk and labelled with the dominant speaker, which is
bounded and acceptable. The existing target and maximum still apply, so a speaker who
talks for six minutes still gets cut every two.

The microphone track is unaffected: it already has exactly one speaker.

**The local participant.** Meet captions everyone on the call, including the person
at this Mac, so a naive reading would cut and label the *remote* track every time
its own user spoke, attributing their audio to a track that never carried it.
`SpeakerTimeline` therefore carries a `localName`, taken from the `userDisplayName`
setting. A confirmed change to the local user still ends the remote speaker's turn,
because they did stop talking, but hands the recorder a nil speaker so the far side
stays unlabelled until someone over there speaks again. The local name is also kept
out of the roster, which the summarizer receives separately.

This depends on the name in Settings matching the one in the meeting app, which is
what that setting's help text asks for. A mismatch costs a mislabelled turn, not a
broken recording.

**Cost.** Cutting on speaker change turns roughly fifteen system chunks per hour into
roughly ninety. Total audio uploaded is unchanged, so the only new cost is the
provider's ten second minimum on chunks shorter than that, which adds well under two
minutes of billed audio to a one hour meeting. Upload concurrency is already capped
at three in `MeetingTranscriber` and ninety requests over an hour is far inside any
rate limit.

### 4. Speaker labels flow through

- `MeetingChunk` gains `speaker: String?`.
- `MeetingSegment` gains `speaker: String?`, copied from its chunk by
  `MeetingTranscriber`.
- `MeetingTranscript.merge` prefers `segment.speaker` and falls back to
  `track.speakerLabel`. Coalescing already compares labels, so consecutive chunks from
  one named speaker still read as one turn.

The label is stamped on the chunk when it closes, not looked up afterwards by time
offset. This matters: chunk offsets are derived from samples written while caption
observations are wall clock, and the two drift if the capture ever drops buffers.
Stamping at cut time removes the alignment problem instead of managing it.

The microphone track is labelled with a new `userDisplayName` setting, defaulting to
`NSFullUserName()` and editable in Settings. An empty value falls back to `You`. Real
names on both sides make the notes readable by someone who was not on the call, and
give the summarizer a consistent vocabulary.

### 5. Summarizer receives the roster

`MeetingSummarizer.summarize` gains a `roster: [String]` parameter, rendered above the
transcript, and its instructions are rewritten to close the gap that produces invented
speakers:

- Name the participants explicitly and state that no one else spoke.
- State that a name occurring inside a turn is a reference to someone, not evidence
  that they spoke. This is the exact failure being fixed and is worth naming outright.
- Keep the existing rules on grounding, gaps, and section omission, which are sound.

With an empty roster the instructions fall back to today's text, so level 3 of the
ladder keeps working.

### 6. `MeetAccessibilitySpeakerSource`

Reads the browser's accessibility tree on a timer. Details that decide whether this
works at all:

- The browser is located by bundle identifier across Chrome, Brave, Arc, Edge and
  Safari, taking the first one running.
- Chromium exposes web content to the accessibility tree only once a client asks.
  `AXManualAccessibility` is set to true on the application element at start, and the
  source waits briefly before its first read. Without this the tree stops at the
  window frame and the source sees nothing.
- The caption container is located **once** by walking the tree for a live region
  inside a window whose title identifies Meet, and the element is cached. Polling
  re-walks only that subtree, once per second. Walking a full Meet document every
  second would be a visible CPU cost for an hour.
- A cached element that starts failing is discarded and relocated on the next tick,
  which covers the user leaving and rejoining a call.
- The roster is read from the participant panel when it is open, and otherwise left
  to the union of caption speakers. The panel is not forced open: moving the user's
  UI during their call is not acceptable. It is re-read every thirty seconds rather
  than once, since people join a call after it starts, and on its own schedule
  rather than the caption lookup's, which was a bug found during implementation.
- Everything is best effort. Any failure logs once and leaves the meeting on level 3.

The source runs off the main actor and hands observations back through the session
controller.

### 7. Session controller wiring

`MeetingSessionController.start` creates the source, the parser and the timeline, and
starts the source after capture. Source failure is logged, not surfaced: a meeting
that records without speaker names is still a good meeting, and an alert at the start
of a call is worse than a slightly weaker note. `stop` tears the source down before
draining uploads, and passes `timeline.roster` to the summarizer.

Speaker detection is gated on a new `meetingSpeakerDetectionEnabled` setting, default
on, so a user who does not want their screen read can turn it off without giving up
meetings.

### 8. Honesty about the screen

The README and `MeetingFailure.screenRecordingDenied` currently promise that no screen
content is captured. That is about to be half true: frames are still not captured by
the accessibility source, but the OCR fallback would capture them, and either way the
app now reads the contents of the meeting window.

Both texts are rewritten to say what is actually true: the app reads the Meet window's
captions and participant list to label who is speaking, this happens on the user's
Mac, nothing from the screen is written to disk or uploaded, and the setting can be
turned off. Understating this would be worse than the feature is worth.

## The OCR fallback, if needed

Built only if the accessibility source returns no captions on a real call.

A second `SCStream` filtered to the Meet window at one frame per second, cropped to
the bottom third where captions render, passed to `VNRecognizeTextRequest` with
`.accurate` and language hints from `settings.resolvedLocale`. Recognized lines go to
the same `MeetCaptionParser`, so nothing downstream changes. Frames are analysed in
memory and released immediately.

It is a separate stream rather than a change to `MeetingAudioCapture` so the working
audio path is not touched. The audio stream keeps its display filter and its 2x2
frames.

## Rejected alternatives

**Detecting the highlighted speaker tile.** Requires per platform pixel heuristics
over tile geometry that changes with grid view, speaker view, screen sharing and
window size, and highlight colours that change with theme. Captions carry the same
information as text in a fixed region.

**A Chrome extension reading Meet's DOM.** The most reliable signal available, and
rejected anyway: it is a second artifact to install, sign and maintain, it needs
native messaging or a local socket to reach the app, it covers only browser meetings,
and this project ships as one self contained application with no third party
dependencies. The accessibility tree carries most of the same data through a pipe the
app already uses.

**Google Workspace server side transcripts.** Speaker labelled and authoritative, and
rejected because they require a Workspace tier, an OAuth account and a network round
trip, against an app whose entire premise is no account.

**A diarizing transcription provider.** Deepgram or AssemblyAI would separate voices
without reading the screen, but returns `Speaker 1` and `Speaker 2`, not names, and
adds a second provider and a second key. The screen already has the names.

**Aligning Meet's caption text against the transcript to split turns inside existing
chunks.** Avoids touching the recorder, but means fuzzy sequence alignment between two
different ASR outputs of the same audio, which fails silently and is far harder to
test than a chunk boundary.

## Testing

Pure layers, matching the existing suite, which has no UI tests. The browser-facing
source is not unit tested; it is verified on a real call.

`MeetCaptionParser`:
- `Name: text` splits into speaker and text.
- Capitalization separates a name from a phrase, and name particles survive it.
- A growing line emits only the new tail.
- An identical repeated line emits nothing.
- A changed speaker opens a new observation.
- Speech containing a colon is not read as a speaker.
- An over-long or punctuated prefix is not read as a speaker.
- Turkish names with diacritics match case insensitively and keep their first spelling.
- Empty and whitespace input emit nothing.

`SpeakerTimeline`:
- `current` returns the latest speaker and goes nil after `staleAfter`.
- The local user is recognized case insensitively and kept out of the roster.
- A single stray line does not trigger a change before `minimumHoldSeconds`.
- `roster` unions caption speakers with panel names and does not duplicate.
- An empty timeline yields an empty roster.

`MeetingChunker.cutPoint`:
- Finds the start of a pause inside the lookback window.
- Returns nil when the tail is continuous speech.
- Ignores a pause older than the lookback window.

`MeetingRecorder`:
- A speaker change past the minimum closes a chunk stamped with the previous speaker.
- A speaker change below the minimum does not close a chunk.
- Samples after the cut point open the next chunk rather than being dropped.
- The microphone track ignores speaker changes.

`MeetingTranscript.merge`:
- Named segments render with their names.
- Consecutive segments from one name coalesce.
- Segments with no speaker fall back to `You` and `Them`.

`MeetingSummarizer`:
- The roster block renders above the transcript.
- An empty roster falls back to the original instructions.

Manual verification on a real Meet call, which is the only way to test the source:
captions on, at least two remote participants, confirm the written note names each
speaker, confirm turns are shorter than two minutes, and confirm that a name merely
mentioned in speech does not appear as a speaker or an action item owner. Then repeat
with captions off to confirm the note is identical to today's.

## Files

The OCR fallback described above is designed but deliberately not built. Whether it
is needed is decided by the first real call: if the accessibility source logs a
located caption region, it never ships.

Added:

- `Sources/NozomiFlowKit/Core/Meeting/MeetingSpeakerSource.swift`
- `Sources/NozomiFlowKit/Core/Meeting/MeetCaptionParser.swift`
- `Sources/NozomiFlowKit/Core/Meeting/SpeakerTimeline.swift`
- `Sources/NozomiFlowKit/Core/Meeting/MeetAccessibilitySpeakerSource.swift`
- `Tests/NozomiFlowKitTests/MeetCaptionParserTests.swift`
- `Tests/NozomiFlowKitTests/SpeakerTimelineTests.swift`

Changed:

- `Sources/NozomiFlowKit/Core/Meeting/MeetingChunker.swift`
- `Sources/NozomiFlowKit/Core/Meeting/MeetingRecorder.swift`
- `Sources/NozomiFlowKit/Core/Meeting/MeetingTranscriber.swift`
- `Sources/NozomiFlowKit/Core/Meeting/MeetingTranscript.swift`
- `Sources/NozomiFlowKit/Core/Meeting/MeetingSummarizer.swift`
- `Sources/NozomiFlowKit/Core/Meeting/MeetingSessionController.swift`
- `Sources/NozomiFlowKit/Core/Settings/SettingsStore.swift`
- `Sources/NozomiFlowKit/UI/Settings/GeneralSettingsView.swift`
- `Tests/NozomiFlowKitTests/MeetingNotesTests.swift`
- `README.md`
