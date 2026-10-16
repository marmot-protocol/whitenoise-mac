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

        // A group has no single person to match, so it keeps MDK's seed.
        var groupRow = row
        groupRow.conversationKind = .group
        var group = Self.presentedRow(groupRow, peerID: nil)
        group.presentation.avatar = .placeholder(stableSeed: conversationHash, source: .groupFallback)

        #expect(
            ChatItem(presented: group, activeAccountIdHex: String(repeating: "f", count: 64)).avatarSeed
                == conversationHash)
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
