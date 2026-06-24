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
    // language preference or effective system locale changes. The unfair lock
    // keeps the cache safe if `currentLocale` is ever touched off the main thread.
    private static let cachedLocale = OSAllocatedUnfairLock<Locale?>(initialState: nil)

    #if DEBUG
        private static let systemLocaleOverride = OSAllocatedUnfairLock<Locale?>(initialState: nil)

        static func setSystemLocaleOverrideForTesting(_ locale: Locale?) {
            systemLocaleOverride.withLock { $0 = locale }
        }
    #endif

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
    /// allocation-free in-memory read in the common case. Also invalidates
    /// `L10n`'s cached `.lproj` bundle, which is keyed on the same preference.
    static func refreshCachedLocale() {
        let locale = resolvedLocaleFromDefaults()
        cachedLocale.withLock { $0 = locale }
        // The localized `.lproj` bundle is cached against this same preference,
        // so invalidate it here too (the single shared invalidation point).
        L10n.refreshCachedLocalizedBundle()
    }

    private static func resolvedLocaleFromDefaults() -> Locale {
        let rawValue = UserDefaults.standard.string(forKey: storageKey)
        let language = resolved(rawValue: rawValue)
        return language.locale ?? systemLocale()
    }

    private static func systemLocale() -> Locale {
        #if DEBUG
            if let override = systemLocaleOverride.withLock({ $0 }) {
                return override
            }
        #endif
        return .autoupdatingCurrent
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
