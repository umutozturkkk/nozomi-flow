import Foundation

/// The languages offered in the UI, shared by Settings and first-run setup so both
/// ask the same question with the same options.
enum LocaleCatalog {

    struct Option: Identifiable {
        let identifier: String
        let label: String
        var id: String { identifier }
    }

    /// The on-device DictationTranscriber locale set (see SPEC.md ground truth).
    /// Cloud endpoints generally cover more, but offering a language the on-device
    /// fallback cannot handle would make a failed request unrecoverable.
    static let identifiers = [
        "en_US", "en_GB", "en_AU", "en_CA", "en_IN",
        "de_DE", "de_AT", "de_CH",
        "es_ES", "es_MX", "es_US", "es_CL",
        "fr_FR", "fr_CA", "fr_BE", "fr_CH",
        "it_IT", "it_CH",
        "pt_BR", "pt_PT",
        "ja_JP", "ko_KR",
        "zh_CN", "zh_TW", "zh_HK", "yue_CN",
        "tr_TR", "ar_SA", "ru_RU", "uk_UA", "pl_PL",
        "nl_NL", "nl_BE",
        "sv_SE", "da_DK", "nb_NO", "fi_FI",
        "cs_CZ", "sk_SK", "hu_HU", "ro_RO",
        "el_GR", "he_IL", "hi_IN", "th_TH", "vi_VN",
        "id_ID", "ms_MY", "ca_ES", "hr_HR",
    ]

    static let curated: [Option] = identifiers
        .map { id in
            Option(identifier: id, label: Locale.current.localizedString(forIdentifier: id) ?? id)
        }
        .sorted { $0.label.localizedStandardCompare($1.label) == .orderedAscending }
}
