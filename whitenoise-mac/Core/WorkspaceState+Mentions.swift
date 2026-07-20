//
//  WorkspaceState+Mentions.swift
//  whitenoise-mac
//
//  Composer @-mention support: the group-member roster the picker draws from, the filtered
//  candidate list for an active query, and the send-time rewrite of "@DisplayName" to the
//  member's stable "@npub…" so mentions travel as public keys, not display names.
//

import Foundation
import MarmotKit

@MainActor
extension WorkspaceState {
    /// Mentionable members of the selected conversation, excluding the local account. Empty for
    /// direct chats, where mentioning the sole peer carries no meaning.
    func mentionRoster() -> [ComposerMentionCandidate] {
        guard let selectedChat, !selectedChat.isDirect,
            let members = groupMemberDetailsCache[selectedChat.id]
        else { return [] }
        if let cached = mentionRosterCache[selectedChat.id] { return cached }

        let roster = members.filter { !$0.isSelf }.map(ComposerMentionCandidate.init(details:))
        mentionRosterCache[selectedChat.id] = roster
        #if DEBUG
            mentionRosterBuildCount += 1
        #endif
        return roster
    }

    /// The candidates the picker should show for an active `@query`, capped and boundary-filtered.
    func mentionCandidates(matching query: String) -> [ComposerMentionCandidate] {
        ComposerMentionQuery.filter(mentionRoster(), matching: query)
    }

    /// Pull the member roster into cache the first time a mention query opens in a group, so the
    /// picker can populate. No-op for direct chats or once the cache is warm.
    func ensureMentionRosterLoaded() {
        guard let selectedChat, !selectedChat.isDirect,
            groupMemberDetailsCache[selectedChat.id] == nil,
            let client, let activeAccount
        else { return }
        Task { _ = await cachedGroupMembers(groupIdHex: selectedChat.id, account: activeAccount, client: client) }
    }

    /// Rewrite display-name mentions to canonical npubs before the text leaves the composer.
    func canonicalizeMentions(in text: String, selections: [ComposerMentionSelection] = []) -> String {
        let roster = mentionRoster()
        guard !roster.isEmpty else { return text }
        return ComposerMentionCanonicalizer.canonicalize(text, selections: selections, candidates: roster)
    }

    /// npub → sanitized display name from the roster already in cache (no FFI), used by the
    /// transcript and chat-list previews to render "@npub…" mention tokens back as
    /// "@Display Name". Reads only the cache — never triggers a `groupDetails` lookup — so it is
    /// safe on the timeline hot path and cannot re-drive a failed/uncached group's lookup (#40).
    /// Empty until some other path (chat-list enrichment, the mention picker, sender-name
    /// fallback) has warmed the roster, in which case mentions keep the truncated-bech32 form.
    func cachedMentionNames(groupIdHex: String) -> MarkdownMentionNames {
        Self.mentionNames(from: groupMemberDetailsCache[groupIdHex] ?? [])
    }

    static func mentionNames(from members: [GroupMemberDetailsFfi]) -> MarkdownMentionNames {
        members.reduce(into: MarkdownMentionNames()) { map, member in
            guard !member.npub.isEmpty, let name = PeerDisplayText.sanitize(member.displayName) else { return }
            map[member.npub] = name
        }
    }
}
