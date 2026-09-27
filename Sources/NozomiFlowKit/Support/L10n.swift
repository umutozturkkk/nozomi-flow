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
