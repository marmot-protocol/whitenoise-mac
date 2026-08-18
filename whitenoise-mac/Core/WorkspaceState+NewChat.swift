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
        // An unnamed refusal belongs to the roster it was raised on. Editing that roster is exactly
        // what the notice asks for, so the claim goes with the edit rather than following a draft
        // that no longer contains whoever it was about.
        hasUnnamedGroupDraftRefusal = false
        return true
    }

    func removeNewChatRecipient(_ recipient: NewChatRecipient) {
        newChatRecipients.removeAll { $0.accountIdHex == recipient.accountIdHex }
        hasUnnamedGroupDraftRefusal = false
    }

    func createNewChat() async {
        guard let client, let activeAccount, !isCreatingChat else { return }

        // Claim the in-flight flag before the first await (the pending-query
        // resolve below). Otherwise two rapid submits both pass the `!isCreatingChat`
        // guard while suspended and each reach `createGroup`, creating duplicate chats.
        lastError = nil
        startChatInvitePrompt = nil
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
            guard activeAccountId == accountId else { return }
            applyChatCreationFailure(error, recipients: recipients, surface: isDirect ? .directChat : .groupDraft)
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
        unreachableDraftMemberIdHexes = []
        hasUnnamedGroupDraftRefusal = false
        startChatInvitePrompt = nil
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
        startChatInvitePrompt = nil
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
            guard activeAccountId == accountId else { return }
            applyChatCreationFailure(error, recipients: [recipient], surface: .directChat)
        }
    }

    /// The invite prompt to render, or `nil` when it belongs to a query the user has since edited.
    ///
    /// Derived rather than cleared on change, because the only hook a clear could use — the
    /// debounced `resolveNewChatQueryIfReady()` — cancels itself on every keystroke and so does not
    /// run until typing settles, which is exactly when a stale prompt is most visible. Comparing
    /// against the live query costs nothing and cannot be forgotten by a future code path. A
    /// contact-row failure records the empty query it was raised under, so it hides the moment the
    /// user starts typing and returns if they clear the field again — the person is still not
    /// reachable, so re-showing it is honest.
    var visibleStartChatInvitePrompt: StartChatInvitePrompt? {
        guard let startChatInvitePrompt,
            startChatInvitePrompt.query == newChatQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        else { return nil }
        return startChatInvitePrompt
    }

    /// Members of the group draft the core has not (yet) refused. The `unreachable` split is
    /// derived from the live roster rather than stored alongside it, so removing someone from
    /// the draft drops their mark with them and no stale entry can outlive the recipient. Marks
    /// survive a remove-then-re-add within the same draft, which is the wanted behaviour: the
    /// core has not changed its mind, and the panel says so without another failed attempt.
    var reachableDraftMembers: [NewChatRecipient] {
        newChatRecipients.filter { !unreachableDraftMemberIdHexes.contains($0.accountIdHex.lowercased()) }
    }

    /// Draft members the core named as having no usable KeyPackage. These are shown apart in the
    /// name-group panel and left out of the next create attempt.
    var unreachableDraftMembers: [NewChatRecipient] {
        newChatRecipients.filter { unreachableDraftMemberIdHexes.contains($0.accountIdHex.lowercased()) }
    }

    /// Create the group from the compose-flow draft (chosen members, required name, timer).
    /// A timer failure keeps the group and surfaces on the background banner.
    func createGroupFromDraft() async {
        guard let client, let activeAccount, !isCreatingChat else { return }
        let name = newChatName.trimmingCharacters(in: .whitespacesAndNewlines)
        // Members the core has already refused are left out of the attempt. This is not a silent
        // drop: the panel lists them under "Not on White Noise yet" and the Create button names
        // the exclusion, so the composition being submitted is the one the user is looking at.
        guard !name.isEmpty, !reachableDraftMembers.isEmpty else { return }
        lastError = nil
        startChatInvitePrompt = nil
        // Whatever this press learns replaces what the last one did, marks included: an
        // unattributed refusal that has since been pinned on a member must not keep claiming
        // there is someone else on top of the ones the panel now names.
        hasUnnamedGroupDraftRefusal = false
        isCreatingChat = true
        defer { isCreatingChat = false }
        let accountId = activeAccount.id
        let retentionSecs = groupDraftRetentionSecs
        guard
            let groupIdHex = await createGroupResolvingEveryRefusal(
                name: name,
                client: client,
                activeAccount: activeAccount,
                accountId: accountId
            )
        else { return }

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
    }

    /// Create the group, but not before every member the core will refuse is known.
    ///
    /// `create_group` resolves the roster in list order and reports only the *first* member with no
    /// usable KeyPackage, so one attempt per refusal is the only way to learn the whole set — there
    /// is no FFI that asks whether a given person has a published KeyPackage. Spending those
    /// attempts one press at a time revealed a draft's unreachable members one by one, and the last
    /// press — the one whose roster the core finally accepted — created the group before the user
    /// had ever seen the full list.
    ///
    /// So this spends them in a single press, and pins the member the core just refused to the end
    /// of every follow-up attempt. That member is known-unreachable, which makes each follow-up
    /// guaranteed to fail: nothing can be created while members are still being checked. And
    /// because the core reports the first refusal *in list order*, an error naming someone else is
    /// a new refusal, while an error naming the pinned member means everyone ahead of them
    /// resolved. Discovery therefore ends on a refusal with nothing created, the panel lists every
    /// excluded member at once, and the Create the user presses next submits the composition they
    /// are looking at.
    ///
    /// Should the core ever name an arbitrary failing member rather than the first, this degrades
    /// to the old behaviour — fewer refusals learned per press — and still never creates a group
    /// mid-discovery, because a pinned refusal keeps every follow-up attempt failing regardless of
    /// which member the error names.
    ///
    /// Returns the new group id, or `nil` when nothing was created: either members were refused
    /// (they are marked, and the panel explains) or the failure was one `applyChatCreationFailure`
    /// routes to the error line.
    private func createGroupResolvingEveryRefusal(
        name: String,
        client: any MarmotRuntime,
        activeAccount: AccountItem,
        accountId: String
    ) async -> String? {
        var candidates = reachableDraftMembers
        // The most recently refused member, carried into the next attempt to keep it failing.
        var pinnedRefusal: NewChatRecipient?
        // Refusals are collected here and published in one go on the way out. Marking them as they
        // arrive let the panel render each partial answer — one name, then two, then three — which
        // reads as the panel changing its mind about who can't be added. The press has one answer,
        // so it says it once.
        var discovered: Set<String> = []
        defer { unreachableDraftMemberIdHexes.formUnion(discovered) }
        while !candidates.isEmpty {
            let attempt = candidates + (pinnedRefusal.map { [$0] } ?? [])
            do {
                let groupIdHex = try await client.createGroup(
                    accountRef: activeAccount.accountRef,
                    name: name,
                    memberRefs: attempt.map { $0.memberRef.isEmpty ? $0.accountIdHex : $0.memberRef },
                    description: nil
                )
                // Only the first attempt is expected to reach here. A later one can succeed only if
                // the pinned member published a KeyPackage between two attempts, and then they are
                // in the group the core just created — which is the roster the user asked for, and
                // the mark taken moments earlier goes out with the rest of the draft when the
                // caller closes the composer.
                return groupIdHex
            } catch {
                guard activeAccountId == accountId else { return nil }
                let failure = ChatCreationFailure(error)
                let refused: NewChatRecipient?
                if case .notOnWhiteNoise(let account) = failure {
                    refused = ChatCreationFailure.refusedRecipient(named: account, among: attempt)
                } else {
                    refused = nil
                }
                guard let refused else {
                    // Nobody to pin this on. Either the refusal named no account — a KeyPackage that
                    // exists but can't be used — or the member stopping the create fails some other
                    // way entirely, which reads as a group-wide error while it is really one person.
                    // Both are answerable by asking about the members one at a time.
                    switch await attributeRefusalMemberByMember(
                        among: candidates,
                        pin: pinnedRefusal ?? unreachableDraftMembers.first,
                        name: name,
                        client: client,
                        activeAccount: activeAccount,
                        accountId: accountId
                    ) {
                    case .created(let groupIdHex):
                        return groupIdHex
                    case .attributed(let marks):
                        discovered.formUnion(marks)
                        return nil
                    case .unattributed:
                        // Nothing owned up to it, so this is reported as what it looked like: a
                        // refusal the panel can't name, or an error that belongs on the error line.
                        if case .notOnWhiteNoise = failure {
                            hasUnnamedGroupDraftRefusal = true
                        } else {
                            applyChatCreationFailure(error, recipients: attempt, surface: .groupDraft)
                        }
                        return nil
                    }
                }
                // The refusal names someone who is not up for checking — the pinned member, whose
                // failure is the signal that everyone ahead of them resolved. There is nothing left
                // to learn and nothing to create until the user presses Create again.
                guard
                    let index = candidates.firstIndex(where: {
                        $0.accountIdHex.caseInsensitiveCompare(refused.accountIdHex) == .orderedSame
                    })
                else { return nil }
                discovered.insert(refused.accountIdHex.lowercased())
                candidates.remove(at: index)
                pinnedRefusal = refused
                // Everyone ahead of a refusal resolved, so only the members behind it are still
                // unknown. A refusal at the end of the roster leaves none — the common
                // one-unreachable-member draft therefore costs exactly the one attempt it always
                // did, and no follow-up is spent confirming what the same error already said.
                guard index < candidates.count else { return nil }
            }
        }
        return nil
    }

    /// What a member-by-member pass concluded about a failure no member could be pinned on.
    enum RefusalAttribution {
        /// The pin resolved between attempts, so the create the probe asked for went through.
        case created(String)
        /// At least one member was named. Carries their account ids for the caller to publish with
        /// the rest of the press's findings.
        case attributed(Set<String>)
        /// Nobody owned up to it. The caller reports the failure as it arrived.
        case unattributed
    }

    /// Work out which member a failure belongs to, by asking about one at a time.
    ///
    /// `MissingKeyPackage` carries the account it is about, but a KeyPackage that exists and cannot
    /// be used (`InvalidKeyPackageEvent`, `InvalidIdentity`) names no one — and the core still stops
    /// the whole create over it. Left there, the panel showed the members it *had* named alongside a
    /// red line about an unnamed someone, which is two different accounts of the same draft.
    ///
    /// Failures of other kinds arrive here too. Member resolution can fail for reasons that look
    /// nothing like a missing KeyPackage — a person with no relay list to fetch one from, say — and
    /// those stopped the whole search, leaving the panel naming the one member it had learned about
    /// before the roster ran into somebody who fails differently.
    ///
    /// `pin` is a member already known to be refused, so `[candidate, pin]` cannot create anything:
    /// an error naming the pin clears that candidate, and any other refusal — named or not — is
    /// about the candidate, because the core reports the first failure in list order and the
    /// candidate goes first. Without a pin (an unnamed refusal on the first attempt of the first
    /// press) there is no safe way to ask, so the notice says as much and names no one.
    ///
    /// The pass is exhaustive rather than a bisection: every member is checked, so it also settles
    /// the members behind the one at fault and the next press has nothing left to discover. What it
    /// will not do is convict on its own say-so — see the corroboration rule at the end.
    private func attributeRefusalMemberByMember(
        among candidates: [NewChatRecipient],
        pin: NewChatRecipient?,
        name: String,
        client: any MarmotRuntime,
        activeAccount: AccountItem,
        accountId: String
    ) async -> RefusalAttribution {
        guard let pin else { return .unattributed }
        // Collected rather than published as they are found: the caller reports this press's
        // findings in one update, so the panel never counts them out loud.
        var marks: Set<String> = []
        // The core named a member at some point in this pass — evidence that it is naming them at
        // all, without which an unnamed probe says nothing about the candidate it was asked about.
        var didNameAnyone = false
        // Refusals that named nobody, held back until that evidence arrives.
        var unattributed: [NewChatRecipient] = []
        for candidate in candidates {
            do {
                let groupIdHex = try await client.createGroup(
                    accountRef: activeAccount.accountRef,
                    name: name,
                    memberRefs: [candidate, pin].map { $0.memberRef.isEmpty ? $0.accountIdHex : $0.memberRef },
                    description: nil
                )
                // The pin resolved after all, so this asked the core to create a real group and it
                // did. Hand it back rather than leave it unowned; the caller selects it, and the
                // draft it came from closes with it.
                return .created(groupIdHex)
            } catch {
                // The composer belongs to another account now: stop, and leave the caller with
                // nothing to report into it.
                guard activeAccountId == accountId else { return .attributed(marks) }
                let named: NewChatRecipient?
                if case .notOnWhiteNoise(let account) = ChatCreationFailure(error) {
                    named = ChatCreationFailure.refusedRecipient(named: account, among: [candidate, pin])
                } else {
                    // A failure of another kind, for a question that only had two members in it and
                    // resolves them in order. It says the same thing an unnamed refusal does.
                    named = nil
                }
                guard let named else {
                    unattributed.append(candidate)
                    continue
                }
                didNameAnyone = true
                if named.accountIdHex.caseInsensitiveCompare(pin.accountIdHex) == .orderedSame {
                    // The pin is what failed, which it always does — so the candidate ahead of it
                    // resolved.
                    continue
                }
                marks.insert(candidate.accountIdHex.lowercased())
            }
        }
        // A pass where the core never named anyone is a pass that proves nothing about anyone: the
        // failure is as likely to be about this account, or the relays, as about the member being
        // asked after. Marking every candidate on that evidence would empty the group and blame
        // people who are perfectly reachable, so the notice says there is someone and names no one.
        if didNameAnyone {
            for candidate in unattributed {
                marks.insert(candidate.accountIdHex.lowercased())
            }
        }
        return marks.isEmpty ? .unattributed : .attributed(marks)
    }

    /// Route a creation failure to the surface that can act on it.
    ///
    /// A one-to-one attempt becomes an invite prompt naming the recipient: the composition is
    /// already minimal, so the only move left is to invite them. A group draft instead pins the
    /// refusal on the member the core named, which moves them into the panel's "Not on White
    /// Noise yet" section and takes them out of the next attempt. Anything the taxonomy doesn't
    /// recognize falls back to the error line, as before.
    ///
    /// The group path reaches here only for a refusal that names nobody the draft knows;
    /// `createGroupResolvingEveryRefusal` handles the named ones itself, because learning them one
    /// per press was the bug it exists to fix.
    ///
    /// Every caller must re-check `activeAccountId` first, the same way the success paths do
    /// (whitenoise-mac#229): each of them suspends across `createGroup`, so a mid-await A→B
    /// switch would otherwise land account A's refusal in account B's composer. The draft half of
    /// that is latent today — the switch closes the composer, and `resetNewChatComposer()` clears
    /// both fields — but `lastError` survives a close, so the guard closes a real leak and stops
    /// the rest from depending on teardown order.
    func applyChatCreationFailure(
        _ error: Error,
        recipients: [NewChatRecipient],
        surface: ChatCreationSurface
    ) {
        switch ChatCreationFailure(error) {
        case .other(let message):
            lastError = message
        case .notOnWhiteNoise(let account):
            if surface == .directChat, let recipient = recipients.first {
                startChatInvitePrompt = StartChatInvitePrompt(
                    accountIdHex: recipient.accountIdHex,
                    recipientName: recipient.displayName,
                    query: newChatQuery.trimmingCharacters(in: .whitespacesAndNewlines))
                return
            }
            // Without a member to pin it on — an unusable KeyPackage event rather than a missing
            // one — the panel says there is someone it can't name, in the same notice that lists
            // the ones it can. A red line beside that notice was two answers to one question.
            guard let refused = ChatCreationFailure.refusedRecipient(named: account, among: recipients) else {
                hasUnnamedGroupDraftRefusal = true
                return
            }
            unreachableDraftMemberIdHexes.insert(refused.accountIdHex.lowercased())
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
