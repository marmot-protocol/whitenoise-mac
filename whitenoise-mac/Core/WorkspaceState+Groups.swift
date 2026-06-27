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
import UserNotifications

@MainActor
extension WorkspaceState {
    func showGroupDetails(for chat: ChatItem) async {
        guard !chat.isDirect else { return }
        lastError = nil
        groupDetailsSnapshot = nil
        groupInviteMemberQuery = ""
        groupTranscriptExportStatus = nil
        isGroupDetailsPresented = true
        await loadGroupDetails(groupIdHex: chat.id)
    }

    func closeGroupDetails() {
        isGroupDetailsPresented = false
        groupDetailsSnapshot = nil
        groupProfileDraftName = ""
        groupProfileDraftDescription = ""
        groupInviteMemberQuery = ""
        // Invalidate any in-flight load so a stale completion cannot repopulate closed details or
        // resurrect the spinner; this also clears `isLoadingGroupDetails`. See issue #135.
        invalidateGroupDetailsLoad()
        isSavingGroupProfile = false
        isInvitingGroupMember = false
        isAcceptingGroupInvite = false
        isDecliningGroupInvite = false
        isArchivingGroup = false
        isLeavingGroup = false
        isExportingGroupTranscript = false
        groupTranscriptExportStatus = nil
        mutatingGroupMemberId = nil
    }

    func copySelectedGroupTranscriptJSON() async {
        guard !isExportingGroupTranscript,
            let client,
            let activeAccount,
            let snapshot = groupDetailsSnapshot
        else { return }

        lastError = nil
        groupTranscriptExportStatus = nil
        isExportingGroupTranscript = true
        defer { isExportingGroupTranscript = false }

        do {
            let accountRef = activeAccount.accountRef
            let groupIdHex = snapshot.groupIdHex
            let groupName = snapshot.name
            // Paginates the whole transcript via blocking FFI and JSON-encodes it; keep it
            // off the main thread so a large export does not freeze the UI.
            let export = try await runOffMain { () -> (json: String, eventCount: Int) in
                let messages = try ConversationTranscriptExport.fetchAllMessages(
                    client: client,
                    accountRef: accountRef,
                    groupIdHex: groupIdHex
                )
                let document = ConversationTranscriptExport.makeDocument(
                    groupIdHex: groupIdHex,
                    groupName: groupName,
                    messages: messages
                )
                return (try ConversationTranscriptExport.encodeJSONString(document), document.eventCount)
            }
            copyText(export.json)
            groupTranscriptExportStatus = String(
                format: L10n.string("Copied transcript JSON for %d events."),
                export.eventCount
            )
        } catch {
            lastError = error.localizedDescription
        }
    }

    func reloadSelectedGroupDetails() async {
        guard let selectedChat, !selectedChat.isDirect else { return }
        await loadGroupDetails(groupIdHex: selectedChat.id)
    }

    func saveGroupProfile() async {
        guard let client, let activeAccount, let snapshot = groupDetailsSnapshot else { return }
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
            await reloadChats()
            await loadGroupDetails(groupIdHex: snapshot.groupIdHex)
        } catch {
            lastError = error.localizedDescription
        }
    }

    func inviteMemberToSelectedGroup() async {
        guard let client, let activeAccount, let snapshot = groupDetailsSnapshot else { return }
        let query = groupInviteMemberQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard looksLikeMemberRef(query) else {
            lastError = L10n.string("Enter a valid npub, profile link, or hex public key.")
            return
        }

        lastError = nil
        isInvitingGroupMember = true
        defer { isInvitingGroupMember = false }

        do {
            let normalized = try await runOffMain {
                try client.normalizeMemberRef(memberRef: query)
            }
            let result = try await client.inviteMembersDetailed(
                accountRef: activeAccount.accountRef,
                groupIdHex: snapshot.groupIdHex,
                memberRefs: [normalized.npub]
            )
            groupInviteMemberQuery = ""
            applyGroupMutationResult(result)
            await reloadChats()
        } catch {
            lastError = error.localizedDescription
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
        guard let client, let activeAccount, let snapshot = groupDetailsSnapshot else { return }
        guard snapshot.isSelfAdmin, !snapshot.isLastAdmin else {
            lastError = L10n.string("Make another member an admin before stepping down.")
            return
        }

        lastError = nil
        mutatingGroupMemberId = snapshot.members.first(where: \.isSelf)?.id
        defer { mutatingGroupMemberId = nil }

        do {
            let result = try await client.selfDemoteAdminDetailed(
                accountRef: activeAccount.accountRef,
                groupIdHex: snapshot.groupIdHex
            )
            applyGroupMutationResult(result)
            await reloadChats()
        } catch {
            lastError = error.localizedDescription
        }
    }

    func setSelectedGroupArchived(_ archived: Bool) async {
        guard let client, let activeAccount, let snapshot = groupDetailsSnapshot else { return }
        lastError = nil
        isArchivingGroup = true
        defer { isArchivingGroup = false }

        do {
            _ = try await client.setGroupArchived(
                accountRef: activeAccount.accountRef,
                groupIdHex: snapshot.groupIdHex,
                archived: archived
            )
            if archived {
                closeGroupDetails()
            }
            await reloadChats()
            if !archived {
                await loadGroupDetails(groupIdHex: snapshot.groupIdHex)
            }
        } catch {
            lastError = error.localizedDescription
        }
    }

    func leaveSelectedGroup() async {
        guard let client, let activeAccount, let snapshot = groupDetailsSnapshot else { return }
        guard snapshot.canLeave, !snapshot.requiresSelfDemoteBeforeLeave else {
            lastError = L10n.string("Demote yourself from admin before leaving this group.")
            return
        }

        lastError = nil
        isLeavingGroup = true
        defer { isLeavingGroup = false }

        do {
            _ = try await client.leaveGroup(
                accountRef: activeAccount.accountRef,
                groupIdHex: snapshot.groupIdHex
            )
            closeGroupDetails()
            await reloadChats()
        } catch {
            lastError = error.localizedDescription
        }
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
        await updateSelectedGroupImage(url: result.imageURL, dim: result.dimension)
    }

    func clearGroupImage() async {
        await updateSelectedGroupImage(url: nil, dim: nil)
    }

    func updateSelectedGroupImage(url: String?, dim: String?) async {
        guard let client,
            let activeAccount,
            let selectedChat,
            !selectedChat.isDirect,
            !isSavingGroupImage
        else { return }
        isSavingGroupImage = true
        defer { isSavingGroupImage = false }

        do {
            _ = try await client.updateGroupAvatarUrl(
                accountRef: activeAccount.accountRef,
                groupIdHex: selectedChat.id,
                url: url,
                dim: dim,
                thumbhash: nil
            )
            await reloadChats()
            closeGroupImagePicker()
        } catch {
            lastError = error.localizedDescription
        }
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
            await reloadChats()
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
                stopTimelineListener()
                selection = nil
                pruneMessageCache(keeping: nil)
            }
            await reloadChats()
        } catch {
            lastError = error.localizedDescription
        }
    }

    func setDisappearingMessages(groupIdHex: String, seconds: UInt64) async {
        guard let client, let activeAccount, !isUpdatingDisappearingMessages else { return }
        lastError = nil
        isUpdatingDisappearingMessages = true
        defer { isUpdatingDisappearingMessages = false }

        do {
            _ = try await client.updateMessageRetention(
                accountRef: activeAccount.accountRef,
                groupIdHex: groupIdHex,
                disappearingMessageSecs: seconds
            )
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
    func deleteGroupLocally(groupIdHex: String) async {
        guard let client, let activeAccount, !isDeletingGroupLocally else { return }
        lastError = nil
        isDeletingGroupLocally = true
        defer { isDeletingGroupLocally = false }

        do {
            _ = try await client.deleteGroupLocal(
                accountRef: activeAccount.accountRef,
                groupIdHex: groupIdHex
            )
            if groupDetailsSnapshot?.groupIdHex == groupIdHex {
                closeGroupDetails()
            }
            if case .chat(let selectedGroupId) = selection, selectedGroupId == groupIdHex {
                stopTimelineListener()
                selection = nil
                pruneMessageCache(keeping: nil)
            }
            await reloadChats()
        } catch {
            lastError = error.localizedDescription
        }
    }

    func loadGroupDetails(groupIdHex: String) async {
        guard let client, let activeAccount else { return }
        guard selectedChat?.id == groupIdHex else { return }

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

    func mutateGroupMember(_ member: GroupMemberItem, action: GroupMemberMutationAction) async {
        guard let client, let activeAccount, let snapshot = groupDetailsSnapshot else { return }
        lastError = nil
        mutatingGroupMemberId = member.id
        defer { mutatingGroupMemberId = nil }

        do {
            let result: GroupMutationResultFfi
            switch action {
            case .promote:
                result = try await client.promoteAdminDetailed(
                    accountRef: activeAccount.accountRef,
                    groupIdHex: snapshot.groupIdHex,
                    memberRef: member.npub
                )
            case .demote:
                if member.isSelf {
                    result = try await client.selfDemoteAdminDetailed(
                        accountRef: activeAccount.accountRef,
                        groupIdHex: snapshot.groupIdHex
                    )
                } else {
                    result = try await client.demoteAdminDetailed(
                        accountRef: activeAccount.accountRef,
                        groupIdHex: snapshot.groupIdHex,
                        memberRef: member.npub
                    )
                }
            case .remove:
                result = try await client.removeMembersDetailed(
                    accountRef: activeAccount.accountRef,
                    groupIdHex: snapshot.groupIdHex,
                    memberRefs: [member.npub]
                )
            }
            applyGroupMutationResult(result)
            await reloadChats()
        } catch {
            lastError = error.localizedDescription
        }
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
        case .newGroup, .membershipChanged, .snapshotRefresh, .removed:
            invalidateGroupMembers(for: groupIdHex)
        case .newLastMessage,
            .lastMessageDeleted,
            .archiveChanged,
            .pendingConfirmationChanged,
            .unreadChanged:
            break
        }
    }

    func beginGroupDetailsLoad() -> UInt64 {
        groupDetailsLoadGeneration &+= 1
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
        groupMemberDetailsCache[groupIdHex] = members
    }

    func invalidateGroupMembers(for groupIdHex: String) {
        groupMemberDetailsCache[groupIdHex] = nil
        groupMemberDetailsLookups[groupIdHex]?.task.cancel()
        groupMemberDetailsLookups[groupIdHex] = nil
        readStateMetadataEnrichmentAttempts.remove(groupIdHex)
    }

    func clearGroupMemberCache() {
        groupMemberDetailsCache.removeAll()
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
                groupMemberDetailsCache[groupIdHex] = members
            }
        }
        return members
    }
}
