# Nozomi Flow

**Don't type. Just murmur.**

Native macOS voice dictation in the spirit of [Wispr Flow](https://wisprflow.ai) —
hold a key, speak naturally, release, and clean formatted text lands in whatever
app you're using. Unlike Wispr Flow, everything runs **100% on-device by
default**: Apple's SpeechAnalyzer for transcription and Apple Intelligence for
AI cleanup. No account, no subscription, no audio leaving your Mac.

## Features

| | |
|---|---|
| 🎙 **Speak into any app** | Hold **fn** (configurable), talk, release — text is inserted at your cursor via Accessibility API (clipboard-free) with a paste fallback. Your clipboard is always restored. |
| 🌊 **Live flow bar** | Liquid Glass pill at the bottom of the screen with a real-time waveform and streaming partial transcript. |
| ✨ **AI auto-edits** | Filler words removed, self-corrections applied ("meet at 2, actually 3" → "meet at 3"), punctuation, capitalization, lists — via on-device Apple Intelligence. Adjustable: Off / Light / Full. |
| 🗣 **Tone matching** | Casual in Slack/Messages (no trailing period), polished in Mail, verbatim identifiers in Xcode/terminals. |
| 🪄 **Command mode** | Hold **Right ⌘** with text selected and say "make this more concise" / "translate to English" — or with nothing selected, dictate an instruction to generate text. |
| 🔒 **Hands-free lock** | Double-tap the dictation key to keep recording without holding; tap again to finish. |
| 📖 **Personal dictionary** | Canonical spellings + misheard variants, fed to the recognizer as contextual vocabulary and applied as replacement rules. |
| 🕘 **History & stats** | Local-only transcript history with raw-transcript access ("undo AI edit"), words, WPM, streaks, corrections, minutes saved. |
| 🌍 **50+ languages on-device** | Engine chosen per language: SpeechTranscriber (30 locales) → DictationTranscriber (54, incl. Turkish) → SFSpeechRecognizer (63). |
| ⌨️ **Spoken commands** | "new line", "new paragraph", and trailing "press enter" (types Return after inserting). |
| ☁️ **Optional cloud** | Bring your own OpenAI key if you want cloud LLM cleanup; off by default. |

## Requirements

- macOS 26 (Tahoe), Apple Silicon
- Apple Intelligence enabled (for the Full cleanup level; Light works without)
- Xcode 26 to build

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

## Architecture

```
Sources/Nozomi Flow           thin executable entry
Sources/MurmurKit
  App/                   contracts, models, observable state, session state machine
  Core/Audio             AVAudioEngine capture, RMS metering, route-change recovery
  Core/Transcription     SpeechAnalyzer / DictationTranscriber / SFSpeechRecognizer chain
  Core/Formatting        rule pass + Apple Intelligence / OpenAI cleanup + command mode
  Core/Insertion         AX-first insertion, pasteboard-swap fallback, clipboard restore
  Core/Hotkey            listen-only CGEventTap (fn / right-modifier hold-to-talk)
  Core/Context           frontmost-app tone mapping, AX field context (password-safe)
  Core/Dictionary        replacement engine + JSON persistence
  Core/History           history, stats, streaks + JSON persistence
  Core/Settings          UserDefaults-backed settings, Keychain for API keys
  UI/                    HUD pill, menu bar, settings window, onboarding
Tests/MurmurKitTests     72 unit tests (rules, stores, selection, trackers)
```

Session flow: `hotkey ↓` → audio + streaming ASR (partials to HUD) → `hotkey ↑`
→ finalize → dictionary → rules (+ optional LLM) → insert → history/stats.

## Privacy

- Speech is transcribed on this Mac. Nothing is sent anywhere unless you
  explicitly select the OpenAI engine.
- Password/secure fields are never read for context and never captured.
- History is a local JSON file; disable or clear it in Settings → History.

## Known limitations

- Listen-only event tap: the hotkey can't be swallowed, so fn also triggers
  whatever macOS binds to it (see tip above).
- AX insertion targets native text controls; web areas and Electron apps use
  the paste fallback.
- Command mode requires Apple Intelligence or an OpenAI key.

## Roadmap ideas

Snippets (voice shortcuts → full text), Transforms (post-hoc polish hotkeys),
Scratchpad, auto-learning dictionary from corrections, per-app language
override, custom hotkey combos.

## License

MIT. See [LICENSE](LICENSE).
