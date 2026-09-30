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
    func mentionRoster(projectedIdentities: [ConversationIdentityFfi] = []) -> [ComposerMentionCandidate] {
        guard let selectedChat,
            let members = groupMemberDetailsCache[selectedChat.id]
        else { return [] }
        // Profile resolution is observable even though the cache itself is intentionally not.
        // Reading the generation makes an open picker rebuild when a late kind:0 arrives.
        _ = peerProfileGeneration
        let stamp = contactNicknameStamp
        if projectedIdentities.isEmpty,
            let cached = mentionRosterCache[selectedChat.id]?.value(at: stamp)
        {
            return cached
        }

        let nicknames = activeContactNicknames
        let preparedNames = Dictionary(
            projectedIdentities.compactMap { identity -> (String, String)? in
                guard let name = PeerDisplayText.sanitize(identity.displayName) else { return nil }
                return (identity.accountIdHex, name)
            },
            uniquingKeysWith: { _, latest in latest }
        )
        let roster = members.filter { !$0.isSelf }.map { member in
            let resolved = peerProfileFFICache[member.memberIdHex]?.resolved
            return ComposerMentionCandidate(
                details: member,
                nickname: member.nickname(from: nicknames),
                projectedDisplayName: preparedNames[member.memberIdHex]
                    ?? MentionPublishedName.resolve(
                        profileDisplayName: resolved?.profileDisplayName,
                        profileName: resolved?.profileName,
                        rosterDisplayName: member.displayName,
                        directoryDisplayName: resolved?.directoryDisplayName
                    )
            )
        }
        if projectedIdentities.isEmpty {
            mentionRosterCache[selectedChat.id] = NicknameStamped(stamp: stamp, value: roster)
        }
        #if DEBUG
            mentionRosterBuildCount += 1
        #endif
        return roster
    }

    /// The candidates the picker should show for an active `@query`, capped and boundary-filtered.
    func mentionCandidates(
        matching query: String,
        projectedIdentities: [ConversationIdentityFfi] = []
    ) -> [ComposerMentionCandidate] {
        ComposerMentionQuery.filter(
            mentionRoster(projectedIdentities: projectedIdentities),
            matching: query
        )
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
        // Read the observed inputs before the memo, which is not observed: a chat-list row renders
        // from this, and one that last rendered from a memo hit would otherwise never learn that
        // the roster or a member's profile arrived.
        let members = groupMemberDetailsCache[groupIdHex] ?? []
        _ = peerProfileGeneration
        if let cached = mentionNamesCache[groupIdHex]?.value(at: stamp) { return cached }

        let names = Self.mentionNames(
            from: members,
            nicknames: activeContactNicknames,
            projectedNamesByAccountID: Dictionary(
                members.compactMap { member in
                    let resolved = peerProfileFFICache[member.memberIdHex]?.resolved
                    return MentionPublishedName.resolve(
                        profileDisplayName: resolved?.profileDisplayName,
                        profileName: resolved?.profileName,
                        rosterDisplayName: member.displayName,
                        directoryDisplayName: resolved?.directoryDisplayName
                    ).map { (member.memberIdHex, $0) }
                },
                uniquingKeysWith: { _, latest in latest }
            )
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
        nicknames: ContactNicknames,
        projectedNamesByAccountID: [String: String] = [:]
    ) -> MarkdownMentionNames {
        members.reduce(into: MarkdownMentionNames()) { map, member in
            guard !member.npub.isEmpty,
                let name = member.nickname(from: nicknames)
                    ?? PeerDisplayText.sanitize(projectedNamesByAccountID[member.memberIdHex])
                    ?? PeerDisplayText.sanitize(member.displayName)
            else { return }
            map[member.npub] = name
        }
    }
}
