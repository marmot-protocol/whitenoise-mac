import Foundation
import MarmotKit
import Observation

/// Selecting several chats in the list and acting on all of them at once — archive or unarchive,
/// mute or unmute, leave. The Mac's counterpart to `whitenoise-ios`'s chat-list selection mode,
/// with the same bulk rules (`ChatListSelection`).
///
/// Owned by `AccountScope`, so switching accounts drops the selection and cancels a batch that is
/// still running instead of letting it finish against the next account's list.
///
/// Rows read only `isActive`; the per-row checkmark reads `isSelected(_:)` from its own small view,
/// so toggling one chat re-renders checkmarks, not the list.
///
/// The selection is tracked against an MDK query, not the rows on screen: the view the drawer
/// shows, plus the search filter while one is typed. When the rows are a bounded window (the
/// unfiltered inbox, or search results) Select All asks MDK for every chat the query matches —
/// `chatListIds`, or `chatListQueryIds` for a search — and counts that; a list the drawer shows
/// whole is its own universe. Every batch first runs the selection through
/// `revalidateChatListIds` / `revalidateChatListQueryIds` with the same query, which drops chats
/// that stopped matching since they were picked and never adds any, then runs the existing
/// per-chat commands on what is left.
@MainActor
@Observable
final class ChatListSelectionViewModel {
    enum Operation: Equatable {
        case archiving
        case muting
        case preparingLeave
        case leaving
    }

    /// The leave the user is being asked to confirm, already checked for blockers.
    struct LeaveConfirmation: Identifiable, Equatable {
        let id = UUID()
        let groupIds: [String]
        var count: Int { groupIds.count }
    }

    private(set) var isActive = false
    private(set) var selectedIds: Set<String> = []
    /// Every chat the query matches when the list is windowed; `nil` until MDK answers, which
    /// keeps Select All and the bulk actions disabled rather than acting on only the window.
    private(set) var viewIds: [String]?
    /// The rows on screen are a bounded window over `view`, so they are not every selectable chat.
    private(set) var isWindowed = false
    /// The visible rows, top to bottom, as of the last `updateVisibleChats`. Shift-click ranges are
    /// read from it, and it is Select All's universe when the list is not windowed.
    private(set) var visibleOrder: [String] = []
    private(set) var operation: Operation?
    var pendingLeave: LeaveConfirmation?
    var alert: ChatActionAlert?

    var isBusy: Bool { operation != nil }

    @ObservationIgnored private let accountRef: String
    /// `nil` only in previews, where every action fails as it would with no runtime.
    @ObservationIgnored private let runtime: (any MarmotRuntime)?
    @ObservationIgnored private let advisory: GroupChangeAdvisoryPrompter?
    /// Runs after every batch with the chats the batch left, so the shell can refresh its legacy
    /// chat state and close an inspector showing a chat this account no longer belongs to.
    @ObservationIgnored private let chatsDidChange: @MainActor (_ departedGroupIds: Set<String>) async -> Void
    /// The MDK query the list on screen is drawn from; Select All and batches read the same one.
    @ObservationIgnored private(set) var query = ChatListSearchQuery.unfiltered(.chats)
    @ObservationIgnored private var anchorId: String?
    @ObservationIgnored private(set) var task: Task<Void, Never>?
    /// Loads `viewIds`. Replaced (and the old one cancelled) whenever the list changes under it.
    @ObservationIgnored private(set) var viewIdsTask: Task<Void, Never>?

    init(
        accountRef: String,
        runtime: (any MarmotRuntime)?,
        advisory: GroupChangeAdvisoryPrompter? = nil,
        chatsDidChange: @escaping @MainActor (_ departedGroupIds: Set<String>) async -> Void = { _ in }
    ) {
        self.accountRef = accountRef
        self.runtime = runtime
        self.advisory = advisory
        self.chatsDidChange = chatsDidChange
    }

    // MARK: - Selection

    func isSelected(_ groupIdHex: String) -> Bool {
        selectedIds.contains(groupIdHex)
    }

    func begin(with groupIdHex: String) {
        guard !isBusy else { return }
        isActive = true
        selectedIds = [groupIdHex]
        anchorId = groupIdHex
        loadViewIds()
    }

    func end() {
        guard !isBusy else { return }
        isActive = false
        selectedIds = []
        anchorId = nil
        pendingLeave = nil
        viewIdsTask?.cancel()
        viewIdsTask = nil
        viewIds = nil
    }

    func toggle(_ groupIdHex: String) {
        guard isActive, !isBusy else { return }
        selectedIds = ChatListSelection.toggling(selectedIds, id: groupIdHex)
        anchorId = groupIdHex
    }

    /// Shift-click: select every row between the last clicked row and this one. Outside selection
    /// mode it starts one, ranging from `defaultAnchor` (the open chat) when that row is visible.
    func extend(to groupIdHex: String, defaultAnchor: String? = nil) {
        guard !isBusy else { return }
        if !isActive {
            isActive = true
            selectedIds = []
            anchorId = defaultAnchor
            loadViewIds()
        }
        selectedIds = ChatListSelection.extending(selectedIds, from: anchorId, to: groupIdHex, in: visibleOrder)
        anchorId = groupIdHex
    }

    /// What Select All selects: every chat in the view when the list is windowed (once MDK has
    /// answered), the visible rows otherwise.
    var selectableIds: [String]? {
        isWindowed ? viewIds : visibleOrder
    }

    var canToggleAll: Bool {
        selectableIds?.isEmpty == false
    }

    /// The bulk actions wait for the full list of a windowed query, so a count and a batch never
    /// rest on a list MDK is still preparing.
    var isScopeReady: Bool {
        !isWindowed || viewIds != nil
    }

    var allSelected: Bool {
        guard let selectableIds else { return false }
        return ChatListSelection.allSelected(selectedIds, visibleIds: Set(selectableIds))
    }

    /// The selection in list order, so a batch walks the chats top to bottom.
    var orderedSelection: [String] {
        ChatListSelection.ordered(selectedIds, by: selectableIds ?? visibleOrder)
    }

    func toggleAll() {
        guard isActive, !isBusy, let selectableIds else { return }
        selectedIds = ChatListSelection.togglingAll(selectedIds, visibleIds: Set(selectableIds))
    }

    /// The list changed under the selection — a new filter, a search, a chat that moved away.
    /// Drops selections that are no longer in the list, except while a batch is running: a chat it
    /// just archived or left is expected to leave the list, and the batch still owns it. A windowed
    /// list is reconciled against the whole view once `chatListIds` answers, not against the
    /// window, so a chat scrolled out of the window stays selected.
    func updateVisibleChats(
        _ orderedIds: [String],
        query: ChatListViewQueryFfi = ChatListSearchQuery.unfiltered(.chats),
        isWindowed: Bool = false
    ) {
        if visibleOrder != orderedIds { visibleOrder = orderedIds }
        let scopeChanged = query != self.query || isWindowed != self.isWindowed
        self.query = query
        if self.isWindowed != isWindowed { self.isWindowed = isWindowed }
        if scopeChanged, viewIds != nil { viewIds = nil }
        guard isActive else { return }
        if isWindowed {
            loadViewIds()
        } else {
            viewIdsTask?.cancel()
            viewIdsTask = nil
            reconcile(with: orderedIds)
        }
    }

    /// Cancels a running batch and forgets the selection. Called when the owning account scope ends.
    func stop() {
        task?.cancel()
        task = nil
        viewIdsTask?.cancel()
        viewIdsTask = nil
        operation = nil
        pendingLeave = nil
        alert = nil
        end()
    }

    // MARK: - Bulk actions

    @discardableResult
    func setArchived(_ archived: Bool, groupIds: [String]) -> Task<Void, Never>? {
        run(.archiving, groupIds: groupIds) { runtime, accountRef, groupIdHex in
            _ = try await runtime.setGroupArchived(
                accountRef: accountRef,
                groupIdHex: groupIdHex,
                archived: archived
            )
        } failure: { failedCount in
            ChatActionAlert(
                title: archived ? L10n.string("Couldn't archive chat") : L10n.string("Couldn't update archive"),
                message: L10n.plural("%lld chats remain. Try again.", Int64(failedCount))
            )
        }
    }

    /// `duration` `nil` unmutes.
    @discardableResult
    func setMuted(_ duration: ChatMuteDuration?, groupIds: [String]) -> Task<Void, Never>? {
        let mutedUntilMs = duration?.mutedUntilMs(from: .now)
        return run(.muting, groupIds: groupIds) { runtime, accountRef, groupIdHex in
            if duration != nil {
                _ = try await FFIExecutor.run {
                    try runtime.setChatMuted(
                        accountRef: accountRef,
                        groupIdHex: groupIdHex,
                        mutedUntilMs: mutedUntilMs
                    )
                }
            } else {
                _ = try await FFIExecutor.run {
                    try runtime.clearChatMuted(accountRef: accountRef, groupIdHex: groupIdHex)
                }
            }
        } failure: { failedCount in
            ChatActionAlert(
                title: L10n.string("Couldn't update notifications"),
                message: L10n.plural("%lld chats remain. Try again.", Int64(failedCount))
            )
        }
    }

    /// Phase one of a bulk leave: check every chat for a blocker before asking anything, so the
    /// confirmation never promises a leave one of the chats will refuse. A sole-admin chat stops the
    /// batch and is named — handing admin over is a per-chat choice the row menu walks through.
    @discardableResult
    func requestLeave(_ chats: [ChatItem]) -> Task<Void, Never>? {
        guard isActive, !isBusy, pendingLeave == nil else { return nil }
        let targets = ChatListSelection.leaveTargets(chats)
        guard !targets.isEmpty else { return nil }
        operation = .preparingLeave
        let query = query
        let task = Task { [weak self] in
            guard let self else { return }
            defer { self.finish() }
            let current: Set<String>
            do {
                current = Set(try await self.revalidated(targets.map(\.id), in: query))
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled else { return }
                self.alert = .leaveFailed()
                return
            }
            var leavable: [String] = []
            for chat in targets where current.contains(chat.id) {
                guard !Task.isCancelled else { return }
                do {
                    guard let runtime = self.runtime else { throw ChatListSelectionUnavailable() }
                    let state = try await runtime.groupManagementState(
                        accountRef: self.accountRef,
                        groupIdHex: chat.id
                    )
                    guard !Task.isCancelled else { return }
                    switch ChatDestructiveActions.leaveBlocker(
                        membership: .member,
                        eligibility: ChatLeaveEligibility(state)
                    ) {
                    case nil:
                        leavable.append(chat.id)
                    case .pending:
                        // Already on its way out: nothing for this batch to do.
                        continue
                    case .lastAdmin:
                        self.alert = Self.leaveBlockedAlert(
                            chat.confirmationSubject,
                            message: L10n.string(
                                "You're the only admin. Make another member an admin before you leave.")
                        )
                        return
                    case .unavailable:
                        self.alert = Self.leaveBlockedAlert(
                            chat.confirmationSubject,
                            message: ChatDestructiveActions.LeaveBlocker.unavailable.message
                        )
                        return
                    }
                } catch is CancellationError {
                    return
                } catch {
                    guard !Task.isCancelled else { return }
                    self.alert = .leaveFailed()
                    return
                }
            }
            guard !Task.isCancelled else { return }
            if leavable.isEmpty {
                await self.chatsDidChange([])
                self.endAfterBatch()
            } else {
                self.pendingLeave = LeaveConfirmation(groupIds: leavable)
            }
        }
        self.task = task
        return task
    }

    /// Phase two: leave each confirmed chat. Eligibility is re-read per chat, because a group can
    /// commit a membership or admin change between the confirmation and the click.
    @discardableResult
    func confirmLeave(_ confirmation: LeaveConfirmation) -> Task<Void, Never>? {
        // Not keyed on `pendingLeave`: the dialog may clear its binding before it runs the
        // button's action, and the confirmation it hands over is the one the user answered.
        guard isActive, !isBusy, !confirmation.groupIds.isEmpty else { return nil }
        pendingLeave = nil
        operation = .leaving
        let query = query
        let task = Task { [weak self] in
            guard let self else { return }
            defer { self.finish() }
            let targets: [String]
            do {
                targets = try await self.revalidated(confirmation.groupIds, in: query)
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled else { return }
                self.alert = ChatActionAlert(
                    title: L10n.string("Couldn't leave chat"),
                    message: L10n.plural(
                        "Couldn't leave %lld chats. Try again.", Int64(confirmation.groupIds.count))
                )
                return
            }
            var departed = Set<String>()
            var failed = Set<String>()
            var waited: GroupChangeAdvisory?
            for groupIdHex in targets {
                guard !Task.isCancelled else { return }
                switch await self.leave(groupIdHex: groupIdHex) {
                case .left: departed.insert(groupIdHex)
                case .failed: failed.insert(groupIdHex)
                case .waited(let advisory): waited = advisory
                case .cancelled: return
                }
            }
            guard !Task.isCancelled else { return }
            await self.chatsDidChange(departed)
            guard !Task.isCancelled else { return }
            if !failed.isEmpty {
                self.selectedIds = failed
                self.alert = ChatActionAlert(
                    title: L10n.string("Couldn't leave chat"),
                    message: L10n.plural("Couldn't leave %lld chats. Try again.", Int64(failed.count))
                )
                return
            }
            // Choosing Wait is not a failure: nothing was published for that chat, and the note says
            // what didn't change.
            if let waited {
                self.alert = waited.waitedAlert
            }
            self.endAfterBatch()
        }
        self.task = task
        return task
    }

    // MARK: - Running a batch

    private enum LeaveOutcome {
        case left
        case failed
        case waited(GroupChangeAdvisory)
        case cancelled
    }

    private func leave(groupIdHex: String) async -> LeaveOutcome {
        guard let runtime else { return .failed }
        let accountRef = accountRef
        do {
            let state = try await runtime.groupManagementState(accountRef: accountRef, groupIdHex: groupIdHex)
            let eligibility = ChatLeaveEligibility(state)
            switch ChatDestructiveActions.leaveBlocker(membership: .member, eligibility: eligibility) {
            case nil: break
            case .pending: return .left
            case .lastAdmin, .unavailable: return .failed
            }
            if ChatDestructiveActions.shouldSelfDemoteBeforeLeave(eligibility) {
                _ = try await GroupChangeAdvisoryRetry.perform(
                    prompter: advisory,
                    runtime: runtime,
                    accountRef: accountRef,
                    groupIdHex: groupIdHex
                ) { [runtime] in
                    // Checked inside the change, so a batch cancelled while the state read or an
                    // advisory acknowledgement was suspended never steps down on either attempt.
                    try Task.checkCancellation()
                    return try await runtime.selfDemoteAdminDetailed(accountRef: accountRef, groupIdHex: groupIdHex)
                }
            }
            try Task.checkCancellation()
            _ = try await runtime.leaveGroup(accountRef: accountRef, groupIdHex: groupIdHex)
            return .left
        } catch is CancellationError {
            return .cancelled
        } catch let declined as GroupChangeAdvisoryDeclined {
            return .waited(declined.advisory)
        } catch {
            if Task.isCancelled { return .cancelled }
            // A leave the core already recorded is a success, not a failure.
            if let error = error as? MarmotKitError, case .LeaveAlreadyRequested = error {
                return .left
            }
            if let state = try? await runtime.groupManagementState(accountRef: accountRef, groupIdHex: groupIdHex),
                state.leaveRequestPending
            {
                return .left
            }
            return .failed
        }
    }

    /// One sequential pass over `groupIds`. Failures keep their chats selected and are reported
    /// together, the way iOS reports a partial bulk delete; a clean pass ends selection mode.
    private func run(
        _ operation: Operation,
        groupIds: [String],
        perform:
            @escaping @MainActor (any MarmotRuntime, _ accountRef: String, _ groupIdHex: String) async throws -> Void,
        failure: @escaping @MainActor (_ failedCount: Int) -> ChatActionAlert
    ) -> Task<Void, Never>? {
        guard isActive, !isBusy, !groupIds.isEmpty else { return nil }
        self.operation = operation
        let query = query
        let task = Task { [weak self] in
            guard let self else { return }
            defer { self.finish() }
            let targets: [String]
            do {
                targets = try await self.revalidated(groupIds, in: query)
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled else { return }
                self.alert = failure(groupIds.count)
                return
            }
            var failed = Set<String>()
            for groupIdHex in targets {
                guard !Task.isCancelled else { return }
                do {
                    guard let runtime = self.runtime else { throw ChatListSelectionUnavailable() }
                    try await perform(runtime, self.accountRef, groupIdHex)
                } catch is CancellationError {
                    return
                } catch {
                    failed.insert(groupIdHex)
                }
            }
            guard !Task.isCancelled else { return }
            await self.chatsDidChange([])
            guard !Task.isCancelled else { return }
            if failed.isEmpty {
                self.endAfterBatch()
            } else {
                self.selectedIds = failed
                self.alert = failure(failed.count)
            }
        }
        self.task = task
        return task
    }

    private func finish() {
        operation = nil
        task = nil
    }

    private func reconcile(with ids: [String]) {
        guard isActive, !isBusy else { return }
        let reconciled = ChatListSelection.reconcile(selectedIds, visibleIds: Set(ids))
        if reconciled != selectedIds {
            selectedIds = reconciled
        }
    }

    /// Reads every chat in a windowed view for Select All, retrying while MDK reports the list not
    /// ready (`ChatPresentationNotReady` while base rows are prepared, never a partial list). Runs
    /// only in selection mode; ending it, or the list changing again, cancels the read.
    private func loadViewIds() {
        viewIdsTask?.cancel()
        viewIdsTask = nil
        guard isActive, isWindowed, let runtime else { return }
        let accountRef = accountRef
        let query = query
        viewIdsTask = Task { [weak self] in
            do {
                let ids = try await ChatListNotReadyRetry.run {
                    try await Self.ids(runtime: runtime, accountRef: accountRef, query: query)
                }
                guard !Task.isCancelled, let self else { return }
                self.viewIds = ids
                self.reconcile(with: ids)
            } catch {
                // Cancelled, or a failed read: Select All and the bulk actions stay disabled until
                // the list changes again and the read is retried.
            }
        }
    }

    private static func ids(runtime: any MarmotRuntime, accountRef: String, query: ChatListViewQueryFfi)
        async throws -> [String]
    {
        query.filter.isEmpty
            ? try await runtime.chatListIds(accountRef: accountRef, view: query.view)
            : try await runtime.chatListQueryIds(accountRef: accountRef, query: query)
    }

    /// The part of `groupIds` still matching `query`, in the caller's order. MDK only removes: a
    /// chat that started matching since the selection was made is never added. Retries a few times
    /// while the list is not ready, then gives up so the batch reports a failure instead of hanging.
    private func revalidated(_ groupIds: [String], in query: ChatListViewQueryFfi) async throws -> [String] {
        guard let runtime else { throw ChatListSelectionUnavailable() }
        let accountRef = accountRef
        let current = try await ChatListNotReadyRetry.run(initialDelay: .milliseconds(100), maxAttempts: 4) {
            query.filter.isEmpty
                ? try await runtime.revalidateChatListIds(accountRef: accountRef, view: query.view, groupIds: groupIds)
                : try await runtime.revalidateChatListQueryIds(
                    accountRef: accountRef, query: query, groupIds: groupIds)
        }
        try Task.checkCancellation()
        // Chats that stopped matching are no longer the user's to act on.
        selectedIds.subtract(Set(groupIds).subtracting(current))
        return current
    }

    private func endAfterBatch() {
        operation = nil
        end()
    }

    private static func leaveBlockedAlert(_ subject: ChatConfirmationSubject, message: String) -> ChatActionAlert {
        let title: String
        switch subject {
        case .namedGroup(let name), .directChat(peerName: let name):
            title = String(format: L10n.string("Couldn't leave “%@”"), PeerDisplayText.templateFragment(name))
        case .unnamedGroup, .unnamedChat:
            title = L10n.string("Couldn't leave chat")
        }
        return ChatActionAlert(title: title, message: message)
    }
}

/// The selection was asked to act with no runtime (a preview).
nonisolated private struct ChatListSelectionUnavailable: Error {}
