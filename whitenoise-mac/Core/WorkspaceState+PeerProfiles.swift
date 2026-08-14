//
//  WorkspaceState+PeerProfiles.swift
//  whitenoise-mac
//
//  Relay-backed peer profile (kind:0) refresh, and the re-projection that makes a
//  late-arriving display name reach rows that were already rendered.
//
//  Two independent halves, and both are needed:
//
//  * **Pull.** `requestPeerProfileRefresh` asks the relays for a peer's kind:0 the
//    first time we see them. Before this existed, `refreshProfile` was wired only to
//    the local accounts and to a hand-typed New Chat recipient, so an inviter's or a
//    message sender's name appeared only once MDK's background directory sync happened
//    to watch that pubkey.
//  * **Re-project.** `schedulePeerProfileReprojection` replays the open conversation's
//    window and the affected sidebar rows once a name lands. `MessageItem.senderName`
//    is baked at projection time and the live delta path deliberately re-maps only
//    *changed* records, so without this a name resolved at T+90s never reaches a
//    message rendered at T+0.
//
//  Pull without re-projection fixes nothing visible; re-projection without pull has
//  nothing to show. iOS pairs `ProfileStore`'s fetch queue with
//  `refreshProfileDependentTimelineProjections`; Android pairs `requestProfile` with
//  `profileRevision`; Flutter pairs `resolve_user` with `subscribe_to_user`.
//

import Foundation
import MarmotKit

@MainActor
extension WorkspaceState {
    // MARK: - Pull

    /// Queues a relay kind:0 fetch for any of `accountIdHexes` we cannot already name.
    ///
    /// Safe to call unconditionally from the projection paths: ids whose cached lookup is
    /// already usable are dropped before the gate is consulted, using the precomputed
    /// `CachedPeerProfile.isComplete` flag, so the all-resolved steady state does no work
    /// beyond one dictionary lookup per id. That short-circuit is what makes the callers
    /// (every timeline window, every live delta, every roster) affordable.
    ///
    /// Not for view bodies. Callers that render per-frame (`reactionReactorDisplay`) read
    /// the observed cache instead and let a projection-path request fill it.
    func requestPeerProfileRefresh(_ accountIdHexes: some Sequence<String>) {
        guard client != nil, let activeAccount else { return }
        let now = nowProvider()
        var admitted: [String] = []

        for accountIdHex in accountIdHexes {
            guard !accountIdHex.isEmpty,
                accountIdHex != activeAccount.accountIdHex,
                peerProfileFFICache[accountIdHex]?.isComplete != true,
                peerProfileRefreshGate.tryStart(accountIdHex, now: now)
            else { continue }
            admitted.append(accountIdHex)
        }

        guard !admitted.isEmpty else { return }
        #if DEBUG
            peerProfileRefreshRequestCount += admitted.count
        #endif
        queuedPeerProfileRefreshIds.append(contentsOf: admitted)
        startPeerProfileRefreshQueueIfNeeded()
    }

    /// Single-id convenience for the render paths that resolve one peer at a time.
    func requestPeerProfileRefresh(_ accountIdHex: String) {
        requestPeerProfileRefresh(CollectionOfOne(accountIdHex))
    }

    private func startPeerProfileRefreshQueueIfNeeded() {
        guard peerProfileRefreshTask == nil, !queuedPeerProfileRefreshIds.isEmpty else { return }
        let taskId = UUID()
        peerProfileRefreshTaskId = taskId
        peerProfileRefreshTask = Task { [weak self] in
            await self?.runPeerProfileRefreshQueue(taskId: taskId)
        }
    }

    private func runPeerProfileRefreshQueue(taskId: UUID) async {
        defer { finishPeerProfileRefreshQueue(taskId: taskId) }

        while !Task.isCancelled {
            guard let client, let account = activeAccount else { return }
            let batch = nextQueuedPeerProfileRefreshIds(limit: Self.peerProfileRefreshFanout)
            guard !batch.isEmpty else { return }

            let relays = await peerProfileLookupRelays(for: account)
            // The account can change while the relay list is being read.
            guard !Task.isCancelled, activeAccountId == account.id else { return }

            var resolvedIds: [String] = []
            // `refreshProfile` is an async FFI call that suspends rather than blocking, so
            // a small fan-out here does not stall the main actor. The local re-resolution
            // it triggers still funnels through the shared `FFIExecutor.queue`.
            await withTaskGroup(of: (String, Bool).self) { group in
                for accountIdHex in batch {
                    group.addTask { @MainActor in
                        let resolved = await self.refreshPeerProfile(
                            accountIdHex: accountIdHex,
                            account: account,
                            relays: relays,
                            client: client
                        )
                        return (accountIdHex, resolved)
                    }
                }
                for await (accountIdHex, resolved) in group where resolved {
                    resolvedIds.append(accountIdHex)
                }
            }

            guard !Task.isCancelled, activeAccountId == account.id else { return }
            if !resolvedIds.isEmpty {
                schedulePeerProfileReprojection(ids: resolvedIds)
            }
        }
    }

    /// Resolves a peer, going to the relays only if the local directory cannot name them.
    /// Returns whether the peer became nameable as a result.
    private func refreshPeerProfile(
        accountIdHex: String,
        account: AccountItem,
        relays: [String],
        client: any MarmotRuntime
    ) async -> Bool {
        let wasComplete = peerProfileFFICache[accountIdHex]?.isComplete == true

        // Every exit path must hand the gate's in-flight slot back. The abort paths below
        // return without an outcome, and `tryStart` has already marked this id in flight, so
        // without this the id stays in flight for the life of the process and the gate refuses
        // it forever — that peer's name would never resolve again.
        //
        // Not hypothetical: `restoreOrSelectFirstAccount` and the preferred-account login path
        // both move `activeAccountId` without going through `resetActiveAccountUIState`, so
        // they never call `clearPeerProfileRefreshState`. A refresh suspended in the relay
        // round-trip when either runs resumes straight into the account-mismatch return.
        //
        // `remove` rather than `finish`: no attempt outcome was observed, so this must not
        // charge the backoff ladder for a round-trip whose result we discarded.
        var recordedOutcome = false
        defer {
            if !recordedOutcome {
                peerProfileRefreshGate.remove(accountIdHex)
            }
        }

        // Try the local directory first. MDK may already hold this peer's kind:0 — fetched
        // by its own background directory sync, or persisted by an earlier session — and the
        // roster/sender call sites request every identity they see before anything has read
        // the cache for it. Going straight to the relays would therefore put a round-trip on
        // the first sight of an already-known contact, which is most of them.
        let local = await resolvedPeerFFI(
            accountIdHex: accountIdHex,
            activeAccount: account,
            client: client
        )
        guard !Task.isCancelled, activeAccountId == account.id else { return false }
        if local?.isComplete == true {
            peerProfileRefreshGate.finish(accountIdHex, now: nowProvider(), resolved: true)
            recordedOutcome = true
            return !wasComplete
        }

        try? await client.refreshProfile(accountIdHex: accountIdHex, relays: relays)

        // A refresh resolving after an account switch must not write the previous
        // account's directory view into the new account's cache — `selectAccount` /
        // `selectAccountFromSettings` already cleared it (whitenoise-mac#8).
        guard !Task.isCancelled, activeAccountId == account.id else { return false }

        // Drop the incomplete entry so `resolvedPeerFFI` re-reads Rust instead of
        // serving the pre-refresh miss back, exactly as `resolveNewChatRecipient` does.
        peerProfileFFICache[accountIdHex] = nil
        let resolved = await resolvedPeerFFI(
            accountIdHex: accountIdHex,
            activeAccount: account,
            client: client
        )

        guard activeAccountId == account.id else { return false }
        let isResolved = resolved?.isComplete == true
        // A nicknamed peer is already labelled correctly everywhere it renders — the nickname
        // outranks every published source. The only thing an unresolved lookup still costs
        // them is the published name shown under the nickname, which is not worth the urgent
        // 2s/4s ladder. Settling the run here sends them straight to the escalating cooldown.
        // Read at finish time, not in `requestPeerProfileRefresh`: this is off the projection
        // hot path, so the check costs nothing the timeline pays for.
        let hasNickname =
            !isResolved
            && activeContactNicknames.nickname(forContactAccountIdHex: accountIdHex) != nil
        peerProfileRefreshGate.finish(
            accountIdHex,
            now: nowProvider(),
            resolved: isResolved,
            deferRetries: hasNickname
        )
        recordedOutcome = true
        return isResolved && !wasComplete
    }

    private func nextQueuedPeerProfileRefreshIds(limit: Int) -> [String] {
        guard limit > 0, !queuedPeerProfileRefreshIds.isEmpty else { return [] }
        let count = min(limit, queuedPeerProfileRefreshIds.count)
        let ids = Array(queuedPeerProfileRefreshIds.prefix(count))
        queuedPeerProfileRefreshIds.removeFirst(count)
        return ids
    }

    private func finishPeerProfileRefreshQueue(taskId: UUID) {
        guard peerProfileRefreshTaskId == taskId else { return }
        peerProfileRefreshTask = nil
        peerProfileRefreshTaskId = nil
        // Ids appended while this drain was returning would otherwise sit unowned.
        startPeerProfileRefreshQueueIfNeeded()
    }

    /// `peerProfileLookupRelays` for whichever account is active, falling back to the seed
    /// relays when there is none. The callers that refresh a *named* identity — the local
    /// account sweep, and a hand-typed New Chat recipient — all need this same choice.
    func peerProfileLookupRelaysForActiveAccount() async -> [String] {
        guard let activeAccount else { return MarmotClient.seedRelays }
        return await peerProfileLookupRelays(for: activeAccount)
    }

    /// Relays to search for a peer's kind:0: the seed relays plus the active account's
    /// own NIP-65 set, deduped. Seed relays alone miss a peer who publishes only to
    /// their own write relays; Android composes the same union in `profileLookupRelays`.
    func peerProfileLookupRelays(for account: AccountItem) async -> [String] {
        if let cached = peerProfileLookupRelaysByAccountId[account.id] { return cached }
        guard let client else { return MarmotClient.seedRelays }

        let accountRelays =
            (try? await FFIExecutor.run { try client.accountRelayLists(accountRef: account.accountRef) })?
            .nip65.relays ?? []

        var relays: [String] = []
        var seen = Set<String>()
        for relay in MarmotClient.seedRelays + accountRelays where seen.insert(relay).inserted {
            relays.append(relay)
        }
        // Only cache under the account that is still active; a switch mid-read must not
        // pin the previous account's relay set.
        if activeAccountId == account.id {
            peerProfileLookupRelaysByAccountId[account.id] = relays
        }
        return relays
    }

    // MARK: - Re-project

    /// Coalescing entry point for "these peers became nameable — repaint what shows them".
    ///
    /// Deliberately not driven by observing `peerProfileGeneration`: the bump is a
    /// notification for view-level observers, while the re-projection is scheduled
    /// directly so a future push-based profile stream can call this same function
    /// without a polling loop in between.
    func schedulePeerProfileReprojection(ids: some Sequence<String>) {
        let ids = Set(ids).subtracting([""])
        guard !ids.isEmpty else { return }
        pendingPeerProfileReprojectionIds.formUnion(ids)
        peerProfileReprojectionArrivals &+= 1
        peerProfileGeneration &+= 1

        guard peerProfileReprojectionTask == nil else { return }
        let taskId = UUID()
        peerProfileReprojectionTaskId = taskId
        peerProfileReprojectionTask = Task { [weak self] in
            await self?.awaitPeerProfileReprojectionDebounce(taskId: taskId)
        }
    }

    /// Trailing debounce: each new batch of resolutions restarts the wait, so a drain that
    /// keeps landing ids produces one re-projection at the end instead of one per window.
    ///
    /// A fixed leading window is the wrong shape here. The refresh queue resolves in batches
    /// of `peerProfileRefreshFanout`, and each batch calls this — so opening a chat with 40
    /// unnamed senders paid a full transcript re-map every 250ms for the length of the drain,
    /// with only the last one showing the finished state.
    ///
    /// Extension is counted, not clocked: `nowProvider` is a fake in tests, and a frozen
    /// clock would spin here. `maxPeerProfileReprojectionDebounceExtensions` therefore caps
    /// the total wait, so a long drain still repaints partway through rather than staying
    /// blank until it finishes.
    private func awaitPeerProfileReprojectionDebounce(taskId: UUID) async {
        var extensions = 0
        while true {
            let arrivalsBeforeSleep = peerProfileReprojectionArrivals
            try? await Task.sleep(nanoseconds: Self.peerProfileReprojectionDebounceNanoseconds)
            guard !Task.isCancelled else {
                // Release ownership of the slot even when the debounce is cancelled mid-sleep.
                // Returning without this would leave `peerProfileReprojectionTask` non-nil
                // forever, and the `== nil` guard in `schedule` would then swallow every later
                // resolution for the life of the process.
                finishPeerProfileReprojection(taskId: taskId)
                return
            }
            guard peerProfileReprojectionArrivals != arrivalsBeforeSleep,
                extensions < Self.maxPeerProfileReprojectionDebounceExtensions
            else { break }
            extensions += 1
        }
        await runPeerProfileReprojection(taskId: taskId)
    }

    private func runPeerProfileReprojection(taskId: UUID) async {
        guard peerProfileReprojectionTaskId == taskId else { return }
        let ids = pendingPeerProfileReprojectionIds
        pendingPeerProfileReprojectionIds.removeAll()

        defer { finishPeerProfileReprojection(taskId: taskId) }
        guard !ids.isEmpty, let client, let account = activeAccount else { return }
        #if DEBUG
            peerProfileReprojectionCount += 1
        #endif

        await reprojectSelectedTimelineForPeerProfiles(ids: ids, account: account, client: client)
        guard activeAccountId == account.id else { return }
        await reprojectChatRowsForPeerProfiles(ids: ids, account: account, client: client)
    }

    private func finishPeerProfileReprojection(taskId: UUID) {
        guard peerProfileReprojectionTaskId == taskId else { return }
        peerProfileReprojectionTask = nil
        peerProfileReprojectionTaskId = nil
        // Resolutions that landed during the pass above own no task yet.
        if !pendingPeerProfileReprojectionIds.isEmpty {
            let pending = pendingPeerProfileReprojectionIds
            pendingPeerProfileReprojectionIds.removeAll()
            schedulePeerProfileReprojection(ids: pending)
        }
    }

    /// Replays the open conversation's authoritative window so every row re-resolves whatever the
    /// projection bakes into it — sender names, and the mention tokens rendered into each bubble
    /// — including rows the live delta path would never revisit.
    ///
    /// `snapshot()` is a pure in-memory clone of the window the runtime already holds: no
    /// store read, no relay traffic, and identical bounds, so a scrolled-back reader keeps
    /// their position and pagination state. `loadMessages` would instead re-run the
    /// initial-load path and re-anchor the window to the head.
    ///
    /// Callers decide whether a replay is worth it; this only re-checks that the window it is
    /// about to replace is still the one on screen, which is also what makes it safe for a
    /// caller whose conversation or account moved on while it was suspended.
    func replaySelectedTimelineWindow(account: AccountItem, client: any MarmotRuntime) async {
        guard let subscription = activeTimelineSubscription,
            let groupIdHex = activeTimelineGroupId,
            selectedChat?.id == groupIdHex
        else { return }

        guard let page = try? await FFIExecutor.run({ subscription.snapshot() }) else { return }
        guard activeAccountId == account.id,
            activeTimelineSubscription === subscription,
            selectedChat?.id == groupIdHex
        else { return }

        await applyTimelineWindow(
            page,
            groupIdHex: groupIdHex,
            account: account,
            client: client,
            owner: .subscription(subscription)
        )
    }

    /// Replays the open window for peers that just became nameable.
    private func reprojectSelectedTimelineForPeerProfiles(
        ids: Set<String>,
        account: AccountItem,
        client: any MarmotRuntime
    ) async {
        guard let groupIdHex = activeTimelineGroupId, selectedChat?.id == groupIdHex else { return }

        // Replay only when a resolved id is one the open window's rows actually name. Most
        // requests come from rosters and reaction lists — a 40-member group whose members
        // have never posted, or reactors whose rows read `peerProfileFFICache` directly and
        // repaint on their own. Replaying for those re-maps and re-diffs the whole transcript
        // to produce byte-identical rows, once per debounce window for the length of a drain.
        //
        // `timelineProjectedSenderIds` is the exact `senderIds` set the last projection of
        // this window resolved, so it covers reply-quote authors and group-system actors too
        // — identities the materialized `MessageItem`s do not carry and a scan of the store
        // would miss.
        guard let projectedSenderIds = timelineProjectedSenderIds[groupIdHex],
            !projectedSenderIds.isDisjoint(with: ids)
        else { return }

        await replaySelectedTimelineWindow(account: account, client: client)
    }

    /// Re-titles direct-chat rows whose peer just became nameable.
    ///
    /// Scoped to direct chats on purpose: a group row's title comes from the group's own
    /// metadata, and its preview's "Alice: " prefix is resolved by MDK on every row read
    /// (`hydrate_chat_list_rows`), so the next chat-list delta carries the new name
    /// without any client work. Only the direct-chat title and avatar are projected from
    /// a peer profile this app resolved itself, and only those can go stale here.
    private func reprojectChatRowsForPeerProfiles(
        ids: Set<String>,
        account: AccountItem,
        client: any MarmotRuntime
    ) async {
        // Resolve which groups are affected once, from the roster cache, instead of scanning
        // every chat's member list per chat. Chat iteration then costs a set lookup per row.
        var affectedGroupIds = Set<String>()
        for (groupIdHex, members) in groupMemberDetailsCache
        where members.contains(where: { ids.contains($0.memberIdHex) }) {
            affectedGroupIds.insert(groupIdHex)
        }

        var updated: [ChatItem] = []
        // Walk the two stored arrays in place. Concatenating them would copy every chat row
        // on every re-projection; the outer array here only holds two copy-on-write handles.
        for chats in [chatsByAccount[account.id] ?? [], archivedChatsByAccount[account.id] ?? []] {
            for chat in chats {
                guard !Task.isCancelled, activeAccountId == account.id else { return }
                // `avatarSeed` is the peer's account id for an enriched direct chat; the
                // roster check also catches a row whose first enrichment ran before the
                // roster was cached.
                guard affectedGroupIds.contains(chat.id) || ids.contains(chat.avatarSeed),
                    let members = groupMemberDetailsCache[chat.id]
                else { continue }

                // Test two-party membership here rather than letting `directPeerProfile` return
                // nil for group rows. It is not a pure query: on a multi-member roster it calls
                // `forgetDirectPeer`, and it resolves the peer over FFI before it can answer. A
                // profile refresh has no business dropping remembered-peer state, and paying an
                // FFI resolve per group row on every pass is the cost this guard removes.
                guard Self.otherMembers(in: members, activeAccount: account).count == 1 else { continue }

                // A named two-person conversation is a group (MDK's `conversation_kind`), and its
                // title is the name its members gave it — projecting a peer profile onto it would
                // put the other member's name back over that name on every profile refresh. Rows
                // whose kind MDK did not supply stay eligible, since they are the legacy
                // roster-enriched ones this pass exists for.
                guard chat.isDirect || !chat.hasAuthoritativeConversationKind else { continue }

                // `readStateMetadataEnrichmentAttempts` is a permanent per-group "tried once"
                // flag, so a group whose single enrichment pass ran before this peer's
                // metadata landed could never re-enrich from the read-state path. Clearing it
                // here re-arms that one retry now that the underlying data changed.
                readStateMetadataEnrichmentAttempts.remove(chat.id)

                // `directPeerProfile` already folds in any private nickname, so `displayName`
                // is nickname-first and `publishedDisplayName` carries what the peer actually
                // published. Re-projecting from it therefore refreshes the published name
                // behind a nickname without ever overwriting the nickname itself.
                guard
                    let peer = await directPeerProfile(
                        from: members,
                        groupIdHex: chat.id,
                        activeAccount: account,
                        client: client
                    ),
                    let name = PeerDisplayText.sanitize(peer.displayName),
                    !name.isEmpty
                else { continue }
                let publishedName = peer.publishedDisplayName.flatMap { PeerDisplayText.sanitize($0) }
                guard
                    name != chat.title
                        || publishedName != chat.publishedTitle
                        || peer.pictureURL != chat.pictureURL
                else { continue }

                updated.append(
                    chat.replacingPeerPresentation(
                        displayName: name,
                        publishedDisplayName: publishedName,
                        pictureURL: peer.pictureURL
                    )
                )
            }
        }

        guard !updated.isEmpty, !Task.isCancelled, activeAccountId == account.id else { return }
        applyChatMetadataEnrichment(updated, account: account)
    }

    // MARK: - Lifecycle

    /// Drops all relay-refresh state. Called wherever `peerProfileFFICache` is cleared:
    /// admission cooldowns, the queue, and the relay-set cache are all scoped to the
    /// active account's directory view, and a queued id resolved after a switch would
    /// otherwise write that account's identity into the new one's cache.
    func clearPeerProfileRefreshState() {
        peerProfileRefreshGate.removeAll()
        queuedPeerProfileRefreshIds.removeAll()
        peerProfileLookupRelaysByAccountId.removeAll()
        pendingPeerProfileReprojectionIds.removeAll()
        // Sender sets describe the previous account's windows; the new account's timelines
        // record their own on first projection.
        timelineProjectedSenderIds.removeAll()
        let refreshTask = peerProfileRefreshTask
        peerProfileRefreshTask = nil
        peerProfileRefreshTaskId = nil
        refreshTask?.cancel()
        let reprojectionTask = peerProfileReprojectionTask
        peerProfileReprojectionTask = nil
        peerProfileReprojectionTaskId = nil
        reprojectionTask?.cancel()
    }

    #if DEBUG
        /// Test hook: settle every queued relay refresh, including a drain already in flight.
        ///
        /// Starting a second drain instead of awaiting the live one races it: the in-flight
        /// pass may already have popped the ids under test and still be suspended in
        /// `refreshProfile`, so a fresh drain finds an empty queue and returns before
        /// anything has been fetched.
        func settlePeerProfileRefreshQueueForTesting() async {
            while true {
                if let task = peerProfileRefreshTask {
                    // `runPeerProfileRefreshQueue` finishes its bookkeeping in a `defer`, so the
                    // task slot is already cleared (and re-armed, if ids arrived late) here.
                    await task.value
                    continue
                }
                guard !queuedPeerProfileRefreshIds.isEmpty else { return }
                let taskId = UUID()
                peerProfileRefreshTaskId = taskId
                await runPeerProfileRefreshQueue(taskId: taskId)
            }
        }

        /// Test hook: run the debounced re-projection body without the 250ms sleep.
        func runPeerProfileReprojectionForTesting() async {
            let taskId = UUID()
            peerProfileReprojectionTask?.cancel()
            peerProfileReprojectionTask = nil
            peerProfileReprojectionTaskId = taskId
            await runPeerProfileReprojection(taskId: taskId)
        }
    #endif
}
