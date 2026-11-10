import Foundation
import MarmotKit
import Testing

@testable import whitenoise_mac

/// Sending NIP-30 custom emoji: which emoji a chat can send, the tags a message carries, and that
/// every image is re-encrypted into the chat once and never fetched from a tag URL.
struct CustomEmojiSendingTests {
    private static let group = "group"

    private static func reference(
        _ name: String, plaintext: Data, url: String? = nil, epoch: UInt64 = 1
    ) -> MediaAttachmentReferenceFfi {
        MediaAttachmentReferenceFfi(
            locators: [MediaLocatorFfi(kind: "blossom", value: url ?? "https://example.invalid/\(name)")],
            ciphertextSha256: String(repeating: "c", count: 64),
            plaintextSha256: CustomEmojiDigest.hex(plaintext),
            nonceHex: String(repeating: "0", count: 24),
            fileName: "\(name).png",
            mediaType: "image/png",
            version: .v1,
            sourceEpoch: epoch,
            sourceEpochIdentity: nil,
            dim: "8x8",
            thumbhash: nil
        )
    }

    private static func installed(_ shortcode: String, set: String = "30030:a:set", bytes: Data)
        -> InstalledCustomEmojiFfi
    {
        InstalledCustomEmojiFfi(
            setCoordinate: set, setTitle: "Set", authorPubkeyHex: "a", shortcode: shortcode, mime: "image/png",
            width: 8, height: 8, frames: 1, sha256: CustomEmojiDigest.hex(bytes), byteLen: UInt64(bytes.count),
            shortcodeCollision: false)
    }

    private static func emojiSet(_ shortcodes: [String], coordinate: String = "30030:a:set") -> EmojiSetFfi {
        EmojiSetFfi(
            coordinate: coordinate, kind: 30030, authorPubkeyHex: "a", identifier: "set",
            eventIdHex: String(repeating: "e", count: 64), createdAt: 0, title: "Set", description: nil,
            imageUrl: nil, emoji: shortcodes.map { EmojiSetEmojiFfi(shortcode: $0, url: "https://x.invalid/\($0)") },
            skipped: [], skippedCount: 0, installed: nil)
    }

    // MARK: - Built-ins

    @Test func theBuiltInsLoadFromTheBundleWithTheirDigests() throws {
        #expect(CustomEmojiBuiltins.all.map(\.shortcode) == ["marmot", "wn"])
        let wn = try #require(CustomEmojiBuiltins.builtin("wn"))
        #expect(wn.plaintextSha256 == CustomEmojiDigest.hex(wn.data))
        #expect(wn.dim == "72x72")
        #expect(wn.spokenName == "White Noise")
    }

    // MARK: - Catalog

    @Test func aBuiltInBeatsAnInstalledEmojiWhichBeatsOneSeenInTheChat() {
        let bytes = Data("party".utf8)
        let sendables = CustomEmojiSendCatalog.sendables(
            installed: [Self.installed("wn", bytes: bytes), Self.installed("party", bytes: bytes)],
            chat: [
                CustomEmojiChatEntry(shortcode: "party", reference: Self.reference("party", plaintext: bytes)),
                CustomEmojiChatEntry(shortcode: "cat", reference: Self.reference("cat", plaintext: bytes)),
                CustomEmojiChatEntry(
                    shortcode: String(repeating: "x", count: 63), reference: Self.reference("x", plaintext: bytes)),
            ]
        )

        #expect(sendables.map(\.shortcode) == ["marmot", "wn", "party", "cat"])
        guard case .builtin = sendables[1].artwork else {
            Issue.record("wn should stay built in")
            return
        }
        guard case .installed = sendables[2].artwork else {
            Issue.record("party should be installed")
            return
        }
    }

    @Test func usedEmojiAreListedOnceInTheOrderTheyFirstAppear() {
        let sendables = CustomEmojiSendCatalog.sendables(installed: [], chat: [])

        let used = CustomEmojiSendCatalog.used(in: ":wn: hi :marmot: :unknown: :wn:", sendables: sendables)

        #expect(used.map(\.shortcode) == ["wn", "marmot"])
        #expect(CustomEmojiSendCatalog.used(in: "no emoji here", sendables: sendables).isEmpty)
    }

    @Test func aReactionTokenFindsItsSendable() {
        let sendables = CustomEmojiSendCatalog.sendables(installed: [], chat: [])

        #expect(CustomEmojiSendCatalog.sendable(forReaction: ":wn:", in: sendables)?.shortcode == "wn")
        #expect(CustomEmojiSendCatalog.sendable(forReaction: "👍", in: sendables) == nil)
        #expect(CustomEmojiSendCatalog.sendable(forReaction: ":nope:", in: sendables) == nil)
    }

    @Test func theChatCatalogKeepsOnlyEmojiWhoseImageTheMessageCarries() {
        let image = Self.reference("cat", plaintext: Data("cat".utf8), url: "https://h/cat")
        let newer = timelineMessage(
            id: "m2", groupIdHex: Self.group, sender: "alice", plaintext: ":cat: :ghost:",
            tags: [
                MessageTagFfi(values: ["emoji", "cat", "https://h/cat"]),
                MessageTagFfi(values: ["emoji", "ghost", "https://h/not-attached"]),
            ],
            recordedAt: 2, media: [image])
        let olderImage = Self.reference("cat-old", plaintext: Data("old".utf8), url: "https://h/old")
        let older = timelineMessage(
            id: "m1", groupIdHex: Self.group, sender: "bob", plaintext: ":cat:",
            tags: [MessageTagFfi(values: ["emoji", "cat", "https://h/old"])], recordedAt: 1, media: [olderImage])

        let entries = CustomEmojiChatCatalog.entries([older, newer])

        #expect(entries == [CustomEmojiChatEntry(shortcode: "cat", reference: image)])
    }

    @Test func installedEmojiAreGroupedBySetAfterTheRest() {
        let bytes = Data("x".utf8)
        let sendables = CustomEmojiSendCatalog.sendables(
            installed: [Self.installed("a", set: "s1", bytes: bytes), Self.installed("b", set: "s2", bytes: bytes)],
            chat: [])

        let groups = CustomEmojiSendCatalog.pickerGroups(sendables)

        #expect(groups.map(\.id) == ["custom", "s1", "s2"])
        #expect(groups[0].emoji.map(\.shortcode) == ["marmot", "wn"])
    }

    // MARK: - Tags

    @Test func aReplyCarriesItsEmojiTagsThenTheReplyRows() throws {
        let reference = Self.reference("wn", plaintext: Data("wn".utf8), url: "https://h/wn")

        let tags = try CustomEmojiTags.messageTags(emoji: [("wn", reference)], replyTargetId: "target")

        #expect(tags == [["emoji", "wn", "https://h/wn"], ["e", "target"], ["q", "target"]])
    }

    @Test func tagsOutsideMDKsLimitsAreRefusedBeforeSending() {
        #expect(throws: CustomEmojiSendError.forbiddenImetaTag) { try CustomEmojiTags.validate([["imeta", "x"]]) }
        #expect(throws: CustomEmojiSendError.emptyEventTarget) { try CustomEmojiTags.validate([["e", " "]]) }
        #expect(throws: CustomEmojiSendError.malformedTag) { try CustomEmojiTags.validate([[]]) }
        #expect(throws: CustomEmojiSendError.tooManyTags(count: 65)) {
            try CustomEmojiTags.precheck(emojiCount: 63, isReply: true)
        }
        #expect(throws: CustomEmojiSendError.tagValuesTooLarge(bytes: 17_000)) {
            try CustomEmojiTags.validate([["x", String(repeating: "a", count: 16_999)]])
        }
    }

    // MARK: - Sending

    @MainActor
    @Test func aMessageUploadsEachImageOnceAndSendsItTagged() async throws {
        let runtime = FakeMarmotRuntime(accounts: [])
        let sender = ConversationCustomEmojiSender(accountRef: "account", groupIdHex: Self.group, runtime: runtime)
        let emoji = CustomEmojiSendCatalog.sendables(installed: [], chat: [])

        try await sender.sendMessage(text: ":wn: :marmot: :wn:", replyTargetId: nil, emoji: emoji)

        let sent = try #require(runtime.taggedMediaSends.first)
        #expect(sent.groupIdHex == Self.group)
        #expect(sent.caption == ":wn: :marmot: :wn:")
        #expect(sent.attachments.count == 2)
        #expect(sent.tags.map { Array($0.prefix(2)) } == [["emoji", "marmot"], ["emoji", "wn"]])
        #expect(sent.tags.map { $0[2] } == sent.attachments.map { $0.locators[0].value })
        // Uploaded, not sent: the tagged message is the one send.
        #expect(runtime.uploadedMediaRequests.allSatisfy { !$0.request.send })
        #expect(sender.uploadCount == 2)
    }

    @MainActor
    @Test func aRetryReusesTheUploadedImages() async throws {
        let runtime = FakeMarmotRuntime(accounts: [])
        runtime.sendTaggedMediaErrors = [MarmotKitError.Publish(details: "offline")]
        let sender = ConversationCustomEmojiSender(accountRef: "account", groupIdHex: Self.group, runtime: runtime)
        let wn = try #require(CustomEmojiSendCatalog.sendables(installed: [], chat: []).last)

        #expect(await !sender.submit(text: ":wn:", replyTargetId: nil, emoji: [wn]))
        #expect(sender.errorMessage == CustomEmojiSendError.sendFailed.message)
        #expect(await sender.submit(text: ":wn:", replyTargetId: nil, emoji: [wn]))

        #expect(sender.errorMessage == nil)
        #expect(runtime.taggedMediaSends.count == 1)
        #expect(sender.uploadCount == 1)
    }

    @MainActor
    @Test func aStaleEpochReencryptsOnceAndSends() async throws {
        let runtime = FakeMarmotRuntime(accounts: [])
        runtime.sendTaggedMediaErrors = [MarmotKitError.MediaReferenceStaleEpoch(sourceEpoch: 1, currentEpoch: 2)]
        let sender = ConversationCustomEmojiSender(accountRef: "account", groupIdHex: Self.group, runtime: runtime)
        let wn = try #require(CustomEmojiSendCatalog.sendables(installed: [], chat: []).last)

        try await sender.sendMessage(text: ":wn:", replyTargetId: nil, emoji: [wn])

        #expect(runtime.taggedMediaSends.count == 1)
        #expect(sender.uploadCount == 2)
    }

    @MainActor
    @Test func anInstalledEmojiUploadsItsStoredBytes() async throws {
        let runtime = FakeMarmotRuntime(accounts: [])
        let bytes = Data("blob".utf8)
        runtime.emojiSetStore = [Self.emojiSet(["blob"])]
        runtime.emojiSetAssetBytes["blob"] = bytes
        _ = try await runtime.installEmojiSet(
            accountRef: "account", coordinate: "30030:a:set", expectedEventIdHex: String(repeating: "e", count: 64),
            control: EmojiSetInstallControlFfi())
        let installed = try await runtime.installedCustomEmoji(accountRef: "account")
        let sender = ConversationCustomEmojiSender(accountRef: "account", groupIdHex: Self.group, runtime: runtime)
        let blob = try #require(CustomEmojiSendable(installed: installed[0]))

        try await sender.sendMessage(text: ":blob:", replyTargetId: nil, emoji: [blob])

        let upload = try #require(runtime.uploadedMediaRequests.first?.request.attachments.first)
        #expect(upload.plaintext == bytes)
        #expect(upload.fileName == "blob.png")
    }

    @MainActor
    @Test func aChatEmojiWhoseBytesAreUnavailableIsNotSent() async throws {
        let runtime = FakeMarmotRuntime(accounts: [])
        let sender = ConversationCustomEmojiSender(accountRef: "account", groupIdHex: Self.group, runtime: runtime)
        let cat = CustomEmojiSendable(
            shortcode: "cat", chatReference: Self.reference("cat", plaintext: Data("cat".utf8)))

        await #expect(throws: CustomEmojiSendError.imageUnavailable) {
            try await sender.sendMessage(text: ":cat:", replyTargetId: nil, emoji: [cat])
        }
        #expect(runtime.taggedMediaSends.isEmpty)
        #expect(runtime.uploadMediaCallCount == 0)
    }

    @MainActor
    @Test func aCustomReactionCarriesItsImageAndOneEmojiTag() async throws {
        let runtime = FakeMarmotRuntime(accounts: [])
        let sender = ConversationCustomEmojiSender(accountRef: "account", groupIdHex: Self.group, runtime: runtime)
        let wn = try #require(CustomEmojiSendCatalog.sendables(installed: [], chat: []).last)

        await sender.react(with: wn, to: "target")

        let reaction = try #require(runtime.mediaReactions.first)
        #expect(reaction.target == "target")
        #expect(reaction.emoji == ":wn:")
        #expect(reaction.attachments.count == 1)
        #expect(reaction.tags == [["emoji", "wn", reaction.attachments[0].locators[0].value]])
        #expect(sender.errorMessage == nil)
    }

    // MARK: - Composer

    @MainActor
    private static func directChatWorkspace() async -> (WorkspaceState, FakeMarmotRuntime, ConversationViewModel) {
        let account = AccountSummaryFfi(
            label: "Desktop Account",
            accountIdHex: "abcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890",
            localSigning: true, externalSigning: false, signedOut: false, running: true, unlinked: false)
        let runtime = FakeMarmotRuntime(accounts: [account])
        runtime.installDirectGroup(
            directGroup(),
            selfAccountIdHex: account.accountIdHex,
            otherAccountIdHex: "alice1234567890alice1234567890alice1234567890alice1234567890",
            otherDisplayName: "Alice",
            otherProfile: UserProfileMetadataFfi(
                name: "alice", displayName: "Alice", about: nil, picture: nil, nip05: nil, lud16: nil))
        let state = WorkspaceState(clientFactory: { runtime })
        await state.bootstrap()
        let conversation = ConversationViewModel(
            account: state.activeAccount!, groupIdHex: "direct-group", runtime: runtime)
        return (state, runtime, conversation)
    }

    @MainActor
    @Test func aComposerDraftWithCustomEmojiIsSentTaggedAndThenCleared() async throws {
        let (state, runtime, conversation) = await Self.directChatWorkspace()
        state.startReply(
            to: MessageItem(
                id: "parent", senderName: "Alice", body: "Hi", sentAt: Date(timeIntervalSince1970: 1),
                isOutgoing: false))
        state.draftText = "hello :wn:"

        let outcome = await CustomEmojiComposerSend.send(workspace: state, conversation: conversation)

        #expect(outcome == .sent)
        let sent = try #require(runtime.taggedMediaSends.first)
        #expect(sent.caption == "hello :wn:")
        #expect(sent.tags.contains(["e", "parent"]))
        #expect(state.draftText.isEmpty)
        #expect(state.replyDraftContext == nil)
        #expect(!state.isSending)
        #expect(runtime.sendTextCallCount == 0)
    }

    @MainActor
    @Test func aFailedCustomEmojiSendKeepsTheDraft() async throws {
        let (state, runtime, conversation) = await Self.directChatWorkspace()
        runtime.sendTaggedMediaErrors = [MarmotKitError.Publish(details: "offline")]
        state.draftText = ":marmot:"

        let outcome = await CustomEmojiComposerSend.send(workspace: state, conversation: conversation)

        #expect(outcome == .kept)
        #expect(state.draftText == ":marmot:")
        #expect(conversation.customEmojiSender.errorMessage == CustomEmojiSendError.sendFailed.message)
    }

    @MainActor
    @Test func aDraftWithoutCustomEmojiIsLeftToTheOrdinarySend() async {
        let (state, runtime, conversation) = await Self.directChatWorkspace()
        state.draftText = "plain :not-an-emoji: text"

        #expect(await CustomEmojiComposerSend.send(workspace: state, conversation: conversation) == .notCustom)
        #expect(runtime.taggedMediaSends.isEmpty)
        #expect(state.draftText == "plain :not-an-emoji: text")
    }

    @MainActor
    @Test func aStoppedSenderSendsNothing() async throws {
        let runtime = FakeMarmotRuntime(accounts: [])
        let sender = ConversationCustomEmojiSender(accountRef: "account", groupIdHex: Self.group, runtime: runtime)
        let wn = try #require(CustomEmojiSendCatalog.sendables(installed: [], chat: []).last)
        sender.stop()

        #expect(await !sender.submit(text: ":wn:", replyTargetId: nil, emoji: [wn]))
        #expect(sender.errorMessage == nil)
        #expect(runtime.taggedMediaSends.isEmpty)
    }
}
