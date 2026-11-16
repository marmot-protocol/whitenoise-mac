// coverage:ignore-file
// Reads the Mac's enabled keyboard layouts through Text Input Sources; the ordering rule it feeds
// is `DictationLocalePolicy`, which is tested.

import Carbon.HIToolbox
import Foundation

/// The languages dictation tries, read from this Mac.
@MainActor
enum DictationLanguages {
    static var candidates: [String] {
        DictationLocalePolicy.candidateIdentifiers(
            preferredLanguages: Locale.preferredLanguages,
            keyboardLanguages: keyboardLanguages
        )
    }

    /// The selected keyboard layout's languages first, then every other enabled one's.
    private static var keyboardLanguages: [String] {
        var languages = languages(of: TISCopyCurrentKeyboardInputSource()?.takeRetainedValue())
        let filter = [kTISPropertyInputSourceCategory: kTISCategoryKeyboardInputSource] as CFDictionary
        if let sources = TISCreateInputSourceList(filter, false)?.takeRetainedValue() as? [TISInputSource] {
            for source in sources {
                languages += self.languages(of: source)
            }
        }
        return languages
    }

    /// A layout lists every language it can type, most important first ("U.S." also lists
    /// Hawaiian, Indonesian, …), so only the first says what the person speaks.
    private static func languages(of source: TISInputSource?) -> [String] {
        guard let source, let pointer = TISGetInputSourceProperty(source, kTISPropertyInputSourceLanguages)
        else { return [] }
        let value = Unmanaged<CFArray>.fromOpaque(pointer).takeUnretainedValue()
        return (value as? [String] ?? []).prefix(1).map(\.self)
    }
}
