import Foundation
import MarmotKit
import Testing

@testable import whitenoise_mac

private let aliceAccountIdHex = String(repeating: "a", count: 64)
private let bidiOnlyPublishedName = "\u{202E}\u{200F}"

struct ContactNicknameValueTests {

    @Test func hexComponentsAreTrimmedAndLowercased() {
        let nicknames = ContactNicknames(
            ownerAccountIdHex: "  OWNER  ",
            byContactIdHex: ["  CONTACT  ": "Mum"]
        )

        #expect(nicknames.ownerAccountIdHex == "owner")
        #expect(nicknames.nickname(forContactAccountIdHex: "contact") == "Mum")
        #expect(nicknames.nickname(forContactAccountIdHex: " CoNtAcT ") == "Mum")
    }

    @Test func blankComponentsNeverResolve() {
        let nicknames = ContactNicknames(ownerAccountIdHex: "owner", byContactIdHex: ["": "Mum", "  ": "Dad"])

        #expect(nicknames.isEmpty)
        #expect(nicknames.nickname(forContactAccountIdHex: "") == nil)
        #expect(nicknames.nickname(forContactAccountIdHex: "   ") == nil)
    }

    /// An unresolved owner must read as "no nicknames" rather than falling through to whatever
    /// entries happen to be in hand — that is what keeps the signed-out window from borrowing
    /// another account's private labels.
    @Test func emptyOwnerResolvesNothing() {
        let nicknames = ContactNicknames(ownerAccountIdHex: "   ", byContactIdHex: ["contact": "Mum"])

        #expect(nicknames.ownerAccountIdHex.isEmpty)
        #expect(nicknames.nickname(forContactAccountIdHex: "contact") == nil)
        #expect(nicknames.displayName(forContactAccountIdHex: "contact", published: "Alice") == "Alice")
        #expect(ContactNicknames.none.nickname(forContactAccountIdHex: "contact") == nil)
    }

    @Test func nicknameOutranksThePublishedNameAndFallsBackWhenAbsent() {
        let nicknames = ContactNicknames(ownerAccountIdHex: "owner", byContactIdHex: ["alice": "Mum"])

        #expect(nicknames.displayName(forContactAccountIdHex: "alice", published: "Alice") == "Mum")
        #expect(nicknames.displayName(forContactAccountIdHex: "alice", published: nil) == "Mum")
        #expect(nicknames.displayName(forContactAccountIdHex: "bob", published: "Bob") == "Bob")
        #expect(nicknames.displayName(forContactAccountIdHex: "bob", published: nil) == nil)
    }

    @Test func twoOwnersResolveIndependently() {
        let first = ContactNicknames(ownerAccountIdHex: "owner-a", byContactIdHex: ["alice": "Mum"])
        let second = ContactNicknames(ownerAccountIdHex: "owner-b", byContactIdHex: ["alice": "Boss"])

        #expect(first.nickname(forContactAccountIdHex: "alice") == "Mum")
        #expect(second.nickname(forContactAccountIdHex: "alice") == "Boss")
        #expect(first != second)
    }

    @Test func storedValuesAreReSanitizedOnConstruction() {
        let nicknames = ContactNicknames(
            ownerAccountIdHex: "owner",
            byContactIdHex: [
                "alice": "M\u{202E}um",
                "bob": "\u{202E}\u{200F}",
                "carol": "   ",
                "dave": "\u{0007}",
            ]
        )

        #expect(nicknames.nickname(forContactAccountIdHex: "alice") == "Mum")
        #expect(nicknames.nickname(forContactAccountIdHex: "bob") == nil)
        #expect(nicknames.nickname(forContactAccountIdHex: "carol") == nil)
        #expect(nicknames.nickname(forContactAccountIdHex: "dave") == nil)
    }

    @Test func sanitizedRejectsBlankInputAndBoundsLength() {
        #expect(ContactNicknames.sanitized(nil) == nil)
        #expect(ContactNicknames.sanitized("") == nil)
        #expect(ContactNicknames.sanitized("   \n ") == nil)
        #expect(ContactNicknames.sanitized(" Mum ") == "Mum")

        let long = String(repeating: "a", count: ContactNicknames.maxLength + 25)
        #expect(ContactNicknames.sanitized(long)?.count == ContactNicknames.maxLength)
    }

    // MARK: - Owner gate

    @Test func noActiveAccountMeansNoOwner() {
        #expect(
            ContactNicknames.owner(
                activeAccountIdHex: nil,
                localAccountIdsHex: ["owner"],
                contactAccountIdHex: "alice"
            ) == nil
        )
        #expect(
            ContactNicknames.owner(
                activeAccountIdHex: "   ",
                localAccountIdsHex: ["owner"],
                contactAccountIdHex: "alice"
            ) == nil
        )
    }

    @Test func blankContactHasNoOwner() {
        #expect(
            ContactNicknames.owner(
                activeAccountIdHex: "owner",
                localAccountIdsHex: ["owner"],
                contactAccountIdHex: "  "
            ) == nil
        )
    }

    @Test func ownAccountsCannotBeNicknamed() {
        #expect(
            ContactNicknames.owner(
                activeAccountIdHex: "OWNER",
                localAccountIdsHex: ["owner", "second-local"],
                contactAccountIdHex: "owner"
            ) == nil
        )
        #expect(
            ContactNicknames.owner(
                activeAccountIdHex: "owner",
                localAccountIdsHex: ["owner", "SECOND-LOCAL"],
                contactAccountIdHex: "second-local"
            ) == nil
        )
    }

    @Test func otherContactsResolveToTheActiveOwner() {
        #expect(
            ContactNicknames.owner(
                activeAccountIdHex: " OWNER ",
                localAccountIdsHex: ["owner"],
                contactAccountIdHex: " ALICE "
            ) == "owner"
        )
    }

    @Test func storeRoundTripsPerOwnerMaps() throws {
        let (store, directory) = temporaryStore()
        defer { try? FileManager.default.removeItem(at: directory) }

        try store.write(["alice": "Mum", "bob": "Boss"], forOwnerAccountIdHex: "owner-a")
        try store.write(["alice": "Landlord"], forOwnerAccountIdHex: "owner-b")

        #expect(
            try store.loadAll() == [
                "owner-a": ["alice": "Mum", "bob": "Boss"],
                "owner-b": ["alice": "Landlord"],
            ]
        )
    }

    @Test func storeNormalizesTheOwnerKey() throws {
        let (store, directory) = temporaryStore()
        defer { try? FileManager.default.removeItem(at: directory) }

        try store.write(["alice": "Mum"], forOwnerAccountIdHex: "  OWNER-A  ")

        #expect(try store.loadAll() == ["owner-a": ["alice": "Mum"]])
        try store.remove(forOwnerAccountIdHex: "Owner-A")
        #expect(try store.loadAll().isEmpty)
    }

    @Test func storeWritingAnEmptyMapRemovesTheRecord() throws {
        let (store, directory) = temporaryStore()
        defer { try? FileManager.default.removeItem(at: directory) }

        try store.write(["alice": "Mum"], forOwnerAccountIdHex: "owner-a")
        try store.write([:], forOwnerAccountIdHex: "owner-a")

        #expect(try store.loadAll().isEmpty)
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
    }

    @Test func storeRemovingOneOwnerLeavesTheOthers() throws {
        let (store, directory) = temporaryStore()
        defer { try? FileManager.default.removeItem(at: directory) }

        try store.write(["alice": "Mum"], forOwnerAccountIdHex: "owner-a")
        try store.write(["alice": "Landlord"], forOwnerAccountIdHex: "owner-b")
        try store.remove(forOwnerAccountIdHex: "owner-b")

        #expect(try store.loadAll() == ["owner-a": ["alice": "Mum"]])
    }

    @Test func storeRemoveAllClearsEveryOwner() throws {
        let (store, directory) = temporaryStore()
        defer { try? FileManager.default.removeItem(at: directory) }

        try store.write(["alice": "Mum"], forOwnerAccountIdHex: "owner-a")
        try store.write(["alice": "Landlord"], forOwnerAccountIdHex: "owner-b")
        try store.removeAll()

        #expect(try store.loadAll().isEmpty)
    }

    @Test func storeIgnoresRecordsFromAnotherVersion() throws {
        let (store, directory) = temporaryStore()
        defer { try? FileManager.default.removeItem(at: directory) }

        try store.write(["alice": "Mum"], forOwnerAccountIdHex: "owner-a")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let future = """
            {"version":2,"ownerAccountIdHex":"owner-b","nicknamesByContactIdHex":{"alice":"Landlord"}}
            """
        try Data(future.utf8).write(to: directory.appendingPathComponent("future.json"))

        #expect(try store.loadAll() == ["owner-a": ["alice": "Mum"]])
    }

    @Test func applyingNicknameRetitlesAndRemembersThePublishedTitle() {
        let row = chatItem(title: "Alice", isDirect: true)

        let renamed = row.applyingNickname("Mum")
        #expect(renamed.title == "Mum")
        #expect(renamed.publishedTitle == "Alice")

        let renamedAgain = renamed.applyingNickname("Mother")
        #expect(renamedAgain.title == "Mother")
        #expect(renamedAgain.publishedTitle == "Alice")

        let cleared = renamedAgain.applyingNickname(nil)
        #expect(cleared.title == "Alice")
        #expect(cleared.publishedTitle == nil)
        #expect(cleared == row)
    }

    @Test func applyingANicknameEqualToThePublishedTitleRecordsNoOverride() {
        let renamed = chatItem(title: "Alice", isDirect: true).applyingNickname("Alice")

        #expect(renamed.title == "Alice")
        #expect(renamed.publishedTitle == nil)
    }

    /// A published name the sanitizer strips to nothing must still leave the row a baseline title.
    /// `applyingNickname(nil)` restores `publishedTitle ?? title`, so without one, clearing the
    /// nickname promotes the nickname itself to the contact's published name.
    @Test func directChatKeepsABaselineWhenThePublishedNameSanitizesAway() {
        let peer = ChatPeerProfile(
            accountIdHex: aliceAccountIdHex,
            displayName: "Mum",
            publishedDisplayName: bidiOnlyPublishedName,
            pictureURL: nil
        )

        // Nothing usable from any source: the baseline is the shortened peer account id.
        let shortened = DisplayText.short(aliceAccountIdHex)
        let unprojected = ChatItem(row: directChatRow(title: ""), activeAccountIdHex: "self", directPeer: peer)
        #expect(unprojected.title == "Mum")
        #expect(unprojected.publishedTitle == shortened)
        #expect(unprojected.applyingNickname(nil).title == shortened)

        // The row's own projected title keeps precedence over that fallback.
        let projected = ChatItem(row: directChatRow(title: "Alice"), activeAccountIdHex: "self", directPeer: peer)
        #expect(projected.publishedTitle == "Alice")
        #expect(projected.applyingNickname(nil).title == "Alice")
    }

    @Test func directChatRecordsNoBaselineWhenNoPublishedNameIsOverridden() {
        let chat = ChatItem(
            row: directChatRow(title: "Alice"),
            activeAccountIdHex: "self",
            directPeer: ChatPeerProfile(
                accountIdHex: aliceAccountIdHex,
                displayName: "Alice",
                publishedDisplayName: nil,
                pictureURL: nil
            )
        )

        #expect(chat.title == "Alice")
        #expect(chat.publishedTitle == nil)
    }

    /// The contact affordance is offered from this and nothing else, so it must never hand back a
    /// group id: a nickname keyed on one would be written against a conversation, not a person.
    @Test func directPeerAccountIdHexResolvesOnlyWhenAPeerIsKnown() {
        let resolved = ChatItem(
            row: directChatRow(title: "Alice"),
            activeAccountIdHex: "self",
            directPeer: ChatPeerProfile(accountIdHex: aliceAccountIdHex, displayName: "Alice", pictureURL: nil)
        )
        #expect(resolved.directPeerAccountIdHex == aliceAccountIdHex)

        // A direct chat whose peer never resolved, so the seed fell back to the group id — the
        // state a note-to-self chat stays in permanently — and an ordinary group.
        let unresolved = chatItem(id: "dm", title: "Alice", isDirect: true, avatarSeed: "dm")
        #expect(unresolved.avatarSeed == unresolved.id)
        #expect(unresolved.directPeerAccountIdHex == nil)
        #expect(chatItem(id: "group", title: "Book club").directPeerAccountIdHex == nil)
    }

    @Test func chatFilterMatchesTheNicknameAndThePublishedTitle() {
        let nicknamed = chatItem(id: "dm", title: "Mum", publishedTitle: "Alice", isDirect: true)
        let group = chatItem(id: "group", title: "Book club")
        let chats = [nicknamed, group]

        #expect(ChatFilter.filtered(chats, query: "mum").map(\.id) == ["dm"])
        #expect(ChatFilter.filtered(chats, query: "alice").map(\.id) == ["dm"])
        #expect(ChatFilter.filtered(chats, query: "book").map(\.id) == ["group"])
        #expect(ChatFilter.filtered(chats, query: "nobody").isEmpty)
    }

    @Test func applyingSenderNicknameRelabelsAndRestoresFromTheRowItself() throws {
        let message = messageItem(senderAccountIdHex: "alice", senderName: "Alice")

        #expect(message.applyingSenderNickname(nil) == nil)
        #expect(message.applyingSenderNickname("Alice") == nil)

        let renamed = try #require(message.applyingSenderNickname("Mum"))
        #expect(renamed.senderName == "Mum")
        #expect(renamed.publishedSenderName == "Alice")
        #expect(renamed.id == message.id)
        #expect(renamed.body == message.body)
        let restored = try #require(renamed.applyingSenderNickname(nil))
        #expect(restored.senderName == "Alice")
        #expect(restored.publishedSenderName == nil)
        #expect(restored == message)
    }

    /// An edit re-derives the row from its base, so it must carry the published name forward:
    /// otherwise clearing the nickname later restores the nickname itself as the "real" name.
    @Test func editingAMessagePreservesTheOverriddenPublishedName() throws {
        let renamed = try #require(
            messageItem(senderAccountIdHex: "alice", senderName: "Alice").applyingSenderNickname("Mum")
        )

        let edited = renamed.applyingEdit(plaintext: "Hello again")
        #expect(edited.senderName == "Mum")
        #expect(edited.publishedSenderName == "Alice")

        let restored = try #require(edited.applyingSenderNickname(nil))
        #expect(restored.senderName == "Alice")
        #expect(restored.publishedSenderName == nil)
    }

    @Test func applyingReplyContextSenderNameRelabelsOnlyTheQuote() throws {
        let quote = MessageReplyContext(targetMessageId: "message-1", senderName: "Alice", body: "Hello")
        let reply = messageItem(senderAccountIdHex: "bob", senderName: "Bob", replyContext: quote)

        #expect(reply.applyingReplyContextSenderName("Alice") == nil)
        #expect(messageItem(senderAccountIdHex: "bob", senderName: "Bob").applyingReplyContextSenderName("Mum") == nil)

        let relabeled = try #require(reply.applyingReplyContextSenderName("Mum"))
        #expect(relabeled.replyContext?.senderName == "Mum")
        #expect(relabeled.replyContext?.targetMessageId == "message-1")
        #expect(relabeled.replyContext?.body == "Hello")
        #expect(relabeled.senderName == "Bob")
    }

    @Test func composeContactIsSearchableByBothNames() {
        let nicknamed = composeContact(displayName: "Mum", publishedDisplayName: "Alice")
        #expect(nicknamed.searchableNames == ["Mum", "Alice"])

        let plain = composeContact(displayName: "Alice", publishedDisplayName: nil)
        #expect(plain.searchableNames == ["Alice"])
    }

    @MainActor
    @Test func publishedContactNameOnlyReportsAnActualOverride() {
        #expect(WorkspaceState.publishedContactName("Alice", overriddenBy: nil) == nil)
        #expect(WorkspaceState.publishedContactName("Alice", overriddenBy: "Mum") == "Alice")
        #expect(WorkspaceState.publishedContactName("Mum", overriddenBy: "Mum") == nil)
        #expect(WorkspaceState.publishedContactName(nil, overriddenBy: "Mum") == nil)
        #expect(WorkspaceState.publishedContactName("  ", overriddenBy: "Mum") == nil)
    }

    private func directChatRow(title: String) -> ChatListRowFfi {
        ChatListRowFfi(
            groupIdHex: "dm",
            archived: false,
            pendingConfirmation: false,
            title: title,
            groupName: "",
            avatarUrl: nil,
            avatar: nil,
            lastMessage: ChatListMessagePreviewFfi(
                messageIdHex: "message-1",
                sender: aliceAccountIdHex,
                senderDisplayName: nil,
                plaintext: "Hello",
                contentTokens: MarkdownDocumentFfi(blocks: [], truncated: false),
                kind: 9,
                timelineAt: 1_700_000_000,
                deleted: false
            ),
            unreadCount: 0,
            hasUnread: false,
            unreadMentionCount: 0,
            unreadMention: false,
            firstUnreadMessageIdHex: nil,
            lastReadMessageIdHex: nil,
            lastReadTimelineAt: nil,
            updatedAt: 1_700_000_000,
            selfMembership: .member
        )
    }

    private func temporaryStore() -> (ContactNicknameFileStore, URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("whitenoise-nicknames-\(UUID().uuidString)", isDirectory: true)
        return (ContactNicknameFileStore(directoryURL: directory), directory)
    }

    private func chatItem(
        id: String = "chat",
        title: String,
        publishedTitle: String? = nil,
        isDirect: Bool = false,
        avatarSeed: String? = nil
    ) -> ChatItem {
        ChatItem(
            id: id,
            title: title,
            publishedTitle: publishedTitle,
            subtitle: isDirect ? "Direct message" : "Group message",
            preview: "Hello",
            updatedAt: Date(timeIntervalSince1970: 1_700_000_000),
            avatarSeed: avatarSeed ?? (isDirect ? "alice" : id),
            pictureURL: nil,
            unreadCount: 0,
            isDirect: isDirect
        )
    }

    private func messageItem(
        senderAccountIdHex: String,
        senderName: String,
        replyContext: MessageReplyContext? = nil
    ) -> MessageItem {
        MessageItem(
            id: "message-1",
            groupIdHex: "chat",
            senderAccountIdHex: senderAccountIdHex,
            senderName: senderName,
            body: "Hello",
            sentAt: Date(timeIntervalSince1970: 1_700_000_000),
            timelineAt: 1_700_000_000,
            isOutgoing: false,
            replyContext: replyContext
        )
    }

    private func composeContact(displayName: String, publishedDisplayName: String?) -> ComposeContact {
        ComposeContact(
            accountIdHex: String(repeating: "a", count: 64),
            npub: "npub1alice",
            displayName: displayName,
            publishedDisplayName: publishedDisplayName,
            pictureURL: nil,
            lastActivity: nil
        )
    }
}
