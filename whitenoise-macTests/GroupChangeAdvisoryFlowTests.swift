//
//  GroupChangeAdvisoryFlowTests.swift
//  whitenoise-macTests
//
//  Every group change MarmotKit 0.14.0 can refuse as advisory (`GroupCatchingUp`,
//  `GroupCommitUndelivered`), driven end to end through `WorkspaceState` against the fake core:
//  invites, member mutations, the admin step-down before a leave, the admin handoff, the group
//  image and retention. Also the `obsoleteOnly` KeyPackage refusal on the invite and group-draft
//  paths, which must ask for an app update instead of marking someone "not on White Noise".
//

import Foundation
import MarmotKit
import Testing

@testable import whitenoise_mac

@MainActor
struct GroupChangeAdvisoryFlowTests {
    private static let aliceAccountIdHex = "a11ce1234567890aa11ce1234567890aa11ce1234567890aa11ce1234567890a"
    private static let bobAccountIdHex = "b0b1234567890abb0b1234567890abb0b1234567890abb0b1234567890abb0b1"

    private static let alice = NewChatRecipient(
        sourceQuery: "npub1alyce", memberRef: "npub1alyce", accountIdHex: aliceAccountIdHex,
        npub: "npub1alyce", displayName: "Alice", pictureURL: nil)
    private static let bob = NewChatRecipient(
        sourceQuery: "npub1p0p", memberRef: "npub1p0p", accountIdHex: bobAccountIdHex,
        npub: "npub1p0p", displayName: "Bob", pictureURL: nil)

    // MARK: - Invites

    @Test func consentedInviteIsAcknowledgedOnceAndCommitted() async throws {
        let (runtime, state, groupIdHex) = try await Self.openGroupDetails()
        runtime.groupChangeAdvisoryRefusals[groupIdHex] = .GroupCatchingUp(groupIdHex: groupIdHex)
        let prompter = GroupChangeAdvisoryPrompter()
        let answerer = PromptAnswerer(prompter, approve: true)

        let invited = await state.inviteMembers([Self.alice], advisory: prompter)
        answerer.stop()

        #expect(invited)
        #expect(answerer.answered.map(\.advisory) == [.catchingUp])
        // Invites get the stronger wording.
        #expect(answerer.answered.map(\.isInvite) == [true])
        #expect(runtime.groupChangeAdvisoryAcknowledgements == ["catchingUp:\(groupIdHex)"])
        #expect(runtime.invitedMemberRefs == ["npub1alyce"])
        #expect(state.lastError == nil)
    }

    /// A held-back group is not a refused member: nobody is marked unreachable and the declined
    /// note lands on the error line.
    @Test func declinedInviteMarksNobodyUnreachable() async throws {
        let (runtime, state, groupIdHex) = try await Self.openGroupDetails()
        runtime.groupChangeAdvisoryRefusals[groupIdHex] = .GroupCommitUndelivered(groupIdHex: groupIdHex)
        let staged = [Self.alice, Self.bob]

        let invited = await state.inviteMembers(staged)

        #expect(!invited)
        #expect(state.lastError == GroupChangeAdvisory.commitUndelivered.declinedMessage)
        #expect(state.unreachableInviteRecipients(staged).isEmpty)
        #expect(!state.hasUnnamedInviteRefusal)
        #expect(runtime.groupChangeAdvisoryAcknowledgements.isEmpty)
        #expect(runtime.inviteMembersDetailedCallCount == 1)
        #expect(runtime.invitedMemberRefs.isEmpty)
    }

    @Test func outdatedInviteeIsAskedToUpdateNotMarkedUnreachable() async throws {
        let (runtime, state, _) = try await Self.openGroupDetails()
        runtime.missingKeyPackageAccountIdHexByMemberRef["npub1p0p"] = Self.bobAccountIdHex
        runtime.obsoleteKeyPackageMemberRefs = ["npub1p0p"]
        let staged = [Self.alice, Self.bob]

        let invited = await state.inviteMembers(staged)

        #expect(!invited)
        #expect(state.lastError == ChatCreationFailure.needsAppUpdateMessage(recipientName: "Bob"))
        #expect(state.unreachableInviteRecipients(staged).isEmpty)
        // The search stops on the outdated member instead of probing the rest one at a time.
        #expect(runtime.inviteMembersDetailedCallCount == 1)
        #expect(runtime.invitedMemberRefs.isEmpty)
    }

    // MARK: - Member mutations

    @Test func consentedPromotionIsAcknowledgedAndApplied() async throws {
        let (runtime, state, groupIdHex) = try await Self.openGroupDetails()
        runtime.groupChangeAdvisoryRefusals[groupIdHex] = .GroupCommitUndelivered(groupIdHex: groupIdHex)
        let member = try #require(state.groupDetailsSnapshot?.members.first { $0.npub == "npub1alyce" })
        let prompter = GroupChangeAdvisoryPrompter()
        let answerer = PromptAnswerer(prompter, approve: true)

        await state.promoteGroupMember(member, advisory: prompter)
        answerer.stop()

        #expect(answerer.answered.map(\.advisory) == [.commitUndelivered])
        #expect(answerer.answered.map(\.isInvite) == [false])
        #expect(runtime.groupChangeAdvisoryAcknowledgements == ["commitUndelivered:\(groupIdHex)"])
        #expect(runtime.promotedAdminRef == "npub1alyce")
        #expect(runtime.promoteAdminDetailedCallCount == 2)
        #expect(state.mutatingGroupMemberId == nil)
    }

    @Test func waitingOnARemovalLeavesTheMemberInPlace() async throws {
        let (runtime, state, groupIdHex) = try await Self.openGroupDetails()
        runtime.groupChangeAdvisoryRefusals[groupIdHex] = .GroupCatchingUp(groupIdHex: groupIdHex)
        let member = try #require(state.groupDetailsSnapshot?.members.first { $0.npub == "npub1p0p" })
        let prompter = GroupChangeAdvisoryPrompter()
        let answerer = PromptAnswerer(prompter, approve: false)

        await state.removeGroupMember(member, advisory: prompter)
        answerer.stop()

        #expect(answerer.answered.map(\.advisory) == [.catchingUp])
        #expect(runtime.groupChangeAdvisoryAcknowledgements.isEmpty)
        #expect(runtime.removedMemberRefs.isEmpty)
        #expect(state.groupDetailsSnapshot?.members.contains { $0.npub == "npub1p0p" } == true)
        #expect(state.mutatingGroupMemberId == nil)
    }

    /// Demoting yourself routes through the self-demote commit, which is refused the same way.
    @Test func consentedSelfDemotionGoesThroughTheAdvisory() async throws {
        let (runtime, state, groupIdHex) = try await Self.openGroupDetails(otherIsAdmin: true)
        runtime.groupChangeAdvisoryRefusals[groupIdHex] = .GroupCatchingUp(groupIdHex: groupIdHex)
        let me = try #require(state.groupDetailsSnapshot?.members.first { $0.isSelf })
        let prompter = GroupChangeAdvisoryPrompter()
        let answerer = PromptAnswerer(prompter, approve: true)

        await state.demoteGroupMember(me, advisory: prompter)
        answerer.stop()

        #expect(answerer.answered.count == 1)
        #expect(runtime.groupChangeAdvisoryAcknowledgements == ["catchingUp:\(groupIdHex)"])
        #expect(runtime.selfDemotedGroupIdHex == groupIdHex)
        #expect(runtime.selfDemoteAdminDetailedCallCount == 2)
    }

    // MARK: - Leave and admin handoff

    /// Leaving is never refused, but the step-down before it can be. Choosing Wait is a note about
    /// the group, not "Couldn't leave chat", and nothing is published.
    @Test func waitingOnTheStepDownIsANoteNotALeaveFailure() async throws {
        let (runtime, state) = try await Self.leavableState(isLastAdmin: false)
        let chat = try #require(state.activeChats.first)
        runtime.groupChangeAdvisoryRefusals[chat.id] = .GroupCatchingUp(groupIdHex: chat.id)
        let prompter = GroupChangeAdvisoryPrompter()
        let answerer = PromptAnswerer(prompter, approve: false)

        await state.prepareChatLeave(for: chat)
        await state.confirmChatLeave(try #require(state.chatPendingLeave), advisory: prompter)
        answerer.stop()

        #expect(state.chatActionAlert == GroupChangeAdvisory.catchingUp.waitedAlert)
        #expect(runtime.leaveGroupCallCount == 0)
        #expect(runtime.groupMutationOrder == ["selfDemote"])
        #expect(runtime.groupChangeAdvisoryAcknowledgements.isEmpty)
        #expect(state.leavingChatId == nil)
        #expect(state.activeChats.contains { $0.id == chat.id })
    }

    @Test func consentedStepDownStillLeaves() async throws {
        let (runtime, state) = try await Self.leavableState(isLastAdmin: false)
        let chat = try #require(state.activeChats.first)
        runtime.groupChangeAdvisoryRefusals[chat.id] = .GroupCommitUndelivered(groupIdHex: chat.id)
        let prompter = GroupChangeAdvisoryPrompter()
        let answerer = PromptAnswerer(prompter, approve: true)

        await state.prepareChatLeave(for: chat)
        await state.confirmChatLeave(try #require(state.chatPendingLeave), advisory: prompter)
        answerer.stop()

        #expect(answerer.answered.count == 1)
        #expect(state.chatActionAlert == nil)
        #expect(runtime.groupChangeAdvisoryAcknowledgements == ["commitUndelivered:\(chat.id)"])
        #expect(runtime.leftGroupIdHex == chat.id)
    }

    /// The promotion and the step-down after it are one action to the user: one prompt, though
    /// each commit is acknowledged on its own.
    @Test func handoffAsksOnceForBothCommits() async throws {
        let (runtime, state) = try await Self.leavableState(isLastAdmin: true)
        let chat = try #require(state.activeChats.first)
        runtime.groupChangeAdvisoryRefusals[chat.id] = .GroupCatchingUp(groupIdHex: chat.id)
        let prompter = GroupChangeAdvisoryPrompter()
        let answerer = PromptAnswerer(prompter, approve: true)

        await state.prepareChatLeave(for: chat)
        let handoff = try #require(state.chatPendingAdminHandoff)
        await state.confirmChatAdminHandoff(
            handoff, successor: try #require(handoff.candidates.first), advisory: prompter)
        answerer.stop()

        #expect(answerer.answered.count == 1)
        #expect(
            runtime.groupChangeAdvisoryAcknowledgements == ["catchingUp:\(chat.id)", "catchingUp:\(chat.id)"])
        // The fake records a step-down attempt before admitting it, so the refused one shows too;
        // the order MIP-03 needs still holds.
        #expect(runtime.groupMutationOrder == ["promote", "selfDemote", "selfDemote", "leave"])
        #expect(runtime.promoteAdminDetailedCallCount == 2)
        #expect(runtime.selfDemoteAdminDetailedCallCount == 2)
        #expect(runtime.leftGroupIdHex == chat.id)
        #expect(state.chatActionAlert == nil)
        #expect(state.handingOffAdminChatId == nil)
    }

    @Test func waitingOnTheHandoffPromotesNobody() async throws {
        let (runtime, state) = try await Self.leavableState(isLastAdmin: true)
        let chat = try #require(state.activeChats.first)
        runtime.groupChangeAdvisoryRefusals[chat.id] = .GroupCommitUndelivered(groupIdHex: chat.id)

        await state.prepareChatLeave(for: chat)
        let handoff = try #require(state.chatPendingAdminHandoff)
        // No prompter: nobody to ask, so the refusal is declined rather than acknowledged.
        await state.confirmChatAdminHandoff(handoff, successor: try #require(handoff.candidates.first))

        #expect(state.chatActionAlert == GroupChangeAdvisory.commitUndelivered.waitedAlert)
        #expect(state.chatActionAlert != ChatActionAlert.adminHandoffFailed())
        #expect(runtime.promotedAdminRef == nil)
        #expect(runtime.groupMutationOrder.isEmpty)
        #expect(runtime.leaveGroupCallCount == 0)
        #expect(state.handingOffAdminChatId == nil)
    }

    // MARK: - Group image and retention

    /// Clearing a group that carries both a legacy URL avatar and an encrypted image is two
    /// commits but one change to the user.
    @Test func clearingBothImagesAsksOnce() async throws {
        let account = desktopAccount()
        let runtime = FakeMarmotRuntime(accounts: [account])
        var group = messageGroup()
        group.avatarUrl = "https://legacy.example/group.jpg"
        group.imageHashHex = "existing-encrypted-image-hash"
        runtime.installGroup(group)
        runtime.groupChangeAdvisoryRefusals[group.groupIdHex] = .GroupCatchingUp(groupIdHex: group.groupIdHex)
        let state = WorkspaceState(clientFactory: { runtime })
        await state.bootstrap()
        state.showGroupImagePicker(for: try #require(state.activeChats.first))
        let prompter = GroupChangeAdvisoryPrompter()
        let answerer = PromptAnswerer(prompter, approve: true)

        await state.clearGroupImage(advisory: prompter)
        answerer.stop()

        #expect(answerer.answered.count == 1)
        #expect(runtime.groupChangeAdvisoryAcknowledgements.count == 2)
        #expect(runtime.updatedGroupAvatar?.url == nil)
        #expect(runtime.clearGroupImageCallCount == 2)
        #expect(state.activeChats.first?.pictureURL == nil)
        #expect(state.activeChats.first?.groupImageHashHex == nil)
    }

    @Test func consentedRetentionChangeIsApplied() async throws {
        let (runtime, state, groupIdHex) = try await Self.openGroupDetails()
        runtime.groupChangeAdvisoryRefusals[groupIdHex] = .GroupCommitUndelivered(groupIdHex: groupIdHex)
        let prompter = GroupChangeAdvisoryPrompter()
        let answerer = PromptAnswerer(prompter, approve: true)

        await state.setDisappearingMessages(groupIdHex: groupIdHex, seconds: 86_400, advisory: prompter)
        answerer.stop()

        #expect(answerer.answered.count == 1)
        #expect(runtime.lastRetentionSecs == 86_400)
        #expect(runtime.updateMessageRetentionCallCount == 2)
        #expect(state.lastError == nil)
        #expect(!state.isUpdatingDisappearingMessages)
    }

    @Test func undecidedRetentionChangeReportsTheDeclinedNote() async throws {
        let (runtime, state, groupIdHex) = try await Self.openGroupDetails()
        runtime.groupChangeAdvisoryRefusals[groupIdHex] = .GroupCatchingUp(groupIdHex: groupIdHex)

        await state.setDisappearingMessages(groupIdHex: groupIdHex, seconds: 3_600)

        #expect(runtime.lastRetentionSecs == nil)
        #expect(runtime.updateMessageRetentionCallCount == 1)
        #expect(state.lastError == GroupChangeAdvisory.catchingUp.declinedMessage)
    }

    // MARK: - Group draft

    @Test func groupDraftWithAnOutdatedMemberAsksForAnUpdate() async throws {
        let account = desktopAccount()
        let runtime = FakeMarmotRuntime(accounts: [account])
        runtime.missingKeyPackageAccountIdHexByMemberRef["npub1p0p"] = Self.bobAccountIdHex
        runtime.obsoleteKeyPackageMemberRefs = ["npub1p0p"]
        let state = WorkspaceState(clientFactory: { runtime })
        await state.bootstrap()
        state.showNewChat()
        state.newChatRecipients = [Self.alice, Self.bob]
        state.newChatName = "Project Room"

        await state.createGroupFromDraft()

        #expect(state.lastError == ChatCreationFailure.needsAppUpdateMessage(recipientName: "Bob"))
        #expect(state.unreachableDraftMembers.isEmpty)
        #expect(state.startChatInvitePrompt == nil)
        #expect(runtime.createGroupAttempts == [["npub1alyce", "npub1p0p"]])
        #expect(runtime.createdGroupMemberRefs.isEmpty)
    }

    // MARK: - Copy

    @Test func everyAdvisoryHasDistinctTitleAndDeclinedCopy() {
        let all: [GroupChangeAdvisory] = [.catchingUp, .commitUndelivered]
        #expect(Set(all.map(\.title)).count == 2)
        #expect(Set(all.map(\.declinedMessage)).count == 2)
        for advisory in all {
            #expect(advisory.waitedAlert == ChatActionAlert(title: advisory.title, message: advisory.declinedMessage))
            #expect(GroupChangeAdvisoryDeclined(advisory: advisory).errorDescription == advisory.declinedMessage)
            let prompt = GroupChangeAdvisoryPrompter.Prompt(advisory: advisory, isInvite: true)
            #expect(prompt.title == advisory.title)
            #expect(prompt.message == advisory.message(isInvite: true))
        }
    }

    @Test func namelessNeedsAppUpdateFallsBackToGenericCopy() {
        #expect(
            ChatCreationFailure.needsAppUpdateMessage(recipientName: "")
                == L10n.string("This user needs to update their app before they can be invited."))
        #expect(
            ChatCreationFailure.needsAppUpdateMessage(recipientName: nil)
                == ChatCreationFailure.needsAppUpdateMessage(recipientName: ""))
    }

    // MARK: - Helpers

    private static func openGroupDetails(
        otherIsAdmin: Bool = false
    ) async throws -> (FakeMarmotRuntime, WorkspaceState, String) {
        let account = desktopAccount()
        let runtime = FakeMarmotRuntime(accounts: [account])
        let details = groupDetailsFixture(selfAccountIdHex: account.accountIdHex, otherIsAdmin: otherIsAdmin)
        runtime.installGroupDetails(details)
        let state = WorkspaceState(clientFactory: { runtime })
        await state.bootstrap()
        await state.showGroupDetails(for: try #require(state.activeChats.first))
        return (runtime, state, details.group.groupIdHex)
    }

    /// An admin who must step down before leaving. As the last admin, only Alice may take over.
    private static func leavableState(isLastAdmin: Bool) async throws -> (FakeMarmotRuntime, WorkspaceState) {
        let account = desktopAccount()
        let runtime = FakeMarmotRuntime(accounts: [account])
        runtime.installGroupDetails(
            groupDetailsFixture(selfAccountIdHex: account.accountIdHex, selfIsAdmin: true),
            managementState: GroupManagementStateFfi(
                myAccountIdHex: account.accountIdHex,
                isSelfAdmin: true,
                isLastAdmin: isLastAdmin,
                canInvite: true,
                canLeave: false,
                requiresSelfDemoteBeforeLeave: true,
                leaveRequestPending: false,
                memberActions: [
                    GroupMemberActionStateFfi(
                        memberIdHex: "alice1234567890alice1234567890alice1234567890alice1234567890",
                        isSelf: false, isAdmin: false, canRemove: true, canPromote: true, canDemote: false)
                ]
            )
        )
        let state = WorkspaceState(clientFactory: { runtime })
        await state.bootstrap()
        return (runtime, state)
    }
}

/// Answers every consent request a prompter raises, as the alert's buttons would, and records
/// what was asked. Resolution happens on the main actor right after the prompt is published, so
/// the change under test keeps running without the test having to interleave by hand.
@MainActor
private final class PromptAnswerer {
    private(set) var answered: [GroupChangeAdvisoryPrompter.Prompt] = []
    private var task: Task<Void, Never>?

    init(_ prompter: GroupChangeAdvisoryPrompter, approve: Bool) {
        task = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                if let prompt = prompter.prompt {
                    self?.answered.append(prompt)
                    prompter.resolve(id: prompt.id, approved: approve)
                }
                await Task.yield()
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
    }
}
