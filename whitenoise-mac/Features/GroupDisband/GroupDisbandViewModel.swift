import Foundation
import MarmotKit
import Observation

/// What ending a group needs from the rest of the app: whether another group commit already holds
/// the inspector, and how to read back what MDK reports once the attempt is over. Installed by the
/// shell, which owns the legacy group-details and chat-list state these touch.
nonisolated struct GroupDisbandHooks: Sendable {
    /// Another group commit is running. End Group joins the inspector's one-commit-at-a-time rule
    /// rather than racing it.
    var isOtherGroupCommitInFlight: @MainActor () -> Bool = { false }
    /// Re-read the open group's details. Runs after every attempt, failed ones included: enabling
    /// disbanding can commit even when the disband after it is refused.
    var groupDetailsDidChange: @MainActor () async -> Void = {}
    /// Re-read the chat list, so the row picks up the group's new lifecycle. Runs once MDK accepts.
    var chatListDidChange: @MainActor () async -> Void = {}
}

/// Ends one group for everyone, and clears the record of an attempt that failed.
///
/// Owned per group by `AccountScope`, so an account switch drops whatever was in flight with the
/// account it belonged to. The model holds only the action's own progress; what the group looks
/// like afterwards is MDK's to say, read back through the ordinary group-details reload.
@MainActor
@Observable
final class GroupDisbandViewModel {
    let groupIdHex: String
    private(set) var isEnding = false
    private(set) var isDismissingFailure = false
    /// The request MDK returned when it accepted this account's End Group, held until the group's
    /// own state reports it (`snapshotDidChange(_:)`). Surfaces read the group through
    /// `reconciled(_:)`, so a read-back that lags the acceptance cannot offer End Group again.
    ///
    /// Known limit: it lives as long as this model, which `AccountScope.releaseConversation` drops
    /// when the user leaves the chat. Coming back before MDK's projection catches up (expected to
    /// take well under a second) shows the lagging state again; a run still in flight stays covered
    /// by the scope's `endingGroupIds`.
    private(set) var acceptedRequest: DisbandRequestFfi?
    /// Why the last action stopped, for the surface to present. Cleared by the surface.
    var alert: ChatActionAlert?

    @ObservationIgnored private let accountRef: String
    @ObservationIgnored private let runtime: any MarmotRuntime
    @ObservationIgnored private let hooks: GroupDisbandHooks
    /// Tells the owning scope when a run starts and stops, so surfaces outside this group's
    /// inspector can hold their own commits until it is done.
    @ObservationIgnored private let onEndingChanged: @MainActor (Bool) -> Void

    init(
        accountRef: String,
        groupIdHex: String,
        runtime: any MarmotRuntime,
        hooks: GroupDisbandHooks = GroupDisbandHooks(),
        onEndingChanged: @escaping @MainActor (Bool) -> Void = { _ in }
    ) {
        self.accountRef = accountRef
        self.groupIdHex = groupIdHex
        self.runtime = runtime
        self.hooks = hooks
        self.onEndingChanged = onEndingChanged
    }

    var isBusy: Bool { isEnding || isDismissingFailure }

    /// The group's state as a surface should show it: what MDK reports, with this account's
    /// accepted request standing in until MDK reports one itself.
    func reconciled(_ state: GroupDisbandState) -> GroupDisbandState {
        state.merging(request: acceptedRequest)
    }

    /// Lets go of the accepted request once the group's own state reports a request or a
    /// lifecycle past active. Holding it longer would resurrect "ending" after a failed request is
    /// dismissed and the group reads as active again.
    ///
    /// This is the only release path besides a dismissed failure, on purpose: if MDK ever dropped
    /// an accepted request without moving the lifecycle, "pending" would stay pinned for this
    /// model's lifetime — which ends when the user leaves the chat, so it heals itself.
    func snapshotDidChange(_ state: GroupDisbandState) {
        if acceptedRequest != nil, state.reportsRequest {
            acceptedRequest = nil
        }
    }

    /// Ends the group: enables disbanding first when the group predates it, then asks MDK to
    /// disband. One confirmation covers both commits, and so does one advisory consent — the user
    /// agreed to end the group, not to each step it takes.
    ///
    /// Returns `true` once MDK has durably accepted the request. Completion — everyone removed, the
    /// group terminal — arrives later through the group's own state, so `true` means "ending", not
    /// "ended". On `false`, `alert` says why, unless the user chose to wait.
    ///
    /// Refuses to start while another group commit is in flight. Once started, `isEnding` holds
    /// through the commits *and* the read-back after them, so nothing else commits against the
    /// group before the inspector shows what MDK now reports.
    @discardableResult
    func endGroup(_ state: GroupDisbandState, advisory: GroupChangeAdvisoryPrompter?) async -> Bool {
        guard !isBusy, !hooks.isOtherGroupCommitInFlight() else { return false }
        setEnding(true)
        defer { setEnding(false) }

        let accepted = await performEndGroup(state, advisory: advisory)
        await hooks.groupDetailsDidChange()
        if accepted {
            await hooks.chatListDidChange()
        }
        return accepted
    }

    private func setEnding(_ ending: Bool) {
        isEnding = ending
        onEndingChanged(ending)
    }

    private func performEndGroup(_ state: GroupDisbandState, advisory: GroupChangeAdvisoryPrompter?) async -> Bool {
        guard state.canEndGroup else {
            alert = .endGroupFailed(state.blockerMessage ?? Self.cannotEndNowMessage)
            return false
        }
        let consents = GroupChangeAdvisoryConsents()
        do {
            var current = state
            if !current.canDisband {
                let result = try await performGroupChange(advisory: advisory, consents: consents) {
                    try await runtime.enableGroupDisbanding(accountRef: accountRef, groupIdHex: groupIdHex)
                }
                current = GroupDisbandState(managementState: result.managementState, group: result.details.group)
            }
            guard current.canDisband else {
                alert = .endGroupFailed(current.blockerMessage ?? Self.cannotEndNowMessage)
                return false
            }
            // Held before the read-back runs, so no frame shows the group as still endable.
            acceptedRequest = try await performGroupChange(advisory: advisory, consents: consents) {
                try await runtime.disbandGroup(accountRef: accountRef, groupIdHex: groupIdHex)
            }
            return true
        } catch let declined as GroupChangeAdvisoryDeclined {
            // Choosing Wait is a note about the group, not a failure to end it.
            alert = declined.advisory.waitedAlert
            return false
        } catch is CancellationError {
            return false
        } catch {
            alert = .endGroupFailed(GroupDisbandPresentation.message(for: error))
            return false
        }
    }

    /// Clears a failed request the user has read. Returns whether MDK held one to clear.
    @discardableResult
    func dismissFailure() async -> Bool {
        guard !isBusy else { return false }
        isDismissingFailure = true
        defer { isDismissingFailure = false }
        do {
            let cleared = try await runtime.acknowledgeDisbandFailure(accountRef: accountRef, groupIdHex: groupIdHex)
            if cleared { acceptedRequest = nil }
            return cleared
        } catch is CancellationError {
            return false
        } catch {
            alert = .disbandFailureDismissFailed(UserFacingError.message(for: error))
            return false
        }
    }

    private func performGroupChange<Result>(
        advisory: GroupChangeAdvisoryPrompter?,
        consents: GroupChangeAdvisoryConsents,
        _ change: () async throws -> Result
    ) async throws -> Result {
        try await GroupChangeAdvisoryRetry.perform(
            prompter: advisory,
            consents: consents,
            runtime: runtime,
            accountRef: accountRef,
            groupIdHex: groupIdHex,
            change
        )
    }

    private static var cannotEndNowMessage: String { L10n.string("This group can't be ended right now.") }
}
