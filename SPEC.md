# Nozomi Flow — Product & Architecture Spec

A native macOS voice-dictation app modeled on Wispr Flow's behavior: hold a key,
speak, release — clean formatted text is inserted into whatever app has focus.
Differentiator vs Wispr: **100% on-device by default** (Apple SpeechAnalyzer +
Apple Intelligence), no account, no cloud dependency; optional OpenAI-compatible
cloud LLM via user API key.

Target: macOS 26+ (Tahoe), Apple Silicon. Swift 5 language mode, SwiftPM,
zero third-party dependencies. Bundle id `co.nozomi.flow`.

## The core loop

```
hold dictation key (default: fn)
  -> HUD pill appears bottom-center, waveform animates, partial words stream in
  -> release key
  -> transcription finalized (on-device ASR)
  -> dictionary replacements -> formatting pipeline (rules + optional LLM)
  -> text inserted into frontmost app (AX-first, paste fallback)
  -> HUD shows success, history + stats recorded, HUD fades out
```

- **Quick tap** (< 0.35s): discard silently. **Double-tap** (2 taps < 0.6s
  apart): hands-free lock — recording continues until the key is tapped again,
  Esc, or 10 min cap. HUD shows a lock indicator.
- **Esc** during recording/processing cancels the session.
- **Command mode** (default: hold Right ⌘): with text selected — the spoken
  instruction transforms the selection in place ("make this more concise",
  "translate to English"); without selection — generates the requested text at
  the cursor. (Wispr uses Fn+Ctrl; we use a single-key alternative.)
- **"press enter"** spoken at the very end of a dictation: stripped from the
  output; a Return keypress is synthesized after insertion.
- Empty/silent transcript -> HUD "Didn't catch that", nothing inserted.

## Behavioral details cloned from Wispr Flow (research-verified)

- Wispr does NOT stream text into the target app; it pastes once at the end.
  Partials are only shown in the HUD ("Flow Bar" equivalent).
- Auto-cleanup levels: `off` (verbatim), `light` (rules only), `full`
  (rules + LLM). Raw transcript is always kept in history ("Undo AI edit").
- Backtrack self-corrections are the most-loved feature: "Let's do coffee at 2
  actually 3" -> "Let's do coffee at 3". Trigger words (actually / no wait /
  scratch that / I mean) AND contextual restatements. LLM-level feature.
- Filler removal: um, uh, er + language-appropriate equivalents. Do NOT strip
  meaningful uses ("I actually enjoyed it" keeps "actually").
- Tone per app category (bundle-id map in `AppContextProvider`):
  casual (Slack/Messages/WhatsApp/Discord: relaxed, contractions, **strip
  trailing period on short casual messages**), professional (Mail/Notion:
  polished complete sentences), technical (Xcode/VS Code/terminals: preserve
  identifiers/casing verbatim, minimal rewriting), neutral.
- Numbered-list detection: "one... two... three..." -> formatted list (LLM).
- Spoken punctuation ("comma", "question mark") is mostly handled by Apple's
  ASR engines already; the LLM pass normalizes the rest.
- Personal dictionary: canonical `phrase` + misheard `variants` (replacement
  rules), fed to ASR as contextual strings AND applied post-transcription.
- Stats (Wispr "Insights"): total words, sessions, average WPM, streak days,
  corrections count, words today, minutes saved vs 40 WPM typing.
- Top Wispr complaints to AVOID: over-aggressive rewriting (keep LLM prompt
  conservative, never answer questions found in the transcript); clipboard
  clobbering (always restore prior clipboard, even on failed paste; prefer AX
  insertion which doesn't touch the clipboard); cloud outages (we're local).

## Architecture (fixed contracts — do not change without coordinator update)

```
Sources/Nozomi Flow/main.swift                 thin entry
Sources/MurmurKit/
  App/Models.swift          shared types (DictationPhase, HistoryEntry, ...)
  App/Contracts.swift       service protocols
  App/AppState.swift        @Observable UI state (main-actor)
  App/DictationCoordinator.swift  session state machine (owns the flow)
  App/MurmurMain.swift      AppDelegate wiring
  Core/Audio/               AVAudioEngine capture + level metering
  Core/Transcription/       SpeechAnalyzer/DictationTranscriber/SFSpeech chain
  Core/Formatting/          rules + Apple Intelligence + OpenAI pipeline
  Core/Insertion/           AX insert -> paste fallback -> clipboard
  Core/Hotkey/              CGEventTap listen-only global keys
  Core/Context/             frontmost app + tone + AX field text
  Core/Dictionary/          personal dictionary store (JSON)
  Core/History/             history + stats store (JSON)
  Core/Settings/            UserDefaults-backed SettingsStore
  Core/Permissions/         mic + accessibility
  UI/HUD/                   floating pill (NSPanel, non-activating)
  UI/StatusItem/            menu bar
  UI/Settings/              settings window (SwiftUI tabs)
  UI/Onboarding/            first-run flow
  Support/                  Log, KeychainHelper, SoundPlayer
```

Ground truth on this machine (probed):
- `SpeechTranscriber.supportedLocales`: 30 (en/de/es/fr/it/ja/ko/pt/zh/yue
  variants). `DictationTranscriber.supportedLocales`: 54 — includes `tr_TR`.
  `SFSpeechRecognizer.supportedLocales()`: 63. No assets installed yet
  (download required on first prepare).
- `SystemLanguageModel.default.availability == .available` (Apple Intelligence
  is enabled on this Mac).

Engine selection: exact locale match in SpeechTranscriber -> language match in
SpeechTranscriber -> same chain in DictationTranscriber -> SFSpeechRecognizer
-> error.

## Rules for build agents

- `swift build && swift test` must pass before you report done.
- Do NOT run any `git` commands. Do NOT edit files outside your ownership list.
- No third-party dependencies. English comments/identifiers, sparse comments.
- If a contract must change, implement what you can and report the needed
  change instead of editing shared files.
- App bundle: `scripts/bundle.sh release` (don't run the app; the integrator
  does live testing).
```
