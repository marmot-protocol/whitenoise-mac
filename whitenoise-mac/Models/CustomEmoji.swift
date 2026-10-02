//
//  CustomEmoji.swift
//  whitenoise-mac
//
//  NIP-30 custom emoji. A chat or reaction carries `["emoji", shortcode, url]` tags; the text
//  names one as `:shortcode:`. In Marmot the URL is not something to fetch: it is the first
//  locator of one of the event's own encrypted attachments, so a shortcode renders only when that
//  attachment is present. Anything that does not resolve stays the literal `:shortcode:` text.
//

import Foundation
import MarmotKit

/// One `["emoji", shortcode, url]` tag.
nonisolated struct CustomEmojiTag: Hashable, Sendable {
    let shortcode: String
    let url: String

    /// The well-formed emoji tags in `tags`, first occurrence of each shortcode winning. NIP-30
    /// limits shortcodes to letters, digits, `_` and `-`; anything else could never appear between
    /// two colons as one token, so it is dropped rather than half-matched.
    static func parse(_ tags: [MessageTagFfi]) -> [CustomEmojiTag] {
        var seen = Set<String>()
        return tags.compactMap { tag in
            guard tag.values.count >= 3, tag.values[0] == "emoji" else { return nil }
            let shortcode = tag.values[1]
            let url = tag.values[2]
            guard CustomEmojiText.isValidShortcode(shortcode), !url.isEmpty, seen.insert(shortcode).inserted
            else { return nil }
            return CustomEmojiTag(shortcode: shortcode, url: url)
        }
    }

    /// Shortcode → attachment for every tag that `text` actually uses and whose URL is the locator
    /// of one of `attachments`' images. An `emoji` URL matching no attachment is not a decryptable
    /// Marmot reference, so it resolves to nothing and the text stays literal.
    static func resolve(
        _ tags: [CustomEmojiTag],
        attachments: [MessageMediaAttachment],
        text: String
    ) -> [String: MessageMediaAttachment] {
        guard !tags.isEmpty, text.contains(":") else { return [:] }
        let used = CustomEmojiText.shortcodes(in: text)
        var resolved: [String: MessageMediaAttachment] = [:]
        for tag in tags where used.contains(tag.shortcode) {
            let match = attachments.first { attachment in
                attachment.rejectionKind == nil
                    && attachment.kind == .image
                    && attachment.reference.locators.contains { $0.value == tag.url }
            }
            if let match { resolved[tag.shortcode] = match }
        }
        return resolved
    }
}

/// Finding `:shortcode:` runs in text.
nonisolated enum CustomEmojiText {
    enum Segment: Equatable {
        case text(String)
        case emoji(String)
    }

    static func isValidShortcode(_ shortcode: String) -> Bool {
        !shortcode.isEmpty
            && shortcode.unicodeScalars.allSatisfy { scalar in
                scalar.isASCII
                    && (CharacterSet.alphanumerics.contains(scalar) || scalar == "_" || scalar == "-")
            }
    }

    /// The shortcode a reaction names, when its content is exactly `:shortcode:`.
    static func reactionShortcode(_ emoji: String) -> String? {
        guard emoji.count > 2, emoji.hasPrefix(":"), emoji.hasSuffix(":") else { return nil }
        let shortcode = String(emoji.dropFirst().dropLast())
        return isValidShortcode(shortcode) ? shortcode : nil
    }

    /// Every well-formed `:shortcode:` token in `text`.
    static func shortcodes(in text: String) -> Set<String> {
        Set(ranges(in: text, matching: nil).map(\.shortcode))
    }

    /// `text` split into literal runs and the emoji among `shortcodes`. A token whose shortcode is
    /// not in the set stays part of the surrounding text.
    static func segments(in text: String, shortcodes: Set<String>) -> [Segment] {
        guard !shortcodes.isEmpty else { return [.text(text)] }
        var segments: [Segment] = []
        var cursor = text.startIndex
        for match in ranges(in: text, matching: shortcodes) {
            if cursor < match.range.lowerBound {
                segments.append(.text(String(text[cursor..<match.range.lowerBound])))
            }
            segments.append(.emoji(match.shortcode))
            cursor = match.range.upperBound
        }
        if cursor < text.endIndex {
            segments.append(.text(String(text[cursor...])))
        }
        return segments
    }

    /// The ranges of the `:shortcode:` tokens among `shortcodes` (any well-formed one when nil),
    /// scanning left to right so `:a:b:` matches `:a:` and leaves `b:` as text.
    static func ranges(
        in text: String,
        matching shortcodes: Set<String>?
    ) -> [(range: Range<String.Index>, shortcode: String)] {
        var matches: [(range: Range<String.Index>, shortcode: String)] = []
        var searchStart = text.startIndex
        while let open = text[searchStart...].firstIndex(of: ":") {
            let afterOpen = text.index(after: open)
            guard let close = text[afterOpen...].firstIndex(of: ":") else { break }
            let shortcode = String(text[afterOpen..<close])
            if isValidShortcode(shortcode), shortcodes?.contains(shortcode) ?? true {
                matches.append((open..<text.index(after: close), shortcode))
                searchStart = text.index(after: close)
            } else {
                // The closing colon may open the next token.
                searchStart = close
            }
        }
        return matches
    }

    /// The shortcode when `text` is exactly one resolvable custom emoji, which draws large and
    /// without a bubble like a lone Unicode emoji does.
    static func soleEmoji(in text: String, shortcodes: Set<String>) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let segments = segments(in: trimmed, shortcodes: shortcodes)
        guard segments.count == 1, case .emoji(let shortcode) = segments[0] else { return nil }
        return shortcode
    }
}
