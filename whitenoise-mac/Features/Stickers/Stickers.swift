import Foundation
import MarmotKit

// Sonar sticker packs (kind 30031) are public Nostr events. A sticker message is a kind-9 with
// empty content and a `sticker` tag naming the pack, the shortcode and the image's SHA-256. MDK
// authorizes and validates every image; its bytes come from a public URL the pack's author chose,
// so loading one discloses this device's IP address to that server.
//
// Stickers are not custom emoji. A custom emoji is an encrypted attachment inside the message; a
// sticker is a reference to a public pack, and is only ever drawn on its own.

/// One sticker's immutable identity: pack, shortcode and image hash.
nonisolated struct StickerKey: Hashable, Sendable {
    let packCoordinate: String
    let shortcode: String
    let plaintextSha256: String

    init(packCoordinate: String, shortcode: String, plaintextSha256: String) {
        self.packCoordinate = packCoordinate
        self.shortcode = shortcode
        self.plaintextSha256 = plaintextSha256
    }

    init(_ ref: StickerRefFfi) {
        self.init(packCoordinate: ref.packCoordinate, shortcode: ref.shortcode, plaintextSha256: ref.plaintextSha256)
    }

    init(_ sticker: StickerFfi) {
        self.init(
            packCoordinate: sticker.packCoordinate, shortcode: sticker.shortcode,
            plaintextSha256: sticker.plaintextSha256)
    }

    var ref: StickerRefFfi {
        StickerRefFfi(packCoordinate: packCoordinate, shortcode: shortcode, plaintextSha256: plaintextSha256)
    }
}

nonisolated enum StickerLoadPolicy {
    /// Whether a sticker in the timeline loads without a click. Loading contacts the pack author's
    /// server, so a received sticker loads by itself only from a pack the person installed, unless
    /// they turned on "Automatically Load Stickers" (`StickerLoadingPreference`). Their own
    /// stickers were already loaded to send them.
    static func loadsAutomatically(isFromMe: Bool, packInstalled: Bool, loadsEverySticker: Bool) -> Bool {
        isFromMe || packInstalled || loadsEverySticker
    }

    /// The text that stands in for a sticker: its emoji when the pack names one, otherwise the
    /// generic label. Peer-controlled, so sanitized and bounded to one grapheme-sized run.
    static func label(emoji: String?) -> String {
        let trimmed = PeerDisplayText.sanitize(emoji) ?? ""
        guard !trimmed.isEmpty, trimmed.count <= 4,
            trimmed.unicodeScalars.contains(where: \.properties.isEmojiPresentation)
        else { return L10n.string("Sticker") }
        return String(format: L10n.string("%@ Sticker"), trimmed)
    }

    /// The spoken description of a sticker.
    static func accessibilityLabel(alt: String?, emoji: String?) -> String {
        guard let alt = PeerDisplayText.sanitize(alt) else { return label(emoji: emoji) }
        return String(format: L10n.string("Sticker: %@"), String(alt.prefix(120)))
    }
}

nonisolated enum StickerPackPresentation {
    /// Packs to offer for discovery: those not installed, with stickers, in MDK's order.
    static func discoverable(_ packs: [StickerPackFfi], installed: Set<String>) -> [StickerPackFfi] {
        packs.filter { !$0.installed && !installed.contains($0.coordinate) && !$0.stickers.isEmpty }
    }

    /// A pasted link, coordinate or `naddr`, or nil when there is nothing to look up. MDK parses
    /// and validates it; this only trims and bounds it.
    static func lookupInput(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.utf8.count <= 2_048 else { return nil }
        return trimmed
    }

    static func title(_ pack: StickerPackFfi) -> String {
        guard let title = PeerDisplayText.sanitize(pack.title) else { return L10n.string("Sticker Pack") }
        return String(title.prefix(80))
    }

    static func description(_ pack: StickerPackFfi) -> String? {
        PeerDisplayText.sanitize(pack.description).map { String($0.prefix(500)) }
    }

    static func summary(_ pack: StickerPackFfi) -> String {
        L10n.plural("%lld stickers", Int64(pack.stickers.count))
    }

    enum DiscoveryState: Equatable {
        case loading
        case packs
        /// The relays answered and hold no packs.
        case noneOnRelays
        case noMatches
        /// Relays couldn't be reached and nothing is cached to show.
        case unreachable(message: String)
    }

    /// What the Discover section shows. Cached packs stay listed when a refresh fails; a failed
    /// refresh never reads as "there are none".
    static func discoveryState(isLoading: Bool, packCount: Int, search: String, syncError: String?)
        -> DiscoveryState
    {
        if packCount > 0 { return .packs }
        if isLoading { return .loading }
        if let syncError { return .unreachable(message: syncError) }
        let searching = !search.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return searching ? .noMatches : .noneOnRelays
    }
}
