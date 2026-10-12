//
//  LinkPreviewMetadata.swift
//  whitenoise-mac
//
//  The title and image a link preview shows, read out of a page's `<head>`. A port of
//  whitenoise-ios's `LinkPreviewMetadata`, kept in step with it.
//

import Foundation

nonisolated struct LinkPreviewMetadata: Equatable, Sendable {
    static let maximumTitleLength = 200
    /// Only the start of a page is read. The `<head>` is near the top, and a page can be anything.
    static let maximumScannedBytes = 2 * 1024 * 1024
    /// The same bound iOS's `ContentSanitizer.maxImageURLLength` puts on any peer-chosen image URL.
    static let maximumURLLength = 2048

    private static let titleKeys = ["og:title", "twitter:title"]
    private static let imageKeys = [
        "og:image:secure_url",
        "og:image",
        "og:image:url",
        "twitter:image",
        "twitter:image:src",
    ]

    let title: String?
    let imageURL: URL?

    /// The link a message previews: its first one that may be fetched at all.
    ///
    /// Links are read from the rendered Markdown, so a URL inside a code block (which renders as
    /// text, not a link) is never previewed, and neither is a mention or a `nostr:` reference.
    static func previewURL(in document: MarkdownDisplayDocument?) -> URL? {
        guard let document else { return nil }
        for text in texts(in: document.blocks.map(\.block)) {
            for run in text.runs {
                guard let url = run.link, let allowed = fetchableURL(url.absoluteString) else { continue }
                return allowed
            }
        }
        return nil
    }

    /// Whether a URL taken from a peer's message, or from the page it links to, may be fetched:
    /// `RemoteImageURLPolicy` (https, a public host, no userinfo), a bounded length, and the
    /// standard port only. An explicit port would let a peer steer connections at arbitrary ports
    /// on public hosts, the one dimension the host check does not constrain.
    static func fetchableURL(_ raw: String) -> URL? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
            trimmed.utf8.count <= maximumURLLength,
            let components = URLComponents(string: trimmed),
            components.port == nil || components.port == 443,
            let url = components.url,
            RemoteImageURLPolicy.isAllowed(url)
        else { return nil }
        return url
    }

    static func parse(html data: Data, baseURL: URL) -> LinkPreviewMetadata? {
        let html = String(decoding: data.prefix(maximumScannedBytes), as: UTF8.self)
        let head =
            html.firstRange(of: #/<\/head\s*>/#.ignoresCase()).map { String(html[..<$0.lowerBound]) } ?? html
        let properties = metaProperties(in: head)

        let title = (titleKeys.lazy.compactMap { properties[$0] }.first ?? documentTitle(in: head))
            .flatMap { compactTitle(decodeEntities($0)) }
        let imageURL = imageKeys.lazy
            .compactMap { properties[$0] }
            .compactMap { resolvedImageURL(decodeEntities($0), baseURL: baseURL) }
            .first

        guard title != nil || imageURL != nil else { return nil }
        return LinkPreviewMetadata(title: title, imageURL: imageURL)
    }

    private static func texts(in blocks: [MarkdownDisplayBlock]) -> [AttributedString] {
        blocks.flatMap { block -> [AttributedString] in
            switch block {
            case .paragraph(let text), .heading(_, let text):
                return [text]
            case .blockQuote(let nested):
                return texts(in: nested.map(\.block))
            case .list(let items):
                return items.flatMap { texts(in: $0.blocks.map(\.block)) }
            case .table(let header, let rows):
                return header.map(\.text) + rows.flatMap { $0.cells.map(\.text) }
            case .thematicBreak, .codeBlock, .mathBlock:
                return []
            }
        }
    }

    private static func metaProperties(in head: String) -> [String: String] {
        var properties: [String: String] = [:]
        for tag in head.matches(of: #/<meta\b[^>]*>/#.ignoresCase()) {
            let attributes = attributes(in: String(tag.output))
            guard let key = (attributes["property"] ?? attributes["name"])?.lowercased(),
                let content = attributes["content"],
                properties[key] == nil
            else { continue }
            properties[key] = content
        }
        return properties
    }

    private static func attributes(in tag: String) -> [String: String] {
        var attributes: [String: String] = [:]
        let pattern = #/([A-Za-z_:][-A-Za-z0-9_:.]*)\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s"'>]+))/#
        for match in tag.matches(of: pattern) {
            let name = match.output.1.lowercased()
            let value = match.output.2 ?? match.output.3 ?? match.output.4 ?? ""
            if attributes[name] == nil { attributes[name] = String(value) }
        }
        return attributes
    }

    private static func documentTitle(in head: String) -> String? {
        guard let match = head.firstMatch(of: #/<title\b[^>]*>([^<]*)<\/title\s*>/#.ignoresCase()) else {
            return nil
        }
        return String(match.output.1)
    }

    /// One line, whitespace collapsed, peer-text sanitized, and bounded — the page is as
    /// untrusted as the message that linked it.
    private static func compactTitle(_ raw: String) -> String? {
        let collapsed = raw.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard let sanitized = PeerDisplayText.sanitize(collapsed) else { return nil }
        return String(sanitized.trimmingCharacters(in: .whitespaces).prefix(maximumTitleLength)).nilIfBlank
    }

    private static func resolvedImageURL(_ raw: String, baseURL: URL) -> URL? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
            trimmed.utf8.count <= maximumURLLength,
            let resolved = URL(string: trimmed, relativeTo: baseURL)?.absoluteURL
        else { return nil }
        return fetchableURL(resolved.absoluteString)
    }

    static func decodeEntities(_ text: String) -> String {
        guard text.contains("&") else { return text }
        return text.replacing(#/&(#[xX][0-9A-Fa-f]{1,6}|#[0-9]{1,7}|[A-Za-z]{2,6});/#) { match in
            let entity = match.output.1
            switch entity.lowercased() {
            case "amp": return "&"
            case "lt": return "<"
            case "gt": return ">"
            case "quot": return "\""
            case "apos": return "'"
            case "nbsp": return " "
            default: break
            }
            let scalarValue: UInt32? =
                if entity.hasPrefix("#x") || entity.hasPrefix("#X") {
                    UInt32(entity.dropFirst(2), radix: 16)
                } else if entity.hasPrefix("#") {
                    UInt32(entity.dropFirst())
                } else {
                    nil
                }
            guard let scalarValue, let scalar = Unicode.Scalar(scalarValue) else { return String(match.output.0) }
            return String(Character(scalar))
        }
    }
}
