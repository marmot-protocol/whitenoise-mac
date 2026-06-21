import Foundation
import os

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
            .chineseTraditional,
        ]
    }

    static var pickerChoices: [AppLanguage] {
        [.system] + supportedAppLanguages
    }

    // `currentLocale` is read from many hot paths (SwiftUI view bodies that
    // re-evaluate frequently, per-message mapping) on the main thread. Resolving
    // it must not read `UserDefaults` or allocate a `Locale` on every call. We
    // cache the resolved locale in memory and only recompute it when the stored
    // language preference actually changes. `refreshCachedLocale()` is invoked
    // from `WorkspaceState.languagePreference` (the only production writer of
    // `storageKey`) so the cache stays correct, while the common-case read is an
    // allocation-free in-memory lookup. The unfair lock keeps the cache safe if
    // `currentLocale` is ever touched off the main thread.
    private static let cachedLocale = OSAllocatedUnfairLock<Locale?>(initialState: nil)

    static var currentLocale: Locale {
        cachedLocale.withLock { cache in
            if let cache {
                return cache
            }
            let locale = resolvedLocaleFromDefaults()
            cache = locale
            return locale
        }
    }

    /// Recompute the cached locale from the stored language preference. Call this
    /// whenever the preference changes so `currentLocale` remains an
    /// allocation-free in-memory read in the common case.
    static func refreshCachedLocale() {
        let locale = resolvedLocaleFromDefaults()
        cachedLocale.withLock { $0 = locale }
    }

    private static func resolvedLocaleFromDefaults() -> Locale {
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
