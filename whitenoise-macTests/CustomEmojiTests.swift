import AppKit
import Foundation
import MarmotKit
import Testing

@testable import whitenoise_mac

/// NIP-30 custom emoji: `["emoji", shortcode, url]` tags whose URL is the locator of one of the
/// event's own attachments (MarmotKit 0.12.0).
struct CustomEmojiTests {
    // MARK: - Tags and text

    @Test func parsesWellFormedEmojiTagsOnlyOncePerShortcode() {
        let tags = CustomEmojiTag.parse([
            MessageTagFfi(values: ["emoji", "party", "https://blob.example/party.png"]),
            MessageTagFfi(values: ["emoji", "party", "https://blob.example/other.png"]),
            MessageTagFfi(values: ["emoji", "bad code", "https://blob.example/bad.png"]),
            MessageTagFfi(values: ["emoji", "missing_url"]),
            MessageTagFfi(values: ["emoji", "no-url", ""]),
            MessageTagFfi(values: ["imeta", "locator blossom https://blob.example/party.png"]),
            MessageTagFfi(values: ["emoji", "thumbs_up-2", "https://blob.example/up.png"]),
        ])

        #expect(
            tags == [
                CustomEmojiTag(shortcode: "party", url: "https://blob.example/party.png"),
                CustomEmojiTag(shortcode: "thumbs_up-2", url: "https://blob.example/up.png"),
            ])
    }

    @Test func segmentsSplitOnlyKnownShortcodes() {
        let segments = CustomEmojiText.segments(in: "hi :party: and :nope: :party:!", shortcodes: ["party"])

        #expect(
            segments == [
                .text("hi "), .emoji("party"), .text(" and :nope: "), .emoji("party"), .text("!"),
            ])
    }

    @Test func aClosingColonCanOpenTheNextToken() {
        #expect(
            CustomEmojiText.segments(in: "a:b c:party:", shortcodes: ["party"]) == [
                .text("a:b c"), .emoji("party"),
            ])
        #expect(CustomEmojiText.segments(in: ":a:b:", shortcodes: ["a", "b"]) == [.emoji("a"), .text("b:")])
        #expect(CustomEmojiText.shortcodes(in: "time 10:30:45 :ok:") == ["30", "ok"])
    }

    @Test func soleEmojiIsOneResolvableShortcodeAndNothingElse() {
        #expect(CustomEmojiText.soleEmoji(in: "  :party:\n", shortcodes: ["party"]) == "party")
        #expect(CustomEmojiText.soleEmoji(in: ":party::party:", shortcodes: ["party"]) == nil)
        #expect(CustomEmojiText.soleEmoji(in: ":party: yay", shortcodes: ["party"]) == nil)
        #expect(CustomEmojiText.soleEmoji(in: ":party:", shortcodes: []) == nil)
    }

    @Test func reactionShortcodeRequiresTheWholeContent() {
        #expect(CustomEmojiText.reactionShortcode(":party:") == "party")
        #expect(CustomEmojiText.reactionShortcode("👍") == nil)
        #expect(CustomEmojiText.reactionShortcode("::") == nil)
        #expect(CustomEmojiText.reactionShortcode(":two words:") == nil)
    }

    // MARK: - Messages

    @Test func emojiResolvesOnlyToAnImageAttachmentWhoseLocatorMatches() {
        let party = Self.attachment("party.png")
        let unused = Self.attachment("unused.png")
        let file = Self.attachment("doc.pdf", mediaType: "application/pdf")
        let tags = [
            CustomEmojiTag(shortcode: "party", url: "https://blob.example/party.png"),
            CustomEmojiTag(shortcode: "unused", url: "https://blob.example/unused.png"),
            CustomEmojiTag(shortcode: "doc", url: "https://blob.example/doc.pdf"),
            CustomEmojiTag(shortcode: "remote", url: "https://elsewhere.example/remote.png"),
        ]

        let resolved = CustomEmojiTag.resolve(
            tags, attachments: [party, unused, file], text: ":party: :doc: :remote: and that's it")

        #expect(resolved == ["party": party])
    }

    @Test func emojiAttachmentsLeaveTheMediaGridAndTheDownloadAction() {
        let party = Self.attachment("party.png")
        let photo = Self.attachment("photo.png")
        let message = MessageItem(
            id: "message",
            senderName: "alice",
            body: "look :party:",
            sentAt: .now,
            isOutgoing: false,
            mediaAttachments: [party, photo],
            customEmojiTags: [CustomEmojiTag(shortcode: "party", url: "https://blob.example/party.png")]
        )

        #expect(message.customEmoji == ["party": party])
        #expect(message.contentMediaAttachments == [photo])
        #expect(message.visualMediaAttachments == [photo])
        #expect(message.mediaAttachments == [party, photo])
        #expect(message.canDownloadMediaAttachments)
    }

    @Test func aTagTheTextDoesNotUseKeepsItsAttachmentInTheGrid() {
        let party = Self.attachment("party.png")
        let message = MessageItem(
            id: "message",
            senderName: "alice",
            body: "no shortcode here",
            sentAt: .now,
            isOutgoing: false,
            mediaAttachments: [party],
            customEmojiTags: [CustomEmojiTag(shortcode: "party", url: "https://blob.example/party.png")]
        )

        #expect(message.customEmoji.isEmpty)
        #expect(message.visualMediaAttachments == [party])
    }

    @Test func anEditReResolvesTheTagsAgainstTheNewText() {
        let party = Self.attachment("party.png")
        let message = MessageItem(
            id: "message",
            senderName: "alice",
            body: "first",
            sentAt: .now,
            isOutgoing: false,
            mediaAttachments: [party],
            customEmojiTags: [CustomEmojiTag(shortcode: "party", url: "https://blob.example/party.png")]
        )

        let edited = message.applyingEdit(plaintext: "now :party:")

        #expect(edited.customEmoji == ["party": party])
        #expect(edited.visualMediaAttachments.isEmpty)
    }

    @Test func timelineMappingKeepsChatEmojiTagsAndDropsThemFromDeletedRows() throws {
        let reference = mediaAttachmentReference(mediaType: "image/png", fileName: "party.png")
        let emojiTag = MessageTagFfi(values: ["emoji", "party", "https://blob.example/party.png"])
        let page = TimelinePageFfi(
            messages: [
                timelineMessage(
                    id: "live", groupIdHex: "group", sender: "alice", plaintext: "yay :party:",
                    tags: [emojiTag], recordedAt: 1, mediaJson: mediaJson(for: reference)),
                timelineMessage(
                    id: "deleted", groupIdHex: "group", sender: "alice", plaintext: "yay :party:",
                    tags: [emojiTag], recordedAt: 2, mediaJson: mediaJson(for: reference), deleted: true),
            ],
            hasMoreBefore: false,
            hasMoreAfter: false
        )

        let messages = MessageItem.timeline(from: page, activeAccountIdHex: "self")

        #expect(messages.first { $0.id == "live" }?.customEmoji.keys.sorted() == ["party"])
        #expect(messages.first { $0.id == "live" }?.visualMediaAttachments.isEmpty == true)
        #expect(messages.first { $0.id == "deleted" }?.customEmojiTags.isEmpty == true)
    }

    // MARK: - Reactions

    @Test func preparedReactionsCarryTheKind7ThatNamesTheirImage() {
        let reactions = MessageReaction.prepared(
            ConversationReactionsFfi(
                totalCount: 2,
                totalKinds: 2,
                items: [
                    ConversationReactionFfi(
                        emoji: ":party:", count: 1, reactors: ["alice"], viewerReacted: false,
                        reactionMessageIdHex: "kind7"),
                    ConversationReactionFfi(
                        emoji: "👍", count: 1, reactors: ["bob"], viewerReacted: false, reactionMessageIdHex: "k2"),
                ],
                omittedKinds: 0
            ),
            activeAccountIdHex: "self"
        )

        #expect(reactions.map(\.reactionMessageIdHex) == ["kind7", "k2"])
        #expect(reactions.map(\.customEmojiShortcode) == ["party", nil])
    }

    @Test func aReactionResolvesToItsKind7sFirstAttachment() {
        let first = mediaAttachmentReference(mediaType: "image/png", fileName: "a.png", plaintextSha256: "a")
        let second = mediaAttachmentReference(mediaType: "image/png", fileName: "b.png", plaintextSha256: "b")
        let records = [
            Self.record(messageIdHex: "kind7", index: 1, reference: second),
            Self.record(messageIdHex: "kind7", index: 0, reference: first),
            Self.record(messageIdHex: "other", index: 0, reference: second),
        ]

        let resolved = CustomEmojiImageStore.reactionReferences(in: records, for: ["kind7", "missing"])

        #expect(resolved == ["kind7": first])
    }

    // MARK: - Image store

    @MainActor
    @Test func loadsAMessageEmojiOnceAndServesItFromTheStore() async throws {
        let runtime = FakeMarmotRuntime(accounts: [])
        let reference = mediaAttachmentReference(mediaType: "image/png", fileName: "party.png")
        runtime.installMediaRecord(
            Self.record(messageIdHex: "message", index: 0, reference: reference),
            download: try Self.pngDownload()
        )
        let store = Self.store(runtime: runtime)

        store.load(reference)
        store.load(reference)
        let loaded = await waitFor { store.image(for: reference) != nil }

        #expect(loaded)
        #expect(runtime.downloadMediaCallCount == 1)
        #expect(!store.hasFailed(reference))
    }

    @MainActor
    @Test func aFailedDownloadIsRememberedAndNotRetried() async throws {
        let runtime = FakeMarmotRuntime(accounts: [])
        let reference = mediaAttachmentReference(mediaType: "image/png", fileName: "gone.png")
        let store = Self.store(runtime: runtime)

        store.load(reference)
        let failed = await waitFor { store.hasFailed(reference) }
        store.load(reference)

        #expect(failed)
        #expect(store.image(for: reference) == nil)
        #expect(runtime.downloadMediaCallCount == 1)
    }

    @MainActor
    @Test func reactionImagesResolveThroughListMediaAndLoad() async throws {
        let runtime = FakeMarmotRuntime(accounts: [])
        let reference = mediaAttachmentReference(mediaType: "image/png", fileName: "party.png")
        runtime.installMediaRecord(
            Self.record(messageIdHex: "kind7", index: 0, reference: reference),
            download: try Self.pngDownload()
        )
        let store = Self.store(runtime: runtime)
        let reaction = MessageReaction(emoji: ":party:", count: 1, isOwn: false, reactionMessageIdHex: "kind7")
        let unicode = MessageReaction(emoji: "👍", count: 1, isOwn: false, reactionMessageIdHex: "k2")

        store.loadReactions([reaction, unicode])
        let loaded = await waitFor { store.reactionImage(for: reaction) != nil }

        #expect(loaded)
        #expect(store.reactionImage(for: unicode) == nil)
        #expect(runtime.listMediaCallCount == 1)
    }

    @MainActor
    @Test func anUnresolvedReactionIsNotListedAgainUntilTheRetryInterval() async throws {
        let runtime = FakeMarmotRuntime(accounts: [])
        var clock = Date(timeIntervalSince1970: 1_000)
        let store = CustomEmojiImageStore(
            accountId: "account",
            accountRef: "account",
            groupIdHex: "group",
            runtime: runtime,
            diskCache: MessageMediaDiskCache.makeIsolated(),
            now: { clock }
        )
        let reaction = MessageReaction(emoji: ":party:", count: 1, isOwn: false, reactionMessageIdHex: "kind7")

        store.loadReactions([reaction])
        #expect(await waitFor { runtime.listMediaCallCount == 1 })
        // Let the lookup finish recording the miss.
        try await Task.sleep(nanoseconds: 50_000_000)
        store.loadReactions([reaction])
        try await Task.sleep(nanoseconds: 50_000_000)
        #expect(runtime.listMediaCallCount == 1)

        clock = clock.addingTimeInterval(CustomEmojiImageStore.unresolvedReactionRetryInterval + 1)
        store.loadReactions([reaction])

        #expect(await waitFor { runtime.listMediaCallCount == 2 })
    }

    // MARK: - Helpers

    private static func attachment(_ fileName: String, mediaType: String = "image/png") -> MessageMediaAttachment {
        MessageMediaAttachment(
            id: "message:\(fileName)",
            reference: mediaAttachmentReference(
                mediaType: mediaType, fileName: fileName, plaintextSha256: "sha-\(fileName)")
        )
    }

    private static func record(
        messageIdHex: String,
        index: UInt32,
        reference: MediaAttachmentReferenceFfi
    ) -> MediaRecordFfi {
        MediaRecordFfi(
            messageIdHex: messageIdHex,
            attachmentIndex: index,
            direction: "inbound",
            groupIdHex: "group",
            sender: "alice",
            reference: reference,
            caption: nil,
            recordedAt: 1,
            receivedAt: 1
        )
    }

    @MainActor
    private static func store(runtime: FakeMarmotRuntime) -> CustomEmojiImageStore {
        CustomEmojiImageStore(
            accountId: "account",
            accountRef: "account",
            groupIdHex: "group",
            runtime: runtime,
            diskCache: MessageMediaDiskCache.makeIsolated()
        )
    }

    private static func pngDownload() throws -> MediaDownloadResultFfi {
        let bitmap = try #require(
            NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: 8, pixelsHigh: 8, bitsPerSample: 8, samplesPerPixel: 4,
                hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        let data = try #require(bitmap.representation(using: .png, properties: [:]))
        return MediaDownloadResultFfi(
            plaintext: data, fileName: "party.png", mediaType: "image/png", sizeBytes: UInt64(data.count))
    }
}
