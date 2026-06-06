import Foundation

enum AppLanguage: String, CaseIterable, Identifiable {
    case system
    case english = "en"
    case german = "de"
    case spanish = "es"
    case french = "fr"
    case italian = "it"
    case portuguese = "pt"
    case russian = "ru"
    case turkish = "tr"
    case chineseSimplified = "zh-Hans"
    case chineseTraditional = "zh-Hant"

    static let storageKey = "whitenoise.mac.appearance.language"

    static var supportedAppLanguages: [AppLanguage] {
        [
            .english,
            .german,
            .spanish,
            .french,
            .italian,
            .portuguese,
            .russian,
            .turkish,
            .chineseSimplified,
            .chineseTraditional
        ]
    }

    static var pickerChoices: [AppLanguage] {
        [.system] + supportedAppLanguages
    }

    static var currentLocale: Locale {
        let rawValue = UserDefaults.standard.string(forKey: storageKey)
        return resolved(rawValue: rawValue).locale ?? .autoupdatingCurrent
    }

    static func resolved(rawValue: String?) -> AppLanguage {
        rawValue.flatMap(AppLanguage.init(rawValue:)) ?? .system
    }

    var id: String { rawValue }

    var locale: Locale? {
        switch self {
        case .system:
            nil
        default:
            Locale(identifier: rawValue)
        }
    }

    var displayName: String {
        switch self {
        case .system:
            L10n.string("System")
        case .english:
            "English"
        case .german:
            "Deutsch"
        case .spanish:
            "Español"
        case .french:
            "Français"
        case .italian:
            "Italiano"
        case .portuguese:
            "Português"
        case .russian:
            "Русский"
        case .turkish:
            "Türkçe"
        case .chineseSimplified:
            "简体中文"
        case .chineseTraditional:
            "繁體中文"
        }
    }
}
