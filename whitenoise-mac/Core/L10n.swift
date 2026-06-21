import Foundation

enum L10n {
    static func string(_ key: String) -> String {
        if let localizedBundle = localizedBundle(for: AppLanguage.currentLocale) {
            let localized = localizedBundle.localizedString(forKey: key, value: nil, table: nil)
            if localized != key {
                return localized
            }
        }

        return Bundle.main.localizedString(forKey: key, value: key, table: nil)
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
