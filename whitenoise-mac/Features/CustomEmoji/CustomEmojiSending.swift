import AppKit
import CryptoKit
import Foundation
import MarmotKit

// Sending NIP-30 custom emoji. A person can send the built-ins, emoji from installed NIP-51 sets,
// and emoji this conversation already holds. Each image is re-encrypted into the chat with
// `uploadMedia(send: false)` and named by `["emoji", shortcode, reference.locators[0].value]`; a
// tag URL is never fetched. Everything here is pure so limits, tags and validation are testable
// without a runtime.

/// Built-in `:marmot:` and `:wn:`: the same PNG bytes White Noise ships on every platform. A
/// message or reaction using one carries the image like any custom emoji, so clients without the
/// built-ins still see it.
nonisolated struct CustomEmojiBuiltin: Hashable, Sendable {
    let shortcode: String
    /// Product name read by VoiceOver in place of the shortcode.
    let spokenName: String
    let data: Data
    let plaintextSha256: String
    let dim: String?

    var fileName: String { "\(shortcode).png" }
    var mediaType: String { "image/png" }

    init(shortcode: String, spokenName: String, data: Data, dim: String?) {
        self.shortcode = shortcode
        self.spokenName = spokenName
        self.data = data
        self.dim = dim
        plaintextSha256 = CustomEmojiDigest.hex(data)
    }
}

nonisolated enum CustomEmojiBuiltins {
    private struct Definition {
        let shortcode: String
        let asset: String
        let spokenName: String
    }

    // Product names, not translated.
    private static let definitions = [
        Definition(shortcode: "marmot", asset: "BuiltinEmojiMarmot", spokenName: "Marmot"),
        Definition(shortcode: "wn", asset: "BuiltinEmojiWN", spokenName: "White Noise"),
    ]

    /// Every built-in whose bundled bytes load, in picker order.
    static let all: [CustomEmojiBuiltin] = definitions.compactMap { definition in
        guard let data = NSDataAsset(name: definition.asset)?.data, !data.isEmpty else { return nil }
        let dim = NSBitmapImageRep(data: data).map { "\($0.pixelsWide)x\($0.pixelsHigh)" }
        return CustomEmojiBuiltin(
            shortcode: definition.shortcode, spokenName: definition.spokenName, data: data, dim: dim)
    }

    static func builtin(_ shortcode: String) -> CustomEmojiBuiltin? {
        all.first { $0.shortcode == shortcode }
    }
}

/// Decoded built-in images, decoded once.
@MainActor
enum CustomEmojiBuiltinImages {
    private static var decoded: [String: NSImage] = [:]

    static func image(for shortcode: String) -> NSImage? {
        if let cached = decoded[shortcode] { return cached }
        guard let builtin = CustomEmojiBuiltins.builtin(shortcode), let image = NSImage(data: builtin.data) else {
            return nil
        }
        decoded[shortcode] = image
        return image
    }
}

nonisolated enum CustomEmojiDigest {
    static func hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

/// MDK `validate_message_tags` limits, enforced before anything is uploaded or sent.
nonisolated enum CustomEmojiSendPolicy {
    static let maxTags = 64
    static let maxTagValueBytes = 16 * 1024
    /// MDK caps reaction content at 64 characters; keeping `:shortcode:` within it lets every
    /// sendable emoji also be a reaction.
    static let maxShortcodeLength = 62

    /// Any valid shortcode short enough to also be a reaction.
    static func isSendable(_ shortcode: String) -> Bool {
        CustomEmojiText.isValidShortcode(shortcode) && shortcode.utf8.count <= maxShortcodeLength
    }
}

/// Why a custom emoji message or reaction could not be sent. A message keeps its composer draft
/// for an explicit retry.
nonisolated enum CustomEmojiSendError: Error, Equatable {
    case unsendableShortcode(String)
    case missingLocator
    case tooManyTags(count: Int)
    case tagValuesTooLarge(bytes: Int)
    case forbiddenImetaTag
    case malformedTag
    case emptyEventTarget
    case mixedWithAttachments
    case imageUnavailable
    case uploadFailed
    case staleEpoch
    case epochUnsettled
    case sendFailed

    var message: String {
        switch self {
        case .tooManyTags, .tagValuesTooLarge:
            L10n.string("This message has too many custom emoji. Remove some and try again.")
        case .mixedWithAttachments:
            L10n.string("Send custom emoji in a separate message from photos and files.")
        case .imageUnavailable:
            L10n.string("A custom emoji image isn't available on this device yet. Try again once it has loaded.")
        case .uploadFailed:
            L10n.string("Couldn't upload the custom emoji. Check your connection and try again.")
        case .staleEpoch:
            L10n.string("The chat changed while sending. Try again.")
        case .epochUnsettled:
            L10n.string("The chat is still syncing. Try again in a moment.")
        case .emptyEventTarget:
            L10n.string("The message you're replying to is unavailable.")
        case .unsendableShortcode, .missingLocator, .forbiddenImetaTag, .malformedTag:
            L10n.string("This custom emoji can't be sent.")
        case .sendFailed:
            L10n.string("Couldn't send. Check your connection and try again.")
        }
    }
}

/// One custom emoji the person can send from this conversation: a NIP-30 shortcode and where its
/// image bytes come from.
nonisolated struct CustomEmojiSendable: Identifiable, Equatable, Sendable {
    enum Artwork: Equatable, Sendable {
        /// The image reference it was received with in this chat; MDK still holds its bytes.
        case chat(reference: MediaAttachmentReferenceFfi)
        case builtin(CustomEmojiBuiltin)
        /// An emoji from an installed NIP-51 set; MDK holds its bytes.
        case installed(InstalledCustomEmojiFfi)
    }

    let shortcode: String
    let artwork: Artwork

    init(shortcode: String, chatReference: MediaAttachmentReferenceFfi) {
        self.shortcode = shortcode
        artwork = .chat(reference: chatReference)
    }

    init(builtin: CustomEmojiBuiltin) {
        shortcode = builtin.shortcode
        artwork = .builtin(builtin)
    }

    init?(installed: InstalledCustomEmojiFfi) {
        guard CustomEmojiText.isValidShortcode(installed.shortcode) else { return nil }
        shortcode = installed.shortcode
        artwork = .installed(installed)
    }

    var id: String { shortcode }
    var token: String { ":\(shortcode):" }

    var plaintextSha256: String {
        switch artwork {
        case .chat(let reference): reference.plaintextSha256.lowercased()
        case .builtin(let builtin): builtin.plaintextSha256
        case .installed(let emoji): emoji.sha256.lowercased()
        }
    }

    /// What VoiceOver reads for the emoji.
    var spokenName: String {
        if case .builtin(let builtin) = artwork { return builtin.spokenName }
        return shortcode
    }
}

/// One custom emoji this conversation already holds: a shortcode and the image it was received
/// with, newest first.
nonisolated struct CustomEmojiChatEntry: Equatable, Sendable {
    let shortcode: String
    let reference: MediaAttachmentReferenceFfi
}

nonisolated enum CustomEmojiChatCatalog {
    /// Every tagged custom emoji in `records` whose image is one of the record's own accepted
    /// image attachments, newest record first, first occurrence of each shortcode winning.
    static func entries(_ records: [TimelineMessageRecordFfi]) -> [CustomEmojiChatEntry] {
        var seen = Set<String>()
        var entries: [CustomEmojiChatEntry] = []
        for record in records.sorted(by: { $0.timelineAt > $1.timelineAt }) where !record.deleted {
            let tags = CustomEmojiTag.parse(record.tags)
            guard !tags.isEmpty else { continue }
            let attachments = MessageMediaParser.attachments(
                resolvedMedia: record.media, mediaJson: record.mediaJson, tags: record.tags,
                messageIdHex: record.messageIdHex)
            for tag in tags where !seen.contains(tag.shortcode) {
                guard
                    let match = attachments.first(where: { attachment in
                        attachment.rejectionKind == nil
                            && attachment.reference.mediaType.lowercased().hasPrefix("image/")
                            && attachment.reference.locators.contains { $0.value == tag.url }
                    })
                else { continue }
                seen.insert(tag.shortcode)
                entries.append(CustomEmojiChatEntry(shortcode: tag.shortcode, reference: match.reference))
            }
        }
        return entries
    }
}

nonisolated enum CustomEmojiSendCatalog {
    /// The built-ins first, then installed set emoji in MDK's install order, then the chat's own
    /// emoji. A built-in shortcode always sends the built-in image, and an installed one beats an
    /// image seen in the chat.
    static func sendables(
        builtins: [CustomEmojiBuiltin] = CustomEmojiBuiltins.all,
        installed: [InstalledCustomEmojiFfi],
        chat: [CustomEmojiChatEntry]
    ) -> [CustomEmojiSendable] {
        var seen = Set<String>()
        var result: [CustomEmojiSendable] = []
        for builtin in builtins
        where CustomEmojiSendPolicy.isSendable(builtin.shortcode) && seen.insert(builtin.shortcode).inserted {
            result.append(CustomEmojiSendable(builtin: builtin))
        }
        for emoji in installed {
            guard let sendable = CustomEmojiSendable(installed: emoji),
                CustomEmojiSendPolicy.isSendable(sendable.shortcode),
                seen.insert(sendable.shortcode).inserted
            else { continue }
            result.append(sendable)
        }
        for entry in chat
        where CustomEmojiSendPolicy.isSendable(entry.shortcode) && seen.insert(entry.shortcode).inserted {
            result.append(CustomEmojiSendable(shortcode: entry.shortcode, chatReference: entry.reference))
        }
        return result
    }

    /// Sendable shortcodes used in `text`, in first-appearance order.
    static func used(in text: String, sendables: [CustomEmojiSendable]) -> [CustomEmojiSendable] {
        let byShortcode = Dictionary(sendables.map { ($0.shortcode, $0) }, uniquingKeysWith: { first, _ in first })
        guard !byShortcode.isEmpty, text.contains(":") else { return [] }
        var seen = Set<String>()
        return CustomEmojiText.ranges(in: text, matching: Set(byShortcode.keys)).compactMap { match in
            guard seen.insert(match.shortcode).inserted else { return nil }
            return byShortcode[match.shortcode]
        }
    }

    /// The sendable a reaction's `:shortcode:` names, if any.
    static func sendable(forReaction emoji: String, in sendables: [CustomEmojiSendable]) -> CustomEmojiSendable? {
        guard let shortcode = CustomEmojiText.reactionShortcode(emoji) else { return nil }
        return sendables.first { $0.shortcode == shortcode }
    }

    /// Picker groups: emoji outside a set first, then one group per installed set in install
    /// order.
    struct PickerGroup: Identifiable, Equatable {
        let id: String
        let title: String
        let emoji: [CustomEmojiSendable]
    }

    static func pickerGroups(_ sendables: [CustomEmojiSendable]) -> [PickerGroup] {
        var other: [CustomEmojiSendable] = []
        var order: [String] = []
        var titles: [String: String] = [:]
        var members: [String: [CustomEmojiSendable]] = [:]
        for sendable in sendables {
            guard case .installed(let emoji) = sendable.artwork else {
                other.append(sendable)
                continue
            }
            if members[emoji.setCoordinate] == nil {
                order.append(emoji.setCoordinate)
                titles[emoji.setCoordinate] = EmojiSetPresentation.title(emoji)
            }
            members[emoji.setCoordinate, default: []].append(sendable)
        }
        var groups: [PickerGroup] = []
        if !other.isEmpty {
            groups.append(PickerGroup(id: "custom", title: L10n.string("Custom Emoji"), emoji: other))
        }
        groups += order.map { PickerGroup(id: $0, title: titles[$0] ?? "", emoji: members[$0] ?? []) }
        return groups
    }
}

nonisolated enum CustomEmojiTags {
    static let eventRefTag = MessageReplyTags.eventRef
    static let quoteRefTag = MessageReplyTags.quoteRef

    /// Mirrors MDK `validate_message_tags`: at most 64 rows and 16 KiB of UTF-8 values, no empty
    /// rows or names, no `imeta`, and `e` / `q` rows need a non-blank target.
    static func validate(_ tags: [[String]]) throws(CustomEmojiSendError) {
        guard tags.count <= CustomEmojiSendPolicy.maxTags else { throw .tooManyTags(count: tags.count) }
        let bytes = tags.joined().reduce(0) { $0 + $1.utf8.count }
        guard bytes <= CustomEmojiSendPolicy.maxTagValueBytes else { throw .tagValuesTooLarge(bytes: bytes) }
        for tag in tags {
            guard let name = tag.first, !name.isEmpty else { throw .malformedTag }
            guard name != "imeta" else { throw .forbiddenImetaTag }
            if name == eventRefTag || name == quoteRefTag {
                guard tag.count >= 2, !tag[1].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    throw .emptyEventTarget
                }
            }
        }
    }

    /// `["emoji", shortcode, reference.locators[0].value]`.
    static func emojiTag(_ shortcode: String, reference: MediaAttachmentReferenceFfi) throws(CustomEmojiSendError)
        -> [String]
    {
        guard CustomEmojiSendPolicy.isSendable(shortcode) else { throw .unsendableShortcode(shortcode) }
        guard let url = reference.locators.first?.value, !url.isEmpty,
            url.trimmingCharacters(in: .whitespacesAndNewlines) == url
        else { throw .missingLocator }
        return ["emoji", shortcode, url]
    }

    /// Tags for a kind-9 chat: one `emoji` row per image in text order, then the `e` + `q` reply
    /// rows MDK's own replies carry.
    static func messageTags(
        emoji: [(shortcode: String, reference: MediaAttachmentReferenceFfi)],
        replyTargetId: String?
    ) throws(CustomEmojiSendError) -> [[String]] {
        var tags: [[String]] = []
        for item in emoji {
            tags.append(try emojiTag(item.shortcode, reference: item.reference))
        }
        tags += MessageReplyTags.tags(replyingTo: replyTargetId)
        try validate(tags)
        return tags
    }

    /// Cheap pre-upload count check so an over-limit message fails before any network work. The
    /// byte limit is checked again with the uploaded URLs.
    static func precheck(emojiCount: Int, isReply: Bool) throws(CustomEmojiSendError) {
        let count = emojiCount + (isReply ? 2 : 0)
        guard count <= CustomEmojiSendPolicy.maxTags else { throw .tooManyTags(count: count) }
    }
}

nonisolated enum CustomEmojiUploadRequest {
    static func chat(_ reference: MediaAttachmentReferenceFfi, plaintext: Data) -> MediaUploadAttachmentRequestFfi {
        MediaUploadAttachmentRequestFfi(
            fileName: reference.fileName, mediaType: reference.mediaType, plaintext: plaintext, dim: reference.dim,
            thumbhash: reference.thumbhash)
    }

    static func builtin(_ builtin: CustomEmojiBuiltin) -> MediaUploadAttachmentRequestFfi {
        MediaUploadAttachmentRequestFfi(
            fileName: builtin.fileName, mediaType: builtin.mediaType, plaintext: builtin.data, dim: builtin.dim,
            thumbhash: nil)
    }

    /// The upload for an installed set emoji: MDK's validated MIME type and size, named after its
    /// shortcode.
    static func installed(_ emoji: InstalledCustomEmojiFfi, plaintext: Data) -> MediaUploadAttachmentRequestFfi {
        let ext = EmojiSetPresentation.fileExtension(mime: emoji.mime)
        let dim = emoji.width > 0 && emoji.height > 0 ? "\(emoji.width)x\(emoji.height)" : nil
        return MediaUploadAttachmentRequestFfi(
            fileName: "\(emoji.shortcode).\(ext)", mediaType: emoji.mime, plaintext: plaintext, dim: dim,
            thumbhash: nil)
    }
}
