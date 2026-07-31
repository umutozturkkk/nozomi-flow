# Nozomi Flow

**Don't type. Just murmur.**

Native macOS voice dictation in the spirit of [Wispr Flow](https://wisprflow.ai):
hold a key, speak naturally, release, and clean formatted text lands in whatever
app you're using. Unlike Wispr Flow, dictation runs **100% on-device by
default**: Apple's SpeechAnalyzer for transcription and Apple Intelligence for
AI cleanup. No account, no subscription, no audio leaving your Mac.

## Features

| | |
|---|---|
| 🎙 **Speak into any app** | Hold **fn** (configurable), talk, release: text is inserted at your cursor via Accessibility API (clipboard-free) with a paste fallback. Your clipboard is always restored. |
| 🌊 **Live flow bar** | Liquid Glass pill at the bottom of the screen with a real-time waveform and streaming partial transcript. |
| ✨ **AI auto-edits** | Filler words removed, self-corrections applied ("meet at 2, actually 3" → "meet at 3"), punctuation, capitalization, lists, via on-device Apple Intelligence. Adjustable: Off / Light / Full. |
| 🗣 **Tone matching** | Casual in Slack/Messages (no trailing period), polished in Mail, verbatim identifiers in Xcode/terminals. |
| 🪄 **Command mode** | Hold **Right ⌘** with text selected and say "make this more concise" / "translate to English", or with nothing selected, dictate an instruction to generate text. |
| 🎧 **Meeting notes** | Record a call from the menu bar. Your mic and the other side are captured as separate tracks, transcribed while the meeting is still running, and written out as one markdown note: summary, decisions, action items, open questions, full transcript. Needs cloud transcription. |
| 🔒 **Hands-free lock** | Double-tap the dictation key to keep recording without holding; tap again to finish. |
| 📖 **Personal dictionary** | Canonical spellings + misheard variants, fed to the recognizer as contextual vocabulary and applied as replacement rules. |
| 🕘 **History & stats** | Local-only transcript history with raw-transcript access ("undo AI edit"), words, WPM, streaks, corrections, minutes saved. |
| 🌍 **50+ languages on-device** | Engine chosen per language: SpeechTranscriber (30 locales) → DictationTranscriber (54, incl. Turkish) → SFSpeechRecognizer (63). |
| ⌨️ **Spoken commands** | "new line", "new paragraph", and trailing "press enter" (types Return after inserting). |
| ☁️ **Optional cloud** | Bring your own key for cloud transcription (any OpenAI-compatible `/audio/transcriptions` endpoint, OpenRouter by default) or OpenAI cleanup. Off by default. |

## Requirements

- macOS 26 (Tahoe), Apple Silicon
- Apple Intelligence enabled (for the Full cleanup level; Light works without)
- Xcode 26 to build
- Meetings only: a key for an OpenAI-compatible endpoint, plus Screen Recording
  permission

## Build & run

```sh
scripts/bundle.sh release --open
```

This builds with SwiftPM, assembles `build/Nozomi Flow.app`, and signs it with your
Apple Development identity (falls back to ad-hoc; note ad-hoc re-prompts
permissions on every rebuild).

First run walks you through: microphone permission → Accessibility permission
(required for the global hotkey and text insertion) → speech model download →
a guided test dictation.

> **fn key tip:** set *System Settings → Keyboard → Press 🌐 key* to
> **Do Nothing**, or macOS will also trigger emoji/dictation on your hotkey.

## Meetings

Menu bar → **Record Meeting**. Both sides of the call are captured as separate
tracks, which is what gives the transcript speaker labels without paying for
diarization: whatever the microphone heard is you, whatever the system played is
everyone else.

While the meeting runs, audio is closed into roughly two-minute chunks on natural
pauses and every chunk is uploaded the moment it closes, so transcription is
nearly finished by the time you stop. The two tracks are then merged into one
ordered transcript, summarized, and written to:

```
~/Library/Application Support/Murmur/Meetings/
```

One markdown file per meeting. Markdown rather than a database so the notes
outlive this app, open in anything, and sync wherever you already sync files. A
meeting whose summary fails still keeps its transcript.

Two things meetings need that dictation does not:

- **Cloud transcription**, turned on in Settings with a key. Meetings are not
  transcribed on-device.
- **Screen Recording permission.** ScreenCaptureKit is the only supported way to
  read system audio on macOS, and it insists on being a screen capture. The video
  side is configured down to 2x2 pixels and every frame is dropped: no screen
  content is captured, sent anywhere or kept.

## Architecture

```
Sources/NozomiFlow         thin executable entry
Sources/NozomiFlowKit
  App/                   contracts, models, observable state, session state machine
  Core/Audio             AVAudioEngine capture, RMS metering, route-change recovery,
                         ScreenCaptureKit dual-track meeting capture
  Core/Transcription     SpeechAnalyzer / DictationTranscriber / SFSpeechRecognizer chain
  Core/Formatting        rule pass + Apple Intelligence / OpenAI cleanup + command mode
  Core/Insertion         AX-first insertion, pasteboard-swap fallback, clipboard restore
  Core/Hotkey            listen-only CGEventTap (fn / right-modifier hold-to-talk)
  Core/Context           frontmost-app tone mapping, AX field context (password-safe)
  Core/Meeting           pause-aware chunking, concurrent chunk upload, transcript
                         merge, summary, markdown store
  Core/Dictionary        replacement engine + JSON persistence
  Core/History           history, stats, streaks + JSON persistence
  Core/Permissions       microphone / accessibility / screen recording state
  Core/Settings          UserDefaults-backed settings, Keychain for API keys
  Support/               logging, Keychain helper, sounds
  UI/                    HUD pill, menu bar, settings window, onboarding, alerts
Tests/NozomiFlowKitTests 133 unit tests (rules, stores, selection, trackers,
                         chunking, transcript merge, meeting session)
```

Dictation flow: `hotkey ↓` → audio + streaming ASR (partials to HUD) → `hotkey ↑`
→ finalize → dictionary → rules (+ optional LLM) → insert → history/stats.

Meeting flow: `menu` → dual-track capture → chunk on pause → upload each chunk →
merge tracks → summarize → markdown on disk → alert offering to open the notes.

## Privacy

- Dictation is transcribed on this Mac. Nothing is sent anywhere unless you
  explicitly select a cloud engine.
- Meetings are the exception: they are transcribed and summarized in the cloud,
  which is why they stay off until you configure a key.
- Screen Recording permission is used only to read system audio. No screen
  content is captured or retained.
- Password/secure fields are never read for context and never captured.
- History is a local JSON file; disable or clear it in Settings → History.
- Meeting notes are local markdown files; delete them like any other file.

## Known limitations

- Listen-only event tap: the hotkey can't be swallowed, so fn also triggers
  whatever macOS binds to it (see tip above).
- AX insertion targets native text controls; web areas and Electron apps use
  the paste fallback.
- Command mode requires Apple Intelligence or an OpenAI key.
- Meeting turns are only as precise as the chunk that contains them: the
  transcription endpoint returns no word-level timestamps, so rapid back-and-forth
  is attributed correctly but not reproduced verbatim.

## Roadmap ideas

Snippets (voice shortcuts → full text), Transforms (post-hoc polish hotkeys),
Scratchpad, auto-learning dictionary from corrections, per-app language
override, custom hotkey combos, an in-app browser for meeting notes.

## License

MIT. See [LICENSE](LICENSE).
