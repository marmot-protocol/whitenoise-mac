//
//  WorkspaceState+Groups.swift
//  whitenoise-mac
//
//  Groups behavior extracted from WorkspaceState.swift (no behavior change).
//

import AVFoundation
import AppKit
import Combine
import Foundation
import MarmotKit
import Observation
import SwiftUI
import UniformTypeIdentifiers
import UserNotifications

private struct GroupImageUpdateContext {
    let client: any MarmotRuntime
    let accountId: String
    let accountRef: String
    let groupIdHex: String
    let hadLegacyURLAvatar: Bool
    let hadEncryptedImage: Bool
}

private enum GroupImageSelectionError: LocalizedError {
    case invalidWebImage
    case downloadFailed
    case notAnImage

    var errorDescription: String? {
        switch self {
        case .invalidWebImage:
            return L10n.string("That image URL is not allowed.")
        case .downloadFailed:
            return L10n.string("That image could not be downloaded.")
        case .notAnImage:
            return L10n.string("Please choose an image file.")
        }
    }
}

@MainActor
extension WorkspaceState {
    func refreshConversationMetadata(for chat: ChatItem) async {
        let generation = claimConversationMetadataGeneration(for: chat.id)
        let epoch = conversationMetadataEpoch

        guard !chat.isDirect, let client, let activeAccount, let accountId = activeAccountId else {
            if conversationMetadataEpoch == epoch,
                conversationMetadataGenerationByChat[chat.id] == generation
            {
                conversationMetadataByChat[chat.id] = nil
            }
            return
        }
        do {
            async let details = client.groupDetails(
                accountRef: activeAccount.accountRef,
                groupIdHex: chat.id
            )
            async let management = client.groupManagementState(
                accountRef: activeAccount.accountRef,
                groupIdHex: chat.id
            )
            let (resolvedDetails, resolvedManagement) = try await (details, management)
            guard
                activeAccountId == accountId,
                conversationMetadataEpoch == epoch,
                conversationMetadataGenerationByChat[chat.id] == generation
            else { return }
            conversationMetadataByChat[chat.id] = ConversationMetadata(
                memberCount: resolvedDetails.members.count,
                disappearingMessageSecs: resolvedDetails.group.disappearingMessageSecs,
                isSelfAdmin: resolvedManagement.isSelfAdmin
            )
        } catch {
            guard
                activeAccountId == accountId,
                conversationMetadataEpoch == epoch,
                conversationMetadataGenerationByChat[chat.id] == generation
            else { return }
            conversationMetadataByChat[chat.id] = nil
        }
    }

    func clearConversationMetadata() {
        conversationMetadataEpoch &+= 1
        conversationMetadataByChat.removeAll()
        conversationMetadataGenerationByChat.removeAll()
    }

    @discardableResult
    func claimConversationMetadataGeneration(for groupIdHex: String) -> UInt64 {
        conversationMetadataGeneration &+= 1
        conversationMetadataGenerationByChat[groupIdHex] = conversationMetadataGeneration
        return conversationMetadataGeneration
    }

    func showGroupDetails(for chat: ChatItem) async {
        cancelGroupTranscriptExport()
        lastError = nil
        if groupDetailsSnapshot?.groupIdHex != chat.id {
            groupDetailsSnapshot = nil
            isLoadingGroupDetails = true
        }
        groupInviteMemberQuery = ""
        groupTranscriptExportStatus = nil
        isGroupDetailsPresented = true
        if chat.isDirect {
            async let details: Void = loadGroupDetails(groupIdHex: chat.id)
            async let commonGroups: Void = loadCommonGroups(
                forContactIdHex: chat.avatarSeed,
                excludingGroupIdHex: chat.id
            )
            // Chat info doubles as the peer's profile for a 1:1 conversation, so it carries the
            // follow control and needs the relationship resolved alongside everything else.
            async let followStatus: Void = refreshDirectPeerFollowStatus(for: chat)
            _ = await (details, commonGroups, followStatus)
        } else {
            clearCommonGroups()
            await loadGroupDetails(groupIdHex: chat.id)
        }
    }

    func closeGroupDetails() {
        cancelGroupTranscriptExport()
        closeContactDetails()
        isGroupDetailsPresented = false
        groupDetailsSnapshot = nil
        groupProfileDraftName = ""
        groupProfileDraftDescription = ""
        groupInviteMemberQuery = ""
        clearCommonGroups()
        // Invalidate any in-flight load so a stale completion cannot repopulate closed details or
        // resurrect the spinner; this also clears `isLoadingGroupDetails`. See issue #135.
        invalidateGroupDetailsLoad()
        isArchivingGroup = false
        isExportingGroupTranscript = false
        groupTranscriptExportStatus = nil
    }

    func showContactDetails(
        accountIdHex: String,
        npub: String = "",
        displayName: String?,
        pictureURL: String?,
        excludingGroupIdHex: String? = nil
    ) async {
        let accountIdHex = accountIdHex.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !accountIdHex.isEmpty, let client, let activeAccount else { return }

        contactDetailsLoadGeneration &+= 1
        let generation = contactDetailsLoadGeneration
        let nickname = activeContactNicknames.nickname(forContactAccountIdHex: accountIdHex)
        let fallback = NewChatRecipient(
            sourceQuery: accountIdHex,
            memberRef: npub.isEmpty ? accountIdHex : npub,
            accountIdHex: accountIdHex,
            npub: npub,
            displayName: nickname ?? displayName,
            publishedDisplayName: Self.publishedContactName(displayName, overriddenBy: nickname),
            pictureURL: pictureURL
        )
        contactDetailsTarget = fallback
        isLoadingContactDetails = true
        lastError = nil

        async let followStatus: Void = refreshFollowStatus(forContactIdHex: accountIdHex)
        async let commonGroups: Void = loadCommonGroups(
            forContactIdHex: accountIdHex,
            excludingGroupIdHex: excludingGroupIdHex
        )
        let resolved = await resolvedPeerFFI(
            accountIdHex: accountIdHex,
            activeAccount: activeAccount,
            client: client
        )
        guard
            contactDetailsLoadGeneration == generation,
            activeAccountId == activeAccount.id,
            contactDetailsTarget?.accountIdHex == accountIdHex
        else { return }

        let published = firstNonBlank([
            PeerDisplayText.sanitize(resolved?.profileDisplayName),
            PeerDisplayText.sanitize(resolved?.profileName),
            displayName,
            PeerDisplayText.sanitize(resolved?.directoryDisplayName),
        ])
        contactDetailsTarget = NewChatRecipient(
            sourceQuery: accountIdHex,
            memberRef: npub.isEmpty ? accountIdHex : npub,
            accountIdHex: accountIdHex,
            npub: npub,
            displayName: nickname ?? published,
            publishedDisplayName: Self.publishedContactName(published, overriddenBy: nickname),
            pictureURL: resolved?.profilePicture?.nilIfBlank ?? pictureURL
        )
        await followStatus
        await commonGroups
        if contactDetailsLoadGeneration == generation {
            isLoadingContactDetails = false
        }
    }

    /// `nonisolated` so the pure value types that carry a nickname-first label — the mention
    /// candidate among them — can record the overridden name the same way this actor does.
    nonisolated static func publishedContactName(_ published: String?, overriddenBy nickname: String?) -> String? {
        guard let nickname, let published = published?.nilIfBlank, published != nickname else { return nil }
        return published
    }

    func showContactDetails(for member: GroupMemberItem) async {
        await showContactDetails(
            accountIdHex: member.id,
            npub: member.npub,
            displayName: member.publishedDisplayName ?? member.displayName,
            pictureURL: nil,
            // A member row is only reachable from the open conversation's details, so that
            // conversation is the one group the viewer already knows they share.
            excludingGroupIdHex: groupDetailsSnapshot?.groupIdHex
        )
    }

    func showContactDetails(for message: MessageItem) async {
        await showContactDetails(
            accountIdHex: message.senderAccountIdHex,
            displayName: message.publishedSenderName ?? message.senderName,
            pictureURL: message.senderPictureURL,
            excludingGroupIdHex: message.groupIdHex
        )
    }

    func closeContactDetails() {
        contactDetailsLoadGeneration &+= 1
        contactDetailsTarget = nil
        isLoadingContactDetails = false
        invalidateFollowStatusRead()
        invalidateFollowMutation()
        clearCommonGroups()
    }

    func messageContact(_ contact: NewChatRecipient) async {
        closeContactDetails()
        if isGroupDetailsPresented {
            closeGroupDetails()
        }
        await startDirectChat(with: contact)
    }

    /// Collect the groups the viewer shares with a contact.
    ///
    /// `excludingGroupIdHex` drops the conversation the contact was opened from: the group whose
    /// details are already on screen is not a group "in common", it is the group you are in.
    func loadCommonGroups(forContactIdHex contactIdHex: String, excludingGroupIdHex: String? = nil) async {
        guard let client, let activeAccount, let accountId = activeAccountId else {
            clearCommonGroups()
            return
        }

        commonGroupsLoadGeneration &+= 1
        let generation = commonGroupsLoadGeneration
        commonGroupsForContact = []
        commonGroupsLoadHadFailures = false
        isLoadingCommonGroups = true
        defer {
            if commonGroupsLoadGeneration == generation {
                isLoadingCommonGroups = false
            }
        }

        let normalizedContactId = contactIdHex.lowercased()
        let excludedGroupId = excludingGroupIdHex?.nilIfBlank?.lowercased()
        let chats =
            ((chatsByAccount[accountId] ?? []) + (archivedChatsByAccount[accountId] ?? []))
            .filter {
                !$0.pendingConfirmation
                    && $0.selfMembership == .member
                    && $0.id.lowercased() != excludedGroupId
            }
            .sorted {
                let lhsDate = $0.updatedAt ?? .distantPast
                let rhsDate = $1.updatedAt ?? .distantPast
                if lhsDate != rhsDate { return lhsDate > rhsDate }
                return $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
            }

        for chat in chats {
            guard commonGroupsLoadGeneration == generation, activeAccountId == accountId else { return }
            guard
                let members = await cachedGroupMembers(
                    groupIdHex: chat.id,
                    account: activeAccount,
                    client: client
                )
            else {
                commonGroupsLoadHadFailures = true
                continue
            }
            guard commonGroupsLoadGeneration == generation, activeAccountId == accountId else { return }
            if members.contains(where: { $0.memberIdHex.lowercased() == normalizedContactId }) {
                commonGroupsForContact.append(chat)
            }
        }
    }

    func openCommonGroup(_ chat: ChatItem) {
        closeContactDetails()
        closeGroupDetails()
        selectChat(chat)
    }

    func clearCommonGroups() {
        commonGroupsLoadGeneration &+= 1
        commonGroupsForContact = []
        isLoadingCommonGroups = false
        commonGroupsLoadHadFailures = false
    }

    static func chooseTranscriptExportDestination(suggestedFilename: String) -> URL? {
        let panel = NSSavePanel()
        panel.title = L10n.string("Export Transcript")
        panel.prompt = L10n.string("Export")
        panel.nameFieldStringValue = suggestedFilename
        panel.allowedContentTypes = [.json]
        panel.allowsOtherFileTypes = false
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        guard panel.runModal() == .OK else { return nil }
        return panel.url
    }

    func startExportSelectedGroupTranscript() {
        guard groupTranscriptExportTask == nil,
            !isExportingGroupTranscript,
            groupDetailsSnapshot != nil
        else { return }
        let filename = ConversationTranscriptExport.suggestedFilename(exportedAt: nowProvider())
        guard let destinationURL = transcriptExportDestinationPicker(filename) else { return }
        groupTranscriptExportTask = Task { [weak self] in
            await self?.exportSelectedGroupTranscript(to: destinationURL)
        }
    }

    func cancelGroupTranscriptExport() {
        groupTranscriptExportTask?.cancel()
    }

    func exportSelectedGroupTranscript(to destinationURL: URL) async {
        defer { groupTranscriptExportTask = nil }

        guard !isExportingGroupTranscript,
            let client,
            let activeAccount,
            let snapshot = groupDetailsSnapshot
        else { return }
        guard !Task.isCancelled else { return }

        lastError = nil
        groupTranscriptExportStatus = nil
        isExportingGroupTranscript = true
        defer { isExportingGroupTranscript = false }

        let accountId = activeAccount.id
        let accountRef = activeAccount.accountRef
        let groupIdHex = snapshot.groupIdHex
        let groupName = snapshot.name
        let exportedAt = nowProvider()

        do {
            // Pagination, bounded disk spooling, and event-by-event JSON encoding all block.
            // Keep the complete export off the main thread so the save sheet remains responsive.
            let export = try await FFIExecutor.runCancellable { checkCancellation in
                try ConversationTranscriptExport.export(
                    client: client,
                    accountRef: accountRef,
                    groupIdHex: groupIdHex,
                    groupName: groupName,
                    to: destinationURL,
                    exportedAt: exportedAt,
                    checkCancellation: checkCancellation
                )
            }
            guard !Task.isCancelled,
                activeAccountId == accountId,
                isGroupDetailsPresented,
                groupDetailsSnapshot?.groupIdHex == groupIdHex
            else { return }
            let statusFormat =
                export.eventCount == 1
                ? L10n.string("Exported %d transcript event to %@.")
                : L10n.string("Exported %d transcript events to %@.")
            groupTranscriptExportStatus = String(
                format: statusFormat,
                export.eventCount,
                export.destinationURL.path
            )
        } catch is CancellationError {
            // User navigated away, switched accounts, or closed details. Treat as an intentional
            // abort rather than surfacing a transient cancellation error in the UI.
        } catch {
            guard !Task.isCancelled,
                activeAccountId == accountId,
                isGroupDetailsPresented,
                groupDetailsSnapshot?.groupIdHex == groupIdHex
            else { return }
            lastError = error.localizedDescription
        }
    }

    func reloadSelectedGroupDetails() async {
        guard let selectedChat, !selectedChat.isDirect else { return }
        await loadGroupDetails(groupIdHex: selectedChat.id)
    }

    func saveGroupProfile() async {
        guard let client,
            let activeAccount,
            let snapshot = groupDetailsSnapshot,
            !hasInFlightGroupCommit
        else { return }
        let trimmedName = groupProfileDraftName.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedDescription = groupProfileDraftDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else {
            lastError = L10n.string("Group name cannot be empty.")
            return
        }

        lastError = nil
        isSavingGroupProfile = true
        defer { isSavingGroupProfile = false }

        do {
            _ = try await client.updateGroupProfile(
                accountRef: activeAccount.accountRef,
                groupIdHex: snapshot.groupIdHex,
                name: trimmedName,
                description: trimmedDescription
            )
            await reloadChats(forceFreshSnapshot: true)
            await loadGroupDetails(groupIdHex: snapshot.groupIdHex)
        } catch {
            lastError = error.localizedDescription
        }
    }

    func inviteMemberToSelectedGroup() async {
        guard let client,
            let activeAccount,
            let snapshot = groupDetailsSnapshot,
            !hasInFlightGroupCommit
        else { return }
        let accountId = activeAccount.id
        let groupIdHex = snapshot.groupIdHex
        let query = groupInviteMemberQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard looksLikeMemberRef(query) else {
            lastError = L10n.string("Enter a valid NIP-05, npub, profile link, or hex public key.")
            return
        }
        let generation = beginGroupDetailsMutation()

        lastError = nil
        isInvitingGroupMember = true
        defer { isInvitingGroupMember = false }

        do {
            let memberRef = try await memberRefCandidate(for: query)
            let normalized = try await FFIExecutor.run {
                try client.normalizeMemberRef(memberRef: memberRef)
            }
            guard
                isCurrentGroupDetailsMutation(
                    generation: generation,
                    accountId: accountId,
                    groupIdHex: groupIdHex
                )
            else { return }
            let result = try await client.inviteMembersDetailed(
                accountRef: activeAccount.accountRef,
                groupIdHex: groupIdHex,
                memberRefs: [normalized.npub]
            )
            guard
                isCurrentGroupDetailsMutation(
                    generation: generation,
                    accountId: accountId,
                    groupIdHex: groupIdHex
                )
            else { return }
            groupInviteMemberQuery = ""
            applyGroupMutationResult(result)
            await reloadChats(forceFreshSnapshot: true)
        } catch {
            guard
                isCurrentGroupDetailsMutation(
                    generation: generation,
                    accountId: accountId,
                    groupIdHex: groupIdHex
                )
            else { return }
            lastError = error.localizedDescription
        }
    }

    /// Invite one or more already-resolved recipients in a single group commit. Recipients carry a
    /// normalized `npub` from the new-chat resolver, so no per-entry re-normalization is needed.
    /// Returns `true` when the commit succeeded so the caller can dismiss only on success.
    @discardableResult
    func inviteMembers(_ recipients: [NewChatRecipient]) async -> Bool {
        guard let client,
            let activeAccount,
            let snapshot = groupDetailsSnapshot,
            !hasInFlightGroupCommit
        else { return false }
        let memberRefs = recipients.map(\.npub).filter { !$0.isEmpty }
        guard !memberRefs.isEmpty else { return false }
        let accountId = activeAccount.id
        let groupIdHex = snapshot.groupIdHex
        let generation = beginGroupDetailsMutation()

        lastError = nil
        isInvitingGroupMember = true
        defer { isInvitingGroupMember = false }

        do {
            let result = try await client.inviteMembersDetailed(
                accountRef: activeAccount.accountRef,
                groupIdHex: groupIdHex,
                memberRefs: memberRefs
            )
            guard
                isCurrentGroupDetailsMutation(generation: generation, accountId: accountId, groupIdHex: groupIdHex)
            else { return false }
            applyGroupMutationResult(result)
            await reloadChats(forceFreshSnapshot: true)
            return true
        } catch {
            guard
                isCurrentGroupDetailsMutation(generation: generation, accountId: accountId, groupIdHex: groupIdHex)
            else { return false }
            // `inviteMembersDetailed` can throw while reading post-commit details *after* the MLS
            // invite already published. Refresh the roster and reconcile: if every recipient is now
            // a member, the invite succeeded despite the read error — report success so the sheet
            // dismisses and a retry doesn't hit "already a member".
            await reloadChats(forceFreshSnapshot: true)
            // Every await here suspends the actor, so re-validate the full presentation context
            // after each one — not just the snapshot: a switch to another chat leaves the old
            // snapshot temporarily intact (`loadGroupDetails` early-returns for a deselected
            // group), and this error must not land in whatever the user is looking at now.
            guard isInviteReconciliationTargetCurrent(accountId: accountId, groupIdHex: groupIdHex) else {
                return false
            }
            await loadGroupDetails(groupIdHex: groupIdHex)
            guard isInviteReconciliationTargetCurrent(accountId: accountId, groupIdHex: groupIdHex) else {
                return false
            }
            let currentMemberIds = Set(groupDetailsSnapshot?.members.map(\.id) ?? [])
            if !currentMemberIds.isEmpty,
                recipients.allSatisfy({ currentMemberIds.contains($0.accountIdHex) })
            {
                return true
            }
            lastError = error.localizedDescription
            return false
        }
    }

    func acceptGroupInvite(for chat: ChatItem) async {
        // DMs are 2-person MLS groups, so their welcomes are accepted the same way.
        await acceptGroupInvite(groupIdHex: chat.id)
    }

    func declineGroupInvite(for chat: ChatItem) async {
        await declineGroupInvite(groupIdHex: chat.id)
    }

    func acceptSelectedGroupInvite() async {
        guard let snapshot = groupDetailsSnapshot else { return }
        await acceptGroupInvite(groupIdHex: snapshot.groupIdHex)
    }

    func declineSelectedGroupInvite() async {
        guard let snapshot = groupDetailsSnapshot else { return }
        await declineGroupInvite(groupIdHex: snapshot.groupIdHex)
    }

    func promoteGroupMember(_ member: GroupMemberItem) async {
        await mutateGroupMember(member, action: .promote)
    }

    func demoteGroupMember(_ member: GroupMemberItem) async {
        await mutateGroupMember(member, action: .demote)
    }

    func removeGroupMember(_ member: GroupMemberItem) async {
        await mutateGroupMember(member, action: .remove)
    }

    func selfDemoteSelectedGroupAdmin() async {
        guard let client,
            let activeAccount,
            let snapshot = groupDetailsSnapshot,
            !hasInFlightGroupCommit
        else { return }
        guard snapshot.isSelfAdmin, !snapshot.isLastAdmin else {
            lastError = L10n.string("Make another member an admin before stepping down.")
            return
        }

        lastError = nil
        let accountId = activeAccount.id
        let groupIdHex = snapshot.groupIdHex
        let generation = beginGroupDetailsMutation()
        let selfMemberId = snapshot.members.first(where: \.isSelf)?.id ?? activeAccount.accountIdHex
        mutatingGroupMemberId = selfMemberId
        defer { mutatingGroupMemberId = nil }

        do {
            let result = try await client.selfDemoteAdminDetailed(
                accountRef: activeAccount.accountRef,
                groupIdHex: groupIdHex
            )
            guard
                isCurrentGroupDetailsMutation(
                    generation: generation,
                    accountId: accountId,
                    groupIdHex: groupIdHex
                )
            else { return }
            applyGroupMutationResult(result)
            await reloadChats(forceFreshSnapshot: true)
        } catch {
            guard
                isCurrentGroupDetailsMutation(
                    generation: generation,
                    accountId: accountId,
                    groupIdHex: groupIdHex
                )
            else { return }
            lastError = error.localizedDescription
        }
    }

    @discardableResult
    func setChatArchived(_ chat: ChatItem, archived: Bool) async -> Bool {
        guard let client, let activeAccount, archivingChatId == nil else { return false }
        lastError = nil
        archivingChatId = chat.id
        defer { archivingChatId = nil }

        do {
            _ = try await client.setGroupArchived(
                accountRef: activeAccount.accountRef,
                groupIdHex: chat.id,
                archived: archived
            )
            await reloadChats(forceFreshSnapshot: true)
            return true
        } catch {
            lastError =
                archived
                ? L10n.string("Couldn't archive chat")
                : L10n.string("Couldn't update archive")
            return false
        }
    }

    func setSelectedGroupArchived(_ archived: Bool) async {
        guard let snapshot = groupDetailsSnapshot, !isArchivingGroup else { return }
        guard let chat = selectedChat ?? chatItem(accountId: activeAccountId ?? "", chatId: snapshot.groupIdHex) else {
            return
        }

        lastError = nil
        isArchivingGroup = true
        defer { isArchivingGroup = false }

        guard await setChatArchived(chat, archived: archived) else { return }
        if archived {
            closeGroupDetails()
        } else {
            await loadGroupDetails(groupIdHex: snapshot.groupIdHex)
        }
    }

    // MARK: - Leaving a chat, and deleting its local copy
    //
    // Both actions are offered by the sidebar row context menu and by the group-details inspector,
    // and both surfaces run these exact methods — the policy in `ChatDestructiveActions` decides
    // *whether* to offer them, and nothing here is snapshot-coupled. This mirrors the invite
    // convention above (`acceptGroupInvite(for:)` / `acceptSelectedGroupInvite()`): one
    // `groupIdHex`-keyed implementation plus thin adapters.
    //
    // Leaving is two-phase because a chat-list row cannot know whether leaving is legal:
    // `ChatListRowFfi` carries membership, but `canLeave` / `isLastAdmin` live only on
    // `GroupManagementStateFfi`, and a `contextMenu` closure cannot await an FFI call. Phase 1
    // resolves eligibility and either opens the confirmation or reports the blocker; phase 2 runs
    // after the user confirms, re-reading eligibility because it can move between the two taps.

    func prepareChatLeave(for chat: ChatItem) async {
        await prepareChatLeave(groupIdHex: chat.id, title: chat.title)
    }

    func prepareSelectedChatLeave() async {
        guard let snapshot = groupDetailsSnapshot else { return }
        await prepareChatLeave(groupIdHex: snapshot.groupIdHex, title: snapshot.name)
    }

    func prepareChatLeave(groupIdHex: String, title: String) async {
        // One preparation at a time, so two quick clicks on different rows cannot both resolve and
        // leave the confirmation naming whichever eligibility fetch happened to finish last.
        guard let client,
            let activeAccount,
            leavingChatId == nil,
            preparingChatLeaveId == nil,
            chatPendingLeave == nil,
            chatPendingAdminHandoff == nil,
            // A handoff already running *is* a leave in progress, but it does not claim
            // `leavingChatId` until its promotion commits. Without this, a second tap in that window
            // resolves eligibility, still finds the sole-admin block, and — because the re-entrancy
            // guard correctly declines to reopen the picker — reports a blocker for a leave that is
            // in fact about to succeed.
            handingOffAdminChatId == nil
        else { return }

        preparingChatLeaveId = groupIdHex
        defer {
            if preparingChatLeaveId == groupIdHex {
                preparingChatLeaveId = nil
            }
        }

        let accountId = activeAccount.id
        do {
            let state = try await client.groupManagementState(
                accountRef: activeAccount.accountRef,
                groupIdHex: groupIdHex
            )
            guard activeAccountId == accountId else { return }
            await presentChatLeaveDecision(
                groupIdHex: groupIdHex,
                title: title,
                state: state
            )
        } catch {
            guard activeAccountId == accountId else { return }
            chatActionAlert = .leaveFailed()
        }
    }

    /// Turn resolved eligibility into either a confirmation dialog or a blocker report. Shared by
    /// both phases so the confirm path re-applies exactly the checks the prepare path applied.
    ///
    /// Takes the whole `GroupManagementStateFfi` rather than the projected `ChatLeaveEligibility`
    /// because the sole-admin branch needs its `memberActions` to know who may be promoted.
    private func presentChatLeaveDecision(
        groupIdHex: String,
        title: String,
        state: GroupManagementStateFfi
    ) async {
        // Both callers only reach here after their surface decided the action was `.leave`, which
        // already implies an active membership — so `.member` is the right assumption rather than a
        // re-lookup. If the account was in fact removed in the meantime, the core reports
        // `canLeave: false` with `isLastAdmin: false`, which lands on `.unavailable`; the next chat
        // -list reload then flips the row to `.deleteLocally` on its own.
        let eligibility = ChatLeaveEligibility(state)
        guard
            let blocker = ChatDestructiveActions.leaveBlocker(
                membership: .member,
                eligibility: eligibility
            )
        else {
            chatPendingLeave = ChatLeaveTarget(
                groupIdHex: groupIdHex,
                title: title,
                requiresSelfDemote: ChatDestructiveActions.shouldSelfDemoteBeforeLeave(eligibility)
            )
            return
        }

        await reportLeaveBlocker(blocker, groupIdHex: groupIdHex, title: title, state: state)
    }

    /// Both phases resolve the same blocker and must react to it identically, so they share this.
    private func reportLeaveBlocker(
        _ blocker: ChatDestructiveActions.LeaveBlocker,
        groupIdHex: String,
        title: String,
        state: GroupManagementStateFfi
    ) async {
        switch blocker {
        case .pending:
            // Already leaving: no dialog and no error — refresh so the row shows its
            // `LeavingGroupBadge` instead.
            await reloadChats(forceFreshSnapshot: true)
        case .lastAdmin:
            // The one blocker the app can clear on the user's behalf — in one of two ways, decided
            // by who is left in the group. Only the genuine dead end falls through to the alert.
            if await resolveLastAdminLeaveBlock(groupIdHex: groupIdHex, title: title, state: state) {
                return
            }
            chatActionAlert = .leaveBlocked(blocker)
        case .unavailable:
            chatActionAlert = .leaveBlocked(blocker)
        }
    }

    /// Clear a sole-admin leave block using the group's roster, or report that it cannot be cleared.
    /// Returns false only for the genuine dead end — an unreadable roster, or members present whom
    /// the core refuses to let this account promote — leaving the caller to report the blocker.
    ///
    /// Which of the two resolutions applies is `ChatDestructiveActions`' decision, not this method's:
    ///
    /// * **A successor exists** → open the picker; the leave runs once the promotion commits.
    /// * **Nobody else is in the group** → offer the local delete. Leaving is normally the only way
    ///   out of a group *because the others have to learn this account stopped reading*; with nobody
    ///   left there is no one to tell, and no leave the core will accept either. This is the only
    ///   case in the app where a member is offered a local delete — see
    ///   `ChatDestructiveActions.action(membership:leaveRequestPending:leaveBlocker:lastAdminResolution:)`.
    ///
    /// The roster comes from a fresh `groupDetails` read rather than from `groupDetailsSnapshot`: the
    /// leave can be started from a sidebar row while an entirely different chat is open, so both
    /// resolutions have to be about *this* group.
    private func resolveLastAdminLeaveBlock(
        groupIdHex: String,
        title: String,
        state: GroupManagementStateFfi
    ) async -> Bool {
        guard let client, let activeAccount else { return false }
        let accountId = activeAccount.id
        guard
            let details = try? await client.groupDetails(
                accountRef: activeAccount.accountRef,
                groupIdHex: groupIdHex
            ),
            activeAccountId == accountId
        else { return false }

        // Reuses the one roster projection the inspector uses, so the picker shows the same
        // nicknames, avatars and admin badges as the member list — and reads `canPromote` from the
        // same `memberActions` the core just returned.
        let members = groupDetailsSnapshot(from: details, managementState: state).members

        switch ChatDestructiveActions.lastAdminResolution(members: members) {
        case .handOffAdmin:
            // `handingOffAdminChatId` is the re-entrancy guard. `confirmChatAdminHandoff` runs the
            // leave through `confirmChatLeave`, which re-reads eligibility; if the promotion
            // committed but the core still reports this account as the last admin, reopening the
            // picker the user just used would loop. Report the blocker instead.
            guard handingOffAdminChatId != groupIdHex else { return false }
            chatPendingAdminHandoff = ChatAdminHandoffTarget(
                groupIdHex: groupIdHex,
                title: title,
                candidates: ChatDestructiveActions.adminHandoffCandidates(from: members)
            )
            return true

        case .deleteLocally:
            // True even if the request is dropped by its own re-entrancy guard (a local delete
            // already confirming or running). The resolution was still correct, and a suppressed
            // duplicate dialog is far better than falling through to a `.lastAdmin` alert telling
            // someone alone in a chat to invite a member — which is the bug this branch removes.
            requestChatLocalDelete(groupIdHex: groupIdHex, title: title)
            return true

        case .blocked:
            return false
        }
    }

    /// Promote `successor`, then run the leave the promotion unblocked.
    ///
    /// The two halves are deliberately sequential and not merged into one core call: the promotion
    /// is its own group commit, and if it fails the account must be left exactly where it was —
    /// still admin, still a member — rather than half-way out. The leave itself goes through
    /// `confirmChatLeave`, which re-reads eligibility and owns the self-demote-then-remove sequence,
    /// so this method adds no second copy of that logic.
    func confirmChatAdminHandoff(_ target: ChatAdminHandoffTarget, successor: GroupMemberItem) async {
        guard let client,
            let activeAccount,
            leavingChatId == nil,
            handingOffAdminChatId == nil
        else { return }

        chatPendingAdminHandoff = nil
        let accountId = activeAccount.id
        let groupIdHex = target.groupIdHex
        handingOffAdminChatId = groupIdHex
        defer {
            if handingOffAdminChatId == groupIdHex {
                handingOffAdminChatId = nil
            }
        }

        do {
            let result = try await client.promoteAdminDetailed(
                accountRef: activeAccount.accountRef,
                groupIdHex: groupIdHex,
                memberRef: successor.npub
            )
            guard activeAccountId == accountId else { return }
            // The returned details describe `groupIdHex`, which is not necessarily the chat on
            // screen — so they may only be applied when it is. Otherwise just drop the stale roster
            // so the next reader refetches.
            if selectedChat?.id == groupIdHex {
                applyGroupMutationResult(result)
            } else {
                invalidateGroupMembers(for: groupIdHex)
            }
        } catch {
            guard activeAccountId == accountId else { return }
            chatActionAlert = .adminHandoffFailed()
            return
        }

        await confirmChatLeave(
            ChatLeaveTarget(groupIdHex: groupIdHex, title: target.title, requiresSelfDemote: true)
        )
    }

    func confirmChatLeave(_ target: ChatLeaveTarget) async {
        guard let client,
            let activeAccount,
            leavingChatId == nil
        else { return }

        chatPendingLeave = nil
        let accountId = activeAccount.id
        let groupIdHex = target.groupIdHex
        leavingChatId = groupIdHex
        // A leave is a group commit, so it also participates in the inspector's commit exclusion.
        // The converse does not hold: starting a leave deliberately does *not* consult
        // `hasInFlightGroupCommit`, so an unrelated in-flight commit on another chat cannot block
        // it. Cross-chat coupling is exactly what the per-chat `leavingChatId` guard avoids.
        isLeavingGroup = true
        defer {
            isLeavingGroup = false
            if leavingChatId == groupIdHex {
                leavingChatId = nil
            }
        }

        do {
            // Eligibility is re-read rather than trusted from `target`: the group can commit a
            // membership or admin change between the menu tap and the confirmation.
            let state = try await client.groupManagementState(
                accountRef: activeAccount.accountRef,
                groupIdHex: groupIdHex
            )
            guard activeAccountId == accountId else { return }
            let eligibility = ChatLeaveEligibility(state)
            if let blocker = ChatDestructiveActions.leaveBlocker(
                membership: .member,
                eligibility: eligibility
            ) {
                await reportLeaveBlocker(
                    blocker,
                    groupIdHex: groupIdHex,
                    title: target.title,
                    state: state
                )
                return
            }

            if ChatDestructiveActions.shouldSelfDemoteBeforeLeave(eligibility) {
                _ = try await client.selfDemoteAdminDetailed(
                    accountRef: activeAccount.accountRef,
                    groupIdHex: groupIdHex
                )
                guard activeAccountId == accountId else { return }
            }

            _ = try await client.leaveGroup(
                accountRef: activeAccount.accountRef,
                groupIdHex: groupIdHex
            )
            guard activeAccountId == accountId else { return }
            clearMediaReferenceResolutionCache(forAccountId: accountId, groupIdHex: groupIdHex)
            if groupDetailsSnapshot?.groupIdHex == groupIdHex {
                closeGroupDetails()
            }
            await reloadChats(forceFreshSnapshot: true)
        } catch {
            guard activeAccountId == accountId else { return }
            // A leave the core already recorded is a success, not a failure: re-requesting inside
            // the same epoch surfaces as `LeaveAlreadyRequested`, and a retry can report the same
            // condition under a different error, so fall back to re-reading the durable state.
            if await leaveIsAlreadyPending(error, groupIdHex: groupIdHex, accountRef: activeAccount.accountRef) {
                guard activeAccountId == accountId else { return }
                await reloadChats(forceFreshSnapshot: true)
                return
            }
            guard activeAccountId == accountId else { return }
            chatActionAlert = .leaveFailed()
        }
    }

    private func leaveIsAlreadyPending(
        _ error: Error,
        groupIdHex: String,
        accountRef: String
    ) async -> Bool {
        if let error = error as? MarmotKitError, case .LeaveAlreadyRequested = error {
            return true
        }
        guard let client else { return false }
        guard
            let state = try? await client.groupManagementState(
                accountRef: accountRef,
                groupIdHex: groupIdHex
            )
        else { return false }
        return state.leaveRequestPending
    }

    func requestChatLocalDelete(for chat: ChatItem) {
        requestChatLocalDelete(groupIdHex: chat.id, title: chat.title)
    }

    func requestSelectedChatLocalDelete() {
        guard let snapshot = groupDetailsSnapshot else { return }
        requestChatLocalDelete(groupIdHex: snapshot.groupIdHex, title: snapshot.name)
    }

    func requestChatLocalDelete(groupIdHex: String, title: String) {
        guard !isDeletingGroupLocally, chatPendingLocalDelete == nil else { return }
        chatPendingLocalDelete = ChatLocalDeleteTarget(groupIdHex: groupIdHex, title: title)
    }

    func confirmChatLocalDelete(_ target: ChatLocalDeleteTarget) async {
        chatPendingLocalDelete = nil
        await deleteGroupLocally(groupIdHex: target.groupIdHex, reportsToChatAlert: true)
    }

    func clearPendingChatDestructiveActions() {
        chatPendingLeave = nil
        chatPendingAdminHandoff = nil
        chatPendingLocalDelete = nil
        chatActionAlert = nil
        preparingChatLeaveId = nil
    }

    func showGroupImagePicker(for chat: ChatItem) {
        guard !chat.isDirect else { return }
        lastError = nil
        closeGroupDetails()
        invalidateGroupImageSearch()
        groupImageSearchQuery = ""
        groupImageResults = []
        isGroupImagePickerPresented = true
    }

    func closeGroupImagePicker() {
        isGroupImagePickerPresented = false
        invalidateGroupImageSearch()
        groupImageResults = []
    }

    func dismissGroupImagePickerIfSelectedChatUnavailable() {
        guard isGroupImagePickerPresented, selectedChat == nil else { return }
        closeGroupImagePicker()
    }

    func searchGroupImages() async {
        let query = groupImageSearchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            invalidateGroupImageSearch()
            groupImageResults = []
            return
        }

        lastError = nil
        let searchGeneration = beginGroupImageSearch()
        isSearchingGroupImages = true
        defer {
            // Spinner ownership is keyed on the generation ALONE, independent of the stricter
            // picker/query guard used for committing results. Only a newer search or an
            // `invalidateGroupImageSearch` (both bump the generation, and each sets the spinner
            // state itself) supersedes this one's ownership of `isSearchingGroupImages`. Editing
            // the query mid-flight without resubmitting must NOT strand the spinner at `true`
            // (which would disable the Search button forever), so it is deliberately not part of
            // this check — see issue #110 adversarial review.
            if ownsGroupImageSearch(generation: searchGeneration) {
                isSearchingGroupImages = false
            }
        }

        do {
            let results = try await groupImageSearchClient.searchImages(query: query)
            // Drop results if a newer search superseded this one, the query was edited, or the
            // picker was dismissed/reopened while the request was in flight.
            guard isCurrentGroupImageSearch(generation: searchGeneration, query: query) else { return }
            groupImageResults = results
        } catch {
            guard isCurrentGroupImageSearch(generation: searchGeneration, query: query) else { return }
            groupImageResults = []
            lastError = error.localizedDescription
        }
    }

    func setGroupImage(_ result: GroupImageSearchResult) async {
        guard let context = beginGroupImageUpdate() else { return }
        defer { isSavingGroupImage = false }

        do {
            guard let sourceURL = RemoteImageURLPolicy.sanitizedURL(from: result.imageURL) else {
                throw GroupImageSelectionError.invalidWebImage
            }
            guard let data = await groupImageSourceLoader.data(for: sourceURL) else {
                throw GroupImageSelectionError.downloadFailed
            }
            let attachment = try await OutgoingMediaDraftProcessor.preparedAttachment(
                fromPastedImageData: data,
                typeIdentifier: nil
            )
            try await commitSelectedGroupImage(attachment, context: context)
        } catch is CancellationError {
            return
        } catch {
            lastError = error.localizedDescription
        }
    }

    func setGroupImage(fileURL: URL) async {
        guard let context = beginGroupImageUpdate() else { return }
        defer { isSavingGroupImage = false }

        let isSecurityScoped = fileURL.startAccessingSecurityScopedResource()
        defer {
            if isSecurityScoped {
                fileURL.stopAccessingSecurityScopedResource()
            }
        }

        do {
            let attachment = try await OutgoingMediaDraftProcessor.preparedAttachment(fromFileURL: fileURL)
            guard attachment.kind == .image else {
                throw GroupImageSelectionError.notAnImage
            }
            try await commitSelectedGroupImage(attachment, context: context)
        } catch is CancellationError {
            return
        } catch {
            lastError = error.localizedDescription
        }
    }

    func clearGroupImage() async {
        guard let context = beginGroupImageUpdate() else { return }
        defer { isSavingGroupImage = false }

        do {
            guard groupImageUpdateStillTargetsSelection(context) else { return }
            if context.hadLegacyURLAvatar {
                _ = try await context.client.updateGroupAvatarUrl(
                    accountRef: context.accountRef,
                    groupIdHex: context.groupIdHex,
                    url: nil,
                    dim: nil,
                    thumbhash: nil
                )
            }
            if context.hadEncryptedImage {
                _ = try await context.client.clearGroupImage(
                    accountRef: context.accountRef,
                    groupIdHex: context.groupIdHex
                )
            }
            await finishGroupImageUpdate(context)
        } catch {
            lastError = error.localizedDescription
        }
    }

    private func beginGroupImageUpdate() -> GroupImageUpdateContext? {
        guard let client,
            let activeAccount,
            let selectedChat,
            !selectedChat.isDirect,
            !hasInFlightGroupCommit
        else { return nil }
        lastError = nil
        isSavingGroupImage = true
        return GroupImageUpdateContext(
            client: client,
            accountId: activeAccount.id,
            accountRef: activeAccount.accountRef,
            groupIdHex: selectedChat.id,
            hadLegacyURLAvatar: selectedChat.pictureURL != nil,
            hadEncryptedImage: selectedChat.groupImageHashHex != nil
        )
    }

    private func commitSelectedGroupImage(
        _ attachment: PendingMediaAttachment,
        context: GroupImageUpdateContext
    ) async throws {
        guard groupImageUpdateStillTargetsSelection(context) else { return }
        _ = try await context.client.updateGroupImage(
            accountRef: context.accountRef,
            groupIdHex: context.groupIdHex,
            plaintext: attachment.data,
            mediaType: attachment.mediaType
        )
        if context.hadLegacyURLAvatar {
            _ = try await context.client.updateGroupAvatarUrl(
                accountRef: context.accountRef,
                groupIdHex: context.groupIdHex,
                url: nil,
                dim: nil,
                thumbhash: nil
            )
        }
        await finishGroupImageUpdate(context)
    }

    private func finishGroupImageUpdate(_ context: GroupImageUpdateContext) async {
        groupImagePayloadCache = groupImagePayloadCache.filter {
            !$0.key.hasPrefix("\(context.accountId)|\(context.groupIdHex)|")
        }
        guard activeAccountId == context.accountId else { return }
        await reloadChats(forceFreshSnapshot: true)
        if groupImageUpdateStillTargetsSelection(context) {
            closeGroupImagePicker()
        }
    }

    private func groupImageUpdateStillTargetsSelection(_ context: GroupImageUpdateContext) -> Bool {
        activeAccountId == context.accountId && selectedChat?.id == context.groupIdHex
    }

    func acceptGroupInvite(groupIdHex: String) async {
        guard let client, let activeAccount, !isAcceptingGroupInvite, !isDecliningGroupInvite else { return }
        lastError = nil
        isAcceptingGroupInvite = true
        defer { isAcceptingGroupInvite = false }

        do {
            _ = try await client.acceptGroupInvite(
                accountRef: activeAccount.accountRef,
                groupIdHex: groupIdHex
            )
            await reloadChats(forceFreshSnapshot: true)
            if isGroupDetailsPresented, groupDetailsSnapshot?.groupIdHex == groupIdHex {
                await loadGroupDetails(groupIdHex: groupIdHex)
            }
        } catch {
            lastError = error.localizedDescription
        }
    }

    func declineGroupInvite(groupIdHex: String) async {
        guard let client, let activeAccount, !isDecliningGroupInvite, !isAcceptingGroupInvite else { return }
        lastError = nil
        isDecliningGroupInvite = true
        defer { isDecliningGroupInvite = false }

        do {
            _ = try await client.declineGroupInvite(
                accountRef: activeAccount.accountRef,
                groupIdHex: groupIdHex
            )
            if groupDetailsSnapshot?.groupIdHex == groupIdHex {
                closeGroupDetails()
            }
            if case .chat(let selectedGroupId) = selection, selectedGroupId == groupIdHex {
                leaveActiveConversation()
                stopTimelineListener()
                selection = nil
                pruneMessageCache(keeping: nil)
            }
            await reloadChats(forceFreshSnapshot: true)
        } catch {
            lastError = error.localizedDescription
        }
    }

    /// The invite-failure reconciliation may only touch workspace state while the user is still
    /// on the same account, with the same group selected, and its details still presented.
    private func isInviteReconciliationTargetCurrent(accountId: String?, groupIdHex: String) -> Bool {
        guard
            activeAccountId == accountId,
            isGroupDetailsPresented,
            groupDetailsSnapshot?.groupIdHex == groupIdHex,
            case .chat(let selectedGroupId) = selection,
            selectedGroupId == groupIdHex
        else { return false }
        return true
    }

    func setDisappearingMessages(groupIdHex: String, seconds: UInt64) async {
        guard let client, let activeAccount, !hasInFlightGroupCommit else { return }
        let accountId = activeAccount.id
        lastError = nil
        isUpdatingDisappearingMessages = true
        defer { isUpdatingDisappearingMessages = false }

        do {
            _ = try await client.updateMessageRetention(
                accountRef: activeAccount.accountRef,
                groupIdHex: groupIdHex,
                disappearingMessageSecs: seconds
            )
            // The commit await may have suspended across an account switch — don't sync another
            // account's header.
            guard activeAccountId == accountId else { return }
            // Keep the mounted conversation header's timer in sync — it reads
            // `conversationMetadataByChat`, which the details reload below does not touch. Bump the
            // metadata generation unconditionally so an older in-flight
            // `refreshConversationMetadata` (which captured the pre-change value) can't complete
            // afterward and overwrite this — the race exists even while the cache is still empty.
            claimConversationMetadataGeneration(for: groupIdHex)
            if let existing = conversationMetadataByChat[groupIdHex] {
                conversationMetadataByChat[groupIdHex] = ConversationMetadata(
                    memberCount: existing.memberCount,
                    disappearingMessageSecs: seconds,
                    isSelfAdmin: existing.isSelfAdmin
                )
            } else if let chat = chatItem(accountId: accountId, chatId: groupIdHex) {
                // Nothing cached to patch: publish a fresh post-commit read instead (it re-bumps
                // the generation itself, so it stays newest). `chatItem` spans active *and*
                // archived indexes, so an archived group that's open still gets its header updated.
                await refreshConversationMetadata(for: chat)
            }
            if isGroupDetailsPresented, groupDetailsSnapshot?.groupIdHex == groupIdHex {
                await loadGroupDetails(groupIdHex: groupIdHex)
            }
        } catch {
            lastError = error.localizedDescription
        }
    }

    func secureDeleteExpiredMessages(groupIdHex: String) async {
        guard let client, let activeAccount, !isSecureDeletingExpired else { return }
        lastError = nil
        isSecureDeletingExpired = true
        defer { isSecureDeletingExpired = false }

        do {
            _ = try await client.secureDeleteExpired(
                accountRef: activeAccount.accountRef,
                groupIdHex: groupIdHex
            )
        } catch {
            lastError = error.localizedDescription
        }
    }

    /// Remove a group from local storage only (no relay/leave traffic). Used to
    /// clear a stale or declined conversation from this device.
    ///
    /// This primitive stays ungated on membership: the *surfaces* decide when to offer a local
    /// delete (see `ChatDestructiveActions`), and non-user-initiated callers must keep working.
    /// `reportsToChatAlert` routes failures to the destructive-action alert instead of `lastError`,
    /// which is not rendered anywhere near the sidebar.
    func deleteGroupLocally(groupIdHex: String, reportsToChatAlert: Bool = false) async {
        guard let client, let activeAccount, !isDeletingGroupLocally else { return }
        lastError = nil
        isDeletingGroupLocally = true
        // Also recorded per-chat so a surface can say *which* chat is being removed. The re-entrancy
        // guard above stays global on purpose, so every Delete affordance must remain disabled while
        // any delete runs — a per-chat `disabled` would let a second click be silently dropped.
        deletingChatId = groupIdHex
        defer {
            isDeletingGroupLocally = false
            deletingChatId = nil
        }

        do {
            _ = try await client.deleteGroupLocal(
                accountRef: activeAccount.accountRef,
                groupIdHex: groupIdHex
            )
            clearMediaReferenceResolutionCache(forAccountId: activeAccount.id, groupIdHex: groupIdHex)
            if groupDetailsSnapshot?.groupIdHex == groupIdHex {
                closeGroupDetails()
            }
            if case .chat(let selectedGroupId) = selection, selectedGroupId == groupIdHex {
                leaveActiveConversation()
                stopTimelineListener()
                selection = nil
                pruneMessageCache(keeping: nil)
            }
            await reloadChats(forceFreshSnapshot: true)
        } catch {
            if reportsToChatAlert {
                chatActionAlert = .localDeleteFailed()
            } else {
                lastError = error.localizedDescription
            }
        }
    }

    func loadGroupDetails(groupIdHex: String) async {
        guard let client, let activeAccount else {
            if groupDetailsSnapshot == nil {
                isLoadingGroupDetails = false
            }
            return
        }
        guard selectedChat?.id == groupIdHex else {
            if groupDetailsSnapshot == nil {
                isLoadingGroupDetails = false
            }
            return
        }

        // Last-request-wins guard (issue #135): this method is reachable concurrently for the same
        // group, and the FFI pair below is completion-ordered, not request-ordered. Capture the
        // generation on entry; only the still-current load may apply its snapshot, clear the shared
        // spinner, or report errors. A superseded load (a newer load started, or `closeGroupDetails`
        // ran) leaves the spinner to its owner so it cannot drop it early or repopulate closed UI.
        let generation = beginGroupDetailsLoad()
        isLoadingGroupDetails = true
        defer {
            if ownsGroupDetailsLoad(generation: generation) {
                isLoadingGroupDetails = false
            }
        }

        do {
            let details = try await client.groupDetails(
                accountRef: activeAccount.accountRef,
                groupIdHex: groupIdHex
            )
            let managementState = try await client.groupManagementState(
                accountRef: activeAccount.accountRef,
                groupIdHex: groupIdHex
            )
            guard ownsGroupDetailsLoad(generation: generation) else { return }
            guard selectedChat?.id == groupIdHex else { return }
            applyGroupDetails(details, managementState: managementState)
        } catch {
            guard ownsGroupDetailsLoad(generation: generation) else { return }
            lastError = error.localizedDescription
        }
    }

    var hasInFlightGroupCommit: Bool {
        isSavingGroupProfile
            || isInvitingGroupMember
            || mutatingGroupMemberId != nil
            || isUpdatingDisappearingMessages
            || isLeavingGroup
            || isSavingGroupImage
            // A successor promotion is a group commit like any other. Included even though the
            // handoff may target a chat other than the one on screen, matching `isLeavingGroup`,
            // which is likewise cross-chat: the inspector's exclusion is intentionally coarse.
            || handingOffAdminChatId != nil
    }

    func mutateGroupMember(_ member: GroupMemberItem, action: GroupMemberMutationAction) async {
        guard let client,
            let activeAccount,
            let snapshot = groupDetailsSnapshot,
            !hasInFlightGroupCommit
        else { return }
        if case .demote = action, member.isSelf {
            await selfDemoteSelectedGroupAdmin()
            return
        }
        let accountId = activeAccount.id
        let groupIdHex = snapshot.groupIdHex
        let generation = beginGroupDetailsMutation()
        lastError = nil
        mutatingGroupMemberId = member.id
        defer { mutatingGroupMemberId = nil }

        do {
            let result: GroupMutationResultFfi
            switch action {
            case .promote:
                result = try await client.promoteAdminDetailed(
                    accountRef: activeAccount.accountRef,
                    groupIdHex: groupIdHex,
                    memberRef: member.npub
                )
            case .demote:
                result = try await client.demoteAdminDetailed(
                    accountRef: activeAccount.accountRef,
                    groupIdHex: groupIdHex,
                    memberRef: member.npub
                )
            case .remove:
                result = try await client.removeMembersDetailed(
                    accountRef: activeAccount.accountRef,
                    groupIdHex: groupIdHex,
                    memberRefs: [member.npub]
                )
            }
            guard
                isCurrentGroupDetailsMutation(
                    generation: generation,
                    accountId: accountId,
                    groupIdHex: groupIdHex
                )
            else { return }
            applyGroupMutationResult(result)
            await reloadChats(forceFreshSnapshot: true)
        } catch {
            guard
                isCurrentGroupDetailsMutation(
                    generation: generation,
                    accountId: accountId,
                    groupIdHex: groupIdHex
                )
            else { return }
            lastError = error.localizedDescription
        }
    }

    /// True if a group-member mutation that captured these values on entry may still commit its
    /// returned details. Mutations own a fresh group-details generation so they supersede any
    /// already in-flight load; closing details, switching accounts, or starting a newer load
    /// invalidates the token before stale details can be applied.
    func isCurrentGroupDetailsMutation(
        generation: UInt64,
        accountId: String,
        groupIdHex: String
    ) -> Bool {
        ownsGroupDetailsLoad(generation: generation)
            && activeAccountId == accountId
            && selectedChat?.id == groupIdHex
    }

    func applyGroupMutationResult(_ result: GroupMutationResultFfi) {
        applyGroupDetails(result.details, managementState: result.managementState)
    }

    func applyGroupDetails(
        _ details: GroupDetailsFfi,
        managementState: GroupManagementStateFfi
    ) {
        storeGroupMembers(details.members, for: details.group.groupIdHex)
        let snapshot = groupDetailsSnapshot(from: details, managementState: managementState)
        groupDetailsSnapshot = snapshot
        groupProfileDraftName = snapshot.name
        groupProfileDraftDescription = snapshot.description
    }

    func invalidateGroupMemberDetailsCacheIfNeeded(
        trigger: ChatListUpdateTriggerFfi,
        groupIdHex: String
    ) {
        switch trigger {
        case .newGroup, .membershipChanged, .conversationKindChanged, .snapshotRefresh, .removed:
            invalidateGroupMembers(for: groupIdHex)
        case .newLastMessage,
            .lastMessageDeleted,
            .latestMessageDeliveryChanged,
            .archiveChanged,
            .pendingConfirmationChanged,
            .unreadChanged,
            .manualUnreadChanged,
            .muteChanged,
            .pinOrderChanged:
            break
        }
    }

    func beginGroupDetailsLoad() -> UInt64 {
        groupDetailsLoadGeneration &+= 1
        return groupDetailsLoadGeneration
    }

    /// Start a group-member mutation's guarded apply window. The mutation returns a fresh
    /// `GroupDetailsFfi`, so it must invalidate any older `loadGroupDetails` already awaiting FFI;
    /// otherwise that load can complete last and overwrite the mutation result with stale members.
    /// Clear the shared load spinner here because the superseded load intentionally no longer owns it.
    func beginGroupDetailsMutation() -> UInt64 {
        invalidateGroupDetailsLoad()
        return groupDetailsLoadGeneration
    }

    /// Invalidate any in-flight group-details load so a stale completion cannot apply its snapshot,
    /// clear the spinner, or report an error against closed/superseded UI state. Also clears the
    /// (now-orphaned) spinner: the in-flight load, once superseded, declines to touch it.
    func invalidateGroupDetailsLoad() {
        groupDetailsLoadGeneration &+= 1
        isLoadingGroupDetails = false
    }

    /// True while `generation` still owns the group-details load — i.e. no newer `loadGroupDetails`
    /// or `invalidateGroupDetailsLoad` (via `closeGroupDetails`) has bumped the generation.
    func ownsGroupDetailsLoad(generation: UInt64) -> Bool {
        groupDetailsLoadGeneration == generation
    }

    func beginGroupImageSearch() -> UInt64 {
        groupImageSearchGeneration &+= 1
        return groupImageSearchGeneration
    }

    func invalidateGroupImageSearch() {
        groupImageSearchGeneration &+= 1
        isSearchingGroupImages = false
    }

    /// True while `generation` still owns the group-image search spinner — i.e. no newer
    /// `beginGroupImageSearch` or `invalidateGroupImageSearch` has bumped the generation. This is
    /// intentionally looser than `isCurrentGroupImageSearch`: it does NOT require the picker to be
    /// presented or the live query to match, because spinner ownership must transfer cleanly even
    /// when the user edits the query mid-flight without resubmitting (otherwise the spinner would
    /// stay stuck `true` and disable the Search button — issue #110 review).
    func ownsGroupImageSearch(generation: UInt64) -> Bool {
        groupImageSearchGeneration == generation
    }

    /// True only if `generation` is still the latest group-image search, the picker is still
    /// presented, and the live (trimmed) query still equals the one this search was issued for.
    /// Any of: a newer search, a dismissed/reopened picker, or an edited query invalidates the
    /// in-flight result so it cannot overwrite current UI state.
    func isCurrentGroupImageSearch(generation: UInt64, query: String) -> Bool {
        ownsGroupImageSearch(generation: generation)
            && isGroupImagePickerPresented
            && groupImageSearchQuery.trimmingCharacters(in: .whitespacesAndNewlines) == query
    }

    func storeGroupMembers(_ members: [GroupMemberDetailsFfi], for groupIdHex: String) {
        groupMemberDetailsLookups[groupIdHex]?.task.cancel()
        groupMemberDetailsLookups[groupIdHex] = nil
        mentionRosterCache[groupIdHex] = nil
        mentionNamesCache[groupIdHex] = nil
        groupMemberDetailsCache[groupIdHex] = members
        // Every roster the app learns about flows through here, including the one chat-list
        // enrichment fetches for a freshly received invite. The welcoming account is always
        // a member of the group it invited us to, so this covers the inviter too — the
        // explicit `welcomerAccountIdHex` request in `groupDetailsSnapshot` only has to
        // cover the details screen.
        requestPeerProfileRefresh(members.map(\.memberIdHex))
    }

    func invalidateGroupMembers(for groupIdHex: String) {
        // A roster change can bring a new sender into a conversation that had none, so let the
        // peer recovery scan run again for it.
        unrecoverableDirectPeerGroupIds.remove(groupIdHex)
        groupMemberDetailsCache[groupIdHex] = nil
        mentionRosterCache[groupIdHex] = nil
        mentionNamesCache[groupIdHex] = nil
        groupMemberDetailsLookups[groupIdHex]?.task.cancel()
        groupMemberDetailsLookups[groupIdHex] = nil
        readStateMetadataEnrichmentAttempts.remove(groupIdHex)
    }

    func clearGroupMemberCache() {
        unrecoverableDirectPeerGroupIds.removeAll()
        groupMemberDetailsCache.removeAll()
        mentionRosterCache.removeAll()
        mentionNamesCache.removeAll()
        for lookup in groupMemberDetailsLookups.values {
            lookup.task.cancel()
        }
        groupMemberDetailsLookups.removeAll()
        readStateMetadataEnrichmentAttempts.removeAll()
    }

    func cachedGroupMembers(
        groupIdHex: String,
        account: AccountItem,
        client: any MarmotRuntime
    ) async -> [GroupMemberDetailsFfi]? {
        if let cached = groupMemberDetailsCache[groupIdHex] {
            return cached
        }
        if let lookup = groupMemberDetailsLookups[groupIdHex] {
            return await lookup.task.value
        }

        nextGroupMemberDetailsLookupToken += 1
        let token = nextGroupMemberDetailsLookupToken
        let accountRef = account.accountRef
        let task = Task { () -> [GroupMemberDetailsFfi]? in
            guard
                let details = try? await client.groupDetails(
                    accountRef: accountRef,
                    groupIdHex: groupIdHex
                )
            else {
                return nil
            }
            return details.members
        }
        groupMemberDetailsLookups[groupIdHex] = GroupMemberDetailsLookup(token: token, task: task)

        let members = await task.value
        if groupMemberDetailsLookups[groupIdHex]?.token == token {
            groupMemberDetailsLookups[groupIdHex] = nil
            if activeAccountId == account.id, let members {
                storeGroupMembers(members, for: groupIdHex)
            }
        }
        return members
    }
}
