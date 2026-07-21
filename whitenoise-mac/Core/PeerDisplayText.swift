import Foundation

/// Sanitization for peer-controlled strings shown as display names or group titles.
nonisolated enum PeerDisplayText {
    private static let firstStrongIsolate = "\u{2068}"
    private static let popDirectionalIsolate = "\u{2069}"

    /// Unicode bidi controls can reorder adjacent peer-controlled text even though they are
    /// invisible. Keep this list explicit so legitimate format scalars such as ZWJ/ZWNJ remain
    /// available to emoji sequences and scripts that require them.
    private static func isBidiControl(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x061C, 0x200E, 0x200F, 0x202A...0x202E, 0x2066...0x2069:
            true
        default:
            false
        }
    }

    /// Removes Unicode bidi controls while preserving unrelated format characters such as ZWJ.
    static func strippingBidiControls(_ text: String) -> String {
        String(
            String.UnicodeScalarView(
                text.unicodeScalars.filter { !isBidiControl($0) })
        )
    }

    /// Strips bidi controls, control characters (`Cc`), and line/paragraph separators
    /// (`Zl`/`Zp`), then treats an all-blank result as absent. Other format scalars are
    /// preserved because joiners are required for valid emoji and complex-script shaping.
    static func sanitize(_ text: String?) -> String? {
        guard let text else { return nil }
        let filtered = String(
            String.UnicodeScalarView(
                text.unicodeScalars.filter { scalar in
                    if isBidiControl(scalar) { return false }
                    switch scalar.properties.generalCategory {
                    case .control, .lineSeparator, .paragraphSeparator:
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
