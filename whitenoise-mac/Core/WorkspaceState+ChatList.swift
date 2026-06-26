//
//  WorkspaceState+ChatList.swift
//  whitenoise-mac
//
//  ChatList behavior extracted from WorkspaceState.swift (no behavior change).
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
    func reloadChats() async {
        guard let client, let activeAccount else { return }
        stopChatListListener()
        isRefreshing = true
        defer { isRefreshing = false }

        do {
            let subscription = try await client.subscribeChatList(
                accountRef: activeAccount.accountRef,
                includeArchived: false
            )
            guard activeAccountId == activeAccount.id else { return }

            let rows = try await runOffMain { subscription.snapshot() }
            guard activeAccountId == activeAccount.id, !Task.isCancelled else { return }
            await applyChatRows(rows, account: activeAccount)
            startChatListListener(account: activeAccount, subscription: subscription)

            await selectMostRecentChatIfNeeded()
        } catch {
            lastError = error.localizedDescription
        }
    }

    func startChatListListener(
        account: AccountItem,
        subscription: ChatListSubscription? = nil
    ) {
        guard client != nil else { return }
        stopChatListListener()
        guard activeAccountId == account.id else { return }
        chatListTaskAccountId = account.id
        chatListTask = Task { [weak self] in
            await self?.runChatListListener(
                account: account,
                existingSubscription: subscription
            )
        }
    }

    func stopChatListListener() {
        chatListTask?.cancel()
        chatListTask = nil
        chatListTaskAccountId = nil
        chatListEnrichmentTask?.cancel()
        chatListEnrichmentTask = nil
        chatListRowEnrichment.cancelAll()
    }

    func runChatListListener(
        account: AccountItem,
        existingSubscription: ChatListSubscription? = nil
    ) async {
        guard let client else { return }
        var reconnectAttempt = 0
        var pendingSubscription = existingSubscription

        while !Task.isCancelled, activeAccountId == account.id {
            do {
                let subscription: ChatListSubscription
                if let existing = pendingSubscription {
                    subscription = existing
                    pendingSubscription = nil
                } else {
                    subscription = try await client.subscribeChatList(
                        accountRef: account.accountRef,
                        includeArchived: false
                    )
                    guard activeAccountId == account.id, !Task.isCancelled else { break }
                    let rows = try await runOffMain { subscription.snapshot() }
                    guard activeAccountId == account.id, !Task.isCancelled else { break }
                    await applyChatRows(rows, account: account)
                }

                while !Task.isCancelled, activeAccountId == account.id {
                    guard let update = await subscription.nextUpdate() else { break }
                    guard !Task.isCancelled, activeAccountId == account.id else { break }
                    reconnectAttempt = 0
                    await applyChatListSubscriptionUpdate(update, account: account)
                }
            } catch is CancellationError {
                return
            } catch {
                if activeAccountId == account.id {
                    setBackgroundStatus(error.localizedDescription)
                }
            }

            guard !Task.isCancelled, activeAccountId == account.id else { break }
            do {
                try await waitBeforeListenerReconnect(attempt: reconnectAttempt)
            } catch is CancellationError {
                return
            } catch {
                if activeAccountId == account.id {
                    setBackgroundStatus(error.localizedDescription)
                }
            }
            reconnectAttempt += 1
        }

        if chatListTaskAccountId == account.id && !Task.isCancelled {
            chatListTask = nil
            chatListTaskAccountId = nil
        }
    }

    func applyChatRows(_ rows: [ChatListRowFfi], account: AccountItem) async {
        guard activeAccountId == account.id else { return }

        let chatItems = rows.map { baseChatItem(from: $0, account: account) }
        let previousChatIds = Set((chatsByAccount[account.id] ?? []).map(\.id))
        let nextChatIds = Set(chatItems.map(\.id))
        let removedChatIds = previousChatIds.subtracting(nextChatIds)
        for groupId in removedChatIds {
            invalidateGroupMembers(for: groupId)
        }
        clearComposerDrafts(for: Array(removedChatIds), accountId: account.id)
        chatsByAccount[account.id] = sortedChatItems(chatItems)
        dismissGroupImagePickerIfSelectedChatUnavailable()
        startChatListEnrichment(rows: rows, account: account)
    }

    func applyChatListSubscriptionUpdate(
        _ update: ChatListSubscriptionUpdateFfi,
        account: AccountItem
    ) async {
        switch update {
        case .row(let trigger, let row):
            invalidateGroupMemberDetailsCacheIfNeeded(trigger: trigger, groupIdHex: row.groupIdHex)
            await applyChatRow(row, account: account)
        case .removeRow(trigger: _, let groupIdHex):
            invalidateGroupMembers(for: groupIdHex)
            removeChat(groupIdHex: groupIdHex, account: account)
        }
    }

    func applyChatRow(
        _ row: ChatListRowFfi,
        account: AccountItem,
        skippingStaleRow: Bool = false,
        shouldEnrich: Bool = true
    ) async {
        guard activeAccountId == account.id else { return }

        let chats = chatsByAccount[account.id] ?? []
        if row.archived {
            removeChat(groupIdHex: row.groupIdHex, account: account)
            return
        }

        var chat = baseChatItem(from: row, account: account)
        let current = chats.first(where: { $0.id == chat.id })
        if skippingStaleRow,
            let current,
            isOlderChatRow(chat, than: current)
        {
            return
        }
        if !shouldEnrich, let current {
            // Read-state-only rows do not change the metadata resolved by enrichment
            // (direct-chat title/avatar/isDirect). Preserve it while applying the row's
            // unread/preview/timestamp fields, otherwise skipping enrichment would cause
            // direct chats to flicker back to their raw group-id fallback.
            chat = ChatListOrdering.preservingResolvedMetadata(in: chat, from: current)
        }
        let needsInitialMetadata = !shouldEnrich && readStateRowNeedsMetadataEnrichment(row, current: current)

        chatsByAccount[account.id] = ChatListOrdering.upserting(chat, into: chats)
        if shouldEnrich {
            startChatListEnrichment(rows: [row], account: account, replacingCurrent: false)
        } else if needsInitialMetadata {
            // A read-state row normally does not need enrichment, but the first selected-chat
            // read-state row can arrive after reload wiring cancels the snapshot enrichment.
            // Resolve at most one missing membership cache per invalidation; repeated failures
            // must not put groupDetails/userProfile work back on every read-marker advance.
            readStateMetadataEnrichmentAttempts.insert(row.groupIdHex)
            await enrichChatRows([row], account: account)
        }
    }

    func isOlderChatRow(_ candidate: ChatItem, than current: ChatItem) -> Bool {
        ChatListOrdering.isOlder(candidate, than: current)
    }

    func readStateRowNeedsMetadataEnrichment(_ row: ChatListRowFfi, current: ChatItem?) -> Bool {
        if readStateMetadataEnrichmentAttempts.contains(row.groupIdHex) { return false }
        if groupMemberDetailsCache[row.groupIdHex] == nil { return true }
        guard let current else { return true }
        guard !current.isDirect else { return false }
        let rawTitle = row.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let groupNameIsBlank = row.groupName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        // Blank-name group rows use the raw row title until one enrichment pass can confirm
        // whether this is a direct chat. Retry once after invalidation, then leave later
        // read-state-only rows on the hot path without another synchronous metadata lookup.
        return groupNameIsBlank && current.title == rawTitle
    }

    func removeChat(groupIdHex: String, account: AccountItem) {
        guard activeAccountId == account.id else { return }

        var chats = chatsByAccount[account.id] ?? []
        chats.removeAll { $0.id == groupIdHex }
        chatsByAccount[account.id] = chats
        messagesByChat[groupIdHex] = nil
        messageLookupByChat[groupIdHex] = nil
        messageIDsByChat[groupIdHex] = nil
        invalidateGroupMembers(for: groupIdHex)
        timelinePagingByChat[groupIdHex] = nil
        clearComposerDrafts(for: [groupIdHex], accountId: account.id)
        if timelineInitialLoadGroupId == groupIdHex {
            timelineInitialLoadGroupId = nil
        }
        lastMarkedReadMarkers[groupIdHex] = nil
        lastConfirmedReadMarkers[groupIdHex] = nil

        guard case .chat(let selectedGroupId) = selection,
            selectedGroupId == groupIdHex
        else { return }

        closeGroupImagePicker()
        let nextChat = mostRecentChat(in: chats)
        selection = nextChat.map { .chat($0.id) }
        pruneMessageCache(keeping: nextChat?.id)
        if let nextChat {
            beginTimelineInitialLoadIfNeeded(groupIdHex: nextChat.id)
            Task { await loadMessages(groupIdHex: nextChat.id) }
        }
    }

    func baseChatItem(from row: ChatListRowFfi, account: AccountItem) -> ChatItem {
        ChatItem(
            row: row,
            activeAccountIdHex: account.accountIdHex,
            groupAvatarURL: firstNonBlank([row.avatarUrl])
        )
    }

    func startChatListEnrichment(
        rows: [ChatListRowFfi],
        account: AccountItem,
        replacingCurrent: Bool = true
    ) {
        guard !rows.isEmpty, client != nil else { return }

        if replacingCurrent {
            // Full-snapshot enrichment (bootstrap / reload): a fresh pass re-enriches every
            // row, so it supersedes any in-flight incremental per-row work.
            chatListEnrichmentTask?.cancel()
            chatListRowEnrichment.cancelAll()

            chatListEnrichmentTask = Task { [weak self] in
                guard let self else { return }
                await self.enrichChatRows(rows, account: account)
            }
            return
        }

        // Incremental, per-row path (chat-list subscription deltas). Track every spawned task
        // and coalesce per group so only one enrichment runs per group at a time, and so they
        // can be cancelled on listener teardown / account switch (issue #40).
        for row in rows {
            let groupId = row.groupIdHex
            // Allocate a globally unique ownership token and cancel any prior task for this
            // group. The token is never reused (even across `cancelAll()` on reload / account
            // switch), so a stale canceled task can never match a future task's token and drop
            // its tracking slot.
            let token = chatListRowEnrichment.beginTask(forGroup: groupId)

            let task = Task { [weak self] in
                guard let self else { return }
                await self.enrichChatRows([row], account: account)
                // Release this group's slot only if a newer update hasn't superseded us;
                // otherwise the newer task owns the slot and must not be dropped.
                self.chatListRowEnrichment.finishTask(forGroup: groupId, token: token)
            }
            chatListRowEnrichment.register(task: task, forGroup: groupId, token: token)
        }
    }

    func enrichChatRows(_ rows: [ChatListRowFfi], account: AccountItem) async {
        guard let client else { return }

        var enrichedItems: [ChatItem] = []
        for row in rows {
            guard !Task.isCancelled else { return }
            enrichedItems.append(await enrichedChatItem(from: row, account: account, client: client))
        }

        guard !Task.isCancelled, activeAccountId == account.id else { return }
        applyChatMetadataEnrichment(enrichedItems, account: account)
    }

    func applyChatMetadataEnrichment(_ enrichedItems: [ChatItem], account: AccountItem) {
        guard activeAccountId == account.id, !enrichedItems.isEmpty else { return }

        var chats = chatsByAccount[account.id] ?? []
        let incremental = enrichedItems.count == 1
        var didUpdate = false
        for enrichedItem in enrichedItems {
            guard let index = chats.firstIndex(where: { $0.id == enrichedItem.id }) else { continue }
            let current = chats[index]
            let next = ChatItem(
                id: current.id,
                title: enrichedItem.title,
                subtitle: enrichedItem.subtitle,
                preview: current.preview,
                updatedAt: current.updatedAt,
                avatarSeed: enrichedItem.avatarSeed,
                pictureURL: enrichedItem.pictureURL ?? current.pictureURL,
                unreadCount: current.unreadCount,
                isDirect: enrichedItem.isDirect,
                pendingConfirmation: current.pendingConfirmation
            )
            guard next != current else { continue }
            if incremental {
                chats = ChatListOrdering.upserting(next, into: chats)
            } else {
                chats[index] = next
            }
            didUpdate = true
        }

        if didUpdate {
            chatsByAccount[account.id] = incremental ? chats : sortedChatItems(chats)
        }
    }

    func enrichedChatItem(
        from row: ChatListRowFfi,
        account: AccountItem,
        client: any MarmotRuntime
    ) async -> ChatItem {
        var directPeer: ChatPeerProfile?
        let groupAvatarURL = firstNonBlank([row.avatarUrl])
        if let members = await cachedGroupMembers(
            groupIdHex: row.groupIdHex,
            account: account,
            client: client
        ) {
            // Bail before the second FFI hop (userProfile lookup) if this enrichment has been
            // cancelled — e.g. the listener was torn down or a newer row update for this group
            // superseded us. Avoids running the rest of the wasted FFI work to completion (#40).
            guard !Task.isCancelled else {
                return ChatItem(row: row, activeAccountIdHex: account.accountIdHex)
            }
            directPeer = await directPeerProfile(
                from: members,
                activeAccount: account,
                client: client
            )
        }

        return ChatItem(
            row: row,
            activeAccountIdHex: account.accountIdHex,
            directPeer: directPeer,
            groupAvatarURL: groupAvatarURL
        )
    }

    func selectMostRecentChatIfNeeded() async {
        guard selectedChat == nil,
            !isShowingSettings,
            let chat = mostRecentChat(in: activeChats)
        else { return }

        selection = .chat(chat.id)
        closeNewChatComposer()
        pruneMessageCache(keeping: chat.id)
        beginTimelineInitialLoadIfNeeded(groupIdHex: chat.id)
        await loadMessages(groupIdHex: chat.id)
    }

    func mostRecentChat(in chatItems: [ChatItem]) -> ChatItem? {
        sortedChatItems(chatItems).first
    }

    func sortedChatItems(_ chatItems: [ChatItem]) -> [ChatItem] {
        ChatListOrdering.sorted(chatItems)
    }

    func directPeerProfile(
        from members: [GroupMemberDetailsFfi],
        activeAccount: AccountItem,
        client: any MarmotRuntime
    ) async -> ChatPeerProfile? {
        let otherMembers = members.filter { member in
            !member.isSelf && member.memberIdHex != activeAccount.accountIdHex
        }
        guard otherMembers.count == 1,
            let otherMember = otherMembers.first
        else { return nil }

        let memberId = otherMember.memberIdHex
        let resolved = await resolvedPeerFFI(
            accountIdHex: memberId,
            activeAccount: activeAccount,
            client: client
        )
        let displayName = firstNonBlank([
            resolved?.profileDisplayName,
            resolved?.profileName,
            otherMember.displayName,
            resolved?.directoryDisplayName,
        ])

        return ChatPeerProfile(
            accountIdHex: memberId,
            displayName: displayName,
            pictureURL: resolved?.profilePicture?.nilIfBlank
        )
    }

    func resolvedPeerFFI(
        accountIdHex: String,
        activeAccount: AccountItem,
        client: any MarmotRuntime
    ) async -> ResolvedPeerFFI? {
        let now = nowProvider()
        if let cached = peerProfileFFICache[accountIdHex],
            cached.isFresh(now: now, ttl: Self.peerProfileCacheTTL)
        {
            return cached.resolved
        }

        let resolved = try? await runOffMain { () -> ResolvedPeerFFI in
            let profile = try? client.userProfile(accountIdHex: accountIdHex)
            return ResolvedPeerFFI(
                profileDisplayName: profile?.displayName,
                profileName: profile?.name,
                profilePicture: profile?.picture,
                directoryDisplayName: client.displayName(accountIdHex: accountIdHex)
            )
        }
        if activeAccountId == activeAccount.id, let resolved {
            peerProfileFFICache[accountIdHex] = CachedPeerProfile(resolved: resolved, resolvedAt: now)
        }
        return resolved
    }

    func messageSenderProfiles(
        from records: [TimelineMessageRecordFfi],
        groupIdHex: String,
        activeAccount: AccountItem,
        client: any MarmotRuntime
    ) async -> [String: ChatPeerProfile] {
        let senderIds = Set(
            records.flatMap { record in
                [record.sender, record.replyPreview?.sender]
            }
            .compactMap { $0 }
            .filter { !$0.isEmpty }
        )
        guard !senderIds.isEmpty else { return [:] }

        // Resolve any senders whose cached lookup is missing, incomplete, or stale in a
        // single off-main FFI batch, then cache the raw lookups (timestamped) so repeated
        // scroll-up pages skip Rust entirely. Incomplete lookups (relay not yet
        // propagated, or a failed lookup) are always re-resolved so a contact is never
        // pinned to a fallback name/avatar for the life of the process; complete lookups
        // are re-resolved once the TTL elapses so later name/avatar changes are picked up
        // within a session (whitenoise-mac#8).
        let now = nowProvider()
        let unresolvedIds = senderIds.filter { senderId in
            guard senderId != activeAccount.accountIdHex else { return false }
            guard let cached = peerProfileFFICache[senderId] else { return true }
            return !cached.isFresh(now: now, ttl: Self.peerProfileCacheTTL)
        }
        if !unresolvedIds.isEmpty {
            let resolved =
                (try? await runOffMain { () -> [String: ResolvedPeerFFI] in
                    var output: [String: ResolvedPeerFFI] = [:]
                    for senderId in unresolvedIds {
                        let profile = try? client.userProfile(accountIdHex: senderId)
                        output[senderId] = ResolvedPeerFFI(
                            profileDisplayName: profile?.displayName,
                            profileName: profile?.name,
                            profilePicture: profile?.picture,
                            directoryDisplayName: client.displayName(accountIdHex: senderId)
                        )
                    }
                    return output
                }) ?? [:]
            // The off-main resolution above suspends this actor. If the user switched
            // accounts while the batch was in flight, `selectAccount`/
            // `selectAccountFromSettings` already cleared `peerProfileFFICache` for the
            // newly selected account. Writing these now-stale, account-scoped lookups
            // would repopulate the cache with the *previous* account's directory/profile
            // entries and leak them into the new account until TTL expiry, undercutting
            // the account-scoped invalidation this code path relies on. Only commit the
            // results if we are still resolving for the same active account; otherwise
            // drop them — the caller re-checks `activeAccountId` after this await and
            // discards the stale window anyway (whitenoise-mac#8).
            if activeAccountId == activeAccount.id {
                for (senderId, value) in resolved {
                    peerProfileFFICache[senderId] = CachedPeerProfile(resolved: value, resolvedAt: now)
                }
            }
        }

        // `groupMemberNames` is only ever read as a fallback for non-local senders whose
        // resolved profile name is blank. In the common live-update steady state every sender
        // already resolves from its cached profile display/name, so fetching the full member
        // list and reducing it into a name map is wasted work on the timeline hot path. Only
        // pay for the member fetch + dictionary when at least one sender actually needs the
        // fallback after profile resolution (before the lower-priority directory name).
        let sendersNeedingMemberFallback = senderIds.filter { senderId in
            guard senderId != activeAccount.accountIdHex else { return false }
            let resolved = peerProfileFFICache[senderId]?.resolved
            return firstNonBlank([resolved?.profileDisplayName, resolved?.profileName]) == nil
        }
        let groupMemberNames: [String: String]
        if sendersNeedingMemberFallback.isEmpty {
            groupMemberNames = [:]
        } else {
            #if DEBUG
                timelineSenderMemberFallbackFetchCount += 1
            #endif
            let members =
                await cachedGroupMembers(
                    groupIdHex: groupIdHex,
                    account: activeAccount,
                    client: client
                ) ?? []
            groupMemberNames = members.reduce(into: [String: String]()) { result, member in
                if let displayName = firstNonBlank([member.displayName]) {
                    result[member.memberIdHex] = displayName
                }
            }
        }

        var profiles: [String: ChatPeerProfile] = [:]
        for senderId in senderIds {
            if senderId == activeAccount.accountIdHex {
                profiles[senderId] = ChatPeerProfile(
                    accountIdHex: senderId,
                    displayName: activeAccount.displayName,
                    pictureURL: activeAccount.pictureURL
                )
                continue
            }

            let resolved = peerProfileFFICache[senderId]?.resolved
            profiles[senderId] = ChatPeerProfile(
                accountIdHex: senderId,
                displayName: firstNonBlank([
                    resolved?.profileDisplayName,
                    resolved?.profileName,
                    groupMemberNames[senderId],
                    resolved?.directoryDisplayName,
                ]),
                pictureURL: resolved?.profilePicture?.nilIfBlank
            )
        }

        return profiles
    }
}
