import Foundation
import os

enum L10n {
    // `string(_:)` is invoked from the same render hot paths as
    // `AppLanguage.currentLocale` (SwiftUI view bodies that re-evaluate
    // frequently, enum `label`/`title` computed properties, per-message
    // mapping). Resolving the language-specific `.lproj` bundle must not stat
    // the filesystem (`Bundle.main.path(forResource:ofType:)`) or allocate a
    // fresh `Bundle(path:)` on every call. We cache the resolved bundle in
    // memory and only recompute it when the stored language preference or
    // effective system locale changes. The cache is cleared from
    // `AppLanguage.refreshCachedLocale()` (the single invalidation point shared
    // with the cached locale), so it stays correct while the common-case read is
    // an allocation-free in-memory lookup.
    //
    // The outer optional distinguishes "not yet resolved" (`nil`) from "resolved,
    // no matching `.lproj` bundle" (`.some(nil)`), so a genuine miss (e.g. the
    // base/development language, which has no separate `.lproj`) is cached too
    // and not re-statted on every call. The unfair lock keeps the cache safe if
    // `string(_:)` is ever touched off the main thread.
    private static let cachedLocalizedBundle = OSAllocatedUnfairLock<Bundle??>(initialState: nil)

    static func string(_ key: String) -> String {
        if let localizedBundle = currentLocalizedBundle() {
            let localized = localizedBundle.localizedString(forKey: key, value: nil, table: nil)
            if localized != key {
                return localized
            }
        }

        return Bundle.main.localizedString(forKey: key, value: key, table: nil)
    }

    /// Clear the cached localized bundle so the next `string(_:)` call re-resolves
    /// it for the current language preference. Called from
    /// `AppLanguage.refreshCachedLocale()` whenever the preference or effective
    /// system locale changes.
    static func refreshCachedLocalizedBundle() {
        cachedLocalizedBundle.withLock { $0 = nil }
    }

    private static func currentLocalizedBundle() -> Bundle? {
        cachedLocalizedBundle.withLock { cache in
            if let cache {
                return cache
            }
            let bundle = localizedBundle(for: AppLanguage.currentLocale)
            cache = .some(bundle)
            return bundle
        }
    }

    private static func localizedBundle(for locale: Locale) -> Bundle? {
        let identifier = locale.identifier.replacingOccurrences(of: "_", with: "-")
        let parts = identifier.split(separator: "-").map(String.init)
        var candidates = [identifier]
        if parts.count >= 2 {
            candidates.append("\(parts[0])-\(parts[1])")
        }
        if let language = parts.first {
            candidates.append(language)
        }

        for candidate in candidates {
            if let path = Bundle.main.path(forResource: candidate, ofType: "lproj"),
                let bundle = Bundle(path: path)
            {
                return bundle
            }
        }
        return nil
    }
}
