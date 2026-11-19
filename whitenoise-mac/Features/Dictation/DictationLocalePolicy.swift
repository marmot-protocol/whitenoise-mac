import Foundation

/// Which languages to try, most likely first.
nonisolated enum DictationLocalePolicy {
    /// The Mac's preferred languages come first, as they do for macOS's own dictation: a Mac
    /// keyboard layout says little about the spoken language (plenty of people who speak Spanish
    /// type on "U.S."). The enabled keyboard layouts follow, the selected one first, so a
    /// language someone types in but never added to Language & Region is still reachable.
    static func candidateIdentifiers(
        preferredLanguages: [String],
        keyboardLanguages: [String]
    ) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for identifier in preferredLanguages + keyboardLanguages {
            guard isSpokenLanguage(identifier) else { continue }
            let key = identifier.replacing("_", with: "-").lowercased()
            guard seen.insert(key).inserted else { continue }
            result.append(identifier)
        }
        return result
    }

    /// Emoji and dictation input modes report pseudo-languages.
    private static func isSpokenLanguage(_ identifier: String) -> Bool {
        let trimmed = identifier.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return false }
        return !["emoji", "dictation", "mul", "und", "zxx"].contains(trimmed.lowercased())
    }
}
