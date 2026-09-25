import CoreGraphics
import Foundation

/// The interoperable text envelope the sibling clients use for GIPHY-backed chat messages: the
/// media URL on the first line, the credit on the second. A GIF travels as an ordinary text
/// message, so every surface that would show message text — the bubble, the chat-list preview,
/// a reply quote, a notification — must recognize the envelope and never expose the raw CDN URL
/// as though it were something the sender typed.
///
/// Kept byte-compatible with whitenoise-ios's `RemoteGiphyMedia`, which is what makes a GIF sent
/// from one client render on the other.
nonisolated struct RemoteGiphyMedia: Equatable, Hashable, Sendable {
    static let maximumWireTextLength = 2_304
    static let maximumAttributionLength = 80
    /// The same ceiling `RemoteImageURLPolicy` puts on an avatar URL string; a GIPHY media URL
    /// with its tracking query is a few hundred characters at most.
    static let maximumMediaURLLength = 2_048

    private static let creditPrefix = "via GIPHY"
    private static let attributedCreditPrefix = "via GIPHY · "

    let url: URL
    let width: Int
    let height: Int
    let attribution: String?

    var wireText: String {
        let credit = attribution.map { "\(Self.attributedCreditPrefix)\($0)" } ?? Self.creditPrefix
        return "\(url.absoluteString)\n\(credit)"
    }

    var aspectRatio: CGFloat {
        CGFloat(max(1, width)) / CGFloat(max(1, height))
    }

    /// The credit line the bubble draws under the GIF.
    var creditLabel: String {
        attribution.map { String(format: L10n.string("via GIPHY · %@"), $0) } ?? L10n.string("via GIPHY")
    }

    /// Parses a received message into a renderable GIF, or nil when it is not a well-formed
    /// envelope. The wire carries no dimensions, so the result starts at 4:3 until the decoded
    /// first frame reports its real geometry.
    static func parse(wireText: String) -> RemoteGiphyMedia? {
        let bounded = String(wireText.prefix(maximumWireTextLength + 1))
        guard bounded.count <= maximumWireTextLength else { return nil }
        let lines = bounded.split(
            separator: "\n",
            maxSplits: 1,
            omittingEmptySubsequences: false
        ).map(String.init)
        guard lines.count == 2,
            let url = validatedMediaURL(lines[0]),
            lines[1] == creditPrefix || lines[1].hasPrefix(attributedCreditPrefix)
        else { return nil }

        let attribution: String?
        if lines[1] == creditPrefix {
            attribution = nil
        } else {
            let raw = String(lines[1].dropFirst(attributedCreditPrefix.count))
            guard let sanitized = sanitizedAttribution(raw), sanitized == raw else { return nil }
            attribution = sanitized
        }
        return RemoteGiphyMedia(url: url, width: 4, height: 3, attribution: attribution)
    }

    /// The one-line label every preview surface (chat list, reply quote, notification body)
    /// shows for a GIPHY message, or nil when `text` is not an envelope.
    static func envelopePreviewText(for text: String) -> String? {
        isEnvelopeText(text) ? L10n.string("GIF via GIPHY") : nil
    }

    /// Whether peer text is a GIPHY envelope for display purposes. Looser than
    /// `parse(wireText:)`, which needs the credit line intact to recover attribution: an envelope
    /// whose credit line is missing, unrecognized, or clipped upstream still has to degrade to the
    /// label instead of rendering the remote CDN URL as message text.
    static func isEnvelopeText(_ text: String) -> Bool {
        let bounded = String(text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(maximumWireTextLength + 1))
        guard bounded.count <= maximumWireTextLength else { return false }
        let firstLine = bounded.prefix { $0 != "\n" }
        return isMediaURLShape(String(firstLine).trimmingCharacters(in: .whitespaces))
    }

    /// Scheme/host shape of an envelope's media URL, without the path checks `validatedMediaURL`
    /// applies, so a URL clipped before its extension is still recognized as GIF media.
    private static func isMediaURLShape(_ raw: String) -> Bool {
        guard raw.utf8.count <= maximumMediaURLLength,
            let components = URLComponents(string: raw),
            components.scheme?.lowercased() == "https",
            components.user == nil,
            components.password == nil,
            components.port == nil,
            let host = components.host?.lowercased(),
            isAllowedMediaHost(host)
        else { return false }
        return true
    }

    /// A GIPHY CDN URL the app is willing to fetch: `https`, no userinfo or port, a
    /// `media`/`mediaN`/`i` `.giphy.com` host, and a media extension. Still passed through
    /// `RemoteImageURLPolicy` so the one SSRF chokepoint keeps the last word.
    static func validatedMediaURL(_ raw: String) -> URL? {
        guard raw.count <= maximumMediaURLLength,
            let url = URL(string: raw),
            let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
            components.scheme?.lowercased() == "https",
            components.user == nil,
            components.password == nil,
            components.port == nil,
            let host = components.host?.lowercased(),
            isAllowedMediaHost(host),
            ["mp4", "gif", "webp"].contains(url.pathExtension.lowercased()),
            RemoteImageURLPolicy.isAllowed(url)
        else { return nil }
        return url
    }

    /// The single-line, bounded form of a creator credit, or nil when nothing printable is left.
    static func sanitizedAttribution(_ raw: String) -> String? {
        guard let sanitized = PeerDisplayText.sanitize(raw)?.trimmingCharacters(in: .whitespaces),
            !sanitized.isEmpty
        else { return nil }
        return String(sanitized.prefix(maximumAttributionLength))
    }

    private static func isAllowedMediaHost(_ host: String) -> Bool {
        guard host.hasSuffix(".giphy.com") else { return false }
        let label = String(host.dropLast(".giphy.com".count))
        if label == "media" || label == "i" { return true }
        guard label.hasPrefix("media") else { return false }
        let suffix = label.dropFirst("media".count)
        return !suffix.isEmpty && suffix.allSatisfy(\.isNumber)
    }
}
