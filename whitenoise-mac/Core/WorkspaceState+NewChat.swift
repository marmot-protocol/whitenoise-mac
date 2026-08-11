//
//  WorkspaceState+NewChat.swift
//  whitenoise-mac
//
//  NewChat behavior extracted from WorkspaceState.swift (no behavior change).
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
    @discardableResult
    func resolveNewChatQuery() async -> NewChatRecipient? {
        let query = newChatQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard client != nil else { return nil }
        guard !query.isEmpty else {
            invalidateNewChatLookup()
            newChatRecipient = nil
            lastError = L10n.string("Enter a NIP-05, npub, profile link, or public key.")
            return nil
        }

        lastError = nil
        let lookupGeneration = beginNewChatLookup()
        isResolvingNewChat = true
        defer {
            // Spinner ownership is keyed on the generation ALONE, independent of the stricter
            // generation+query guard used for committing results. Only a newer lookup or an
            // `invalidateNewChatLookup` (both bump the generation, and each sets the spinner
            // state itself) supersedes this one's ownership of `isResolvingNewChat`. Editing the
            // query mid-flight without resubmitting must NOT strand the spinner at `true`, so it
            // is deliberately not part of this check — see issue #255 (mirrors the #110 fix for
            // group-image search).
            if ownsNewChatLookup(generation: lookupGeneration) {
                isResolvingNewChat = false
            }
        }

        do {
            guard let recipient = try await resolveNewChatRecipient(for: query) else { return nil }
            guard isCurrentNewChatLookup(generation: lookupGeneration, query: query) else {
                return nil
            }
            newChatRecipient = recipient
            return recipient
        } catch {
            guard isCurrentNewChatLookup(generation: lookupGeneration, query: query) else {
                return nil
            }
            newChatRecipient = nil
            lastError = L10n.string("Enter a valid NIP-05, npub, profile link, or hex public key.")
            return nil
        }
    }

    /// Resolve a profile/member reference without reading from or writing to the live New Chat
    /// input fields. Callers that own the composer state can apply their own freshness checks.
    func resolveNewChatRecipient(for query: String) async throws -> NewChatRecipient? {
        guard let client else { return nil }
        let memberRef = try await memberRefCandidate(for: query)
        let member = try await FFIExecutor.run {
            try client.normalizeMemberRef(memberRef: memberRef)
        }
        // Seed relays alone miss a recipient published only to their own NIP-65 write
        // relays, so use the same union every peer refresh uses.
        let relays = await peerProfileLookupRelaysForActiveAccount()
        try? await client.refreshProfile(accountIdHex: member.accountIdHex, relays: relays)
        peerProfileFFICache[member.accountIdHex] = nil
        let resolved = try? await FFIExecutor.run { () -> ResolvedPeerFFI in
            let profile = try? client.userProfile(accountIdHex: member.accountIdHex)
            return ResolvedPeerFFI(
                profileDisplayName: profile?.displayName,
                profileName: profile?.name,
                profilePicture: profile?.picture,
                directoryDisplayName: client.displayName(accountIdHex: member.accountIdHex)
            )
        }
        let published = firstNonBlank([
            PeerDisplayText.sanitize(resolved?.profileDisplayName),
            PeerDisplayText.sanitize(resolved?.profileName),
            PeerDisplayText.sanitize(resolved?.directoryDisplayName),
        ])
        let nickname = activeContactNicknames.nickname(forContactAccountIdHex: member.accountIdHex)
        return NewChatRecipient(
            sourceQuery: query,
            memberRef: member.memberRef,
            accountIdHex: member.accountIdHex,
            npub: member.npub,
            displayName: nickname ?? published,
            publishedDisplayName: Self.publishedContactName(published, overriddenBy: nickname),
            pictureURL: resolved?.profilePicture
        )
    }

    func resolveNewChatQueryIfReady() async {
        let query = newChatQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            invalidateNewChatLookup()
            newChatRecipient = nil
            lastError = nil
            return
        }
        guard looksLikeMemberRef(query) else {
            invalidateNewChatLookup()
            newChatRecipient = nil
            return
        }
        guard resolvedNewChatRecipient == nil else { return }

        await resolveNewChatQuery()
    }

    /// Resolve the current query (if needed) and move that recipient into the
    /// confirmed members list, clearing the input so the next pubkey can be added.
    @discardableResult
    func addCurrentNewChatRecipient() async -> Bool {
        let recipient: NewChatRecipient?
        if let resolvedNewChatRecipient {
            recipient = resolvedNewChatRecipient
        } else {
            recipient = await resolveNewChatQuery()
        }
        guard let recipient else { return false }

        let didAppend = appendNewChatRecipient(recipient)
        invalidateNewChatLookup()
        newChatQuery = ""
        newChatRecipient = nil
        lastError = nil
        // `false` when the pubkey was already in the list (deduped), so callers
        // can tell "nothing new added" from a genuine failure to resolve.
        return didAppend
    }

    @discardableResult
    func appendNewChatRecipient(_ recipient: NewChatRecipient) -> Bool {
        guard !newChatRecipients.contains(where: { $0.accountIdHex == recipient.accountIdHex }) else {
            return false
        }
        newChatRecipients.append(recipient)
        return true
    }

    func removeNewChatRecipient(_ recipient: NewChatRecipient) {
        newChatRecipients.removeAll { $0.accountIdHex == recipient.accountIdHex }
    }

    func createNewChat() async {
        guard let client, let activeAccount, !isCreatingChat else { return }

        // Claim the in-flight flag before the first await (the pending-query
        // resolve below). Otherwise two rapid submits both pass the `!isCreatingChat`
        // guard while suspended and each reach `createGroup`, creating duplicate chats.
        lastError = nil
        isCreatingChat = true
        defer { isCreatingChat = false }

        // Capture the creating account on entry so a mid-await A→B account switch (e.g. via
        // a notification tap while `createGroup`/`reloadChats` are suspended) cannot graft
        // account A's freshly created group onto account B's chat list or select/load it
        // under B's context. The group's FFI data stays partitioned by account ref; this
        // only guards the workspace UI state. See whitenoise-mac#229.
        let accountId = activeAccount.id

        // Gather every member: the confirmed list plus whatever is still sitting
        // in the input, so a pubkey typed but not yet added via return/+ is never
        // silently dropped. If the pending query already resolved, fold it in; if
        // there is non-empty text that has not resolved yet (e.g. the debounce
        // hadn't fired), resolve it now and *block* creation when it can't, rather
        // than quietly leaving that recipient out. Dedup by account so the same
        // person can't be invited twice.
        var recipients = newChatRecipients
        if let resolvedNewChatRecipient {
            if !recipients.contains(where: { $0.accountIdHex == resolvedNewChatRecipient.accountIdHex }) {
                recipients.append(resolvedNewChatRecipient)
            }
        } else if !newChatQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            guard let resolved = await resolveNewChatQuery() else { return }
            if !recipients.contains(where: { $0.accountIdHex == resolved.accountIdHex }) {
                recipients.append(resolved)
            }
        }
        guard let primary = recipients.first else { return }
        let isDirect = recipients.count == 1

        do {
            if isDirect,
                let existing = await existingDirectChat(
                    with: primary.accountIdHex,
                    account: activeAccount,
                    client: client
                )
            {
                if existing.isArchived {
                    guard await setChatArchived(existing.chat, archived: false) else { return }
                }
                guard activeAccountId == accountId else { return }
                selection = .chat(existing.chat.id)
                closeNewChatComposer()
                beginTimelineInitialLoadIfNeeded(groupIdHex: existing.chat.id)
                await loadMessages(groupIdHex: existing.chat.id)
                return
            }

            let trimmedName = newChatName.trimmingCharacters(in: .whitespacesAndNewlines)
            let trimmedDescription = newChatDescription.trimmingCharacters(in: .whitespacesAndNewlines)
            let fallbackTitle =
                isDirect
                ? primary.title
                : recipients.map(\.title).joined(separator: ", ")
            let groupName = trimmedName.isEmpty ? fallbackTitle : trimmedName
            let groupIdHex = try await client.createGroup(
                accountRef: activeAccount.accountRef,
                name: groupName,
                memberRefs: recipients.map(\.memberRef),
                description: trimmedDescription.isEmpty ? nil : trimmedDescription
            )
            await reloadChats(forceFreshSnapshot: true)
            guard activeAccountId == accountId else { return }
            insertCreatedChatIfNeeded(
                groupIdHex: groupIdHex,
                title: groupName,
                avatarSeed: primary.accountIdHex,
                pictureURL: isDirect ? primary.pictureURL : nil,
                isDirect: isDirect
            )
            selection = .chat(groupIdHex)
            closeNewChatComposer()
            beginTimelineInitialLoadIfNeeded(groupIdHex: groupIdHex)
            await loadMessages(groupIdHex: groupIdHex)
        } catch {
            lastError = error.localizedDescription
        }
    }

    private func existingDirectChat(
        with targetAccountIdHex: String,
        account: AccountItem,
        client: any MarmotRuntime
    ) async -> (chat: ChatItem, isArchived: Bool)? {
        let target = targetAccountIdHex.lowercased()
        let expectedMembers = Set([account.accountIdHex.lowercased(), target])
        let candidates = activeChats.map { ($0, false) } + archivedChats.map { ($0, true) }

        for (chat, isArchived) in candidates where chat.isDirect {
            guard !Task.isCancelled else { return nil }
            guard
                let members = await cachedGroupMembers(
                    groupIdHex: chat.id,
                    account: account,
                    client: client
                )
            else { continue }
            let memberIds = Set(members.map { $0.memberIdHex.lowercased() })
            if memberIds == expectedMembers {
                return (chat, isArchived)
            }
        }
        return nil
    }

    var hasInProgressNewChatComposition: Bool {
        !newChatRecipients.isEmpty
            || !newChatName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !newChatDescription.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !newChatQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    func resetNewChatComposer() {
        invalidateNewChatLookup()
        invalidateUserDiscovery()
        composePane = .newChat
        newChatQuery = ""
        newChatName = ""
        newChatDescription = ""
        newChatRecipient = nil
        newChatRecipients = []
        groupDraftRetentionSecs = 0
        creatingDirectChatIdHex = nil
    }

    /// Drops the active account's compose directory and invalidates any refresh that is
    /// still fetching group rosters, preventing it from restoring contacts after teardown.
    /// Also releases any in-flight people search: it belongs to the account being torn down,
    /// and its relay traversal must not outlive it.
    func resetComposeContacts() {
        composeContacts = []
        isLoadingComposeContacts = false
        composeContactsGeneration &+= 1
        invalidateUserDiscovery()
    }

    func beginNewChatLookup() -> UInt64 {
        newChatLookupGeneration &+= 1
        return newChatLookupGeneration
    }

    func invalidateNewChatLookup() {
        newChatLookupGeneration &+= 1
        isResolvingNewChat = false
    }

    /// True while `generation` still owns the new-chat lookup spinner — i.e. no newer
    /// `beginNewChatLookup` or `invalidateNewChatLookup` has bumped the generation. This is
    /// intentionally looser than `isCurrentNewChatLookup`: it does NOT require the live query to
    /// match, because spinner ownership must transfer cleanly even when the user edits the query
    /// mid-flight without resubmitting (otherwise the spinner would stay stuck `true` — issue #255).
    func ownsNewChatLookup(generation: UInt64) -> Bool {
        newChatLookupGeneration == generation
    }

    /// True only if `generation` is still the latest new-chat lookup and the live (trimmed) query
    /// still equals the one this lookup was issued for. Either a newer lookup or an edited query
    /// invalidates the in-flight result so it cannot overwrite `newChatRecipient` / `lastError`.
    func isCurrentNewChatLookup(generation: UInt64, query: String) -> Bool {
        ownsNewChatLookup(generation: generation)
            && newChatQuery.trimmingCharacters(in: .whitespacesAndNewlines) == query
    }

    func insertCreatedChatIfNeeded(
        groupIdHex: String,
        title: String,
        avatarSeed: String,
        pictureURL: String?,
        isDirect: Bool = true
    ) {
        guard let activeAccountId else { return }
        guard chatItem(accountId: activeAccountId, chatId: groupIdHex) == nil else { return }

        let chat = ChatItem(
            id: groupIdHex,
            title: title,
            subtitle: isDirect ? L10n.string("Direct message") : L10n.string("Group chat"),
            preview: "",
            updatedAt: nil,
            avatarSeed: avatarSeed,
            pictureURL: pictureURL,
            unreadCount: 0,
            isDirect: isDirect
        )
        upsertChat(chat, forAccountId: activeAccountId)
    }

    func looksLikeMemberRef(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if NIP05Identifier(trimmed) != nil {
            return true
        }
        if MarkdownLinkPolicy.isProfileReferenceInput(trimmed) {
            return true
        }
        if MarmotProfileLink.hasProfileLinkPrefix(trimmed) {
            return true
        }
        return trimmed.count == 64 && trimmed.allSatisfy(\.isHexDigit)
    }

    func memberRefCandidate(for query: String) async throws -> String {
        // A query carrying a nostr marker must never resolve as NIP-05 — an embedded `@domain`
        // would fire a request at that host before the authoritative FFI parse runs.
        if MarkdownLinkPolicy.containsNostrReferenceMarker(query) {
            return query
        }
        if NIP05Identifier(query) != nil {
            return try await nip05Resolver.accountReference(for: query)
        }
        return query
    }

    // MARK: - Compose flow

    /// Rebuild the compose-flow contact directory. There is no contact-enumeration FFI, so
    /// candidates come from what the workspace already loaded: direct-chat peers (instant)
    /// and the rosters of the most recent groups, fetched through the per-group member cache
    /// and merged in progressively.
    func refreshComposeContacts() async {
        guard let client, let activeAccount else { return }
        composeContactsGeneration &+= 1
        let generation = composeContactsGeneration
        let accountId = activeAccount.id
        let selfHex = activeAccount.accountIdHex
        let nicknames = activeContactNicknames

        var byHex: [String: ComposeContact] = [:]
        let chats = (chatsByAccount[accountId] ?? []) + (archivedChatsByAccount[accountId] ?? [])
        for chat in chats where chat.isDirect {
            let hex = chat.avatarSeed
            guard hex != selfHex, hex.count == 64 else { continue }
            let existing = byHex[hex]
            byHex[hex] = ComposeContact(
                accountIdHex: hex,
                npub: existing?.npub ?? "",
                displayName: chat.title,
                publishedDisplayName: chat.publishedTitle,
                pictureURL: chat.pictureURL ?? existing?.pictureURL,
                lastActivity: latestDate(existing?.lastActivity, chat.updatedAt)
            )
        }
        composeContacts = sortedComposeContacts(byHex)

        // Follows are the third source. The list is read up front but merged last, so that
        // a chat or roster entry — which carries a display name, a picture and a real
        // `lastActivity` — always wins over the bare hex a follow contributes.
        await refreshFollowedAccounts()
        guard composeContactsGeneration == generation, activeAccountId == accountId else { return }

        let groups = chats.filter { !$0.isDirect && !$0.pendingConfirmation }
            .sorted { ($0.updatedAt ?? .distantPast) > ($1.updatedAt ?? .distantPast) }
            .prefix(40)
        guard !groups.isEmpty else {
            // A superseded refresh may no longer clear the spinner it set (the generation
            // bump above orphaned its defer), so this early return must clear it.
            isLoadingComposeContacts = false
            await mergeFollowedComposeContacts(
                into: byHex,
                generation: generation,
                accountId: accountId,
                selfHex: selfHex,
                nicknames: nicknames,
                client: client
            )
            return
        }
        isLoadingComposeContacts = true
        defer {
            if composeContactsGeneration == generation {
                isLoadingComposeContacts = false
            }
        }
        for group in groups {
            guard composeContactsGeneration == generation, activeAccountId == accountId else { return }
            guard
                let members = await cachedGroupMembers(
                    groupIdHex: group.id,
                    account: activeAccount,
                    client: client
                )
            else { continue }
            guard composeContactsGeneration == generation, activeAccountId == accountId else { return }
            for member in members where !member.isSelf {
                let hex = member.memberIdHex
                guard hex != selfHex else { continue }
                let existing = byHex[hex]
                var npub = member.npub
                if let existing, !existing.npub.isEmpty {
                    npub = existing.npub
                }
                let published = existing?.publishedDisplayName ?? existing?.displayName ?? member.displayName
                let nickname = nicknames.nickname(forContactAccountIdHex: hex)
                byHex[hex] = ComposeContact(
                    accountIdHex: hex,
                    npub: npub,
                    displayName: nickname ?? published,
                    publishedDisplayName: Self.publishedContactName(published, overriddenBy: nickname),
                    pictureURL: existing?.pictureURL,
                    lastActivity: latestDate(existing?.lastActivity, group.updatedAt)
                )
            }
            composeContacts = sortedComposeContacts(byHex)
        }
        await mergeFollowedComposeContacts(
            into: byHex,
            generation: generation,
            accountId: accountId,
            selfHex: selfHex,
            nicknames: nicknames,
            client: client
        )
    }

    /// Fold the accounts this identity follows into a compose refresh, keeping only the keys
    /// no chat or group roster already supplied. Someone you follow but have never messaged
    /// is otherwise absent from this list entirely, which makes a first DM a paste-an-npub
    /// exercise. They carry no `lastActivity`, so `sortedComposeContacts` files them below
    /// every real conversation.
    private func mergeFollowedComposeContacts(
        into byHex: [String: ComposeContact],
        generation: UInt64,
        accountId: String,
        selfHex: String,
        nicknames: ContactNicknames,
        client: any MarmotRuntime
    ) async {
        let selfKey = selfHex.lowercased()
        let missing =
            followedAccountIdsHex
            .filter { $0.count == 64 && $0 != selfKey && byHex[$0] == nil && !isLocalAccount(accountIdHex: $0) }
            .sorted()
        guard !missing.isEmpty else { return }

        // `displayName` and `npub` are cached, network-free lookups, so the whole batch
        // fits in one hop off the main thread.
        let resolved =
            (try? await FFIExecutor.run {
                missing.map { hex in
                    ResolvedFollowContact(
                        accountIdHex: hex,
                        displayName: client.displayName(accountIdHex: hex),
                        npub: client.npub(accountIdHex: hex)
                    )
                }
            }) ?? missing.map { ResolvedFollowContact(accountIdHex: $0, displayName: nil, npub: nil) }
        guard composeContactsGeneration == generation, activeAccountId == accountId else { return }

        var byHex = byHex
        for contact in resolved where byHex[contact.accountIdHex] == nil {
            let published = PeerDisplayText.sanitize(contact.displayName)
            let nickname = nicknames.nickname(forContactAccountIdHex: contact.accountIdHex)
            byHex[contact.accountIdHex] = ComposeContact(
                accountIdHex: contact.accountIdHex,
                npub: contact.npub ?? "",
                displayName: nickname ?? published,
                publishedDisplayName: Self.publishedContactName(published, overriddenBy: nickname),
                pictureURL: nil,
                lastActivity: nil
            )
        }
        composeContacts = sortedComposeContacts(byHex)
    }

    func filteredComposeContacts(matching query: String) -> [ComposeContact] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return composeContacts }
        var prefixMatches: [ComposeContact] = []
        var containedMatches: [ComposeContact] = []
        for contact in composeContacts {
            let isPrefixMatch = contact.searchableNames.contains { name in
                guard let range = name.range(of: needle, options: [.caseInsensitive, .diacriticInsensitive])
                else { return false }
                return range.lowerBound == name.startIndex
            }
            if isPrefixMatch {
                prefixMatches.append(contact)
                continue
            }
            let isContainedMatch = contact.searchableNames.contains { name in
                name.range(of: needle, options: [.caseInsensitive, .diacriticInsensitive]) != nil
            }
            if isContainedMatch {
                containedMatches.append(contact)
            }
        }
        return prefixMatches + containedMatches
    }

    func existingDirectChat(peerAccountIdHex: String) -> ChatItem? {
        guard let activeAccountId else { return nil }
        let match: (ChatItem) -> Bool = { $0.isDirect && $0.avatarSeed == peerAccountIdHex }
        if let chat = (chatsByAccount[activeAccountId] ?? []).first(where: match) {
            return chat
        }
        return (archivedChatsByAccount[activeAccountId] ?? []).first(where: match)
    }

    /// Open the existing direct chat with this person, or create one and select it. Direct
    /// chats are created with an empty group name; the chat list titles them from the peer
    /// profile.
    func startDirectChat(with recipient: NewChatRecipient) async {
        if let existing = existingDirectChat(peerAccountIdHex: recipient.accountIdHex) {
            selectChat(existing)
            return
        }
        guard let client, let activeAccount, !isCreatingChat else { return }
        lastError = nil
        isCreatingChat = true
        creatingDirectChatIdHex = recipient.accountIdHex
        defer {
            isCreatingChat = false
            creatingDirectChatIdHex = nil
        }
        // Capture the creating account so a mid-await account switch cannot graft the new
        // chat onto another account's UI state (see whitenoise-mac#229).
        let accountId = activeAccount.id
        do {
            let memberRef = recipient.memberRef.isEmpty ? recipient.accountIdHex : recipient.memberRef
            let groupIdHex = try await client.createGroup(
                accountRef: activeAccount.accountRef,
                name: "",
                memberRefs: [memberRef],
                description: nil
            )
            await reloadChats(forceFreshSnapshot: true)
            guard activeAccountId == accountId else { return }
            insertCreatedChatIfNeeded(
                groupIdHex: groupIdHex,
                title: recipient.title,
                avatarSeed: recipient.accountIdHex,
                pictureURL: recipient.pictureURL,
                isDirect: true
            )
            selection = .chat(groupIdHex)
            closeNewChatComposer()
            beginTimelineInitialLoadIfNeeded(groupIdHex: groupIdHex)
            await loadMessages(groupIdHex: groupIdHex)
        } catch {
            lastError = error.localizedDescription
        }
    }

    /// Create the group from the compose-flow draft (chosen members, required name, timer).
    /// A timer failure keeps the group and surfaces on the background banner.
    func createGroupFromDraft() async {
        guard let client, let activeAccount, !isCreatingChat else { return }
        let name = newChatName.trimmingCharacters(in: .whitespacesAndNewlines)
        let members = newChatRecipients
        guard !name.isEmpty, !members.isEmpty else { return }
        lastError = nil
        isCreatingChat = true
        defer { isCreatingChat = false }
        let accountId = activeAccount.id
        let retentionSecs = groupDraftRetentionSecs
        do {
            let groupIdHex = try await client.createGroup(
                accountRef: activeAccount.accountRef,
                name: name,
                memberRefs: members.map { $0.memberRef.isEmpty ? $0.accountIdHex : $0.memberRef },
                description: nil
            )
            if retentionSecs > 0 {
                do {
                    try await client.updateMessageRetention(
                        accountRef: activeAccount.accountRef,
                        groupIdHex: groupIdHex,
                        disappearingMessageSecs: retentionSecs
                    )
                } catch {
                    if activeAccountId == accountId {
                        backgroundStatus = L10n.string(
                            "The group was created, but disappearing messages could not be turned on.")
                    }
                }
            }
            await reloadChats(forceFreshSnapshot: true)
            guard activeAccountId == accountId else { return }
            insertCreatedChatIfNeeded(
                groupIdHex: groupIdHex,
                title: name,
                avatarSeed: groupIdHex,
                pictureURL: nil,
                isDirect: false
            )
            selection = .chat(groupIdHex)
            closeNewChatComposer()
            beginTimelineInitialLoadIfNeeded(groupIdHex: groupIdHex)
            await loadMessages(groupIdHex: groupIdHex)
        } catch {
            lastError = error.localizedDescription
        }
    }

    func toggleComposeMember(_ recipient: NewChatRecipient) {
        if newChatRecipients.contains(where: { $0.accountIdHex == recipient.accountIdHex }) {
            removeNewChatRecipient(recipient)
        } else {
            appendNewChatRecipient(recipient)
            clearComposeSearch()
        }
    }

    func sortedComposeContacts(_ byHex: [String: ComposeContact]) -> [ComposeContact] {
        byHex.values.sorted { lhs, rhs in
            switch (lhs.lastActivity, rhs.lastActivity) {
            case (let left?, let right?) where left != right:
                return left > right
            case (.some, nil):
                return true
            case (nil, .some):
                return false
            default:
                return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
            }
        }
    }
}

/// One followed account with whatever the local directory already knows about it. Carried
/// back across the off-main hop that batches those cached lookups.
private struct ResolvedFollowContact: Sendable {
    let accountIdHex: String
    let displayName: String?
    let npub: String?
}

private func latestDate(_ first: Date?, _ second: Date?) -> Date? {
    switch (first, second) {
    case (let first?, let second?):
        return max(first, second)
    case (let first?, nil):
        return first
    case (nil, let second?):
        return second
    default:
        return nil
    }
}
