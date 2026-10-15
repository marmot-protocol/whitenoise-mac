//
//  GroupsInCommonViewModel.swift
//  whitenoise-mac
//
//  The groups a direct chat's peer shares with the viewer, as its chat info lists them.
//

import Foundation
import MarmotKit
import Observation

/// Pure decisions shared by every "Groups in Common" list.
enum GroupsInCommon {
    /// The conversations that could be shared with someone, newest first.
    ///
    /// `excludingGroupIdHex` drops the conversation the list was opened from: the group whose
    /// details are already on screen is not a group "in common", it is the group you are in.
    static func candidates(from chats: [ChatItem], excludingGroupIdHex: String?) -> [ChatItem] {
        let excludedGroupId = excludingGroupIdHex?.nilIfBlank?.lowercased()
        return
            chats
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
    }

    /// The other person in a direct chat: the roster's one other member, else the chat row's peer.
    ///
    /// The roster is the authority on who is in the conversation; the row only knows its peer
    /// once chat-list enrichment has resolved them, and is nil before that. (It used to be read
    /// out of the avatar seed, which an MDK-presented row fills with a cache key — searching
    /// rosters for that found nobody, and chat info read "No groups in common".)
    static func directPeerAccountIdHex(
        resolvedPeerAccountIdHex: String?,
        members: [GroupMemberItem]
    ) -> String? {
        let others = members.filter { !$0.isSelf }
        if others.count == 1, let peer = others[0].id.nilIfBlank { return peer }
        return resolvedPeerAccountIdHex?.nilIfBlank
    }
}

/// Where a "Groups in Common" lookup reads from.
struct GroupsInCommonSource {
    /// Every conversation of the active account, archived ones included.
    let conversations: @MainActor () -> [ChatItem]
    /// The member account ids of a conversation, or nil when its roster could not be read.
    let memberIds: @MainActor (_ groupIdHex: String) async -> [String]?
}

extension GroupsInCommonSource {
    static func workspace(_ workspace: WorkspaceState) -> Self {
        Self(
            conversations: { [weak workspace] in
                guard let workspace, let accountId = workspace.activeAccountId else { return [] }
                return (workspace.chatsByAccount[accountId] ?? [])
                    + (workspace.archivedChatsByAccount[accountId] ?? [])
            },
            memberIds: { [weak workspace] groupIdHex in
                guard let workspace, let client = workspace.client, let account = workspace.activeAccount
                else { return nil }
                return await workspace.cachedGroupMembers(
                    groupIdHex: groupIdHex,
                    account: account,
                    client: client
                )?.map(\.memberIdHex)
            }
        )
    }
}

/// The groups a direct chat's info lists as shared with its peer.
///
/// Owned by the chat info rather than read from the workspace's contact-profile list: a member's
/// profile slides in over the chat info and clears that list when it closes, which used to leave
/// the chat info reading "No groups in common" behind it.
@MainActor
@Observable
final class GroupsInCommonViewModel {
    private(set) var groups: [ChatItem] = []
    private(set) var isLoading = false
    private(set) var hadFailures = false
    /// The lookup `groups` answers completely, so re-showing the same chat info does not blank
    /// a finished list back to a spinner.
    @ObservationIgnored private var loadedKey: String?

    /// Lists the conversations shared with `contactIdHex`, appending each as it is confirmed.
    ///
    /// Driven by `.task(id:)`: a superseded load is cancelled, so it checks cancellation after
    /// every await instead of carrying a generation counter.
    func load(contactIdHex: String, excludingGroupIdHex: String?, from source: GroupsInCommonSource) async {
        let contactId = contactIdHex.lowercased()
        let key = "\(contactId)|\(excludingGroupIdHex?.lowercased() ?? "")"
        if loadedKey == key { return }

        loadedKey = nil
        groups = []
        hadFailures = false
        isLoading = true
        defer {
            if !Task.isCancelled { isLoading = false }
        }

        let candidates = GroupsInCommon.candidates(
            from: source.conversations(),
            excludingGroupIdHex: excludingGroupIdHex
        )
        for chat in candidates {
            let memberIds = await source.memberIds(chat.id)
            guard !Task.isCancelled else { return }
            guard let memberIds else {
                hadFailures = true
                continue
            }
            if memberIds.contains(where: { $0.lowercased() == contactId }) {
                groups.append(chat)
            }
        }
        if !hadFailures {
            loadedKey = key
        }
    }
}
