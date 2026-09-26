# Personal model data: collection and review

Status: design, approved in conversation 2026-09-26. Builds on `fix/dictation-audio-capture`.

## Why

On-device Turkish transcription is well behind the cloud. On eight recordings of
one speaker (natural speech, English tech terms mixed in), mean WER excluding the
numbers sample was:

| Engine | WER | Wait after key release |
|---|---|---|
| MAI-Transcribe 1.5 (cloud, OpenRouter) | 7.5% | 1.7 s |
| Whisper large-v3-turbo (WhisperKit, local) | 20.8% | 0.4 s |
| Apple DictationTranscriber (current local) | 29.4% | 0.4 s |

Prompting Whisper with a vocabulary fixed tech terms but not the overall rate:
the remaining errors are ordinary Turkish words misheard, which only adapting the
model to the speaker's voice can fix. The plan is to fine-tune Whisper turbo on
the user's own dictations, labelled by the cloud model, with the few uncertain
words confirmed by the user. This spec covers collecting and reviewing that
data. Fine-tuning and a local Whisper dictation engine are separate follow-ups.

## Goals

- Every cloud-transcribed dictation becomes a training sample (audio + label)
  without the user doing anything.
- The user never has to listen through recordings. The app finds the words it
  is unsure about and asks short yes/no questions, in a batch, when the user
  chooses.
- Confirmed answers improve daily dictation immediately (personal dictionary),
  not only after training.
- New UI is available in Turkish and English, following the macOS language.

## Non-goals

- Training or converting models (follow-up).
- Using Whisper as the live dictation engine (follow-up).
- Translating the rest of the app (follow-up; this work adds the infrastructure).
- Collecting command-mode or meeting audio.

## Phase 1: sample collection

### What is stored

One sample per dictation that meets all of:

- transcribed by the cloud engine (a local transcript is not a trustworthy label);
- dictation mode, not command mode;
- at least 1 s of audio and a non-empty raw transcript;
- collection is enabled in Settings.

Per sample, in `~/Library/Application Support/Murmur/Training/`:

- `<id>.wav`: the exact 16 kHz mono PCM16 audio that was uploaded. The cloud
  session already builds this; it is exposed on `TranscriptionOutcome` instead
  of being discarded. It is post-gain audio, which is also what a local engine
  will hear, so training and inference match.
- `<id>.json`:

```json
{
  "id": "UUID",
  "createdAt": "ISO-8601",
  "durationSeconds": 6.2,
  "appBundleID": "com.apple.TextEdit",
  "labelSource": "microsoft/mai-transcribe-1.5",
  "localeIdentifier": "tr_TR",
  "rawLabel": "cloud raw transcript, before dictionary and AI cleanup",
  "label": "current best label (rawLabel with confirmed corrections applied)",
  "status": "unchecked | agreed | pending | corrected | verified | uncertain",
  "check": { "whisperText": "...", "candidates": [ ... ] }
}
```

The JSON is written last, via a temporary file and rename, so a sample without a
JSON is incomplete and is deleted on the next launch.

### Components

- `TrainingSampleStore` (Core/Training): writes, lists, updates and deletes
  samples; reports the total collected duration; cleans up orphans at launch.
  Pure file I/O behind a directory URL so tests use a temp dir.
- `DictationCoordinator` hands the finished dictation to the store after
  insertion, off the main actor. A failure is logged and never affects the
  dictation.

### Settings

A new **Personal model** section at the end of the **General** tab:

- toggle **Collect data for a personal model**, off by default;
- progress: collected minutes against a 90-minute target;
- model download status (phase 2);
- **Delete all collected data**.

Turning collection off stops new samples and leaves existing data alone.

## Phase 2: finding uncertain words

### Whisper in the app

- Add `argmax-oss-swift` (product `WhisperKit`) to `Package.swift`.
- When collection is enabled, download `openai_whisper-large-v3-v20240930_turbo`
  (~1.5 GB) to `Murmur/Models/`, with the tokenizer folder pointed there too
  (WhisperKit's default writes into `~/Documents/huggingface`).
- Transcribe with language forced to `tr` (the dictation locale), word
  timestamps and per-word probabilities enabled.

### When it runs

An `NSBackgroundActivityScheduler` job processes `unchecked` samples when the
system allows it, never while a dictation is recording or processing, and stops
early when interrupted. The model is loaded for the batch and released after.

### Per sample

1. **Whisper pass**: words with timestamps and probabilities.
2. **Alignment** (`TranscriptAligner`): word-level alignment of the cloud label
   and Whisper output (edit distance over normalised tokens). Normalisation
   folds Turkish case correctly (İ/ı), strips punctuation and apostrophes, and
   treats numbers written as digits or words as equal, so formatting
   differences are never candidates.
3. **Candidates** (`CandidateFinder`): spans where the aligned words differ,
   plus label words aligned to a Whisper word with probability below a
   threshold. Adjacent differing words merge into one span.
4. **No candidates**: status `agreed`; both models heard the same thing, the
   most reliable training data.
5. **Candidates**: each is sent to the suggester, and pairs already answered
   before are resolved without asking (see "Answers").

### Suggestion

`SuggestionClient` calls OpenRouter chat completions (default
`google/gemini-2.5-flash-lite`, configurable, same key as cloud transcription)
with: the cloud sentence, the candidate span, Whisper's alternative, and the
personal dictionary terms. Only text is sent; no audio. The model returns JSON:

```json
{ "ask": true, "suggestion": "Slack'e", "baseTerm": "Slack" }
```

`ask: false` means the span looks fine; it is dropped. Malformed JSON drops the
candidate. Parsing is a pure function with tests.

### Limits

- At most 10 pending questions. When full, the scheduler stops generating new
  ones until some are answered; unchecked samples wait.
- A (heard, suggested) pair answered once is never asked again.
- Network failure leaves the sample `unchecked` for the next run.

## Phase 2: review cards

### Entry point

When questions are pending, the menu bar icon shows a dot and the menu shows
**Review suggestions (N)**. It opens a small window with one card at a time:

> …ran the tests again and posted the result to **~~Sheila~~**.
> **Did you mean "Slack"?**
> ▶ Play snippet
> [Yes ↩] [No, it's right] [Something else: ___] [Skip (esc)]

Snippet playback plays the candidate's time range ±1 s, from Whisper's
timestamps. Keyboard: ↩ yes, esc skip.

### Answers

| Answer | Sample | Also |
|---|---|---|
| Yes | label corrected, status `corrected` | `baseTerm` added to the personal dictionary as a phrase (boost only) |
| No, it's right | status `verified` | pair stored as "don't ask" |
| Something else | label replaced with the typed text, `corrected` | typed term added to the dictionary |
| Skip | status `uncertain` | never asked again; excluded from training |

Dictionary additions are the base term only, with no replacement variants: an
automatic "heard X → write Y" rule would fire on the real word X too (a name, for
example), and Turkish suffixes make single replacements unreliable. Boosting the
term via contextual strings and the cleanup prompt is safe. Added terms appear
in Settings → Dictionary and can be removed there.

A sample with several candidates stays `pending` until all are answered.

## Localization

- `Package.swift`: `defaultLocalization: "en"`, a String Catalog
  (`Localizable.xcstrings`) as a resource of `NozomiFlowKit`.
- `scripts/bundle.sh`: copy the SwiftPM resource bundle into
  `NozomiFlow.app/Contents/Resources`, and declare `en` and `tr` in
  `CFBundleLocalizations` so macOS offers the per-app language setting.
- All new UI (settings section, review window, menu item) is written with
  localized strings in English and Turkish. The language follows macOS; the
  user can override it per app in System Settings → General → Language &
  Region → Applications.
- Existing screens stay English until the follow-up translation pass.

## Privacy

- Audio and labels stay in Application Support; nothing is uploaded beyond the
  audio that cloud transcription already sends.
- The suggester receives only sentence text.
- Collection is off until the user turns it on; deletion is one button.
- The data directory is outside the repository.

## Error handling

Nothing in this feature may affect a dictation. Store write failures skip the
sample. A failed model download or Whisper load keeps collection running and
shows the state in Settings. Suggester failures retry on a later run. Orphaned
files are removed at launch.

## Testing

Unit tests, TDD, fakes for Whisper and network behind protocols:

- `TrainingSampleStore`: write/read/update/delete, eligibility rules, total
  duration, orphan cleanup, atomic JSON.
- `TranscriptAligner`: Turkish case folding, apostrophes, punctuation,
  digits vs words, insertions and deletions.
- `CandidateFinder`: differences, low-probability words, span merging.
- Suggestion JSON parsing, including malformed responses.
- Question cap and "never ask twice".
- Answer handling: label updates, statuses, dictionary additions.

End-to-end check against the existing eight bake-off recordings, whose cloud
and Whisper outputs are already known, e.g. a misheard "Slack" in the short
tech sample must produce a question and a correct-looking suggestion.

## Follow-ups

1. Whisper turbo as a selectable local dictation engine.
2. Fine-tuning on collected data (LoRA, on-device), CoreML conversion with
   whisperkittools, scoring with the bake-off harness on held-out samples.
3. Translating the rest of the app into Turkish.
