//
//  WorkspaceState+Mentions.swift
//  whitenoise-mac
//
//  Composer @-mention support: the group-member roster the picker draws from, the filtered
//  candidate list for an active query, and the send-time rewrite of "@DisplayName" to the
//  member's stable "@npub…" so mentions travel as public keys, not display names.
//
//  Both projections here fold in the viewer's private nicknames, so a mention reads as the name
//  the viewer gave the person wherever it renders. The nickname never leaves the device: it is
//  applied on the way *out* of the wire format (npub → label) and stripped on the way back in
//  (label → npub), so the message a peer receives is byte-identical either way.
//

import Foundation
import MarmotKit

@MainActor
extension WorkspaceState {
    func mentionRoster() -> [ComposerMentionCandidate] {
        guard let selectedChat,
            let members = groupMemberDetailsCache[selectedChat.id]
        else { return [] }
        let stamp = contactNicknameStamp
        if let cached = mentionRosterCache[selectedChat.id]?.value(at: stamp) { return cached }

        let nicknames = activeContactNicknames
        let roster = members.filter { !$0.isSelf }.map { member in
            ComposerMentionCandidate(details: member, nickname: member.nickname(from: nicknames))
        }
        mentionRosterCache[selectedChat.id] = NicknameStamped(stamp: stamp, value: roster)
        #if DEBUG
            mentionRosterBuildCount += 1
        #endif
        return roster
    }

    /// The candidates the picker should show for an active `@query`, capped and boundary-filtered.
    func mentionCandidates(matching query: String) -> [ComposerMentionCandidate] {
        ComposerMentionQuery.filter(mentionRoster(), matching: query)
    }

    func ensureMentionRosterLoaded() {
        guard let selectedChat,
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

    /// npub → display name from the roster already in cache (no FFI), used by the transcript and
    /// chat-list previews to render "@npub…" mention tokens back as "@Display Name". Reads only
    /// the cache — never triggers a `groupDetails` lookup — so it is safe on the timeline hot path
    /// and cannot re-drive a failed/uncached group's lookup (#40). Empty until some other path
    /// (chat-list enrichment, the mention picker, sender-name fallback) has warmed the roster, in
    /// which case mentions keep the truncated-bech32 form.
    ///
    /// The memo is stamped with the nickname set it was built from, so a nickname write costs one
    /// stamp comparison here rather than an eager sweep over every group's projection.
    func cachedMentionNames(groupIdHex: String) -> MarkdownMentionNames {
        let stamp = contactNicknameStamp
        if let cached = mentionNamesCache[groupIdHex]?.value(at: stamp) { return cached }

        let names = Self.mentionNames(
            from: groupMemberDetailsCache[groupIdHex] ?? [],
            nicknames: activeContactNicknames
        )
        mentionNamesCache[groupIdHex] = NicknameStamped(stamp: stamp, value: names)
        #if DEBUG
            mentionNamesBuildCount += 1
        #endif
        return names
    }

    /// A private nickname outranks the published name here exactly as it does on a chat row or a
    /// sender label — a mention is the same person under the same label. It also *is* a name for
    /// a member who published none, who would otherwise render as truncated bech32.
    nonisolated static func mentionNames(
        from members: [GroupMemberDetailsFfi],
        nicknames: ContactNicknames
    ) -> MarkdownMentionNames {
        members.reduce(into: MarkdownMentionNames()) { map, member in
            guard !member.npub.isEmpty,
                let name = member.nickname(from: nicknames) ?? PeerDisplayText.sanitize(member.displayName)
            else { return }
            map[member.npub] = name
        }
    }
}
