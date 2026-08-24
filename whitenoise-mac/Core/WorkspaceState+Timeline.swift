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

/// Ownership token for subscription, initial-load, or post-send timeline applies.
/// Re-checked after every suspension in window and projection paths so a superseded
/// listener or query cannot overwrite a replacement for the same account/chat.
enum TimelineWindowOwner {
    case subscription(TimelineMessagesSubscription)
    case loadGeneration(UInt64)
    case postSendRefresh(generation: UInt64, subscription: TimelineMessagesSubscription?)
}

@MainActor
extension WorkspaceState {
    func loadMessages(groupIdHex: String) async {
        let draftAccountId = activeAccountId
        if let draftAccountId {
            await restoreComposerDraftIfNeeded(accountId: draftAccountId, groupIdHex: groupIdHex)
        }
        if timelineTaskGroupId == groupIdHex, ensureMessageTimelineStore(for: groupIdHex).isLoaded {
            if let draftAccountId, activeAccountId == draftAccountId {
                hydrateRestoredReplyContext(accountId: draftAccountId, groupIdHex: groupIdHex)
            }
            finishTimelineInitialLoad(groupIdHex: groupIdHex)
            return
        }

        guard client != nil, let activeAccount else {
            cancelTimelineLoad()
            finishTimelineInitialLoad(groupIdHex: groupIdHex)
            return
        }
        let accountId = activeAccount.id

        if let existing = timelineLoadTask,
            timelineLoadGroupId == groupIdHex,
            timelineLoadAccountId == accountId
        {
            // Same-account duplicate loads join the owner task; its defer clears the spinner.
            await existing.value
            if let draftAccountId, activeAccountId == draftAccountId {
                hydrateRestoredReplyContext(accountId: draftAccountId, groupIdHex: groupIdHex)
            }
            return
        }

        timelineLoadTask?.cancel()
        timelineLoadGeneration &+= 1
        let generation = timelineLoadGeneration
        let task = Task<Void, Never> { [weak self] in
            await self?.performTimelineLoad(
                groupIdHex: groupIdHex,
                accountId: accountId,
                generation: generation
            )
        }
        timelineLoadTask = task
        timelineLoadGroupId = groupIdHex
        timelineLoadAccountId = accountId

        await task.value
        if let draftAccountId, activeAccountId == draftAccountId {
            hydrateRestoredReplyContext(accountId: draftAccountId, groupIdHex: groupIdHex)
        }

        if timelineLoadTask == task {
            timelineLoadTask = nil
            timelineLoadGroupId = nil
            timelineLoadAccountId = nil
        }
    }

    func performTimelineLoad(groupIdHex: String, accountId: String, generation: UInt64) async {
        guard let client, let activeAccount, activeAccount.id == accountId else {
            if ownsTimelineLoad(generation: generation, accountId: accountId, groupIdHex: groupIdHex) {
                finishTimelineInitialLoad(groupIdHex: groupIdHex)
            }
            return
        }
        guard canContinueTimelineLoad(generation: generation, accountId: accountId, groupIdHex: groupIdHex) else {
            return
        }
        if timelineTaskGroupId == groupIdHex, ensureMessageTimelineStore(for: groupIdHex).isLoaded {
            // `loadMessages` checks this before spawning, but the store may become loaded while
            // this task waits for the main actor; keep the defensive in-task short-circuit.
            finishTimelineInitialLoad(groupIdHex: groupIdHex)
            return
        }
        stopTimelineListener()
        guard canContinueTimelineLoad(generation: generation, accountId: accountId, groupIdHex: groupIdHex),
            selectedChat?.id == groupIdHex
        else {
            if ownsTimelineLoad(generation: generation, accountId: accountId, groupIdHex: groupIdHex) {
                finishTimelineInitialLoad(groupIdHex: groupIdHex)
            }
            return
        }
        beginTimelineInitialLoadIfNeeded(groupIdHex: groupIdHex)
        defer {
            if ownsTimelineLoad(generation: generation, accountId: accountId, groupIdHex: groupIdHex) {
                finishTimelineInitialLoad(groupIdHex: groupIdHex)
            }
        }
        do {
            let accountRef = activeAccount.accountRef
            if let row = try await FFIExecutor.run({
                try client.initializeChatReadState(accountRef: accountRef, groupIdHex: groupIdHex)
            }) {
                guard
                    canContinueTimelineLoad(
                        generation: generation,
                        accountId: accountId,
                        groupIdHex: groupIdHex
                    )
                else { return }
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
            guard canContinueTimelineLoad(generation: generation, accountId: accountId, groupIdHex: groupIdHex),
                selectedChat?.id == groupIdHex
            else { return }

            let snapshot = try await FFIExecutor.run { subscription.snapshot() }
            guard canContinueTimelineLoad(generation: generation, accountId: accountId, groupIdHex: groupIdHex),
                selectedChat?.id == groupIdHex
            else { return }
            let page =
                snapshot
                ?? TimelinePageFfi(
                    messages: [],
                    hasMoreBefore: false,
                    hasMoreAfter: false
                )
            await applyTimelineWindow(
                page,
                groupIdHex: groupIdHex,
                account: activeAccount,
                client: client,
                owner: .loadGeneration(generation)
            )
            guard canContinueTimelineLoad(generation: generation, accountId: accountId, groupIdHex: groupIdHex),
                selectedChat?.id == groupIdHex
            else { return }
            // Start the listener first (it tears down any prior listener, which would clear
            // these), then record the subscription so scroll-back pagination can reach it.
            // `startTimelineListener` can bail without starting a task (e.g. selection changed
            // while we awaited above); only record the subscription when it actually started,
            // otherwise we leak a live handle with no `next()` loop draining it.
            startTimelineListener(groupIdHex: groupIdHex, account: activeAccount, subscription: subscription)
            guard canContinueTimelineLoad(generation: generation, accountId: accountId, groupIdHex: groupIdHex),
                timelineTaskGroupId == groupIdHex
            else { return }
            activeTimelineSubscription = subscription
            activeTimelineGroupId = groupIdHex
        } catch is CancellationError {
            return
        } catch {
            guard ownsTimelineLoad(generation: generation, accountId: accountId, groupIdHex: groupIdHex) else { return }
            lastError = error.localizedDescription
        }
    }

    func ownsTimelineLoad(generation: UInt64, accountId: String, groupIdHex: String) -> Bool {
        timelineLoadGeneration == generation
            && timelineLoadAccountId == accountId
            && timelineLoadGroupId == groupIdHex
            && activeAccountId == accountId
    }

    func canContinueTimelineLoad(generation: UInt64, accountId: String, groupIdHex: String) -> Bool {
        ownsTimelineLoad(generation: generation, accountId: accountId, groupIdHex: groupIdHex)
            && !Task.isCancelled
    }

    func cancelTimelineLoad() {
        timelineLoadTask?.cancel()
        timelineLoadTask = nil
        timelineLoadGroupId = nil
        timelineLoadAccountId = nil
        timelineLoadGeneration &+= 1
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
            guard activeAccountId == activeAccount.id,
                selectedChat?.id == groupIdHex,
                activeTimelineGroupId == groupIdHex,
                activeTimelineSubscription === subscription
            else { return }
            await applyTimelineWindow(
                page,
                groupIdHex: groupIdHex,
                account: activeAccount,
                client: client,
                owner: .subscription(subscription)
            )
        } catch {
            guard activeAccountId == activeAccount.id,
                selectedChat?.id == groupIdHex,
                activeTimelineGroupId == groupIdHex,
                activeTimelineSubscription === subscription
            else { return }
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
            guard activeAccountId == activeAccount.id,
                selectedChat?.id == groupIdHex,
                activeTimelineGroupId == groupIdHex,
                activeTimelineSubscription === subscription
            else { return }
            await applyTimelineWindow(
                page,
                groupIdHex: groupIdHex,
                account: activeAccount,
                client: client,
                owner: .subscription(subscription)
            )
        } catch {
            guard activeAccountId == activeAccount.id,
                selectedChat?.id == groupIdHex,
                activeTimelineGroupId == groupIdHex,
                activeTimelineSubscription === subscription
            else { return }
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
        client: any MarmotRuntime,
        owner: TimelineWindowOwner
    ) async {
        guard
            canApplyTimelineWindow(
                groupIdHex: groupIdHex,
                accountId: account.id,
                owner: owner
            )
        else { return }
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
        let mentionNames = cachedMentionNames(groupIdHex: groupIdHex)
        guard
            canApplyTimelineWindow(
                groupIdHex: groupIdHex,
                accountId: account.id,
                owner: owner
            )
        else { return }

        #if DEBUG
            await passTimelineApplyMapGateIfArmed()
            guard
                canApplyTimelineWindow(
                    groupIdHex: groupIdHex,
                    accountId: account.id,
                    owner: owner
                )
            else { return }
        #endif

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
                senderProfiles: senderProfiles,
                mentionNames: mentionNames
            )
        }
        guard
            canApplyTimelineWindow(
                groupIdHex: groupIdHex,
                accountId: account.id,
                owner: owner
            )
        else { return }

        let editMutations = MessageEditOverlay.mutations(from: page.messages)
        let currentPaging = timelinePagingByChat[groupIdHex]
        // Keep "Delete for me" hides out of every full window replace, not just the incremental path.
        let visibleMessages = filterHiddenMessages(mappedMessages, groupIdHex: groupIdHex)
        let didChangeMediaAttachments = TimelineSignpost.store.interval(
            "replaceMessages", count: visibleMessages.count
        ) {
            replaceMessages(
                visibleMessages,
                groupIdHex: groupIdHex,
                paging: TimelinePagingState(
                    hasMoreBefore: page.hasMoreBefore,
                    hasMoreAfter: page.hasMoreAfter,
                    isLoadingBefore: currentPaging?.isLoadingBefore ?? false,
                    isLoadingAfter: currentPaging?.isLoadingAfter ?? false
                ),
                editMutations: editMutations
            )
        }
        if didChangeMediaAttachments {
            clearMediaReferenceResolutionCache(forAccountId: account.id, groupIdHex: groupIdHex)
        }
        await markLatestVisibleMessageRead(groupIdHex: groupIdHex, account: account, client: client)
    }

    private func canApplyTimelineWindow(
        groupIdHex: String,
        accountId: String,
        owner: TimelineWindowOwner?
    ) -> Bool {
        guard activeAccountId == accountId, selectedChat?.id == groupIdHex else { return false }
        guard let owner else { return true }
        switch owner {
        case .subscription(let expectedSubscription):
            guard activeTimelineGroupId == groupIdHex,
                activeTimelineSubscription === expectedSubscription
            else { return false }
        case .loadGeneration(let generation):
            guard ownsTimelineLoad(generation: generation, accountId: accountId, groupIdHex: groupIdHex)
            else { return false }
        case .postSendRefresh(let generation, let expectedSubscription):
            guard timelinePostSendRefreshGeneration == generation else { return false }
            if let expectedSubscription {
                guard activeTimelineGroupId == groupIdHex,
                    activeTimelineSubscription === expectedSubscription
                else { return false }
            } else {
                guard activeTimelineSubscription == nil, activeTimelineGroupId == nil else { return false }
            }
        }
        return true
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
        client: any MarmotRuntime,
        subscription: TimelineMessagesSubscription
    ) async {
        switch update {
        case .page(let page):
            await applyTimelineWindow(
                page,
                groupIdHex: groupIdHex,
                account: account,
                client: client,
                owner: .subscription(subscription)
            )
        case .projection(let runtimeUpdate):
            await applyTimelineProjection(
                runtimeUpdate.update,
                groupIdHex: groupIdHex,
                account: account,
                client: client,
                owner: .subscription(subscription)
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
        client: any MarmotRuntime,
        owner: TimelineWindowOwner? = nil
    ) async {
        guard
            canApplyTimelineWindow(
                groupIdHex: groupIdHex,
                accountId: account.id,
                owner: owner
            )
        else { return }
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
        let editMutations = MessageEditOverlay.mutations(from: upsertRecords)
        guard !upsertRecords.isEmpty || !removalIds.isEmpty || !editMutations.isEmpty else { return }

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
        let mentionNames = cachedMentionNames(groupIdHex: groupIdHex)
        guard
            canApplyTimelineWindow(
                groupIdHex: groupIdHex,
                accountId: account.id,
                owner: owner
            )
        else { return }

        #if DEBUG
            await passTimelineApplyMapGateIfArmed()
            guard
                canApplyTimelineWindow(
                    groupIdHex: groupIdHex,
                    accountId: account.id,
                    owner: owner
                )
            else { return }
        #endif
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
                senderProfiles: senderProfiles,
                mentionNames: mentionNames
            )
        }
        guard
            canApplyTimelineWindow(
                groupIdHex: groupIdHex,
                accountId: account.id,
                owner: owner
            )
        else { return }

        let paging = timelinePagingByChat[groupIdHex] ?? .empty
        // The window is "anchored" to the live head while there is no newer history to
        // page toward. A detached (scrolled-back) window must not grow a new head row —
        // the user re-anchors via forward pagination — so a brand-new message that sorts
        // strictly after the window's newest row is suppressed, exactly as the runtime
        // does. Existing rows still update in place (edits, reactions, delivery state).
        let anchored = !paging.hasMoreAfter
        let timelineStore = ensureMessageTimelineStore(for: groupIdHex)

        guard
            canApplyTimelineWindow(
                groupIdHex: groupIdHex,
                accountId: account.id,
                owner: owner
            )
        else { return }

        // Keep "Delete for me" messages out of the window across every reprojection.
        let (visibleUpserts, visibleRemovals) = partitionHiddenMessages(
            upserts: mappedUpserts, removals: removalIds, groupIdHex: groupIdHex)
        let result = TimelineSignpost.store.interval(
            "applyProjection", count: visibleUpserts.count + visibleRemovals.count
        ) {
            timelineStore.applyProjection(
                upserts: visibleUpserts,
                removals: visibleRemovals,
                editMutations: editMutations,
                anchoredToNewest: anchored,
                windowLimit: Self.timelineWindowLimit
            )
        }
        guard result.didChange else { return }

        if result.didChangeMediaAttachments {
            clearMediaReferenceResolutionCache(forAccountId: account.id, groupIdHex: groupIdHex)
        }

        finalizeTimelineStoreMutation(
            groupIdHex: groupIdHex,
            paging: TimelinePagingState(
                hasMoreBefore: paging.hasMoreBefore || result.didTrimOlderMessages,
                hasMoreAfter: paging.hasMoreAfter,
                isLoadingBefore: paging.isLoadingBefore,
                isLoadingAfter: paging.isLoadingAfter
            ),
            pruneMediaDownloads: result.didRemoveMessages
                || result.didTrimOlderMessages
                || result.didChangeMediaAttachments
        )
        await markLatestVisibleMessageRead(groupIdHex: groupIdHex, account: account, client: client)
    }

    func startReply(to message: MessageItem) {
        guard message.supportsChatActions else { return }
        // Media uploads cannot carry a reply target yet, so reply and pending media are
        // mutually exclusive — starting a reply drops any staged attachments.
        if let draftKey = selectedComposerDraftKey {
            pendingMediaAttachmentsByConversation[draftKey]?.forEach { cancelPendingMediaUpload($0.id) }
            pendingMediaAttachmentsByConversation[draftKey] = nil
            pendingMediaUploadStatesByConversation[draftKey] = nil
        }
        replyDraftContext = MessageReplyContext(
            targetMessageId: message.id,
            senderName: message.senderName,
            body: message.replyPreviewText
        )
    }

    func cancelReply() {
        replyDraftContext = nil
    }

    func startEditingMessage(_ message: MessageItem) {
        guard message.canEdit, let draftKey = selectedComposerDraftKey else { return }
        guard editingMessageContextByConversation[draftKey] == nil else { return }
        cancelVoiceRecording()
        let preservedDraft = draftTextByConversation[draftKey] ?? ""
        editingMessageContextByConversation[draftKey] = MessageEditContext(
            targetMessageId: message.id,
            senderName: message.senderName,
            originalBody: message.body,
            preservedDraft: preservedDraft,
            preservedMentionSelections: composerMentionSelectionsByConversation[draftKey] ?? [],
            preservedReplyContext: replyDraftContextByConversation[draftKey],
            preservedMediaAttachments: pendingMediaAttachmentsByConversation[draftKey] ?? [],
            preservedMediaUploadStates: pendingMediaUploadStatesByConversation[draftKey] ?? [:]
        )
        replyDraftContextByConversation[draftKey] = nil
        pendingMediaAttachmentsByConversation[draftKey] = nil
        pendingMediaUploadStatesByConversation[draftKey] = nil
        draftTextByConversation[draftKey] = message.wireBody
        composerMentionSelectionsByConversation[draftKey] = nil
    }

    func cancelEditingMessage() {
        guard let draftKey = selectedComposerDraftKey,
            let edit = editingMessageContextByConversation.removeValue(forKey: draftKey)
        else { return }
        draftTextByConversation[draftKey] = edit.preservedDraft.isEmpty ? nil : edit.preservedDraft
        composerMentionSelectionsByConversation[draftKey] =
            edit.preservedMentionSelections.isEmpty ? nil : edit.preservedMentionSelections
        replyDraftContextByConversation[draftKey] = edit.preservedReplyContext
        pendingMediaAttachmentsByConversation[draftKey] =
            edit.preservedMediaAttachments.isEmpty ? nil : edit.preservedMediaAttachments
        pendingMediaUploadStatesByConversation[draftKey] =
            edit.preservedMediaUploadStates.isEmpty ? nil : edit.preservedMediaUploadStates
    }

    func copyText(of message: MessageItem) {
        guard message.canCopyText else { return }
        copyText(message.body)
    }

    /// Whether the conversation this row belongs to is re-driving its pending sends right now.
    ///
    /// Group-scoped like the retry itself: `retryGroupConvergence` re-drives every operation the
    /// core has committed for the chat, so a retry started from one failed bubble really is
    /// carrying its neighbours too, and they say so.
    func isRetryingDelivery(of message: MessageItem) -> Bool {
        guard let activeAccountId, let selectedChat, selectedChat.id == message.groupIdHex else { return false }
        return inFlightMessageRetryScopes.contains(
            Self.messageRetryScope(accountId: activeAccountId, groupIdHex: selectedChat.id)
        )
    }

    /// The delivery marker a row should wear at `now`, with an in-flight retry folded in.
    ///
    /// A retry puts the send back in the state a first attempt is in, so the row goes back to
    /// reading "Sending" — the clock in the bubble's own footer — rather than keeping the failure
    /// marker and announcing the retry in a line underneath it. That also takes the recovery row
    /// down for the length of the retry, since it is gated on the same marker: there is nothing to
    /// retry or delete while the retry is the thing running.
    ///
    /// Group-scoped through `isRetryingDelivery`, like the core call: every failed row in the chat
    /// is being carried by this retry, so they all go back to "Sending" together. Rows that are not
    /// failed are left exactly as they were.
    func deliveryIndicator(for message: MessageItem, at now: Date) -> MessageDeliveryIndicator {
        let indicator = message.deliveryIndicator(at: now)
        guard indicator == .failed, isRetryingDelivery(of: message) else { return indicator }
        return .sending
    }

    func retryDelivery(of message: MessageItem) async {
        guard message.canRetryDelivery(at: .now),
            let client,
            let activeAccount,
            let activeAccountId,
            let selectedChat,
            selectedChat.id == message.groupIdHex
        else { return }

        let retryScope = Self.messageRetryScope(accountId: activeAccountId, groupIdHex: selectedChat.id)
        guard !inFlightMessageRetryScopes.contains(retryScope) else { return }
        inFlightMessageRetryScopes.insert(retryScope)
        defer { inFlightMessageRetryScopes.remove(retryScope) }

        do {
            // Retry the core's already-committed pending operation. Re-sending `wireBody`
            // would create a second MLS commit and a duplicate chat bubble.
            _ = try await client.retryGroupConvergence(
                accountRef: activeAccount.accountRef,
                groupIdHex: selectedChat.id
            )
            await refreshSelectedTimelineAfterSend(
                groupIdHex: selectedChat.id,
                account: activeAccount,
                client: client
            )
        } catch {
            lastError = error.localizedDescription
        }
    }

    /// Unit separator, so an account id and a group id cannot run together into the same scope.
    private static func messageRetryScope(accountId: String, groupIdHex: String) -> String {
        "\(accountId)\u{1F}\(groupIdHex)"
    }

    var isTimelineSelectionMode: Bool {
        !selectedTimelineMessageIds.isEmpty
    }

    var selectedTimelineMessagesForAction: [MessageItem] {
        selectedMessages.filter { selectedTimelineMessageIds.contains($0.id) }
    }

    func beginMessageSelection(_ message: MessageItem) {
        guard message.presentation.isChatBubble else { return }
        selectedTimelineMessageIds = [message.id]
    }

    func toggleMessageSelection(_ message: MessageItem) {
        guard message.presentation.isChatBubble else { return }
        if selectedTimelineMessageIds.contains(message.id) {
            selectedTimelineMessageIds.remove(message.id)
        } else {
            selectedTimelineMessageIds.insert(message.id)
        }
    }

    func cancelMessageSelection() {
        selectedTimelineMessageIds.removeAll()
    }

    func showMessageInfo(_ message: MessageItem) {
        messageInfoTarget = message
    }

    func startForwarding(_ messages: [MessageItem]) {
        let ids = messages.filter(\.canForward).map(\.id)
        guard !ids.isEmpty else { return }
        forwardingMessageIds = ids
        isForwardPickerPresented = true
    }

    func cancelForwarding() {
        forwardingMessageIds = []
        isForwardPickerPresented = false
    }

    func forwardPendingMessages(to chat: ChatItem) async {
        guard !isForwardingMessages,
            chat.canUseComposer,
            let client,
            let activeAccount
        else { return }
        let messages = selectedMessages.filter { forwardingMessageIds.contains($0.id) && $0.canForward }
        guard !messages.isEmpty else { return }

        isForwardingMessages = true
        defer { isForwardingMessages = false }
        do {
            for message in messages {
                _ = try await client.sendText(
                    accountRef: activeAccount.accountRef,
                    groupIdHex: chat.id,
                    text: message.wireBody
                )
            }
            cancelForwarding()
            cancelMessageSelection()
        } catch {
            lastError = error.localizedDescription
        }
    }

    func messageDeletionTarget(for message: MessageItem) -> MessageDeletionTarget? {
        guard message.supportsChatActions, let selectedChat, let activeAccount, let activeAccountId else {
            return nil
        }
        return MessageDeletionTarget(
            message: message,
            accountId: activeAccountId,
            accountRef: activeAccount.accountRef,
            groupIdHex: selectedChat.id,
            isDirectConversation: selectedChat.isDirect,
            isSelfGroupAdmin: conversationMetadataByChat[selectedChat.id]?.isSelfAdmin == true
        )
    }

    /// The authoritative deletion-scope model captured when the action was opened. Both the action
    /// UI and mutation path use this immutable target; the engine remains the final authority.
    func messageDeletionCapability(_ target: MessageDeletionTarget) -> MessageDeletionCapability {
        let message = target.message
        guard message.supportsChatActions else { return .none }
        return MessageDeletionCapability.resolve(
            isActionable: true,
            isDirectConversation: target.isDirectConversation,
            isOwnMessage: message.isOutgoing,
            isSelfGroupAdmin: target.isSelfGroupAdmin
        )
    }

    func messageDeletionCapability(_ message: MessageItem) -> MessageDeletionCapability {
        guard let target = messageDeletionTarget(for: message) else { return .none }
        return messageDeletionCapability(target)
    }

    func canDeleteMessage(_ message: MessageItem) -> Bool {
        messageDeletionCapability(message).canDelete
    }

    /// Adaptive supporting copy for the delete-confirmation surface. Explains the offered scopes
    /// without admin-branding the action, per the unified model.
    func messageDeletionScopeExplanation(_ target: MessageDeletionTarget) -> String {
        let message = target.message
        let capability = messageDeletionCapability(target)
        guard capability.canDeleteForEveryone else {
            return L10n.string("This message will be hidden on this device only.")
        }
        if message.isOutgoing {
            return L10n.string("Remove this message for everyone, or hide it just for you.")
        }
        return L10n.string("Remove this message for everyone in the group, or hide it just for you.")
    }

    func deleteSelectedMessages() async {
        // Multi-select acts only on messages the user may delete for everyone — it must not
        // silently mix in local hides; single-message delete-for-me goes through the confirmation.
        let targets = selectedTimelineMessagesForAction.compactMap { message -> MessageDeletionTarget? in
            guard let target = messageDeletionTarget(for: message),
                messageDeletionCapability(target).canDeleteForEveryone
            else { return nil }
            return target
        }
        guard !targets.isEmpty else { return }
        for target in targets {
            await deleteForEveryone(target)
        }
        cancelMessageSelection()
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

    /// Ordered edit history (oldest first) for `message` in the selected conversation, or empty
    /// when it was never edited. Derived from the timeline store's retained edit overlays.
    func editHistory(for message: MessageItem) -> [MessageEditVersion] {
        guard case .chat(let groupIdHex) = selection,
            let store = messageTimelineStores[groupIdHex]
        else { return [] }
        return store.editHistory(forTarget: message.id)
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
        guard let client, let activeAccount, let activeAccountId, let selectedChat else { return }
        // Reentrancy guard: the removal deletes the reaction event, so key on its id
        // (shared namespace with `deleteMessage`) to drop a repeated in-flight removal.
        let inFlightKey = deleteInFlightKey(
            accountId: activeAccountId,
            groupIdHex: selectedChat.id,
            messageId: reactionMessageId
        )
        guard !inFlightDeleteMessageIds.contains(inFlightKey) else { return }
        inFlightDeleteMessageIds.insert(inFlightKey)
        defer { inFlightDeleteMessageIds.remove(inFlightKey) }
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

    /// Delete for everyone: publish a group-wide tombstone (self-retraction, or an admin moderating
    /// another member's group message). Re-checks the capability so a mis-rendered option can't
    /// drive an unauthorized retraction — the engine is the final authority, this is the local guard.
    func deleteForEveryone(_ message: MessageItem) async {
        guard let target = messageDeletionTarget(for: message) else { return }
        await deleteForEveryone(target)
    }

    func deleteForEveryone(_ target: MessageDeletionTarget) async {
        let message = target.message
        guard let client, messageDeletionCapability(target).canDeleteForEveryone else { return }
        // Reentrancy guard: drop a repeated delete of the same in-flight message.
        let inFlightKey = deleteInFlightKey(
            accountId: target.accountId,
            groupIdHex: target.groupIdHex,
            messageId: message.id
        )
        guard !inFlightDeleteMessageIds.contains(inFlightKey) else { return }
        inFlightDeleteMessageIds.insert(inFlightKey)
        defer { inFlightDeleteMessageIds.remove(inFlightKey) }
        do {
            _ = try await client.deleteMessage(
                accountRef: target.accountRef,
                groupIdHex: target.groupIdHex,
                targetMessageId: message.id
            )
            clearComposerContextTargeting(message.id, target: target)
        } catch {
            lastError = error.localizedDescription
        }
    }

    /// Delete for me: hide the message locally and persist the hidden id. Publishes nothing.
    func deleteForMe(_ message: MessageItem) {
        guard let target = messageDeletionTarget(for: message) else { return }
        deleteForMe(target)
    }

    func deleteForMe(_ target: MessageDeletionTarget) {
        let message = target.message
        guard messageDeletionCapability(target).canDeleteForMe else { return }
        hideMessageLocally(accountId: target.accountId, groupIdHex: target.groupIdHex, messageId: message.id)
        clearComposerContextTargeting(message.id, target: target)
    }

    private func deleteInFlightKey(accountId: String, groupIdHex: String, messageId: String) -> String {
        "\(accountId)\u{1F}\(groupIdHex)\u{1F}\(messageId)"
    }

    /// Drop any reply or in-progress edit in the selected conversation that targets `messageId`,
    /// so a deleted message can't remain a live reply/edit target.
    private func clearComposerContextTargeting(_ messageId: String, target: MessageDeletionTarget) {
        let draftKey = ComposerDraftKey(accountId: target.accountId, chatId: target.groupIdHex)
        var didChangeDraft = false
        if replyDraftContextByConversation[draftKey]?.targetMessageId == messageId {
            replyDraftContextByConversation[draftKey] = nil
            didChangeDraft = true
        }
        if let edit = editingMessageContextByConversation[draftKey],
            edit.targetMessageId == messageId
        {
            editingMessageContextByConversation[draftKey] = nil
            draftTextByConversation[draftKey] = edit.preservedDraft.isEmpty ? nil : edit.preservedDraft
            composerMentionSelectionsByConversation[draftKey] =
                edit.preservedMentionSelections.isEmpty ? nil : edit.preservedMentionSelections
            replyDraftContextByConversation[draftKey] = edit.preservedReplyContext
            pendingMediaAttachmentsByConversation[draftKey] =
                edit.preservedMediaAttachments.isEmpty ? nil : edit.preservedMediaAttachments
            pendingMediaUploadStatesByConversation[draftKey] =
                edit.preservedMediaUploadStates.isEmpty ? nil : edit.preservedMediaUploadStates
        }
        if didChangeDraft {
            composerDraftDidChange(for: draftKey)
        }
    }

    func sendDraft() async {
        let text = canonicalizeMentions(in: draftText, selections: composerMentionSelections)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let mediaAttachments = pendingMediaAttachments
        // `!isSending` is the reentrancy guard: `isSending` flips synchronously here, but an
        // edit only restores its preserved draft at the `await` below. Without this guard a
        // second invocation delivered before SwiftUI re-renders the disabled send button
        // (Return auto-repeat, double events) would still observe the old `draftText` and
        // re-send the same message. A new draft empties its composer synchronously
        // (`sendNewDraftIfPossible`), so there the guard is the second line of defence.
        guard let client,
            let activeAccount,
            let selectedChat,
            // Mirrors `canSend`: the core rejects sends while an invite is pending,
            // or once the local account left/was removed (`invalid_transition`).
            selectedChat.canUseComposer,
            let draftKey = selectedComposerDraftKey,
            let editContext = editingMessageContextByConversation[draftKey],
            !text.isEmpty || !mediaAttachments.isEmpty,
            !isSending
        else {
            await sendNewDraftIfPossible(text: text, mediaAttachments: mediaAttachments)
            return
        }
        isSending = true
        defer { isSending = false }

        do {
            _ = try await client.editMessage(
                accountRef: activeAccount.accountRef,
                groupIdHex: selectedChat.id,
                targetMessageId: editContext.targetMessageId,
                content: text
            )
            editingMessageContextByConversation[draftKey] = nil
            draftTextByConversation[draftKey] = editContext.preservedDraft.isEmpty ? nil : editContext.preservedDraft
            composerMentionSelectionsByConversation[draftKey] =
                editContext.preservedMentionSelections.isEmpty ? nil : editContext.preservedMentionSelections
            replyDraftContextByConversation[draftKey] = editContext.preservedReplyContext
            pendingMediaAttachmentsByConversation[draftKey] =
                editContext.preservedMediaAttachments.isEmpty ? nil : editContext.preservedMediaAttachments
            pendingMediaUploadStatesByConversation[draftKey] =
                editContext.preservedMediaUploadStates.isEmpty ? nil : editContext.preservedMediaUploadStates
            await refreshSelectedTimelineAfterSend(groupIdHex: selectedChat.id, account: activeAccount, client: client)
        } catch {
            lastError = error.localizedDescription
        }
    }

    private func sendNewDraftIfPossible(text: String, mediaAttachments: [PendingMediaAttachment]) async {
        guard let client,
            let activeAccount,
            let selectedChat,
            selectedChat.canUseComposer,
            let draftKey = selectedComposerDraftKey,
            editingMessageContextByConversation[draftKey] == nil,
            !text.isEmpty || !mediaAttachments.isEmpty,
            !isSending
        else { return }
        isSending = true
        defer { isSending = false }
        // Past the guards, so a send the core would refuse never moves the transcript. Both
        // branches below empty the composer synchronously from here, so the bubble the user is
        // scrolled to — pending or real — is part of the same view update.
        outgoingSendScrollGeneration &+= 1

        if !mediaAttachments.isEmpty {
            // Hand the send off and return. Staging started every upload the moment the file
            // was attached, so most of the time the blobs are already on Blossom — but when
            // they are not, the wait belongs to the message's bubble, not to the Send button
            // (#710 blocked the button; this is the hybrid that does not).
            handOffMediaSend(
                mediaAttachments,
                caption: text,
                draftKey: draftKey,
                account: activeAccount,
                client: client
            )
            await deletePersistedComposerDraft(
                for: draftKey,
                accountRef: activeAccount.accountRef,
                client: client
            )
            return
        }

        // Text empties the composer on hand-off too, before the publish rather than after it.
        // Clearing only once `sendText`/`replyToMessage` returned meant the draft sat in the
        // input for the whole relay round-trip — and since the message's own bubble appears
        // from the local projection as soon as it is stored, the user saw the same text twice.
        // What the composer gives up, the pending message below takes over: the transcript carries
        // the message from here until the core has a row of its own for it.
        let pending = PendingOutgoingTextMessage(
            text: text,
            replyContext: replyDraftContextByConversation[draftKey]
        )
        clearComposerAfterSend(for: draftKey, mediaAttachments: mediaAttachments)
        // Parked in the same view update that empties the composer, and before the `await` below:
        // deleting the persisted draft yields the main actor, so registering the row after it would
        // leave a frame with the message in neither place — the disappearance this whole path
        // exists to prevent. The media branch above hands off ahead of its own delete for the
        // same reason.
        beginPendingOutgoingTextSend(
            pending,
            for: draftKey,
            account: activeAccount,
            client: client
        )
        await deletePersistedComposerDraft(
            for: draftKey,
            accountRef: activeAccount.accountRef,
            client: client
        )
    }

    /// Drops both halves of every outgoing text send: the publish chain and the pending rows that
    /// chain is carrying. They are torn down together because a parked message whose publish task is
    /// gone is a bubble that can never resolve — it would sit in the transcript claiming to be on its
    /// way out with nothing left to send it.
    func cancelAllOutgoingTextSends() {
        for task in outgoingTextSendTasks.values {
            task.cancel()
        }
        outgoingTextSendTasks.removeAll()
        cancelAllPendingOutgoingTextSends()
    }

    func cancelOutgoingTextSends(for draftKey: ComposerDraftKey) {
        outgoingTextSendTasks.removeValue(forKey: draftKey)?.cancel()
        cancelPendingOutgoingTextSends(for: draftKey)
    }

    func cancelOutgoingTextSends(forAccountId accountId: String) {
        for draftKey in outgoingTextSendTasks.keys.filter({ $0.accountId == accountId }) {
            outgoingTextSendTasks.removeValue(forKey: draftKey)?.cancel()
        }
        cancelPendingOutgoingTextSends(forAccountId: accountId)
    }

    /// Moves a media draft out of the composer and into a pending outgoing message, then returns.
    ///
    /// The uploads staging started are *detached* rather than cancelled: the composer clear that
    /// follows would otherwise kill the very transfers the new bubble is about to wait on. An
    /// attachment whose upload already finished contributes its reference directly, and one whose
    /// upload failed contributes nothing — the send re-uploads it.
    private func handOffMediaSend(
        _ mediaAttachments: [PendingMediaAttachment],
        caption: String,
        draftKey: ComposerDraftKey,
        account: AccountItem,
        client: any MarmotRuntime
    ) {
        let uploadStates = pendingMediaUploadStatesByConversation[draftKey] ?? [:]
        var adoptedUploads: [PendingMediaAttachment.ID: Task<MediaAttachmentReferenceFfi?, Never>] = [:]
        for attachment in mediaAttachments {
            if let reference = uploadStates[attachment.id]?.reference {
                // Wrapping a finished reference as a task keeps the send routine on one code path
                // instead of branching on whether staging beat the user to it.
                adoptedUploads[attachment.id] = Task { reference }
            } else if let inFlight = detachPendingMediaUpload(attachment.id) {
                adoptedUploads[attachment.id] = inFlight
            }
        }
        // A recording goes out as audio and nothing else. Staging one already empties the composer
        // and blocks every other staging path, so this is the last line of that invariant rather
        // than a case the UI can reach. Dropping the caption here rather than at publish time also
        // keeps the pending bubble honest: it never shows a caption the message will not carry.
        let carriesVoiceMessage = mediaAttachments.contains(where: \.isVoiceMessage)
        clearComposerAfterSend(for: draftKey, mediaAttachments: mediaAttachments)
        beginPendingOutgoingMediaSend(
            PendingOutgoingMediaMessage(
                attachments: mediaAttachments,
                caption: carriesVoiceMessage ? "" : caption
            ),
            adoptedUploads: adoptedUploads,
            for: draftKey,
            account: account,
            client: client
        )
    }

    /// Empties one conversation's composer.
    ///
    /// Always clears via the captured `draftKey`, never the `draftText`/`replyDraftContext`
    /// setters — those resolve their key from the *live* selection, so if the user switched chats
    /// during a send they would wipe the newly selected conversation's composer instead of the one
    /// we sent from. Attachments staged *since* the snapshot survive: paste, drop and the importer
    /// all still work while a send is in flight.
    private func clearComposerAfterSend(
        for draftKey: ComposerDraftKey,
        mediaAttachments: [PendingMediaAttachment]
    ) {
        draftTextByConversation[draftKey] = nil
        composerMentionSelectionsByConversation[draftKey] = nil
        replyDraftContextByConversation[draftKey] = nil
        mediaAttachments.forEach { cancelPendingMediaUpload($0.id) }
        let sentIds = Set(mediaAttachments.map(\.id))
        let remainingAttachments = (pendingMediaAttachmentsByConversation[draftKey] ?? [])
            .filter { !sentIds.contains($0.id) }
        pendingMediaAttachmentsByConversation[draftKey] = remainingAttachments.isEmpty ? nil : remainingAttachments
        var remainingUploadStates = pendingMediaUploadStatesByConversation[draftKey] ?? [:]
        sentIds.forEach { remainingUploadStates[$0] = nil }
        pendingMediaUploadStatesByConversation[draftKey] = remainingUploadStates.isEmpty ? nil : remainingUploadStates
    }

    /// Files the plaintext we just published under the same cache key the bubble will look it up
    /// by, so an outgoing attachment renders from disk instead of round-tripping through Blossom.
    ///
    /// This is the durable copy, and it is what every render after the first one reads. The *first*
    /// frame of the published row cannot come from here — opening the container, decrypting and
    /// verifying is asynchronous, so a row that waited on it came up on a spinner over bytes this
    /// process was still holding; it is primed from the outgoing message's own attachments instead
    /// (`primeOwnSendMediaDownload`).
    func cacheOutgoingMediaPlaintext(
        _ attachments: [PendingMediaAttachment],
        references: [MediaAttachmentReferenceFfi],
        accountId: String,
        groupIdHex: String
    ) async {
        for (attachment, reference) in zip(attachments, references) {
            let cacheKey = MessageMediaDiskCacheKey(
                accountId: accountId,
                groupIdHex: groupIdHex,
                reference: reference
            )
            await mediaDiskCache.store(
                MessageMediaDownload(
                    data: attachment.data,
                    fileName: attachment.fileName,
                    mediaType: attachment.mediaType,
                    sizeBytes: UInt64(attachment.data.count),
                    // The id the cache would hand a read of this entry, so a row primed from the
                    // send's own plaintext and one that later re-reads it from disk share a payload
                    // identity — and with it one decoded image.
                    payloadId: cacheKey.payloadID
                ),
                for: cacheKey
            )
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
        timelinePostSendRefreshGeneration &+= 1
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
                    let page = try await FFIExecutor.run { subscription.snapshot() }
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
                            client: client,
                            owner: .subscription(subscription)
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
                        client: client,
                        subscription: subscription
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

    @discardableResult
    func replaceMessages(
        _ messages: [MessageItem],
        groupIdHex: String,
        paging: TimelinePagingState? = nil,
        editMutations: [MessageEditMutation] = []
    ) -> Bool {
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
        let didChangeMediaAttachments = timelineStore.replace(
            with: messages,
            editMutations: editMutations,
            windowLimit: Self.timelineWindowLimit
        )
        if timelinePagingByChat.count == 1, timelinePagingByChat[groupIdHex] != nil {
            timelinePagingByChat[groupIdHex] = nextPaging
        } else {
            timelinePagingByChat = [groupIdHex: nextPaging]
        }
        finishTimelineInitialLoad(groupIdHex: groupIdHex)
        pruneMediaDownloadCache(keeping: groupIdHex)
        return didChangeMediaAttachments
    }

    func finalizeTimelineStoreMutation(
        groupIdHex: String,
        paging: TimelinePagingState,
        pruneMediaDownloads: Bool
    ) {
        let timelineStore = ensureMessageTimelineStore(for: groupIdHex)
        for (storeGroupId, store) in messageTimelineStores where storeGroupId != groupIdHex {
            store.clear()
        }
        cachedMessageChatIds = [groupIdHex]
        messageTimelineStores = [groupIdHex: timelineStore]
        timelinePagingByChat = [groupIdHex: paging]
        finishTimelineInitialLoad(groupIdHex: groupIdHex)
        if pruneMediaDownloads {
            pruneMediaDownloadCache(keeping: groupIdHex)
        }
    }

    func refreshSelectedTimelineAfterSend(
        groupIdHex: String,
        account: AccountItem,
        client: any MarmotRuntime
    ) async {
        guard activeAccountId == account.id, selectedChat?.id == groupIdHex else { return }
        timelinePostSendRefreshGeneration &+= 1
        let refreshGeneration = timelinePostSendRefreshGeneration
        let subscription = activeTimelineGroupId == groupIdHex ? activeTimelineSubscription : nil
        let owner = TimelineWindowOwner.postSendRefresh(
            generation: refreshGeneration,
            subscription: subscription
        )
        let pageLimit = Self.timelinePageLimit
        do {
            let page = try await FFIExecutor.run {
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
            await applyTimelineWindow(
                page,
                groupIdHex: groupIdHex,
                account: account,
                client: client,
                owner: owner
            )
        } catch {
            guard
                canApplyTimelineWindow(groupIdHex: groupIdHex, accountId: account.id, owner: owner)
            else { return }
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
            let row = try await FFIExecutor.run({
                try client.markTimelineMessageRead(
                    accountRef: accountRef,
                    groupIdHex: groupIdHex,
                    messageIdHex: messageId
                )
            })
            // Read-marker bookkeeping belongs to the account/group, not to the currently
            // selected conversation. Navigating to another chat while the FFI is in flight
            // must not discard a successful commit or leave the confirmed marker stale.
            guard activeAccountId == account.id else { return }
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
            // Account switches clear these dictionaries, so never repopulate them for a stale
            // account. A same-account chat switch is different: roll back the per-group slot so
            // returning to the conversation can retry the failed marker.
            guard activeAccountId == account.id else { return }
            lastMarkedReadMarkers[groupIdHex] = ReadMarker.afterFailedOptimisticAdvance(
                current: lastMarkedReadMarkers[groupIdHex],
                attempted: marker,
                confirmed: lastConfirmedReadMarkers[groupIdHex]
            )
            if selectedChat?.id == groupIdHex {
                setBackgroundStatus(error.localizedDescription)
            }
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
