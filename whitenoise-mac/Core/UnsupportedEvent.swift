import Foundation

/// A timeline row of a kind White Noise can't draw, as a card says it: the kind, a title and a
/// line of summary when the event carries them, and the event itself as JSON for anyone who wants
/// to look. Built from untrusted peer content, so every string shown as text is sanitized and the
/// JSON escapes everything that could reorder or hide what is drawn.
nonisolated struct UnsupportedEvent: Hashable, Sendable {
    let kind: UInt64
    /// A `title` or `subject` tag.
    let title: String?
    /// The NIP-31 `alt` tag, which exists for exactly this: a client that can't render a kind
    /// shows it instead. Failing that, the content when it reads as text rather than data.
    let summary: String?
    /// The event as NIP-01 JSON (`id`, `pubkey`, `created_at`, `kind`, `tags`, `content`),
    /// indented with one tag per line. The card shows all of it, and Copy JSON copies it.
    let json: String

    static let summaryLimit = 280

    init(id: String, pubkey: String, createdAt: UInt64, kind: UInt64, tags: [[String]], content: String) {
        self.kind = kind
        title = Self.firstLine(tagged: ["title", "subject"], in: tags)
        summary =
            Self.firstLine(tagged: ["alt"], in: tags)
            ?? (Self.looksLikeData(content) ? nil : Self.line(content))
        json = Self.eventJSON(id: id, pubkey: pubkey, createdAt: createdAt, kind: kind, tags: tags, content: content)
    }

    // MARK: Text

    /// The first of `names`' tags whose value still has text once sanitized, so a blank `title`
    /// doesn't hide a usable `subject`.
    private static func firstLine(tagged names: [String], in tags: [[String]]) -> String? {
        for name in names {
            for tag in tags where tag.first == name && tag.count > 1 {
                if let line = line(tag[1]) { return line }
            }
        }
        return nil
    }

    /// One display line: newlines folded to spaces, unsafe scalars dropped, length bounded.
    private static func line(_ text: String) -> String? {
        let folded = text.split(whereSeparator: \.isNewline).joined(separator: " ")
        guard let clean = PeerDisplayText.sanitize(folded)?.trimmingCharacters(in: .whitespaces), !clean.isEmpty
        else { return nil }
        return clean.count > summaryLimit ? String(clean.prefix(summaryLimit)) + "…" : clean
    }

    private static func looksLikeData(_ content: String) -> Bool {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.hasPrefix("{") || trimmed.hasPrefix("[")
    }

    // MARK: JSON

    /// NIP-01 field order, which `JSONSerialization` can't keep, so the object is written by hand.
    static func eventJSON(
        id: String, pubkey: String, createdAt: UInt64, kind: UInt64, tags: [[String]], content: String
    ) -> String {
        let tagLines = tags.map { tag in "    [" + tag.map(quoted).joined(separator: ", ") + "]" }
        let tagsValue = tags.isEmpty ? "[]" : "[\n" + tagLines.joined(separator: ",\n") + "\n  ]"
        return """
            {
              "id": \(quoted(id)),
              "pubkey": \(quoted(pubkey)),
              "created_at": \(createdAt),
              "kind": \(kind),
              "tags": \(tagsValue),
              "content": \(quoted(content))
            }
            """
    }

    /// A JSON string literal. Beyond what JSON requires, it also escapes format scalars (bidi
    /// overrides, zero-width characters) and line separators, so peer text can't make the block
    /// read differently from what it holds.
    static func quoted(_ value: String) -> String {
        var out = "\""
        for scalar in value.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default:
                switch scalar.properties.generalCategory {
                case .control, .format, .lineSeparator, .paragraphSeparator, .surrogate, .unassigned:
                    // UTF-16 code units, so a scalar past the BMP becomes a surrogate pair.
                    for unit in String(scalar).utf16 { out += String(format: "\\u%04x", unit) }
                default:
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        return out + "\""
    }
}
