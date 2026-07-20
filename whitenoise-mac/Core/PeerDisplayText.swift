import Foundation

/// Sanitization for peer-controlled strings shown as display names or group titles.
nonisolated enum PeerDisplayText {
    private static let firstStrongIsolate = "\u{2068}"
    private static let popDirectionalIsolate = "\u{2069}"

    /// Removes bidi embedding, override, and isolate controls (U+202A–U+202E,
    /// U+2066–U+2069) while preserving unrelated format characters such as ZWJ.
    static func strippingBidiControls(_ text: String) -> String {
        String(
            String.UnicodeScalarView(
                text.unicodeScalars.filter { scalar in
                    let value = scalar.value
                    if (0x202A...0x202E).contains(value) { return false }
                    if (0x2066...0x2069).contains(value) { return false }
                    return true
                })
        )
    }

    /// Strips Unicode format controls (`Cf`), control characters (`Cc`), and line/
    /// paragraph separators (`Zl`/`Zp`), including bidi embedding/override/isolate
    /// scalars (U+202A–U+202E, U+2066–U+2069), then treats an all-blank result as absent.
    static func sanitize(_ text: String?) -> String? {
        guard let text else { return nil }
        let filtered = String(
            String.UnicodeScalarView(
                text.unicodeScalars.filter { scalar in
                    switch scalar.properties.generalCategory {
                    case .format, .control, .lineSeparator, .paragraphSeparator:
                        return false
                    default:
                        return true
                    }
                })
        )
        return filtered.nilIfBlank
    }

    /// Sanitized text wrapped in first-strong isolate and PDI for safe `%@` interpolation.
    static func templateFragment(_ text: String) -> String {
        guard let core = sanitize(text) else { return "" }
        return firstStrongIsolate + core + popDirectionalIsolate
    }
}
