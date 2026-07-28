//
//  EmojiPresentation.swift
//  whitenoise-mac
//
//  Shared Unicode-aware classification for emoji-only presentation.
//

import Foundation

nonisolated enum EmojiPresentation {
    static func singleEmoji(in candidate: String) -> String? {
        let value = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.count == 1 else { return nil }

        // Swift's Character boundary retains valid multi-scalar emoji such as flags, skin-tone
        // variants, keycaps, and ZWJ families. Requiring an emoji-presentation scalar (or VS16)
        // rejects ordinary one-character text such as digits and unstyled symbols.
        let scalars = value.unicodeScalars
        guard scalars.contains(where: { $0.properties.isEmojiPresentation || $0.value == 0xFE0F })
        else { return nil }
        return value
    }
}
