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

    private static let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    private func catalogStrings() throws -> [String: [String: Any]] {
        let catalog = Self.repoRoot.appendingPathComponent("Sources/NozomiFlowKit/Resources/Localizable.xcstrings")
        let json = try JSONSerialization.jsonObject(with: Data(contentsOf: catalog)) as? [String: Any]
        return try XCTUnwrap(json?["strings"] as? [String: [String: Any]])
    }

    /// A key typed in code but missing from the catalog shows up as the raw key,
    /// and nothing else would catch the typo.
    func testEveryKeyUsedInCodeExistsInTheCatalog() throws {
        let strings = try catalogStrings()
        let pattern = try NSRegularExpression(pattern: #"L10n\.(?:string|format)\(\s*"([^"]+)""#)
        let sources = Self.repoRoot.appendingPathComponent("Sources")
        let files = FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil)!
            .compactMap { $0 as? URL }
            .filter { $0.pathExtension == "swift" }
        var used = 0
        for file in files {
            let text = try String(contentsOf: file, encoding: .utf8)
            for match in pattern.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                let key = String(text[Range(match.range(at: 1), in: text)!])
                used += 1
                XCTAssertNotNil(strings[key], "\(file.lastPathComponent) uses missing key \(key)")
            }
        }
        XCTAssertGreaterThan(used, 0)
    }

    func testEveryKeyHasEnglishAndTurkish() throws {
        let strings = try catalogStrings()
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
