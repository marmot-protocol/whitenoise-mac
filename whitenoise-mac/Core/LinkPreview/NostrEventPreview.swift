//
//  NostrEventPreview.swift
//  whitenoise-mac
//
//  What a card shows for a public Nostr event a message links (`note`, `nevent`, `naddr`): a
//  short text note in full, a long-form article as a title card, and anything else as a pointer
//  to njump.me. MDK fetches and verifies the event; this only reads the JSON it hands back.
//

import Foundation

nonisolated struct NostrEventPreview: Equatable, Sendable {
    static let textNoteKind: UInt16 = 1
    static let longFormArticleKind: UInt16 = 30023
    /// A note is shown, not read in full: anything longer is cut, and the card links to the rest.
    static let maximumNoteLength = 600
    static let maximumTitleLength = 200
    static let maximumSummaryLength = 300

    enum Body: Equatable, Sendable {
        /// Kind 1. Plain text, never Markdown: other clients publish it raw.
        case note(text: String)
        /// Kind 30023 (NIP-23).
        case article(title: String?, summary: String?, imageURL: URL?)
        /// Any other kind — a list, a reaction, a kind this app does not draw. The card only
        /// names the author and opens the event on njump.me.
        case other
    }

    let authorIdHex: String
    let createdAt: Date
    let body: Body

    /// The first `note`, `nevent` or `naddr` a message links, as its bare reference. Read from the
    /// rendered Markdown, so a reference inside a code block is never previewed.
    static func previewReference(in document: MarkdownDisplayDocument?) -> String? {
        guard let document else { return nil }
        for text in LinkPreviewMetadata.texts(in: document.blocks.map(\.block)) {
            for run in text.runs {
                guard let url = run.link,
                    let reference = MarkdownLinkPolicy.nostrReference(from: url),
                    let event = MarkdownLinkPolicy.eventReference(reference)
                else { continue }
                return event
            }
        }
        return nil
    }

    /// Reads the signed event MDK verified. Nil only when the JSON is not an event.
    static func parse(eventJson: String) -> NostrEventPreview? {
        guard let event = try? JSONDecoder().decode(SignedEvent.self, from: Data(eventJson.utf8)),
            event.pubkey.count == 64, event.pubkey.allSatisfy(\.isHexDigit)
        else { return nil }
        let createdAt = Date(timeIntervalSince1970: TimeInterval(event.createdAt))
        let author = event.pubkey.lowercased()

        switch event.kind {
        case textNoteKind:
            return NostrEventPreview(
                authorIdHex: author, createdAt: createdAt, body: .note(text: noteText(event.content)))
        case longFormArticleKind:
            let published = event.firstTagValue("published_at").flatMap(TimeInterval.init)
                .map { Date(timeIntervalSince1970: $0) }
            return NostrEventPreview(
                authorIdHex: author,
                createdAt: published ?? createdAt,
                body: .article(
                    title: singleLine(event.firstTagValue("title"), limit: maximumTitleLength),
                    summary: singleLine(event.firstTagValue("summary"), limit: maximumSummaryLength),
                    imageURL: event.firstTagValue("image").flatMap(LinkPreviewMetadata.fetchableURL)
                )
            )
        default:
            return NostrEventPreview(authorIdHex: author, createdAt: createdAt, body: .other)
        }
    }

    /// A note's text as the card draws it: peer-controlled, so stripped of bidi and control
    /// characters (newlines kept), blank-line runs collapsed, every `nostr:` reference shortened
    /// the way the transcript shortens one, and bounded.
    static func noteText(_ content: String) -> String {
        let filtered = String(
            String.UnicodeScalarView(
                PeerDisplayText.strippingBidiControls(content).unicodeScalars.filter { scalar in
                    if scalar == "\n" { return true }
                    switch scalar.properties.generalCategory {
                    case .control, .lineSeparator, .paragraphSeparator: return false
                    default: return true
                    }
                })
        )
        let shortened = filtered.replacing(#/nostr:((?:npub|nprofile|note|nevent|naddr)1[02-9ac-hj-np-z]+)/#) {
            MarkdownMentionText.shortBech32(String($0.output.1))
        }
        let collapsed = shortened.replacing(#/\n{3,}/#, with: "\n\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard collapsed.count > maximumNoteLength else { return collapsed }
        return String(collapsed.prefix(maximumNoteLength)).trimmingCharacters(in: .whitespacesAndNewlines) + "…"
    }

    private static func singleLine(_ raw: String?, limit: Int) -> String? {
        guard let raw else { return nil }
        let collapsed = raw.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return PeerDisplayText.sanitize(collapsed).map { String($0.prefix(limit)) }
    }

    private struct SignedEvent: Decodable {
        let pubkey: String
        let createdAt: UInt64
        let kind: UInt16
        let tags: [[String]]
        let content: String

        enum CodingKeys: String, CodingKey {
            case pubkey, kind, tags, content
            case createdAt = "created_at"
        }

        func firstTagValue(_ name: String) -> String? {
            tags.first { $0.first == name && $0.count > 1 }?[1]
        }
    }
}
