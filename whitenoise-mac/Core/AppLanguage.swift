import Foundation
import os

nonisolated enum AppLanguage: String, CaseIterable, Identifiable {
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
    // The generation token prevents a cache-miss resolver from publishing a stale
    // `UserDefaults` read if `refreshCachedLocale()` updates the preference while
    // resolution happens outside the lock.
    private struct LocaleCache {
        var locale: Locale?
        var twelveHourLocale: Locale?
        var generation: UInt64 = 0
    }

    private static let cachedLocale = OSAllocatedUnfairLock<LocaleCache>(initialState: LocaleCache())

    #if DEBUG
        private static let systemLocaleOverride = OSAllocatedUnfairLock<Locale?>(initialState: nil)

        static func setSystemLocaleOverrideForTesting(_ locale: Locale?) {
            systemLocaleOverride.withLock { $0 = locale }
        }
    #endif

    static var currentLocale: Locale {
        currentLocalePair.locale
    }

    /// The selected locale with a forced 12-hour clock, cached alongside `currentLocale` so
    /// per-message timestamp formatting does not rebuild `Locale.Components` on the hot path.
    static var currentTwelveHourLocale: Locale {
        currentLocalePair.twelveHourLocale
    }

    static func twelveHourLocale(for locale: Locale) -> Locale {
        let pair = currentLocalePair
        guard locale.identifier != pair.locale.identifier else {
            return pair.twelveHourLocale
        }
        return makeTwelveHourLocale(from: locale)
    }

    private static var currentLocalePair: (locale: Locale, twelveHourLocale: Locale) {
        while true {
            let snapshot = cachedLocale.withLock { cache in
                (
                    locale: cache.locale,
                    twelveHourLocale: cache.twelveHourLocale,
                    generation: cache.generation
                )
            }
            if let locale = snapshot.locale,
                let twelveHourLocale = snapshot.twelveHourLocale
            {
                return (locale, twelveHourLocale)
            }

            let resolvedLocale = resolvedLocaleFromDefaults()
            let resolvedTwelveHourLocale = makeTwelveHourLocale(from: resolvedLocale)
            if let pair = cachedLocale.withLock({ cache -> (Locale, Locale)? in
                if let locale = cache.locale,
                    let twelveHourLocale = cache.twelveHourLocale
                {
                    return (locale, twelveHourLocale)
                }
                guard cache.generation == snapshot.generation else {
                    return nil
                }
                cache.locale = resolvedLocale
                cache.twelveHourLocale = resolvedTwelveHourLocale
                return (resolvedLocale, resolvedTwelveHourLocale)
            }) {
                return pair
            }
        }
    }

    /// Recompute the cached locale from the stored language preference. Call this
    /// whenever the preference changes so `currentLocale` remains an
    /// allocation-free in-memory read in the common case. Also invalidates
    /// `L10n`'s cached `.lproj` bundle, which is keyed on the same preference.
    static func refreshCachedLocale() {
        let locale = resolvedLocaleFromDefaults()
        let twelveHourLocale = makeTwelveHourLocale(from: locale)
        cachedLocale.withLock { cache in
            cache.generation &+= 1
            cache.locale = locale
            cache.twelveHourLocale = twelveHourLocale
        }
        // The localized `.lproj` bundle is cached against this same preference,
        // so invalidate it here too (the single shared invalidation point).
        L10n.refreshCachedLocalizedBundle()
    }

    private static func makeTwelveHourLocale(from locale: Locale) -> Locale {
        var components = Locale.Components(locale: locale)
        components.hourCycle = .oneToTwelve
        return Locale(components: components)
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

    static func currentSystemLocaleIdentifier() -> String {
        systemLocale().identifier
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
