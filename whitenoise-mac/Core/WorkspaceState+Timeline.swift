//
//  WorkspaceState+Timeline.swift
//  whitenoise-mac
//
//  Timeline behavior extracted from WorkspaceState.swift (no behavior change).
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
    func loadMessages(groupIdHex: String) async {
        guard let client, let activeAccount else {
            finishTimelineInitialLoad(groupIdHex: groupIdHex)
            return
        }
        if timelineTaskGroupId == groupIdHex, ensureMessageTimelineStore(for: groupIdHex).isLoaded {
            finishTimelineInitialLoad(groupIdHex: groupIdHex)
            return
        }
        stopTimelineListener()
        guard selectedChat?.id == groupIdHex else {
            finishTimelineInitialLoad(groupIdHex: groupIdHex)
            return
        }
        beginTimelineInitialLoadIfNeeded(groupIdHex: groupIdHex)
        defer { finishTimelineInitialLoad(groupIdHex: groupIdHex) }
        do {
            let accountRef = activeAccount.accountRef
            if let row = try await runOffMain({
                try client.initializeChatReadState(accountRef: accountRef, groupIdHex: groupIdHex)
            }) {
                // `initializeChatReadState` may race a live chat-list delta. Do not let an
                // older read-state row roll back a newer preview/timestamp already applied
                // by the subscription listener while the FFI call was in flight.
                await applyChatRow(
                    row,
                    account: activeAccount,
                    skippingStaleRow: true,
                    shouldEnrich: false
                )
            }

            let subscription = try await client.subscribeTimelineMessages(
                accountRef: activeAccount.accountRef,
                groupIdHex: groupIdHex,
                limit: Self.timelinePageLimit
            )
            guard activeAccountId == activeAccount.id, selectedChat?.id == groupIdHex else { return }

            let snapshot = try await runOffMain { subscription.snapshot() }
            guard activeAccountId == activeAccount.id,
                selectedChat?.id == groupIdHex,
                !Task.isCancelled
            else { return }
            let page =
                snapshot
                ?? TimelinePageFfi(
                    messages: [],
                    hasMoreBefore: false,
                    hasMoreAfter: false
                )
            await applyTimelineWindow(page, groupIdHex: groupIdHex, account: activeAccount, client: client)
            // Start the listener first (it tears down any prior listener, which would clear
            // these), then record the subscription so scroll-back pagination can reach it.
            // `startTimelineListener` can bail without starting a task (e.g. selection changed
            // while we awaited above); only record the subscription when it actually started,
            // otherwise we leak a live handle with no `next()` loop draining it.
            startTimelineListener(groupIdHex: groupIdHex, account: activeAccount, subscription: subscription)
            guard timelineTaskGroupId == groupIdHex else { return }
            activeTimelineSubscription = subscription
            activeTimelineGroupId = groupIdHex
        } catch {
            lastError = error.localizedDescription
        }
    }

    func loadOlderMessages(groupIdHex: String) async {
        guard let client, let activeAccount else { return }
        guard selectedChat?.id == groupIdHex, activeTimelineGroupId == groupIdHex else { return }
        guard let subscription = activeTimelineSubscription else { return }
        guard var paging = timelinePagingByChat[groupIdHex],
            paging.hasMoreBefore,
            !paging.isLoadingBefore
        else { return }

        paging.isLoadingBefore = true
        timelinePagingByChat[groupIdHex] = paging
        defer {
            if var currentPaging = timelinePagingByChat[groupIdHex] {
                currentPaging.isLoadingBefore = false
                timelinePagingByChat[groupIdHex] = currentPaging
            }
        }

        do {
            // The subscription owns the materialized window; `paginateBackwards` extends it
            // toward older history off the main thread and returns the new authoritative
            // window (already sorted, deduped, capped, with correct has-more flags).
            let page = try await TimelineSignpost.pagination.asyncInterval("paginateBackwards") {
                try await subscription.paginateBackwards(count: Self.timelinePageLimit)
            }
            guard activeAccountId == activeAccount.id, selectedChat?.id == groupIdHex else { return }
            await applyTimelineWindow(page, groupIdHex: groupIdHex, account: activeAccount, client: client)
        } catch {
            lastError = error.localizedDescription
        }
    }

    func loadNewerMessages(groupIdHex: String) async {
        guard let client, let activeAccount else { return }
        guard selectedChat?.id == groupIdHex, activeTimelineGroupId == groupIdHex else { return }
        guard let subscription = activeTimelineSubscription else { return }
        guard var paging = timelinePagingByChat[groupIdHex],
            paging.hasMoreAfter,
            !paging.isLoadingAfter
        else { return }

        paging.isLoadingAfter = true
        timelinePagingByChat[groupIdHex] = paging
        defer {
            if var currentPaging = timelinePagingByChat[groupIdHex] {
                currentPaging.isLoadingAfter = false
                timelinePagingByChat[groupIdHex] = currentPaging
            }
        }

        do {
            let page = try await TimelineSignpost.pagination.asyncInterval("paginateForwards") {
                try await subscription.paginateForwards(count: Self.timelinePageLimit)
            }
            guard activeAccountId == activeAccount.id, selectedChat?.id == groupIdHex else { return }
            await applyTimelineWindow(page, groupIdHex: groupIdHex, account: activeAccount, client: client)
        } catch {
            lastError = error.localizedDescription
        }
    }

    /// Render an authoritative timeline window from the subscription (initial snapshot,
    /// pagination result, or live update). The window is already ordered/deduped/capped by
    /// the runtime, so we map + resolve senders and replace the transcript wholesale.
    func applyTimelineWindow(
        _ page: TimelinePageFfi,
        groupIdHex: String,
        account: AccountItem,
        client: any MarmotRuntime
    ) async {
        guard activeAccountId == account.id, selectedChat?.id == groupIdHex else { return }
        let senderProfiles = await TimelineSignpost.mapping.asyncInterval(
            "resolveSenders.window", count: page.messages.count
        ) {
            await messageSenderProfiles(
                from: page.messages,
                groupIdHex: groupIdHex,
                activeAccount: account,
                client: client
            )
        }
        guard activeAccountId == account.id, selectedChat?.id == groupIdHex else { return }

        // Maps every record in the window and builds each bubble's Markdown display model
        // (attributed strings + block ids) eagerly — historically the dominant scroll-back
        // cost. Run off the main actor so this pure transformation does not block the UI
        // thread during the window replace, then re-check the selection guard after the
        // await before mutating timeline state (whitenoise-mac#285). Capture the plain
        // `accountIdHex` value before hopping off-main to avoid capturing actor state.
        let activeAccountIdHex = account.accountIdHex
        let mappedMessages = await TimelineSignpost.mapping.asyncInterval(
            "mapWindow", count: page.messages.count
        ) {
            await Self.mapTimelineOffMain(
                page: page,
                activeAccountIdHex: activeAccountIdHex,
                senderProfiles: senderProfiles
            )
        }
        guard activeAccountId == account.id, selectedChat?.id == groupIdHex else { return }

        let currentPaging = timelinePagingByChat[groupIdHex]
        TimelineSignpost.store.interval("replaceMessages", count: mappedMessages.count) {
            replaceMessages(
                mappedMessages,
                groupIdHex: groupIdHex,
                paging: TimelinePagingState(
                    hasMoreBefore: page.hasMoreBefore,
                    hasMoreAfter: page.hasMoreAfter,
                    isLoadingBefore: currentPaging?.isLoadingBefore ?? false,
                    isLoadingAfter: currentPaging?.isLoadingAfter ?? false
                )
            )
        }
        await markLatestVisibleMessageRead(groupIdHex: groupIdHex, account: account, client: client)
    }

    /// Route a live timeline subscription update to the right apply path.
    ///
    /// `.projection` is the steady-state hot path: a single send emits a burst of these
    /// (the new row, then each delivery-state transition, the relay echo, per-relay
    /// acks). Each carries only the changed rows, so we apply it incrementally rather
    /// than re-mapping every `MessageItem` (and its Markdown AST) in the window and
    /// replacing the whole transcript per delivery. `.page` is the runtime's
    /// authoritative re-window, emitted only when the event stream lags and the window
    /// must be re-materialized; it is applied wholesale.
    func applyTimelineSubscriptionUpdate(
        _ update: TimelineSubscriptionUpdateFfi,
        groupIdHex: String,
        account: AccountItem,
        client: any MarmotRuntime
    ) async {
        switch update {
        case .page(let page):
            await applyTimelineWindow(page, groupIdHex: groupIdHex, account: account, client: client)
        case .projection(let runtimeUpdate):
            await applyTimelineProjection(
                runtimeUpdate.update,
                groupIdHex: groupIdHex,
                account: account,
                client: client
            )
        }
    }

    /// Apply a projection delta to the selected rendered window. Only changed records are
    /// mapped to `MessageItem`s, then `MessageTimelineStore` mutates the affected rows in
    /// place using its id/index caches. That avoids the old live-update shape of copying,
    /// searching, sorting, and replacing the whole transcript for every delivery tick.
    func applyTimelineProjection(
        _ update: TimelineProjectionUpdateFfi,
        groupIdHex: String,
        account: AccountItem,
        client: any MarmotRuntime
    ) async {
        guard activeAccountId == account.id, selectedChat?.id == groupIdHex else { return }
        guard update.groupIdHex == groupIdHex else { return }

        // Partition the delta into upserts (need mapping) and removals. An empty
        // `changes` list means the runtime sent the resolved rows directly in
        // `messages`, all of which are upserts (matching the core's own fall-through).
        var upsertRecords: [TimelineMessageRecordFfi] = []
        var removalIds: Set<String> = []
        if update.changes.isEmpty {
            upsertRecords = update.messages
        } else {
            for change in update.changes {
                switch change {
                case .upsert(_, let message):
                    upsertRecords.append(message)
                case .remove(let messageIdHex, _):
                    removalIds.insert(messageIdHex)
                }
            }
        }
        guard !upsertRecords.isEmpty || !removalIds.isEmpty else { return }

        // Resolve senders for just the changed records (the common case is an all-cached
        // lookup) and map only those records — not the entire window.
        let senderProfiles = await TimelineSignpost.mapping.asyncInterval(
            "resolveSenders.projection", count: upsertRecords.count
        ) {
            await messageSenderProfiles(
                from: upsertRecords,
                groupIdHex: groupIdHex,
                activeAccount: account,
                client: client
            )
        }
        guard activeAccountId == account.id, selectedChat?.id == groupIdHex else { return }
        // Map only the changed records off the main actor (same pure transformation as the
        // window path), then re-check the selection guard after the await before mutating
        // the store (whitenoise-mac#285). Capture the plain `accountIdHex` before hopping
        // off-main to avoid capturing actor state.
        let activeAccountIdHex = account.accountIdHex
        let upsertPage = TimelinePageFfi(messages: upsertRecords, hasMoreBefore: false, hasMoreAfter: false)
        let mappedUpserts = await TimelineSignpost.mapping.asyncInterval(
            "mapProjection", count: upsertRecords.count
        ) {
            await Self.mapTimelineOffMain(
                page: upsertPage,
                activeAccountIdHex: activeAccountIdHex,
                senderProfiles: senderProfiles
            )
        }
        guard activeAccountId == account.id, selectedChat?.id == groupIdHex else { return }

        let paging = timelinePagingByChat[groupIdHex] ?? .empty
        // The window is "anchored" to the live head while there is no newer history to
        // page toward. A detached (scrolled-back) window must not grow a new head row —
        // the user re-anchors via forward pagination — so a brand-new message that sorts
        // strictly after the window's newest row is suppressed, exactly as the runtime
        // does. Existing rows still update in place (edits, reactions, delivery state).
        let anchored = !paging.hasMoreAfter
        let timelineStore = ensureMessageTimelineStore(for: groupIdHex)
        let result = TimelineSignpost.store.interval(
            "applyProjection", count: mappedUpserts.count + removalIds.count
        ) {
            timelineStore.applyProjection(
                upserts: mappedUpserts,
                removals: removalIds,
                anchoredToNewest: anchored,
                windowLimit: Self.timelineWindowLimit
            )
        }
        guard result.didChange else { return }

        finalizeTimelineStoreMutation(
            groupIdHex: groupIdHex,
            paging: TimelinePagingState(
                hasMoreBefore: paging.hasMoreBefore || result.didTrimOlderMessages,
                hasMoreAfter: paging.hasMoreAfter,
                isLoadingBefore: paging.isLoadingBefore,
                isLoadingAfter: paging.isLoadingAfter
            )
        )
        await markLatestVisibleMessageRead(groupIdHex: groupIdHex, account: account, client: client)
    }

    func startReply(to message: MessageItem) {
        guard message.supportsChatActions else { return }
        replyDraftContext = MessageReplyContext(
            targetMessageId: message.id,
            senderName: message.senderName,
            body: message.replyPreviewText
        )
    }

    func cancelReply() {
        replyDraftContext = nil
    }

    func copyText(of message: MessageItem) {
        guard message.canCopyText else { return }
        copyText(message.body)
    }

    /// Copies `text` to the system pasteboard.
    ///
    /// Every value copied from this app is private-messenger content — decrypted message
    /// bodies, full conversation transcripts, and Nostr identity keys — so copies default to
    /// `concealed`. A concealed copy additionally carries the `org.nspasteboard.ConcealedType`
    /// marker (see `copyToGeneralPasteboard`), which clipboard-history managers honor to avoid
    /// persisting the value and which discourages Universal Clipboard (Handoff) from syncing it
    /// to the user's other devices.
    func copyText(_ text: String, concealed: Bool = true) {
        copyTextHandler(text, concealed)
    }

    func react(to message: MessageItem, emoji: String) async {
        guard message.supportsChatActions else { return }
        guard let client, let activeAccount, let selectedChat else { return }
        // Reentrancy guard: drop a duplicate of the *same* in-flight reaction
        // (same target + emoji) while allowing a different emoji on the same message.
        let reactionKey = "\(selectedChat.id)\u{1F}\(message.id)\u{1F}\(emoji)"
        guard !inFlightReactionKeys.contains(reactionKey) else { return }
        inFlightReactionKeys.insert(reactionKey)
        defer { inFlightReactionKeys.remove(reactionKey) }
        do {
            _ = try await client.reactToMessage(
                accountRef: activeAccount.accountRef,
                groupIdHex: selectedChat.id,
                targetMessageId: message.id,
                emoji: emoji
            )
        } catch {
            lastError = error.localizedDescription
        }
    }

    func removeReaction(_ reaction: MessageReaction, from message: MessageItem) async {
        guard message.supportsChatActions else { return }
        guard reaction.canRemoveOwnReaction, let reactionMessageId = reaction.ownReactionMessageId else { return }
        guard let client, let activeAccount, let selectedChat else { return }
        // Reentrancy guard: the removal deletes the reaction event, so key on its id
        // (shared namespace with `deleteMessage`) to drop a repeated in-flight removal.
        guard !inFlightDeleteMessageIds.contains(reactionMessageId) else { return }
        inFlightDeleteMessageIds.insert(reactionMessageId)
        defer { inFlightDeleteMessageIds.remove(reactionMessageId) }
        do {
            _ = try await client.deleteMessage(
                accountRef: activeAccount.accountRef,
                groupIdHex: selectedChat.id,
                targetMessageId: reactionMessageId
            )
        } catch {
            lastError = error.localizedDescription
        }
    }

    func deleteMessage(_ message: MessageItem) async {
        guard message.canDelete else { return }
        guard let client, let activeAccount, let selectedChat else { return }
        // Reentrancy guard: drop a repeated delete of the same in-flight message.
        guard !inFlightDeleteMessageIds.contains(message.id) else { return }
        inFlightDeleteMessageIds.insert(message.id)
        defer { inFlightDeleteMessageIds.remove(message.id) }
        do {
            _ = try await client.deleteMessage(
                accountRef: activeAccount.accountRef,
                groupIdHex: selectedChat.id,
                targetMessageId: message.id
            )
            if replyDraftContext?.targetMessageId == message.id {
                replyDraftContext = nil
            }
        } catch {
            lastError = error.localizedDescription
        }
    }

    func sendDraft() async {
        let text = draftText.trimmingCharacters(in: .whitespacesAndNewlines)
        let mediaAttachments = pendingMediaAttachments
        // `!isSending` is the reentrancy guard: `isSending` flips synchronously here,
        // but the model only suspends (and `draftText` is only cleared) at the `await`
        // below. Without this guard a second invocation delivered before SwiftUI
        // re-renders the disabled send button (⌘-Return auto-repeat, double events)
        // would still observe the old `draftText` and re-send the same message.
        guard let client,
            let activeAccount,
            let selectedChat,
            let draftKey = selectedComposerDraftKey,
            !text.isEmpty || !mediaAttachments.isEmpty,
            !isSending
        else { return }
        isSending = true
        defer { isSending = false }

        do {
            if !mediaAttachments.isEmpty {
                _ = try await client.uploadMedia(
                    accountRef: activeAccount.accountRef,
                    groupIdHex: selectedChat.id,
                    request: MediaUploadRequestFfi(
                        attachments: mediaAttachments.map(\.uploadRequest),
                        caption: text.isEmpty ? nil : text,
                        send: true,
                        blossomServer: nil
                    )
                )
            } else if let replyDraftContext {
                _ = try await client.replyToMessage(
                    accountRef: activeAccount.accountRef,
                    groupIdHex: selectedChat.id,
                    targetMessageId: replyDraftContext.targetMessageId,
                    text: text
                )
            } else {
                _ = try await client.sendText(
                    accountRef: activeAccount.accountRef,
                    groupIdHex: selectedChat.id,
                    text: text
                )
            }
            // Clear via the captured `draftKey`, not the `draftText`/`replyDraftContext`
            // setters — those resolve their key from the *live* selection, so if the user
            // switched chats during the `await` above they would wipe the newly selected
            // conversation's composer state instead of the one we just sent from.
            draftTextByConversation[draftKey] = nil
            replyDraftContextByConversation[draftKey] = nil
            pendingMediaAttachmentsByConversation[draftKey] = nil
            // One authoritative re-window so the user sees their just-sent message
            // immediately, even if the live projection for it is momentarily in flight.
            // The follow-on delivery-state transitions then arrive as projection deltas
            // and are applied incrementally by `applyTimelineProjection` — no longer a
            // full re-map per delivery.
            await refreshSelectedTimelineAfterSend(groupIdHex: selectedChat.id, account: activeAccount, client: client)
        } catch {
            lastError = error.localizedDescription
        }
    }

    func startTimelineListener(
        groupIdHex: String,
        account: AccountItem,
        subscription: TimelineMessagesSubscription? = nil
    ) {
        guard client != nil else { return }
        stopTimelineListener()
        guard activeAccountId == account.id, selectedChat?.id == groupIdHex else { return }
        timelineTaskGroupId = groupIdHex
        timelineTask = Task { [weak self] in
            await self?.runTimelineListener(
                groupIdHex: groupIdHex,
                account: account,
                existingSubscription: subscription
            )
        }
    }

    func stopTimelineListener() {
        timelineTask?.cancel()
        timelineTask = nil
        timelineTaskGroupId = nil
        activeTimelineSubscription = nil
        activeTimelineGroupId = nil
    }

    func runTimelineListener(
        groupIdHex: String,
        account: AccountItem,
        existingSubscription: TimelineMessagesSubscription? = nil
    ) async {
        guard let client else { return }
        var reconnectAttempt = 0
        var pendingSubscription = existingSubscription

        while !Task.isCancelled,
            activeAccountId == account.id,
            selectedChat?.id == groupIdHex
        {
            do {
                let subscription: TimelineMessagesSubscription
                if let existing = pendingSubscription {
                    subscription = existing
                    pendingSubscription = nil
                } else {
                    subscription = try await client.subscribeTimelineMessages(
                        accountRef: account.accountRef,
                        groupIdHex: groupIdHex,
                        limit: Self.timelinePageLimit
                    )
                    guard activeAccountId == account.id,
                        selectedChat?.id == groupIdHex,
                        !Task.isCancelled
                    else { break }
                    let page = try await runOffMain { subscription.snapshot() }
                    guard activeAccountId == account.id,
                        selectedChat?.id == groupIdHex,
                        !Task.isCancelled
                    else { break }
                    // Pagination should only see this subscription after the initial
                    // snapshot has been materialized off-main and is ready to apply.
                    activeTimelineSubscription = subscription
                    activeTimelineGroupId = groupIdHex
                    if let page {
                        await applyTimelineWindow(
                            page,
                            groupIdHex: groupIdHex,
                            account: account,
                            client: client
                        )
                    }
                }
                // `nextUpdate()` blocks for the next live change and returns the raw
                // delta. A `.projection` carries only the changed rows, so we apply it
                // incrementally against the current window instead of re-materializing
                // and re-rendering the whole transcript on every delivery-state tick a
                // send emits; a `.page` is an authoritative re-window (broadcast lag),
                // applied wholesale.
                while !Task.isCancelled,
                    activeAccountId == account.id,
                    selectedChat?.id == groupIdHex
                {
                    guard let update = await subscription.nextUpdate() else { break }
                    guard !Task.isCancelled,
                        activeAccountId == account.id,
                        selectedChat?.id == groupIdHex
                    else { break }
                    reconnectAttempt = 0
                    await applyTimelineSubscriptionUpdate(
                        update,
                        groupIdHex: groupIdHex,
                        account: account,
                        client: client
                    )
                }
            } catch is CancellationError {
                return
            } catch {
                if activeAccountId == account.id, selectedChat?.id == groupIdHex {
                    setBackgroundStatus(error.localizedDescription)
                }
            }

            guard !Task.isCancelled,
                activeAccountId == account.id,
                selectedChat?.id == groupIdHex
            else { break }
            do {
                try await waitBeforeListenerReconnect(attempt: reconnectAttempt)
            } catch is CancellationError {
                return
            } catch {
                if activeAccountId == account.id, selectedChat?.id == groupIdHex {
                    setBackgroundStatus(error.localizedDescription)
                }
            }
            reconnectAttempt += 1
        }

        if timelineTaskGroupId == groupIdHex && !Task.isCancelled {
            timelineTask = nil
            timelineTaskGroupId = nil
        }
    }

    func replaceMessages(
        _ messages: [MessageItem],
        groupIdHex: String,
        paging: TimelinePagingState? = nil
    ) {
        // The window is already ordered, deduped, and capped by the runtime subscription,
        // so render it as-is. The per-chat id/lookup caches live on the store
        // (`MessageTimelineStore.replace` rebuilds them); we only mark this chat as the one
        // cached window.
        let nextPaging = paging ?? timelinePagingByChat[groupIdHex] ?? .empty
        let timelineStore = ensureMessageTimelineStore(for: groupIdHex)

        for (storeGroupId, store) in messageTimelineStores where storeGroupId != groupIdHex {
            store.clear()
        }

        cachedMessageChatIds = [groupIdHex]
        messageTimelineStores = [groupIdHex: timelineStore]
        timelineStore.replace(with: messages)
        if timelinePagingByChat.count == 1, timelinePagingByChat[groupIdHex] != nil {
            timelinePagingByChat[groupIdHex] = nextPaging
        } else {
            timelinePagingByChat = [groupIdHex: nextPaging]
        }
        finishTimelineInitialLoad(groupIdHex: groupIdHex)
    }

    func finalizeTimelineStoreMutation(
        groupIdHex: String,
        paging: TimelinePagingState
    ) {
        let timelineStore = ensureMessageTimelineStore(for: groupIdHex)
        for (storeGroupId, store) in messageTimelineStores where storeGroupId != groupIdHex {
            store.clear()
        }
        cachedMessageChatIds = [groupIdHex]
        messageTimelineStores = [groupIdHex: timelineStore]
        timelinePagingByChat = [groupIdHex: paging]
        finishTimelineInitialLoad(groupIdHex: groupIdHex)
    }

    func refreshSelectedTimelineAfterSend(
        groupIdHex: String,
        account: AccountItem,
        client: any MarmotRuntime
    ) async {
        guard activeAccountId == account.id, selectedChat?.id == groupIdHex else { return }
        let pageLimit = Self.timelinePageLimit
        do {
            let page = try await runOffMain {
                try client.timelineMessages(
                    accountRef: account.accountRef,
                    query: TimelineMessageQueryFfi(
                        groupIdHex: groupIdHex,
                        search: nil,
                        before: nil,
                        beforeMessageId: nil,
                        after: nil,
                        afterMessageId: nil,
                        limit: pageLimit
                    )
                )
            }
            guard activeAccountId == account.id, selectedChat?.id == groupIdHex else { return }
            await applyTimelineWindow(page, groupIdHex: groupIdHex, account: account, client: client)
        } catch {
            setBackgroundStatus(error.localizedDescription)
        }
    }

    func pruneMessageCache(keeping groupIdHex: String?) {
        defer {
            pruneMediaDownloadCache(keeping: groupIdHex)
        }

        guard let groupIdHex else {
            for store in messageTimelineStores.values {
                store.clear()
            }
            cachedMessageChatIds = []
            messageTimelineStores = [:]
            timelinePagingByChat = [:]
            timelineInitialLoadGroupId = nil
            return
        }

        // Keep only the surviving chat's store and drop the rest. Whether the survivor stays
        // "cached" mirrors the old behaviour: it was cached iff its window had been recorded
        // (now tracked by `cachedMessageChatIds`) rather than merely having an empty store.
        let survivorWasCached = cachedMessageChatIds.contains(groupIdHex)
        if let timelineStore = messageTimelineStores[groupIdHex] {
            for (storeGroupId, store) in messageTimelineStores where storeGroupId != groupIdHex {
                store.clear()
            }
            messageTimelineStores = [groupIdHex: timelineStore]
            cachedMessageChatIds = survivorWasCached ? [groupIdHex] : []
        } else {
            for store in messageTimelineStores.values {
                store.clear()
            }
            messageTimelineStores = [:]
            cachedMessageChatIds = []
        }
        if let paging = timelinePagingByChat[groupIdHex] {
            timelinePagingByChat = [groupIdHex: paging]
        } else {
            timelinePagingByChat = [:]
        }
        if timelineInitialLoadGroupId != groupIdHex {
            timelineInitialLoadGroupId = nil
        } else if messageTimelineStores[groupIdHex]?.isLoaded == true {
            timelineInitialLoadGroupId = nil
        }
    }

    func beginTimelineInitialLoadIfNeeded(groupIdHex: String) {
        if !ensureMessageTimelineStore(for: groupIdHex).isLoaded {
            timelineInitialLoadGroupId = groupIdHex
        } else if timelineInitialLoadGroupId == groupIdHex {
            timelineInitialLoadGroupId = nil
        }
    }

    func finishTimelineInitialLoad(groupIdHex: String) {
        if timelineInitialLoadGroupId == groupIdHex {
            timelineInitialLoadGroupId = nil
        }
    }

    func markLatestVisibleMessageRead(
        groupIdHex: String,
        account: AccountItem,
        client: any MarmotRuntime
    ) async {
        guard activeAccountId == account.id, selectedChat?.id == groupIdHex else { return }
        // A selected chat is necessary but not sufficient: only advance the read marker
        // when the app is active and the conversation window is actually visible. If the
        // user has switched away or the window is hidden/minimized, incoming live deltas
        // must not silently clear unread state for messages they have not seen — this
        // mirrors the focus gate the notification path already applies in
        // handleNotificationUpdate(_:). Marking is deferred until the conversation becomes
        // visible again (see handleConversationVisibilityChange()).
        guard selectedConversationIsVisible() else { return }
        guard
            let latest = ensureMessageTimelineStore(for: groupIdHex).messages.last(where: { message in
                message.timelineKind == 9 && !message.isDeleted
            })
        else {
            return
        }
        let marker = ReadMarker(sentAt: latest.sentAt, messageId: latest.id)
        let currentMarker = lastMarkedReadMarkers[groupIdHex]
        guard currentMarker != marker else { return }
        guard currentMarker.map({ $0 < marker }) ?? true else { return }
        lastMarkedReadMarkers[groupIdHex] = marker

        do {
            let accountRef = account.accountRef
            let messageId = latest.id
            let row = try await runOffMain({
                try client.markTimelineMessageRead(
                    accountRef: accountRef,
                    groupIdHex: groupIdHex,
                    messageIdHex: messageId
                )
            })
            guard activeAccountId == account.id, selectedChat?.id == groupIdHex else { return }
            let committedState = ReadMarker.afterSuccessfulCommit(
                current: lastMarkedReadMarkers[groupIdHex],
                confirmed: lastConfirmedReadMarkers[groupIdHex],
                attempted: marker
            )
            lastMarkedReadMarkers[groupIdHex] = committedState.current
            lastConfirmedReadMarkers[groupIdHex] = committedState.confirmed
            if let row {
                await applyChatRow(row, account: account, shouldEnrich: false)
            }
        } catch {
            guard activeAccountId == account.id, selectedChat?.id == groupIdHex else { return }
            lastMarkedReadMarkers[groupIdHex] = ReadMarker.afterFailedOptimisticAdvance(
                current: lastMarkedReadMarkers[groupIdHex],
                attempted: marker,
                confirmed: lastConfirmedReadMarkers[groupIdHex]
            )
            setBackgroundStatus(error.localizedDescription)
        }
    }

    /// Flush any read-marking that was deferred while the conversation was not visible.
    ///
    /// `markLatestVisibleMessageRead(_:)` refuses to advance the read marker while the app
    /// is inactive or its conversation window has no visible key window, so messages that
    /// arrive while the user is away stay unread. When the conversation becomes visible
    /// again it is safe to advance the marker to the latest visible message. Call this from
    /// app/window activation hooks (see ContentView).
    func handleConversationVisibilityChange() async {
        guard selectedConversationIsVisible() else { return }
        guard let client, let activeAccount, let selectedChat else { return }
        await markLatestVisibleMessageRead(
            groupIdHex: selectedChat.id,
            account: activeAccount,
            client: client
        )
    }
}
