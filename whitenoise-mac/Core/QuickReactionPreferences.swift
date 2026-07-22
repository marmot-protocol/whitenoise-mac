//
//  QuickReactionPreferences.swift
//  whitenoise-mac
//
//  Normalized local persistence for the ordered one-tap reaction set.
//

import Foundation

nonisolated enum ChatReactionDefaults {
    static let quick = ["❤️", "👍", "👎", "😂", "😮", "😢"]
}

nonisolated enum QuickReactionSet {
    static let slotCount = 6

    static func normalized(_ candidates: [String]) -> [String] {
        var result: [String] = []
        result.reserveCapacity(slotCount)

        for candidate in candidates {
            guard result.count < slotCount,
                let emoji = validatedEmoji(candidate),
                !result.contains(emoji)
            else { continue }
            result.append(emoji)
        }

        for emoji in ChatReactionDefaults.quick where result.count < slotCount {
            guard !result.contains(emoji) else { continue }
            result.append(emoji)
        }

        return result
    }

    static func validatedEmoji(_ candidate: String) -> String? {
        let value = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.count == 1 else { return nil }

        // Swift's Character boundary retains valid multi-scalar emoji such as flags, skin-tone
        // variants, keycaps, and ZWJ families. Requiring an emoji-presentation scalar (or VS16)
        // rejects ordinary one-character text from malformed older preferences.
        let scalars = value.unicodeScalars
        guard scalars.contains(where: { $0.properties.isEmojiPresentation || $0.value == 0xFE0F })
        else { return nil }
        return value
    }
}

@MainActor
protocol QuickReactionStoring: AnyObject {
    func load() -> [String]
    func save(_ reactions: [String])
    func reset()
}

@MainActor
final class UserDefaultsQuickReactionStore: QuickReactionStoring {
    static let storageKey = "whitenoise.mac.quickReactions.v1"
    static let legacyStorageKeys = [
        "whitenoise.mac.quickReactions",
        "chat.quick-reactions",
    ]

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func load() -> [String] {
        if let object = defaults.object(forKey: Self.storageKey),
            let candidates = Self.decodedCandidates(from: object)
        {
            return migrate(candidates)
        }

        for key in Self.legacyStorageKeys {
            guard let object = defaults.object(forKey: key),
                let candidates = Self.decodedCandidates(from: object)
            else { continue }
            return migrate(candidates)
        }

        let hasMalformedStoredValue =
            defaults.object(forKey: Self.storageKey) != nil
            || Self.legacyStorageKeys.contains { defaults.object(forKey: $0) != nil }
        if hasMalformedStoredValue {
            return migrate([])
        }

        return ChatReactionDefaults.quick
    }

    func save(_ reactions: [String]) {
        defaults.set(QuickReactionSet.normalized(reactions), forKey: Self.storageKey)
        removeLegacyValues()
    }

    func reset() {
        defaults.removeObject(forKey: Self.storageKey)
        removeLegacyValues()
    }

    private func migrate(_ candidates: [String]) -> [String] {
        let normalized = QuickReactionSet.normalized(candidates)
        defaults.set(normalized, forKey: Self.storageKey)
        removeLegacyValues()
        return normalized
    }

    private func removeLegacyValues() {
        for key in Self.legacyStorageKeys {
            defaults.removeObject(forKey: key)
        }
    }

    private static func decodedCandidates(from object: Any) -> [String]? {
        if let values = object as? [String] {
            return values
        }
        if let data = object as? Data {
            return try? JSONDecoder().decode([String].self, from: data)
        }
        if let string = object as? String,
            let data = string.data(using: .utf8)
        {
            return try? JSONDecoder().decode([String].self, from: data)
        }
        return nil
    }
}
