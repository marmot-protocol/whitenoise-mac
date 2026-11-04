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
    /// The visible rows, top to bottom, as of the last `updateVisibleChats`. Shift-click ranges are
    /// read from it; it is not observed because nothing renders from it.
    @ObservationIgnored private var visibleOrder: [String] = []
    @ObservationIgnored private var anchorId: String?
    @ObservationIgnored private(set) var task: Task<Void, Never>?

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
    }

    func end() {
        guard !isBusy else { return }
        isActive = false
        selectedIds = []
        anchorId = nil
        pendingLeave = nil
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
        }
        selectedIds = ChatListSelection.extending(selectedIds, from: anchorId, to: groupIdHex, in: visibleOrder)
        anchorId = groupIdHex
    }

    var allVisibleSelected: Bool {
        ChatListSelection.allSelected(selectedIds, visibleIds: Set(visibleOrder))
    }

    func toggleAll() {
        guard isActive, !isBusy else { return }
        selectedIds = ChatListSelection.togglingAll(selectedIds, visibleIds: Set(visibleOrder))
    }

    /// The list changed under the selection — a new filter, a search, a chat that moved away.
    /// Drops selections that are no longer visible, except while a batch is running: a chat it just
    /// archived or left is expected to leave the list, and the batch still owns it.
    func updateVisibleChats(_ orderedIds: [String]) {
        visibleOrder = orderedIds
        guard isActive, !isBusy else { return }
        let reconciled = ChatListSelection.reconcile(selectedIds, visibleIds: Set(orderedIds))
        if reconciled != selectedIds {
            selectedIds = reconciled
        }
    }

    /// Cancels a running batch and forgets the selection. Called when the owning account scope ends.
    func stop() {
        task?.cancel()
        task = nil
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
        let task = Task { [weak self] in
            guard let self else { return }
            defer { self.finish() }
            var leavable: [String] = []
            for chat in targets {
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
        let task = Task { [weak self] in
            guard let self else { return }
            defer { self.finish() }
            var departed = Set<String>()
            var failed = Set<String>()
            var waited: GroupChangeAdvisory?
            for groupIdHex in confirmation.groupIds {
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
                    try await runtime.selfDemoteAdminDetailed(accountRef: accountRef, groupIdHex: groupIdHex)
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
        let task = Task { [weak self] in
            guard let self else { return }
            defer { self.finish() }
            var failed = Set<String>()
            for groupIdHex in groupIds {
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
