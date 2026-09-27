//
//  ChatInviteRuleTests.swift
//  whitenoise-macTests
//

import Foundation
import MarmotKit
import Testing

@testable import whitenoise_mac

struct ChatInviteRuleTests {
    private static let recipient = NewChatRecipient(
        sourceQuery: "npub1recipient",
        memberRef: "npub1recipient",
        accountIdHex: "ABCDEF0123",
        npub: "npub1recipient",
        displayName: "Robin",
        pictureURL: nil
    )

    @Test func onlyAnUnarchivedInviteWithALiveMembershipCounts() {
        #expect(PendingInviteBadgeCount.counts(pendingConfirmation: true, isArchived: false, membership: .member))
        #expect(!PendingInviteBadgeCount.counts(pendingConfirmation: false, isArchived: false, membership: .member))
        #expect(!PendingInviteBadgeCount.counts(pendingConfirmation: true, isArchived: true, membership: .member))
        #expect(!PendingInviteBadgeCount.counts(pendingConfirmation: true, isArchived: false, membership: .left))
        #expect(!PendingInviteBadgeCount.counts(pendingConfirmation: true, isArchived: false, membership: .removed))
    }

    @Test func loadedChatItemsCountOnlyTheirLiveInvites() {
        let chats = [
            pendingInviteChatItem(id: "invite-a"),
            pendingInviteChatItem(id: "invite-b"),
            pendingInviteChatItem(id: "invite-left", selfMembership: .left),
            pendingInviteChatItem(id: "invite-removed", selfMembership: .removed),
            chatListOrderingTestItem(id: "plain", title: "Plain", updatedAt: 1_700_000_000),
        ]
        #expect(PendingInviteBadgeCount.count(inUnarchived: chats) == 2)
        #expect(PendingInviteBadgeCount.count(inUnarchived: []) == 0)
    }

    @Test func rawRowsCountTheirOwnArchivedFlagAndMembership() {
        func row(_ id: String, pending: Bool, archived: Bool = false, membership: SelfMembershipFfi = .member)
            -> ChatListRowFfi
        {
            chatListRow(
                groupIdHex: id, title: id, preview: "", sender: "", timelineAt: 1_700_000_000,
                selfMembership: membership, archived: archived, pendingConfirmation: pending
            )
        }
        let rows = [
            row("invite", pending: true),
            row("archived-invite", pending: true, archived: true),
            row("left-invite", pending: true, membership: .left),
            row("removed-invite", pending: true, membership: .removed),
            row("accepted", pending: false),
        ]
        #expect(PendingInviteBadgeCount.count(inRows: rows) == 1)
    }

    @Test func refusedRecipientIsMatchedByEitherIdentifierIgnoringCase() {
        let candidates = [Self.recipient]
        #expect(ChatCreationFailure.refusedRecipient(named: "abcdef0123", among: candidates) == Self.recipient)
        #expect(ChatCreationFailure.refusedRecipient(named: "NPUB1RECIPIENT", among: candidates) == Self.recipient)
        #expect(ChatCreationFailure.refusedRecipient(named: "someone-else", among: candidates) == nil)
        #expect(ChatCreationFailure.refusedRecipient(named: "", among: candidates) == nil)
        #expect(ChatCreationFailure.refusedRecipient(named: nil, among: candidates) == nil)
    }

    @Test func addMemberMessageNamesTheRefusedRecipientWhenKnown() {
        let named = ChatCreationFailure.message(
            for: MarmotKitError.MissingKeyPackage(account: " abcdef0123 "),
            candidates: [Self.recipient]
        )
        #expect(named.contains("Robin"))
        #expect(!named.contains("abcdef0123"))

        let unnamed = L10n.string("Someone you picked isn't on White Noise yet, so they can't be added.")
        #expect(
            ChatCreationFailure.message(
                for: MarmotKitError.MissingKeyPackage(account: "unknown"), candidates: [Self.recipient]
            ) == unnamed
        )
        #expect(
            ChatCreationFailure.message(
                for: MarmotKitError.InvalidKeyPackageEvent(details: "bad event"), candidates: [Self.recipient]
            ) == unnamed
        )
    }

    @Test func addMemberMessagePassesOtherErrorsThrough() {
        let error = NSError(domain: "test", code: 7, userInfo: [NSLocalizedDescriptionKey: "Relay unreachable"])
        #expect(ChatCreationFailure.message(for: error, candidates: [Self.recipient]) == "Relay unreachable")
    }

    @Test func inviteCopyCarriesTheDownloadLinkAndTheRecipientsName() {
        // The invite is pasted into another messenger, so every translation has to keep the link.
        #expect(WhiteNoiseInvite.message.contains("https://whitenoise.chat"))
        #expect(WhiteNoiseInvite.detail(recipientName: "Robin").contains("Robin"))
        #expect(
            WhiteNoiseInvite.detail(recipientName: "")
                == L10n.string("They aren't on White Noise yet. Share the app so you can chat securely.")
        )
        #expect(WhiteNoiseInvite.detail(recipientName: nil) == WhiteNoiseInvite.detail(recipientName: ""))
    }
}
