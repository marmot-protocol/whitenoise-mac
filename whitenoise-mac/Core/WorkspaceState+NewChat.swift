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
    /// `reportingErrors: false` leaves `lastError` alone, for a field that isn't the screen's own —
    /// the add-members sheet, whose parent pane renders `lastError` behind it.
    // TODO(arch): `reportingErrors` drops with `lastError` as a global channel.
    @discardableResult
    func resolveNewChatQuery(reportingErrors: Bool = true) async -> NewChatRecipient? {
        let query = newChatQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard client != nil else { return nil }
        guard !query.isEmpty else {
            invalidateNewChatLookup()
            newChatRecipient = nil
            if reportingErrors {
                lastError = L10n.string("Enter a NIP-05, npub, profile link, or public key.")
            }
            return nil
        }

        if reportingErrors { lastError = nil }
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
            if reportingErrors {
                lastError = L10n.string("Enter a valid NIP-05, npub, profile link, or hex public key.")
            }
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
            displayNameIsPrivate: Self.nicknameIsPrivate(nickname, over: published),
            pictureURL: resolved?.profilePicture
        )
    }

    // TODO(arch): `reportingErrors` drops with `lastError` as a global channel.
    func resolveNewChatQueryIfReady(reportingErrors: Bool = true) async {
        let query = newChatQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            invalidateNewChatLookup()
            newChatRecipient = nil
            if reportingErrors { lastError = nil }
            return
        }
        guard looksLikeMemberRef(query) else {
            invalidateNewChatLookup()
            newChatRecipient = nil
            return
        }
        guard resolvedNewChatRecipient == nil else { return }

        await resolveNewChatQuery(reportingErrors: reportingErrors)
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
            let result = try await client.createGroup(
                accountRef: activeAccount.accountRef,
                name: groupName,
                memberRefs: recipients.map(\.memberRef),
                description: trimmedDescription.isEmpty ? nil : trimmedDescription
            )
            guard activeAccountId == accountId else { return }
            let report = MemberResolutionReport(outcomes: result.memberOutcomes, recipients: recipients)
            guard let groupIdHex = result.groupIdHex else {
                applyNothingAdded(report, recipients: recipients, surface: isDirect ? .directChat : .groupDraft)
                return
            }
            if let notice = report.notAddedNotice {
                backgroundStatus = notice
            }
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
        for chat in chats {
            guard let hex = chat.directPeerAccountIdHex, hex != selfHex, hex.count == 64 else { continue }
            let existing = byHex[hex]
            byHex[hex] = ComposeContact(
                accountIdHex: hex,
                npub: existing?.npub ?? "",
                displayName: chat.title,
                publishedDisplayName: chat.publishedTitle,
                displayNameIsPrivate: Self.nicknameIsPrivate(
                    nicknames.nickname(forContactAccountIdHex: hex), over: chat.publishedTitle),
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
            await finishComposeContacts(
                byHex,
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
                let published = existing?.profileName ?? member.displayName
                let nickname = nicknames.nickname(forContactAccountIdHex: hex)
                byHex[hex] = ComposeContact(
                    accountIdHex: hex,
                    npub: npub,
                    displayName: nickname ?? published,
                    publishedDisplayName: Self.publishedContactName(published, overriddenBy: nickname),
                    displayNameIsPrivate: Self.nicknameIsPrivate(nickname, over: published),
                    pictureURL: existing?.pictureURL,
                    lastActivity: latestDate(existing?.lastActivity, group.updatedAt)
                )
            }
            composeContacts = sortedComposeContacts(byHex)
        }
        await finishComposeContacts(
            byHex,
            generation: generation,
            accountId: accountId,
            selfHex: selfHex,
            nicknames: nicknames,
            client: client
        )
    }

    /// The last two passes of a compose refresh: fold in follows, then fill in npubs and pictures.
    private func finishComposeContacts(
        _ byHex: [String: ComposeContact],
        generation: UInt64,
        accountId: String,
        selfHex: String,
        nicknames: ContactNicknames,
        client: any MarmotRuntime
    ) async {
        guard
            let merged = await mergeFollowedComposeContacts(
                into: byHex,
                generation: generation,
                accountId: accountId,
                selfHex: selfHex,
                nicknames: nicknames,
                client: client
            )
        else { return }
        await fillComposeContactGaps(merged, generation: generation, accountId: accountId, client: client)
    }

    /// A direct chat hands its contact a picture but no npub; a group roster entry or a follow is
    /// the reverse. Without this pass the list shows hex under a DM peer and initials for
    /// someone you only share groups with. Fill both from the core's local caches — a fresh
    /// peer-cache entry for free, the rest in one network-free hop off the main thread.
    private func fillComposeContactGaps(
        _ byHex: [String: ComposeContact],
        generation: UInt64,
        accountId: String,
        client: any MarmotRuntime
    ) async {
        let now = nowProvider()
        var cachedPictures: [String: String] = [:]
        var needsPicture: [String] = []
        var needsNpub: [String] = []
        for contact in byHex.values {
            if contact.npub.isEmpty {
                needsNpub.append(contact.accountIdHex)
            }
            guard contact.pictureURL == nil else { continue }
            if let cached = peerProfileFFICache[contact.accountIdHex],
                cached.isFresh(now: now, ttl: Self.peerProfileCacheTTL)
            {
                cachedPictures[contact.accountIdHex] = cached.resolved.profilePicture?.nilIfBlank
            } else {
                needsPicture.append(contact.accountIdHex)
            }
        }
        guard !cachedPictures.isEmpty || !needsPicture.isEmpty || !needsNpub.isEmpty else { return }

        let fetched =
            (try? await FFIExecutor.run {
                (
                    pictures: needsPicture.reduce(into: [String: String]()) { result, hex in
                        result[hex] = (try? client.userProfile(accountIdHex: hex))?.picture?.nilIfBlank
                    },
                    npubs: needsNpub.reduce(into: [String: String]()) { result, hex in
                        result[hex] = client.npub(accountIdHex: hex)?.nilIfBlank
                    }
                )
            }) ?? (pictures: [:], npubs: [:])
        let pictures = cachedPictures.merging(fetched.pictures) { cached, _ in cached }
        guard !pictures.isEmpty || !fetched.npubs.isEmpty else { return }
        guard composeContactsGeneration == generation, activeAccountId == accountId else { return }

        // Fill the live list, not `byHex`: a nickname edited during the hop relabels
        // `composeContacts` in place without bumping the generation, so writing the pre-hop
        // copy back would revert it. Neither field is a sort key, so the order stands.
        composeContacts = composeContacts.map { contact in
            let picture = pictures[contact.accountIdHex]
            let npub = fetched.npubs[contact.accountIdHex]
            guard picture != nil || npub != nil else { return contact }
            return contact.filling(npub: npub, pictureURL: picture)
        }
    }

    /// Fold the accounts this identity follows into a compose refresh, keeping only the keys
    /// no chat or group roster already supplied. Someone you follow but have never messaged
    /// is otherwise absent from this list entirely, which makes a first DM a paste-an-npub
    /// exercise. They carry no `lastActivity`, so `sortedComposeContacts` files them below
    /// every real conversation.
    ///
    /// - Returns: The merged directory, or nil when a newer refresh or an account switch
    ///   superseded this one.
    private func mergeFollowedComposeContacts(
        into byHex: [String: ComposeContact],
        generation: UInt64,
        accountId: String,
        selfHex: String,
        nicknames: ContactNicknames,
        client: any MarmotRuntime
    ) async -> [String: ComposeContact]? {
        let selfKey = selfHex.lowercased()
        let missing =
            followedAccountIdsHex
            .filter { $0.count == 64 && $0 != selfKey && byHex[$0] == nil && !isLocalAccount(accountIdHex: $0) }
            .sorted()
        guard !missing.isEmpty else { return byHex }

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
        guard composeContactsGeneration == generation, activeAccountId == accountId else { return nil }

        var byHex = byHex
        for contact in resolved where byHex[contact.accountIdHex] == nil {
            let published = PeerDisplayText.sanitize(contact.displayName)
            let nickname = nicknames.nickname(forContactAccountIdHex: contact.accountIdHex)
            byHex[contact.accountIdHex] = ComposeContact(
                accountIdHex: contact.accountIdHex,
                npub: contact.npub ?? "",
                displayName: nickname ?? published,
                publishedDisplayName: Self.publishedContactName(published, overriddenBy: nickname),
                displayNameIsPrivate: Self.nicknameIsPrivate(nickname, over: published),
                pictureURL: nil,
                lastActivity: nil
            )
        }
        composeContacts = sortedComposeContacts(byHex)
        return byHex
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

    /// The direct chat "Message" reuses: the newest one with this person the viewer is still in.
    /// Same rule as the New chat chooser (`DirectChatChoices.existing`), so the two never disagree
    /// about which chats count. It can be archived when that is the newest one, so the choice says so.
    func existingDirectChat(peerAccountIdHex: String) -> DirectChatChoice? {
        guard let activeAccountId else { return nil }
        return DirectChatChoices.existing(
            withPeer: peerAccountIdHex,
            active: chatsByAccount[activeAccountId] ?? [],
            archived: archivedChatsByAccount[activeAccountId] ?? []
        ).first
    }

    /// Open the existing direct chat with this person, or create one and select it. Direct
    /// chats are created with an empty group name; the chat list titles them from the peer
    /// profile.
    ///
    /// `reusingExisting: false` always creates a new chat: the New chat chooser
    /// (`DirectChatChooserViewModel`) has already offered the existing ones and the user asked
    /// for another.
    ///
    /// `expectedAccountId`, when given, is the account the request was made under: if another
    /// account is active by the time this runs, nothing is created.
    func startDirectChat(
        with recipient: NewChatRecipient,
        reusingExisting: Bool = true,
        expectedAccountId: String? = nil
    ) async {
        if reusingExisting, let existing = existingDirectChat(peerAccountIdHex: recipient.accountIdHex) {
            // An archived chat comes back into the chat list first, as the chooser's open path
            // does, or the user lands in a chat the sidebar is not showing.
            if existing.isArchived {
                // Re-checked after the await so a mid-unarchive account switch cannot select this
                // account's chat id under the next one.
                let accountId = activeAccountId
                guard await setChatArchived(existing.chat, archived: false), activeAccountId == accountId else {
                    return
                }
            }
            selectChat(existing.chat)
            return
        }
        guard let client, let activeAccount, !isCreatingChat else { return }
        if let expectedAccountId, activeAccount.id != expectedAccountId { return }
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
            let memberRef = recipient.inviteRef
            let groupIdHex: String
            if reusingExisting {
                // MDK reuses its canonical direct chat with this peer or founds one with both
                // accounts as admins, in one step on the account worker. A retry after a timeout
                // or cancellation lands on the same group rather than creating a duplicate.
                groupIdHex = try await client.startDirectConversation(
                    accountRef: activeAccount.accountRef,
                    peerAccountId: memberRef
                )
            } else {
                // The user asked for another chat beside the existing one, which
                // `startDirectConversation` would hand back, so this one is created directly.
                let result = try await client.createGroup(
                    accountRef: activeAccount.accountRef,
                    name: "",
                    memberRefs: [memberRef],
                    description: nil
                )
                guard activeAccountId == accountId else { return }
                // MDK creates nothing when the one member it was asked for is unavailable, and
                // reports why in the outcomes rather than throwing.
                guard let created = result.groupIdHex else {
                    applyNothingAdded(
                        MemberResolutionReport(outcomes: result.memberOutcomes, recipients: [recipient]),
                        recipients: [recipient],
                        surface: .directChat
                    )
                    return
                }
                groupIdHex = created
                // Both people in a direct chat are its admins. `createGroup` founds a group with
                // its creator as the only admin, so the peer is promoted straight after. Best
                // effort: the chat works without it and the creator can still make them an admin
                // from chat info, so a refusal does not turn a created chat into a failed one.
                _ = try? await client.promoteAdminDetailed(
                    accountRef: activeAccount.accountRef,
                    groupIdHex: groupIdHex,
                    memberRef: memberRef
                )
            }
            await reloadChats(forceFreshSnapshot: true)
            guard activeAccountId == accountId else { return }
            // `startDirectConversation` may answer with an archived chat the lookup above did not
            // match to this peer. It comes back into the chat list first, as that path does.
            if let archived = archivedChatItem(accountId: accountId, chatId: groupIdHex) {
                guard await setChatArchived(archived, archived: false), activeAccountId == accountId else { return }
            }
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

    /// Create the group from the compose-flow draft (chosen members, required name, timer, and the
    /// optional picture). A timer failure keeps the group and surfaces on the background banner.
    ///
    /// `image` founds the group with it, so it is in the group's first metadata rather than a
    /// later commit; the New group panel owns it, since `WorkspaceState` takes no new draft state.
    func createGroupFromDraft(image: GroupDraftImage? = nil) async {
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
        let attempt = reachableDraftMembers
        let groupIdHex: String
        let report: MemberResolutionReport
        do {
            let result =
                if let image {
                    try await client.createGroupWithInitialImage(
                        accountRef: activeAccount.accountRef,
                        name: name,
                        memberRefs: attempt.map(\.inviteRef),
                        description: nil,
                        initialImage: image.initialImage
                    )
                } else {
                    try await client.createGroup(
                        accountRef: activeAccount.accountRef,
                        name: name,
                        memberRefs: attempt.map(\.inviteRef),
                        description: nil
                    )
                }
            guard activeAccountId == accountId else { return }
            report = MemberResolutionReport(outcomes: result.memberOutcomes, recipients: attempt)
            guard let created = result.groupIdHex else {
                applyNothingAdded(report, recipients: attempt, surface: .groupDraft)
                return
            }
            groupIdHex = created
        } catch {
            guard activeAccountId == accountId else { return }
            applyChatCreationFailure(error, recipients: attempt, surface: .groupDraft)
            return
        }
        // MDK went ahead with whoever it could reach. The group opens, and the banner names the
        // people it left out, since the panel that would have listed them closes with the draft.
        var notices = report.notAddedNotice.map { [$0] } ?? []
        if retentionSecs > 0 {
            do {
                try await client.updateMessageRetention(
                    accountRef: activeAccount.accountRef,
                    groupIdHex: groupIdHex,
                    disappearingMessageSecs: retentionSecs
                )
            } catch {
                notices.append(
                    L10n.string("The group was created, but disappearing messages could not be turned on."))
            }
        }
        if !notices.isEmpty, activeAccountId == accountId {
            backgroundStatus = notices.joined(separator: " ")
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

    /// Answer a create that added nobody: a nonempty roster where MDK found no one available, so
    /// no group exists. Unreachable members are marked in the panel (or, for a one-to-one attempt,
    /// offered an invitation); outdated and incomplete ones go on the error line, since a mark
    /// would say the wrong thing about them.
    ///
    /// Callers re-check `activeAccountId` first, as for `applyChatCreationFailure`.
    func applyNothingAdded(
        _ report: MemberResolutionReport,
        recipients: [NewChatRecipient],
        surface: ChatCreationSurface
    ) {
        if surface == .directChat, let recipient = recipients.first,
            report.skipped.contains(where: { $0.reason == .unreachable })
        {
            startChatInvitePrompt = StartChatInvitePrompt(
                accountIdHex: recipient.accountIdHex,
                recipientName: recipient.displayName,
                query: newChatQuery.trimmingCharacters(in: .whitespacesAndNewlines))
            return
        }
        if surface == .groupDraft {
            unreachableDraftMemberIdHexes.formUnion(report.unreachableRecipientIdHexes)
            if report.hasUnnamedUnreachable {
                hasUnnamedGroupDraftRefusal = true
            }
        }
        if let message = report.nothingAddedMessage {
            lastError = message
        }
    }

    /// Route a creation failure to the surface that can act on it.
    ///
    /// A one-to-one attempt becomes an invite prompt naming the recipient: the composition is
    /// already minimal, so the only move left is to invite them. A group draft instead pins the
    /// refusal on the member the core named, which moves them into the panel's "Not on White
    /// Noise yet" section and takes them out of the next attempt. Anything the taxonomy doesn't
    /// recognize falls back to the error line, as before.
    ///
    /// Since MarmotKit 0.17 a create reports unavailable members as outcomes rather than errors
    /// (`applyNothingAdded`), so the KeyPackage cases here come from `startDirectConversation`,
    /// which stays all-or-nothing.
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
        case .needsAppUpdate(let account):
            // Not an invitation: they already have White Noise and need to update it. A one-to-one
            // attempt has exactly one recipient to name even when the core's label doesn't match.
            let named =
                ChatCreationFailure.refusedRecipient(named: account, among: recipients)
                ?? (surface == .directChat ? recipients.first : nil)
            lastError = ChatCreationFailure.needsAppUpdateMessage(recipientName: named?.title)
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
