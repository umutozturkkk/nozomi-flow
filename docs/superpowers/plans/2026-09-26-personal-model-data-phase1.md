# Personal Model Data, Phase 1 (Collection) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Every cloud-transcribed dictation is saved on disk as a training sample (the uploaded 16 kHz audio plus the raw cloud transcript), controlled from a localized (English/Turkish) "Personal model" section in Settings.

**Architecture:** The cloud session already holds the exact PCM16 audio it uploads; `TranscriptionEngine.endSession` attaches it to `TranscriptionOutcome`. After a dictation is inserted, `DictationCoordinator` checks a pure eligibility rule and hands the sample to `TrainingSampleStore`, which writes `<id>.wav` then `<id>.json` (atomically) under Application Support off the main actor. Localization comes from a String Catalog in the `NozomiFlowKit` resource bundle, which `bundle.sh` copies into the app.

**Tech Stack:** Swift 6 toolchain (language mode 5), SwiftPM, XCTest, SwiftUI, AppKit, AVFAudio. No new dependencies in this phase.

**Spec:** `docs/superpowers/specs/2026-09-26-personal-model-data-design.md` (phase 1 and the Localization section). Phase 2 (Whisper check, suggestions, review cards) gets its own plan after this ships.

## Global Constraints

- Platform: macOS 26, Apple Silicon (`platforms: [.macOS("26.0")]` in `Package.swift`).
- Data directory: `~/Library/Application Support/Murmur/Training/` (the folder is still named "Murmur" on purpose, like the other stores).
- Audio format on disk: 16 kHz, mono, PCM16 WAV, byte-identical to what was uploaded (`CloudTranscriptionSession.makeWAV`).
- Samples come only from dictation mode, cloud engine, at least 1 s of audio, non-empty raw transcript, collection enabled.
- Collection is off by default. Turning it off never deletes data.
- JSON is written last, via temp file + rename. A `.wav` without a `.json` is incomplete and is removed at launch.
- Nothing in this feature may delay, fail or alter a dictation. Store errors are logged and swallowed.
- All new user-facing strings are localized in `en` and `tr`; the language follows macOS (per-app override in System Settings).
- Tests: XCTest in `Tests/NozomiFlowKitTests`, run with `swift test`. Every task ends with the full suite green.
- Commits end with the line `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`.
- Work on branch `feat/personal-model-data`.

## Review Focus

1. **Cloud request failed and the dictation was rescued by the on-device replay.** The outcome then carries a local transcript and must not become a sample, because its label is untrustworthy. Pinned in Task 3 (`testLocalEngineOutcomeIsNotASample`) and Task 2 (audio is only attached on the cloud path).
2. **App killed between writing the WAV and the JSON.** It must leave nothing half-written that later reads as a sample. Pinned in Task 3 (`testIncompleteSamplesAreRemoved`, `testSampleWithoutJSONIsNotListed`).
3. **A key missing its Turkish translation.** It would silently show English to a Turkish user. Pinned in Task 1 (`testEveryKeyHasEnglishAndTurkish`).
4. **The resource bundle missing from the built app.** `Bundle.module` traps at first use and would crash the app when Settings opens. Pinned in Task 1: `bundle.sh` fails the build if the bundle is absent, and the manual check opens Settings from the installed app.
5. **Disk write fails (full disk, permissions).** The dictation must still insert normally. Pinned in Task 3 (`testSaveIntoUnwritableDirectoryThrowsInsteadOfCrashing`) and Task 4 (the coordinator catches and logs).

---

## File Structure

| File | Responsibility |
|---|---|
| `Package.swift` (modify) | `defaultLocalization: "en"`, `resources: [.process("Resources")]` on `NozomiFlowKit` |
| `Sources/NozomiFlowKit/Resources/Localizable.xcstrings` (create) | All new strings, `en` + `tr` |
| `Sources/NozomiFlowKit/Support/L10n.swift` (create) | One lookup helper; tests can force a localization |
| `scripts/bundle.sh` (modify) | Copy `NozomiFlow_NozomiFlowKit.bundle` into `Contents/Resources`, fail if missing |
| `Support/Info.plist` (modify) | `CFBundleLocalizations` = `en`, `tr` |
| `Sources/NozomiFlowKit/App/Models.swift` (modify) | `TranscriptionOutcome.audio` |
| `Sources/NozomiFlowKit/Core/Transcription/TranscriptionEngine.swift` (modify) | Attach cloud audio in `endSession` |
| `Sources/NozomiFlowKit/Core/Training/TrainingSample.swift` (create) | Sample model + eligibility rule |
| `Sources/NozomiFlowKit/Core/Training/TrainingSampleStore.swift` (create) | Disk I/O for samples |
| `Sources/NozomiFlowKit/Core/Settings/SettingsStore.swift` (modify) | `collectTrainingData` setting |
| `Sources/NozomiFlowKit/App/DictationCoordinator.swift` (modify) | Hand eligible dictations to the store |
| `Sources/NozomiFlowKit/App/NozomiFlowMain.swift` (modify) | Create the store, clean up at launch, wire it in |
| `Sources/NozomiFlowKit/UI/Settings/PersonalModelSection.swift` (create) | The localized Settings section |
| `Sources/NozomiFlowKit/UI/Settings/GeneralSettingsView.swift`, `SettingsRootView.swift`, `SettingsWindowController.swift` (modify) | Pass the store through, show the section |
| Tests (create) | `LocalizationTests.swift`, `TrainingSampleTests.swift`, `TrainingSampleStoreTests.swift`; `CloudTranscriptionTests.swift` (modify) |

---

### Task 1: Localization infrastructure

**Files:**
- Modify: `Package.swift`
- Create: `Sources/NozomiFlowKit/Resources/Localizable.xcstrings`
- Create: `Sources/NozomiFlowKit/Support/L10n.swift`
- Modify: `scripts/bundle.sh`
- Modify: `Support/Info.plist`
- Test: `Tests/NozomiFlowKitTests/LocalizationTests.swift`

**Interfaces:**
- Produces: `enum L10n { static func string(_ key: String, localization: String? = nil) -> String }` plus the keys listed in the catalog below. Tasks 5+ use `L10n.string("…")`.

Verified beforehand in a scratch package: SwiftPM (this toolchain) compiles `.xcstrings` into `en.lproj`/`tr.lproj/Localizable.strings` inside the resource bundle. `String(localized:locale:)` does **not** pick the language from `locale`, so tests select a localization by loading that `.lproj` bundle explicitly.

- [ ] **Step 1: Write the failing tests**

`Tests/NozomiFlowKitTests/LocalizationTests.swift`:

```swift
import XCTest
@testable import NozomiFlowKit

/// New UI ships in English and Turkish. A key without a Turkish value falls back
/// to English silently, which a Turkish user would see as a half-translated app.
final class LocalizationTests: XCTestCase {

    func testTurkishStringsResolveFromTheResourceBundle() {
        XCTAssertEqual(L10n.string("training.header", localization: "tr"), "Kişisel model")
        XCTAssertEqual(L10n.string("training.header", localization: "en"), "Personal model")
    }

    func testUnknownKeyFallsBackToTheKeyItself() {
        XCTAssertEqual(L10n.string("no.such.key", localization: "tr"), "no.such.key")
    }

    func testEveryKeyHasEnglishAndTurkish() throws {
        let catalog = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/NozomiFlowKit/Resources/Localizable.xcstrings")
        let json = try JSONSerialization.jsonObject(with: Data(contentsOf: catalog)) as? [String: Any]
        let strings = try XCTUnwrap(json?["strings"] as? [String: [String: Any]])
        XCTAssertFalse(strings.isEmpty)
        for (key, entry) in strings {
            let localizations = entry["localizations"] as? [String: Any] ?? [:]
            for language in ["en", "tr"] {
                let unit = (localizations[language] as? [String: Any])?["stringUnit"] as? [String: Any]
                let value = unit?["value"] as? String ?? ""
                XCTAssertFalse(value.isEmpty, "\(key) has no \(language) value")
            }
        }
    }
}
```

- [ ] **Step 2: Run to verify they fail**

Run: `swift test --filter LocalizationTests 2>&1 | grep -E "error|Executed"`
Expected: build error `cannot find 'L10n' in scope`.

- [ ] **Step 3: Implement**

`Package.swift`: add `defaultLocalization: "en",` after `name: "NozomiFlow",`, and give the `NozomiFlowKit` target a resources entry:

```swift
        .target(
            name: "NozomiFlowKit",
            path: "Sources/NozomiFlowKit",
            resources: [.process("Resources")],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
```

`Sources/NozomiFlowKit/Support/L10n.swift`:

```swift
import Foundation

/// Lookup for strings in the NozomiFlowKit String Catalog. The app language
/// follows macOS; `localization` exists so tests can pin one.
enum L10n {
    static func string(_ key: String, localization: String? = nil) -> String {
        bundle(for: localization).localizedString(forKey: key, value: key, table: nil)
    }

    /// Formats a catalog string that contains `%lld`-style placeholders.
    static func format(_ key: String, _ arguments: CVarArg..., localization: String? = nil) -> String {
        String(format: string(key, localization: localization), arguments: arguments)
    }

    private static func bundle(for localization: String?) -> Bundle {
        guard let localization,
              let path = Bundle.module.path(forResource: localization, ofType: "lproj"),
              let bundle = Bundle(path: path)
        else { return .module }
        return bundle
    }
}
```

`Sources/NozomiFlowKit/Resources/Localizable.xcstrings` (all phase-1 keys; Tasks 5 uses them):

```json
{
  "sourceLanguage" : "en",
  "version" : "1.0",
  "strings" : {
    "training.header" : { "localizations" : {
      "en" : { "stringUnit" : { "state" : "translated", "value" : "Personal model" } },
      "tr" : { "stringUnit" : { "state" : "translated", "value" : "Kişisel model" } } } },
    "training.toggle" : { "localizations" : {
      "en" : { "stringUnit" : { "state" : "translated", "value" : "Collect data for a personal model" } },
      "tr" : { "stringUnit" : { "state" : "translated", "value" : "Kişisel model için veri topla" } } } },
    "training.progress" : { "localizations" : {
      "en" : { "stringUnit" : { "state" : "translated", "value" : "%1$lld of %2$lld minutes collected" } },
      "tr" : { "stringUnit" : { "state" : "translated", "value" : "%1$lld / %2$lld dakika toplandı" } } } },
    "training.footer" : { "localizations" : {
      "en" : { "stringUnit" : { "state" : "translated", "value" : "Dictations transcribed in the cloud are saved on this Mac with their transcript, to train a model on your voice later. Nothing extra is uploaded." } },
      "tr" : { "stringUnit" : { "state" : "translated", "value" : "Bulutta çözülen dikteler metinleriyle birlikte bu Mac'e kaydedilir ve ileride sesine özel bir model eğitmek için kullanılır. Buluta ek bir şey gönderilmez." } } } },
    "training.needsCloud" : { "localizations" : {
      "en" : { "stringUnit" : { "state" : "translated", "value" : "Needs cloud transcription: on-device transcripts are not reliable enough to learn from." } },
      "tr" : { "stringUnit" : { "state" : "translated", "value" : "Bulut transkripsiyonu gerekir: cihaz içi metinler öğrenmek için yeterince güvenilir değil." } } } },
    "training.deleteAll" : { "localizations" : {
      "en" : { "stringUnit" : { "state" : "translated", "value" : "Delete All Collected Data…" } },
      "tr" : { "stringUnit" : { "state" : "translated", "value" : "Toplanan Tüm Verileri Sil…" } } } },
    "training.deleteConfirm.title" : { "localizations" : {
      "en" : { "stringUnit" : { "state" : "translated", "value" : "Delete all collected data?" } },
      "tr" : { "stringUnit" : { "state" : "translated", "value" : "Toplanan tüm veriler silinsin mi?" } } } },
    "training.deleteConfirm.message" : { "localizations" : {
      "en" : { "stringUnit" : { "state" : "translated", "value" : "All saved recordings and transcripts are removed from this Mac. This can't be undone." } },
      "tr" : { "stringUnit" : { "state" : "translated", "value" : "Kaydedilen tüm sesler ve metinler bu Mac'ten silinir. Bu işlem geri alınamaz." } } } },
    "common.delete" : { "localizations" : {
      "en" : { "stringUnit" : { "state" : "translated", "value" : "Delete" } },
      "tr" : { "stringUnit" : { "state" : "translated", "value" : "Sil" } } } },
    "common.cancel" : { "localizations" : {
      "en" : { "stringUnit" : { "state" : "translated", "value" : "Cancel" } },
      "tr" : { "stringUnit" : { "state" : "translated", "value" : "Vazgeç" } } } }
  }
}
```

`Support/Info.plist`: add inside the top-level `<dict>`:

```xml
	<key>CFBundleLocalizations</key>
	<array>
		<string>en</string>
		<string>tr</string>
	</array>
```

`scripts/bundle.sh`: after the `cp "$ROOT/Support/Info.plist" …` line, add:

```sh
# Localized strings live in the NozomiFlowKit resource bundle. Bundle.module traps
# when it can't find it, so a missing bundle must fail the build, not the app.
RES_BUNDLE="$(swift build -c "$CONF" --show-bin-path)/NozomiFlow_NozomiFlowKit.bundle"
if [ ! -d "$RES_BUNDLE" ]; then
  echo "error: resource bundle not found at $RES_BUNDLE" >&2
  exit 1
fi
cp -R "$RES_BUNDLE" "$APP/Contents/Resources/"
```

- [ ] **Step 4: Run to verify they pass**

Run: `swift test 2>&1 | grep -E "error:|Test Suite 'All tests'" -A1 | tail -3`
Expected: all tests pass (previous 145 + 3 new).

- [ ] **Step 5: Verify the built app finds the bundle**

Run: `scripts/bundle.sh release && ls build/NozomiFlow.app/Contents/Resources/NozomiFlow_NozomiFlowKit.bundle/Contents/Resources/`
Expected: `en.lproj` and `tr.lproj` listed. The launch check that Turkish actually shows happens in Task 5, once a localized screen exists.

- [ ] **Step 6: Commit**

```bash
git add Package.swift Sources/NozomiFlowKit/Resources Sources/NozomiFlowKit/Support/L10n.swift scripts/bundle.sh Support/Info.plist Tests/NozomiFlowKitTests/LocalizationTests.swift
git commit -m "feat(l10n): add English/Turkish string catalog and ship its bundle

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 2: Expose the uploaded audio on the transcription outcome

**Files:**
- Modify: `Sources/NozomiFlowKit/App/Models.swift:77-81`
- Modify: `Sources/NozomiFlowKit/Core/Transcription/TranscriptionEngine.swift` (`endSession`)
- Test: `Tests/NozomiFlowKitTests/CloudTranscriptionTests.swift`

**Interfaces:**
- Produces: `TranscriptionOutcome.audio: [Int16]?`, 16 kHz mono samples, non-nil only when the text came from the cloud session. `static func TranscriptionEngine.uploadedAudio(from session: any TranscriptionBackendSession) -> [Int16]?`.

- [ ] **Step 1: Write the failing tests**

Append to `CloudTranscriptionTests`:

```swift
    // MARK: - Audio handed to training

    func testUploadedAudioIsTheCloudSessionsRecordedSamples() throws {
        let session = try XCTUnwrap(CloudTranscriptionSession(
            config: CloudTranscriptionConfig(isEnabled: true, apiKey: "k"),
            locale: Locale(identifier: "tr_TR")
        ))
        let samples: [Int16] = (0..<16_000).map { Int16(truncatingIfNeeded: $0) }
        for buffer in CloudTranscriptionSession.buffers(from: samples) { session.accept(buffer) }

        XCTAssertEqual(TranscriptionEngine.uploadedAudio(from: session), samples)
    }

    func testOnDeviceSessionsHaveNoUploadedAudio() {
        XCTAssertNil(TranscriptionEngine.uploadedAudio(from: FakeLocalSession()))
    }
```

and at the bottom of the file:

```swift
private final class FakeLocalSession: TranscriptionBackendSession, @unchecked Sendable {
    var onPartial: (@Sendable (String) -> Void)?
    let engineKind: TranscriptionEngineKind = .dictation
    let resolvedLocaleIdentifier = "tr_TR"
    func accept(_ buffer: AVAudioPCMBuffer) {}
    func finish() async throws -> String { "" }
    func cancel() {}
    func snapshotText() -> String { "" }
}
```

(Add `import AVFAudio` at the top of the test file if it is not there. If `CloudTranscriptionConfig`'s memberwise init needs every property, pass the existing defaults explicitly; check `CloudTranscriptionTests.testConfigIsUnusableUntilEnabledAndKeyed` for how the file builds a config and copy that.)

- [ ] **Step 2: Run to verify they fail**

Run: `swift test --filter CloudTranscriptionTests 2>&1 | grep -E "error|Executed"`
Expected: `type 'TranscriptionEngine' has no member 'uploadedAudio'`.

- [ ] **Step 3: Implement**

`Models.swift`:

```swift
struct TranscriptionOutcome: Equatable {
    var text: String
    var localeIdentifier: String?
    var engine: TranscriptionEngineKind
    /// The exact 16 kHz mono PCM16 audio that was uploaded, when `text` came from
    /// the cloud. nil for on-device results, including an on-device rescue of a
    /// failed cloud request: those transcripts are not trustworthy training labels.
    var audio: [Int16]? = nil
}
```

`TranscriptionEngine.swift`: add next to `replayOnDevice`:

```swift
    /// The audio a cloud session uploaded, for training samples; nil for any
    /// on-device session.
    static func uploadedAudio(from session: any TranscriptionBackendSession) -> [Int16]? {
        guard let cloud = session as? CloudTranscriptionSession else { return nil }
        let samples = cloud.recordedSamples()
        return samples.isEmpty ? nil : samples
    }
```

and change the last line of `endSession` (the normal-path return, after the replay and timeout checks) to:

```swift
        return TranscriptionOutcome(
            text: text, localeIdentifier: session.resolvedLocaleIdentifier,
            engine: session.engineKind, audio: Self.uploadedAudio(from: session)
        )
```

The replay path keeps returning an outcome without audio.

- [ ] **Step 4: Run to verify they pass**

Run: `swift test 2>&1 | grep -E "error:|Test Suite 'All tests'" -A1 | tail -3`
Expected: all pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/NozomiFlowKit/App/Models.swift Sources/NozomiFlowKit/Core/Transcription/TranscriptionEngine.swift Tests/NozomiFlowKitTests/CloudTranscriptionTests.swift
git commit -m "feat(training): carry the uploaded cloud audio on the transcription outcome

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 3: Training sample model, eligibility and store

**Files:**
- Create: `Sources/NozomiFlowKit/Core/Training/TrainingSample.swift`
- Create: `Sources/NozomiFlowKit/Core/Training/TrainingSampleStore.swift`
- Test: `Tests/NozomiFlowKitTests/TrainingSampleTests.swift`, `Tests/NozomiFlowKitTests/TrainingSampleStoreTests.swift`

**Interfaces:**
- Consumes: `TranscriptionOutcome.audio` (Task 2), `SessionMode`, `TranscriptionEngineKind`, `CloudTranscriptionSession.makeWAV(samples:sampleRate:)`.
- Produces:
  - `struct TrainingSample: Codable, Equatable, Identifiable` with `id: UUID`, `createdAt: Date`, `durationSeconds: Double`, `appBundleID: String?`, `labelSource: String`, `rawLabel: String`, `label: String`, `status: TrainingSample.Status`; `enum Status: String, Codable { case unchecked, agreed, pending, corrected, verified, uncertain }`; `static func make(rawLabel:audioSampleCount:appBundleID:labelSource:) -> TrainingSample`.
  - `enum TrainingSampleEligibility { static let minimumSeconds: Double; static func accepts(enabled: Bool, mode: SessionMode, outcome: TranscriptionOutcome) -> Bool }`.
  - `final class TrainingSampleStore: @unchecked Sendable` with `init(directory: URL = TrainingSampleStore.defaultDirectory)`, `static var defaultDirectory: URL`, `func save(_ sample: TrainingSample, audio: [Int16]) throws`, `func loadAll() -> [TrainingSample]`, `func update(_ sample: TrainingSample) throws`, `func audioURL(for id: UUID) -> URL`, `func totalDurationSeconds() -> Double`, `func deleteAll() throws`, `func removeIncomplete()`.

- [ ] **Step 1: Write the failing eligibility tests**

`Tests/NozomiFlowKitTests/TrainingSampleTests.swift`:

```swift
import XCTest
@testable import NozomiFlowKit

/// Which dictations become training data. A wrong "yes" teaches the model a bad
/// label; the worst case is an on-device rescue of a failed cloud request.
final class TrainingSampleTests: XCTestCase {

    private func cloudOutcome(seconds: Double = 3, text: String = "merhaba dünya") -> TranscriptionOutcome {
        TranscriptionOutcome(text: text, localeIdentifier: "tr_TR", engine: .cloud,
                             audio: Array(repeating: 1, count: Int(seconds * 16_000)))
    }

    func testCloudDictationIsASample() {
        XCTAssertTrue(TrainingSampleEligibility.accepts(enabled: true, mode: .dictation, outcome: cloudOutcome()))
    }

    func testNothingIsCollectedWhileDisabled() {
        XCTAssertFalse(TrainingSampleEligibility.accepts(enabled: false, mode: .dictation, outcome: cloudOutcome()))
    }

    func testCommandModeIsNotASample() {
        XCTAssertFalse(TrainingSampleEligibility.accepts(enabled: true, mode: .command, outcome: cloudOutcome()))
    }

    func testLocalEngineOutcomeIsNotASample() {
        var outcome = cloudOutcome()
        outcome.engine = .dictation // e.g. the on-device rescue after a failed upload
        XCTAssertFalse(TrainingSampleEligibility.accepts(enabled: true, mode: .dictation, outcome: outcome))
    }

    func testOutcomeWithoutAudioIsNotASample() {
        var outcome = cloudOutcome()
        outcome.audio = nil
        XCTAssertFalse(TrainingSampleEligibility.accepts(enabled: true, mode: .dictation, outcome: outcome))
    }

    func testUnderOneSecondIsNotASample() {
        XCTAssertFalse(TrainingSampleEligibility.accepts(enabled: true, mode: .dictation, outcome: cloudOutcome(seconds: 0.9)))
    }

    func testBlankTranscriptIsNotASample() {
        XCTAssertFalse(TrainingSampleEligibility.accepts(enabled: true, mode: .dictation, outcome: cloudOutcome(text: "  \n")))
    }

    func testNewSampleStartsUncheckedWithLabelEqualToRaw() {
        let sample = TrainingSample.make(rawLabel: "selam", audioSampleCount: 32_000,
                                         appBundleID: "com.apple.TextEdit", labelSource: "m")
        XCTAssertEqual(sample.status, .unchecked)
        XCTAssertEqual(sample.label, "selam")
        XCTAssertEqual(sample.durationSeconds, 2, accuracy: 0.001)
    }
}
```

- [ ] **Step 2: Run to verify they fail**

Run: `swift test --filter TrainingSampleTests 2>&1 | grep -E "error|Executed"`
Expected: `cannot find 'TrainingSampleEligibility' in scope`.

- [ ] **Step 3: Implement `TrainingSample.swift`**

```swift
import Foundation

/// One dictation kept for training: the uploaded audio (stored beside this as
/// `<id>.wav`) and its transcript. `rawLabel` is what the cloud returned, before
/// dictionary rules and AI cleanup; `label` is the current best transcript, which
/// the review flow (phase 2) corrects.
struct TrainingSample: Codable, Equatable, Identifiable {
    enum Status: String, Codable {
        case unchecked, agreed, pending, corrected, verified, uncertain
    }

    static let sampleRate = 16_000

    var id: UUID
    var createdAt: Date
    var durationSeconds: Double
    var appBundleID: String?
    var labelSource: String
    var rawLabel: String
    var label: String
    var status: Status

    static func make(rawLabel: String, audioSampleCount: Int, appBundleID: String?, labelSource: String) -> TrainingSample {
        TrainingSample(
            id: UUID(), createdAt: Date(),
            durationSeconds: Double(audioSampleCount) / Double(sampleRate),
            appBundleID: appBundleID, labelSource: labelSource,
            rawLabel: rawLabel, label: rawLabel, status: .unchecked
        )
    }
}

/// Which finished dictations become samples. Pure, so the rule is testable
/// without a coordinator.
enum TrainingSampleEligibility {
    static let minimumSeconds = 1.0

    static func accepts(enabled: Bool, mode: SessionMode, outcome: TranscriptionOutcome) -> Bool {
        guard enabled, mode == .dictation, outcome.engine == .cloud, let audio = outcome.audio else { return false }
        guard Double(audio.count) / Double(TrainingSample.sampleRate) >= minimumSeconds else { return false }
        return !outcome.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
```

- [ ] **Step 4: Run to verify they pass**

Run: `swift test --filter TrainingSampleTests 2>&1 | grep -E "error|Executed"`
Expected: `Executed 8 tests, with 0 failures`.

- [ ] **Step 5: Write the failing store tests**

`Tests/NozomiFlowKitTests/TrainingSampleStoreTests.swift`:

```swift
import XCTest
@testable import NozomiFlowKit

/// The on-disk sample set. It has to survive the app being killed mid-write
/// without leaving anything that later reads as a sample.
final class TrainingSampleStoreTests: XCTestCase {

    private var dir: URL!
    private var store: TrainingSampleStore!

    override func setUp() {
        super.setUp()
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("training-tests-\(UUID().uuidString)")
        store = TrainingSampleStore(directory: dir)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: dir)
        super.tearDown()
    }

    private func sample(seconds: Double = 2, text: String = "selam") -> (TrainingSample, [Int16]) {
        let audio = [Int16](repeating: 7, count: Int(seconds * 16_000))
        return (TrainingSample.make(rawLabel: text, audioSampleCount: audio.count, appBundleID: nil, labelSource: "m"), audio)
    }

    func testSavedSampleRoundTripsWithItsAudio() throws {
        let (s, audio) = sample()
        try store.save(s, audio: audio)

        XCTAssertEqual(store.loadAll(), [s])
        let wav = try Data(contentsOf: store.audioURL(for: s.id))
        XCTAssertEqual(wav, CloudTranscriptionSession.makeWAV(samples: audio, sampleRate: 16_000))
    }

    func testSamplesListOldestFirst() throws {
        var (a, audio) = sample(text: "a")
        var (b, _) = sample(text: "b")
        a.createdAt = Date(timeIntervalSince1970: 200)
        b.createdAt = Date(timeIntervalSince1970: 100)
        try store.save(a, audio: audio)
        try store.save(b, audio: audio)

        XCTAssertEqual(store.loadAll().map(\.rawLabel), ["b", "a"])
    }

    func testUpdateReplacesTheLabelAndStatus() throws {
        var (s, audio) = sample()
        try store.save(s, audio: audio)
        s.label = "selam dünya"
        s.status = .corrected
        try store.update(s)

        XCTAssertEqual(store.loadAll().first?.label, "selam dünya")
        XCTAssertEqual(store.loadAll().first?.status, .corrected)
    }

    func testTotalDurationAddsUpEverySample() throws {
        let (a, audioA) = sample(seconds: 2)
        let (b, audioB) = sample(seconds: 3.5)
        try store.save(a, audio: audioA)
        try store.save(b, audio: audioB)

        XCTAssertEqual(store.totalDurationSeconds(), 5.5, accuracy: 0.001)
    }

    func testSampleWithoutJSONIsNotListed() throws {
        let (s, audio) = sample()
        try store.save(s, audio: audio)
        try FileManager.default.removeItem(at: dir.appendingPathComponent("\(s.id.uuidString).json"))

        XCTAssertEqual(store.loadAll(), [])
    }

    func testIncompleteSamplesAreRemoved() throws {
        let (s, audio) = sample()
        try store.save(s, audio: audio)
        // Killed after the WAV was written, before the JSON rename:
        let orphan = dir.appendingPathComponent("\(UUID().uuidString).wav")
        try Data([1, 2, 3]).write(to: orphan)
        let tmp = dir.appendingPathComponent("\(UUID().uuidString).json.tmp")
        try Data("{".utf8).write(to: tmp)

        store.removeIncomplete()

        XCTAssertFalse(FileManager.default.fileExists(atPath: orphan.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: tmp.path))
        XCTAssertEqual(store.loadAll(), [s], "a complete sample must survive the cleanup")
    }

    func testCorruptJSONIsSkippedNotFatal() throws {
        let (s, audio) = sample()
        try store.save(s, audio: audio)
        try Data("not json".utf8).write(to: dir.appendingPathComponent("\(UUID().uuidString).json"))

        XCTAssertEqual(store.loadAll(), [s])
    }

    func testDeleteAllEmptiesTheStore() throws {
        let (s, audio) = sample()
        try store.save(s, audio: audio)
        try store.deleteAll()

        XCTAssertEqual(store.loadAll(), [])
        XCTAssertEqual(store.totalDurationSeconds(), 0)
    }

    func testSaveIntoUnwritableDirectoryThrowsInsteadOfCrashing() throws {
        let blocker = FileManager.default.temporaryDirectory.appendingPathComponent("blocker-\(UUID().uuidString)")
        try Data().write(to: blocker) // a file where the directory should be
        defer { try? FileManager.default.removeItem(at: blocker) }
        let broken = TrainingSampleStore(directory: blocker)
        let (s, audio) = sample()

        XCTAssertThrowsError(try broken.save(s, audio: audio))
    }
}
```

- [ ] **Step 6: Run to verify they fail**

Run: `swift test --filter TrainingSampleStoreTests 2>&1 | grep -E "error|Executed"`
Expected: `cannot find 'TrainingSampleStore' in scope`.

- [ ] **Step 7: Implement `TrainingSampleStore.swift`**

```swift
import Foundation

/// Training samples on disk: `<id>.wav` (16 kHz mono PCM16, as uploaded) plus
/// `<id>.json`. The WAV is written first and the JSON last, via a temp file and
/// rename, so a sample only exists once both are complete; anything else is
/// debris from an interrupted write and `removeIncomplete` deletes it.
///
/// Thread-safe: saves run off the main actor while Settings reads totals.
final class TrainingSampleStore: @unchecked Sendable {

    static var defaultDirectory: URL {
        // Still "Murmur" after the rename to Nozomi Flow, like the other stores.
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Murmur/Training", isDirectory: true)
    }

    private let directory: URL
    private let lock = NSLock()
    private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }()
    private let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    init(directory: URL = TrainingSampleStore.defaultDirectory) {
        self.directory = directory
    }

    func audioURL(for id: UUID) -> URL {
        directory.appendingPathComponent("\(id.uuidString).wav")
    }

    private func jsonURL(for id: UUID) -> URL {
        directory.appendingPathComponent("\(id.uuidString).json")
    }

    func save(_ sample: TrainingSample, audio: [Int16]) throws {
        lock.lock(); defer { lock.unlock() }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let wav = CloudTranscriptionSession.makeWAV(samples: audio, sampleRate: TrainingSample.sampleRate)
        try wav.write(to: audioURL(for: sample.id), options: .atomic)
        try writeJSONLocked(sample)
    }

    func update(_ sample: TrainingSample) throws {
        lock.lock(); defer { lock.unlock() }
        try writeJSONLocked(sample)
    }

    func loadAll() -> [TrainingSample] {
        lock.lock(); defer { lock.unlock() }
        return loadAllLocked()
    }

    func totalDurationSeconds() -> Double {
        loadAll().reduce(0) { $0 + $1.durationSeconds }
    }

    func deleteAll() throws {
        lock.lock(); defer { lock.unlock() }
        guard FileManager.default.fileExists(atPath: directory.path) else { return }
        try FileManager.default.removeItem(at: directory)
    }

    /// Deletes WAVs without a JSON and leftover temp files. Call once at launch.
    func removeIncomplete() {
        lock.lock(); defer { lock.unlock() }
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        let complete = Set(files.filter { $0.pathExtension == "json" }.map { $0.deletingPathExtension().lastPathComponent })
        for file in files {
            let isTemp = file.lastPathComponent.hasSuffix(".json.tmp")
            let isOrphanAudio = file.pathExtension == "wav" && !complete.contains(file.deletingPathExtension().lastPathComponent)
            if isTemp || isOrphanAudio {
                try? FileManager.default.removeItem(at: file)
            }
        }
    }

    // MARK: - Locked helpers

    private func writeJSONLocked(_ sample: TrainingSample) throws {
        let data = try encoder.encode(sample)
        let final = jsonURL(for: sample.id)
        let temp = final.appendingPathExtension("tmp")
        try data.write(to: temp)
        if FileManager.default.fileExists(atPath: final.path) {
            _ = try FileManager.default.replaceItemAt(final, withItemAt: temp)
        } else {
            try FileManager.default.moveItem(at: temp, to: final)
        }
    }

    private func loadAllLocked() -> [TrainingSample] {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return files
            .filter { $0.pathExtension == "json" }
            .compactMap { try? decoder.decode(TrainingSample.self, from: Data(contentsOf: $0)) }
            .filter { FileManager.default.fileExists(atPath: audioURL(for: $0.id).path) }
            .sorted { $0.createdAt < $1.createdAt }
    }
}
```

Note `jsonURL(for:)` ends in `.json`, so `appendingPathExtension("tmp")` yields `<id>.json.tmp`, matching the cleanup rule. `loadAllLocked` also drops a JSON whose WAV is missing, so a sample is listed only when both files exist.

- [ ] **Step 8: Run to verify they pass**

Run: `swift test 2>&1 | grep -E "error:|Test Suite 'All tests'" -A1 | tail -3`
Expected: all pass.

- [ ] **Step 9: Commit**

```bash
git add Sources/NozomiFlowKit/Core/Training Tests/NozomiFlowKitTests/TrainingSampleTests.swift Tests/NozomiFlowKitTests/TrainingSampleStoreTests.swift
git commit -m "feat(training): add training sample model, eligibility rule and disk store

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 4: Setting and coordinator hook

**Files:**
- Modify: `Sources/NozomiFlowKit/Core/Settings/SettingsStore.swift`
- Modify: `Sources/NozomiFlowKit/App/DictationCoordinator.swift`
- Modify: `Sources/NozomiFlowKit/App/NozomiFlowMain.swift`
- Test: `Tests/NozomiFlowKitTests/TrainingSampleTests.swift` (setting persistence)

**Interfaces:**
- Consumes: `TrainingSampleEligibility.accepts`, `TrainingSample.make`, `TrainingSampleStore.save/removeIncomplete` (Task 3), `TranscriptionOutcome.audio` (Task 2).
- Produces: `SettingsStore.collectTrainingData: Bool` (UserDefaults key `collectTrainingData`, default `false`). `DictationCoordinator.init` gains a trailing `trainingStore: TrainingSampleStore` parameter.

- [ ] **Step 1: Write the failing test**

Append to `TrainingSampleTests`:

```swift
    @MainActor
    func testCollectionSettingIsOffByDefaultAndPersists() throws {
        let suite = "training-settings-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let first = SettingsStore(defaults: defaults)
        XCTAssertFalse(first.collectTrainingData)
        first.collectTrainingData = true

        XCTAssertTrue(SettingsStore(defaults: defaults).collectTrainingData)
    }
```

- [ ] **Step 2: Run to verify it fails**

Run: `swift test --filter TrainingSampleTests 2>&1 | grep -E "error|Executed"`
Expected: `value of type 'SettingsStore' has no member 'collectTrainingData'`.

- [ ] **Step 3: Implement the setting**

In `SettingsStore`, after the cloud transcription properties:

```swift
    // MARK: - Personal model

    /// Saves cloud-transcribed dictations as training samples. Off by default.
    var collectTrainingData: Bool = false {
        didSet { persist(collectTrainingData, "collectTrainingData") }
    }
```

and in `load()`, next to the other bools:

```swift
        if defaults.object(forKey: "collectTrainingData") != nil {
            collectTrainingData = defaults.bool(forKey: "collectTrainingData")
        }
```

- [ ] **Step 4: Run to verify it passes**

Run: `swift test --filter TrainingSampleTests 2>&1 | grep -E "error|Executed"`
Expected: `Executed 9 tests, with 0 failures`.

- [ ] **Step 5: Hook the coordinator**

In `DictationCoordinator`:

1. Add a stored property `private let trainingStore: TrainingSampleStore`, a trailing init parameter `trainingStore: TrainingSampleStore`, and `self.trainingStore = trainingStore` in the init body.
2. In `finishDictation`, right after the `recordHistory(...)` call and before `succeed(with: text)`, add `collectTrainingSample(raw: raw, outcome: outcome)`.
3. Add the method next to `recordHistory`:

```swift
    /// Hands an eligible dictation to the training store. Runs after insertion and
    /// off the main actor, so a slow or failing disk never touches the dictation.
    private func collectTrainingSample(raw: String, outcome: TranscriptionOutcome) {
        guard TrainingSampleEligibility.accepts(
            enabled: settings.collectTrainingData, mode: .dictation, outcome: outcome
        ), let audio = outcome.audio else { return }
        let sample = TrainingSample.make(
            rawLabel: raw, audioSampleCount: audio.count,
            appBundleID: pendingContext?.bundleID, labelSource: settings.cloudTranscriptionModel
        )
        let store = trainingStore
        Task.detached(priority: .utility) {
            do {
                try store.save(sample, audio: audio)
            } catch {
                Log.app.error("training sample not saved: \(error.localizedDescription, privacy: .public)")
            }
        }
    }
```

`raw` here is the trimmed cloud text before dictionary rules and formatting, which is the label the spec asks for.

- [ ] **Step 6: Wire it in `AppDelegate`**

In `NozomiFlowMain.swift`: add `private var trainingStore: TrainingSampleStore!`; in `applicationDidFinishLaunching`, before creating the coordinator:

```swift
        trainingStore = TrainingSampleStore()
        let store = trainingStore!
        Task.detached(priority: .utility) { store.removeIncomplete() }
```

and pass `trainingStore: trainingStore` as the last argument of `DictationCoordinator(...)`.

- [ ] **Step 7: Build and run the full suite**

Run: `swift build 2>&1 | grep -E "error" ; swift test 2>&1 | grep -E "error:|Test Suite 'All tests'" -A1 | tail -3`
Expected: no build errors; all tests pass.

- [ ] **Step 8: Commit**

```bash
git add Sources/NozomiFlowKit/Core/Settings/SettingsStore.swift Sources/NozomiFlowKit/App/DictationCoordinator.swift Sources/NozomiFlowKit/App/NozomiFlowMain.swift Tests/NozomiFlowKitTests/TrainingSampleTests.swift
git commit -m "feat(training): save eligible cloud dictations as training samples

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 5: "Personal model" section in Settings, and end-to-end check

**Files:**
- Create: `Sources/NozomiFlowKit/UI/Settings/PersonalModelSection.swift`
- Modify: `Sources/NozomiFlowKit/UI/Settings/GeneralSettingsView.swift`
- Modify: `Sources/NozomiFlowKit/UI/Settings/SettingsRootView.swift`
- Modify: `Sources/NozomiFlowKit/UI/Settings/SettingsWindowController.swift`
- Modify: `Sources/NozomiFlowKit/App/NozomiFlowMain.swift`

**Interfaces:**
- Consumes: `L10n.string/format` and keys (Task 1), `SettingsStore.collectTrainingData` and `cloudTranscriptionEnabled`, `TrainingSampleStore.totalDurationSeconds/deleteAll` (Task 3).
- Produces: `struct PersonalModelSection: View` with `init(settings: SettingsStore, store: TrainingSampleStore)`; `static let targetMinutes = 90`.

This task is UI wiring with no new logic worth a unit test (the numbers come from `totalDurationSeconds`, already tested). It is verified by running the app.

- [ ] **Step 1: Create the section**

`Sources/NozomiFlowKit/UI/Settings/PersonalModelSection.swift`:

```swift
import SwiftUI

/// Settings > General > Personal model: the collection toggle, progress toward
/// the training target, and deleting what was collected.
struct PersonalModelSection: View {
    static let targetMinutes = 90

    @Bindable var settings: SettingsStore
    let store: TrainingSampleStore

    @State private var collectedMinutes = 0
    @State private var confirmingDelete = false

    var body: some View {
        Section {
            Toggle(L10n.string("training.toggle"), isOn: $settings.collectTrainingData)
            Text(L10n.format("training.progress", collectedMinutes, Self.targetMinutes))
                .foregroundStyle(.secondary)
            Button(L10n.string("training.deleteAll"), role: .destructive) {
                confirmingDelete = true
            }
            .disabled(collectedMinutes == 0)
        } header: {
            Text(L10n.string("training.header"))
        } footer: {
            Text(L10n.string(settings.cloudTranscriptionEnabled ? "training.footer" : "training.needsCloud"))
        }
        .task { refresh() }
        .confirmationDialog(
            L10n.string("training.deleteConfirm.title"),
            isPresented: $confirmingDelete
        ) {
            Button(L10n.string("common.delete"), role: .destructive) {
                try? store.deleteAll()
                refresh()
            }
            Button(L10n.string("common.cancel"), role: .cancel) {}
        } message: {
            Text(L10n.string("training.deleteConfirm.message"))
        }
    }

    private func refresh() {
        collectedMinutes = Int(store.totalDurationSeconds() / 60)
    }
}
```

`L10n.format` takes `CVarArg...`; pass `collectedMinutes` and `Self.targetMinutes` as `Int`, which matches `%lld` on 64-bit.

- [ ] **Step 2: Pass the store through Settings**

- `SettingsWindowController`: add `private let trainingStore: TrainingSampleStore`, a matching init parameter, and pass `trainingStore: trainingStore` into `SettingsRootView(...)`.
- `SettingsRootView`: add `let trainingStore: TrainingSampleStore` and pass it where `GeneralSettingsView(settings:)` is built: `GeneralSettingsView(settings: settings, trainingStore: trainingStore)`.
- `GeneralSettingsView`: add `let trainingStore: TrainingSampleStore` and, as the last child of the `Form` (after the "Behavior" section), `PersonalModelSection(settings: settings, store: trainingStore)`.
- `AppDelegate`: pass `trainingStore: trainingStore` to `SettingsWindowController(...)`.

- [ ] **Step 3: Build and run the full suite**

Run: `swift build 2>&1 | grep -E "error" ; swift test 2>&1 | grep -E "error:|Test Suite 'All tests'" -A1 | tail -3`
Expected: no errors; all tests pass.

- [ ] **Step 4: Install and verify by hand**

```bash
scripts/bundle.sh release && pkill -x NozomiFlow; rm -rf /Applications/NozomiFlow.app && cp -R build/NozomiFlow.app /Applications/ && open /Applications/NozomiFlow.app
```

The ad-hoc signature resets Accessibility and Microphone permissions; re-grant them as before. Then check:

1. Menu bar → Settings → General: the last section reads **Kişisel model** with the toggle **Kişisel model için veri topla** (system language is Turkish). The app did not crash when opening Settings (Review Focus 4).
2. Turn the toggle on. With cloud transcription on, dictate 2–3 sentences of more than a second each with the dictation key.
3. `ls ~/Library/Application\ Support/Murmur/Training/` shows one `.wav` + `.json` pair per dictation; `cat` one JSON and confirm `rawLabel` is the text you said, `status` is `unchecked`.
4. `afinfo` on one WAV shows `1 ch, 16000 Hz, 'lpcm' 16-bit`.
5. Reopen Settings: the progress line shows the collected minutes (0 until a minute accumulates).
6. A command-mode dictation (right ⌘) adds no files.
7. Delete all → confirm → the folder is gone and the button is disabled.
8. Turn the toggle back on for real use.

- [ ] **Step 5: Commit**

```bash
git add Sources/NozomiFlowKit/UI/Settings Sources/NozomiFlowKit/App/NozomiFlowMain.swift
git commit -m "feat(training): add localized Personal model section to Settings

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```
