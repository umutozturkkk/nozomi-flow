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
