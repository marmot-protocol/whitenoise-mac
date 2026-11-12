import Foundation
import MarmotKit
import Testing

@testable import whitenoise_mac

/// Peer avatars reach the chat list and the conversation as bytes MDK has already acquired, read
/// through `readAvatarAssets`. Every read used to ask for a 32 MiB budget the core rejects, so no
/// peer avatar drew anywhere; `FakeMarmotRuntime` now rejects what the core rejects.
@MainActor
struct AvatarAssetTests {
    @Test func chatListDrawsRetainedPeerAvatarForADirectChat() async {
        let runtime = FakeMarmotRuntime(accounts: [])
        let bytes = Data([0x89, 0x50, 0x4e, 0x47])
        var row = chatListRow(
            groupIdHex: "dm", title: "Alice", preview: "hi", sender: "alice", timelineAt: 1
        )
        row.conversationKind = .direct
        var presented = Self.presentedRow(row, peerID: "alice")
        presented.avatarAsset = Self.asset(target: "dm", reference: "alice-ref", byteCount: bytes.count)
        runtime.avatarBytes = [Self.bytes(reference: "alice-ref", data: bytes)]
        runtime.presentedChatListSnapshot = PresentedChatListSnapshotFfi(
            rows: [presented],
            presentationVersion: PresentationVersionFfi(
                accountStoreEpoch: Data(repeating: 1, count: 16), revision: 1
            )
        )
        let model = ChatListViewModel(account: AccountItem.samples[0], runtime: runtime)

        model.start()
        for _ in 0..<100 where model.presentedRows.isEmpty {
            await Task.yield()
        }

        let chat = model.chats(view: .chats, nicknames: .none).first
        #expect(chat?.isDirect == true)
        #expect(chat?.groupImagePayload?.data == bytes)
        model.stop()
    }

    /// MDK seeds a prepared row's avatar with its cache key, which need not be the peer. Reading
    /// the peer back out of the seed listed one person twice in the compose flow — once under
    /// that key with their picture, once from a group roster under their npub without it.
    @Test func directChatKeepsItsPeerWhenTheAvatarCacheKeyIsNotThePeer() {
        let peerHex = String(repeating: "a", count: 64)
        var row = chatListRow(
            groupIdHex: String(repeating: "d", count: 64), title: "Alice", preview: "hi",
            sender: peerHex, timelineAt: 1
        )
        row.conversationKind = .direct
        var presented = Self.presentedRow(row, peerID: peerHex)
        presented.presentation.avatar = .remoteImage(
            url: "https://example.com/alice.png", cacheKey: "avatar-cache-key")

        let chat = ChatItem(presented: presented, activeAccountIdHex: String(repeating: "f", count: 64))

        #expect(chat.avatarSeed == peerHex)
        #expect(chat.directPeerAccountIdHex == peerHex)
    }

    /// MDK's placeholder seed for a DM hashes the conversation in with the peer, so a row seeded
    /// by it drew the chat list, header and chat info in one color and the same person's member
    /// row and contact card — seeded by their hex — in another. Both now agree on the peer.
    @Test func directChatPlaceholderColorMatchesThePeerNotTheConversationHash() {
        let peerHex = String(repeating: "a", count: 64)
        let conversationHash = String(repeating: "9f", count: 32)
        var row = chatListRow(
            groupIdHex: String(repeating: "d", count: 64), title: "Alice", preview: "hi",
            sender: peerHex, timelineAt: 1
        )
        row.conversationKind = .direct
        var direct = Self.presentedRow(row, peerID: peerHex)
        direct.presentation.avatar = .placeholder(stableSeed: conversationHash, source: .peerFallback)

        let chat = ChatItem(presented: direct, activeAccountIdHex: String(repeating: "f", count: 64))

        #expect(chat.avatarSeed == peerHex)
        // The fixture only proves anything if the hash would have drawn a different accent.
        #expect(AvatarPalette.accentIndex(for: conversationHash) != AvatarPalette.accentIndex(for: peerHex))

        // A group has no single person to match, so it takes its group id — the seed the header
        // and chat info draw it with — rather than MDK's hash.
        var groupRow = row
        groupRow.conversationKind = .group
        var group = Self.presentedRow(groupRow, peerID: nil)
        group.presentation.avatar = .placeholder(stableSeed: conversationHash, source: .groupFallback)
        // What MDK sends for an unnamed group with no peer and no image; the seed no longer reads
        // it, but the fixture stays realistic.
        group.presentation.avatarSource = .groupFallback

        #expect(
            ChatItem(presented: group, activeAccountIdHex: String(repeating: "f", count: 64)).avatarSeed
                == groupRow.groupIdHex)
    }

    /// The two avatars MDK selects for a named two-member conversation with no group image
    /// (`select_chat_presentation`): the peer's picture when they publish one, otherwise a
    /// placeholder sourced from the peer. It never sends `.group` for this row — that source means
    /// the group has its own image, and then no placeholder is drawn at all.
    static let namedPairAvatars: [(SelectedAvatarFfi, PresentationSourceFfi)] = [
        (.placeholder(stableSeed: "9f", source: .peerFallback), .peerFallback),
        (.remoteImage(url: "https://example.com/alice.png", cacheKey: "alice-cache-key"), .peerProfile),
    ]

    /// A named two-member conversation is a group, but MDK still reports its other member as the
    /// presentation's `peerId` and sources its avatar from that peer. The chat list seeded the row
    /// with the peer while the conversation header and chat info — built from the row, which drops
    /// a named chat's peer — seeded it with the group id, so the same group drew in two colors.
    /// Both paths now go through `init(row:…)`, and land on the group id.
    @Test(arguments: namedPairAvatars)
    func namedTwoMemberGroupDrawsTheSameColorInTheChatListAndTheConversation(
        avatar: SelectedAvatarFfi, avatarSource: PresentationSourceFfi
    ) {
        let selfHex = String(repeating: "f", count: 64)
        let peerHex = String(repeating: "a", count: 64)
        let groupHex = String(repeating: "3", count: 64)
        let (row, presented) = Self.namedPair(
            groupHex: groupHex, peerHex: peerHex, avatar: avatar, avatarSource: avatarSource
        )

        let listed = ChatItem(presented: presented, activeAccountIdHex: selfHex)
        let opened = ChatItem(
            row: row,
            activeAccountIdHex: selfHex,
            directPeer: ChatPeerProfile(accountIdHex: peerHex, displayName: "Alice", pictureURL: nil)
        )

        #expect(listed.avatarSeed == groupHex)
        #expect(opened.avatarSeed == groupHex)
        #expect(listed.directPeerAccountIdHex == nil)
        // The fixture only proves anything if the peer's color differs from the group's.
        #expect(AvatarPalette.accentIndex(for: peerHex) != AvatarPalette.accentIndex(for: groupHex))
    }

    /// MDK also gives a named pair the peer's picture when the group has none, which the chat list
    /// drew while the header — built from the row, which drops a named chat's peer — drew the
    /// group's placeholder. The list now drops that picture too, URL and retained bytes alike.
    @Test func namedTwoMemberGroupDrawsTheSameAvatarInTheChatListAndTheConversation() {
        let selfHex = String(repeating: "f", count: 64)
        let peerHex = String(repeating: "a", count: 64)
        let (row, presented) = Self.namedPair(
            groupHex: String(repeating: "3", count: 64), peerHex: peerHex,
            avatar: .remoteImage(url: "https://example.com/alice.png", cacheKey: "alice-cache-key"),
            avatarSource: .peerProfile
        )

        let listed = ChatItem(
            presented: presented,
            activeAccountIdHex: selfHex,
            avatarBytes: Self.bytes(reference: "alice-ref", data: Data([0x89, 0x50, 0x4e, 0x47]))
        )
        let opened = ChatItem(
            row: row,
            activeAccountIdHex: selfHex,
            directPeer: ChatPeerProfile(
                accountIdHex: peerHex, displayName: "Alice", pictureURL: "https://example.com/alice.png")
        )

        #expect(listed.pictureURL == nil)
        #expect(listed.groupImagePayload == nil)
        #expect(opened.pictureURL == nil)
        #expect(opened.groupImagePayload == nil)
    }

    /// The unnamed direct chat keeps the peer's picture: only a *named* row is a group.
    @Test func unnamedDirectChatKeepsThePeersPicture() {
        let peerHex = String(repeating: "a", count: 64)
        var row = chatListRow(
            groupIdHex: String(repeating: "d", count: 64), title: "Alice", preview: "hi",
            sender: peerHex, timelineAt: 1
        )
        row.conversationKind = .direct
        let bytes = Data([0x89, 0x50, 0x4e, 0x47])
        let presented = Self.presentedRow(row, peerID: peerHex)

        let chat = ChatItem(
            presented: presented,
            activeAccountIdHex: String(repeating: "f", count: 64),
            avatarBytes: Self.bytes(reference: "alice-ref", data: bytes)
        )

        #expect(chat.pictureURL == "https://example.com/alice.png")
        #expect(chat.groupImagePayload?.data == bytes)
    }

    @Test func readsMoreAvatarsThanOneCoreBatchHolds() async throws {
        let runtime = FakeMarmotRuntime(accounts: [])
        let references = (0..<20).map { "ref-\($0)" }
        runtime.avatarBytes = references.map { Self.bytes(reference: $0, data: Data([1])) }

        let payloads = try await AvatarAssetReads.read(
            runtime: runtime, accountRef: "account", references: references
        )

        #expect(Set(payloads.keys) == Set(references))
        #expect(runtime.readAvatarReferenceBatches.map(\.count).sorted() == [4, 16])
    }

    @Test func conversationRequestsSenderAvatarsTheCoreHasNotFetched() async {
        let runtime = FakeMarmotRuntime(accounts: [])
        let ready = Self.asset(target: "ready-sender", reference: "ready-ref", byteCount: 1)
        let missing = AvatarAssetFfi(
            target: "missing-sender", reference: nil, availability: .missing,
            acquisition: .idle, contentRevision: 0, byteCount: 0
        )
        let fetching = AvatarAssetFfi(
            target: "fetching-sender", reference: nil, availability: .missing,
            acquisition: .fetching, contentRevision: 0, byteCount: 0
        )
        runtime.avatarBytes = [Self.bytes(reference: "ready-ref", data: Data([1]))]
        let store = AvatarAssetStore(accountRef: "account", runtime: runtime)

        await store.load(assets: [ready, missing, fetching])

        #expect(runtime.requestedAvatarTargetBatches == [["missing-sender"]])
        #expect(store.bytesByReference["ready-ref"]?.bytes == Data([1]))
        #expect(store.error == nil)
    }

    @Test func staleAvatarBytesStillDrawWhileARefreshIsPending() {
        var stale = Self.bytes(reference: "ref", data: Data([1]))
        stale.availability = .stale
        var deferred = Self.bytes(reference: "ref", data: Data())
        deferred.deferred = true

        #expect(AvatarAssetReads.drawablePayload(stale)?.data == Data([1]))
        #expect(AvatarAssetReads.drawablePayload(deferred) == nil)
    }

    @Test func refreshedAvatarGetsANewPayloadIdentity() {
        var first = Self.bytes(reference: "ref", data: Data([1]))
        first.contentRevision = 1
        var refreshed = first
        refreshed.contentRevision = 2

        #expect(
            AvatarAssetReads.drawablePayload(first)?.id != AvatarAssetReads.drawablePayload(refreshed)?.id
        )
    }

    private static func asset(target: String, reference: String, byteCount: Int) -> AvatarAssetFfi {
        AvatarAssetFfi(
            target: target, reference: reference, availability: .ready,
            acquisition: nil, contentRevision: 1, byteCount: UInt64(byteCount)
        )
    }

    private static func bytes(reference: String, data: Data) -> AvatarBytesFfi {
        AvatarBytesFfi(
            reference: reference, availability: .ready, contentRevision: 1,
            byteCount: UInt64(data.count), deferred: false, bytes: data,
            mediaType: "image/png", width: 1, height: 1
        )
    }

    private static func namedPair(
        groupHex: String, peerHex: String, avatar: SelectedAvatarFfi, avatarSource: PresentationSourceFfi
    ) -> (ChatListRowFfi, PresentedChatRowFfi) {
        var row = chatListRow(
            groupIdHex: groupHex, title: "Book club", preview: "hi", sender: peerHex, timelineAt: 1
        )
        row.groupName = "Book club"
        row.conversationKind = .group
        var presented = presentedRow(row, peerID: peerHex)
        presented.presentation.avatar = avatar
        presented.presentation.avatarSource = avatarSource
        presented.presentation.titleSource = .group
        return (row, presented)
    }

    private static func presentedRow(_ row: ChatListRowFfi, peerID: String?) -> PresentedChatRowFfi {
        PresentedChatRowFfi(
            draftVersion: nil,
            preview: .message,
            actions: ChatListRowActionsFfi(
                canMarkRead: false, canMarkUnread: true, canPin: true, canUnpin: false,
                canMute: true, canUnmute: false, canArchive: true, canRestore: false,
                canStartLeave: true, canDeleteLocal: false
            ),
            row: row,
            presentation: ConversationPresentationFfi(
                title: .literal(text: row.title),
                avatar: .remoteImage(url: "https://example.com/alice.png", cacheKey: peerID ?? row.groupIdHex),
                titleSource: .peerProfile,
                avatarSource: .peerProfile,
                peerId: peerID,
                resolution: .cached
            ),
            avatarAsset: nil
        )
    }
}
