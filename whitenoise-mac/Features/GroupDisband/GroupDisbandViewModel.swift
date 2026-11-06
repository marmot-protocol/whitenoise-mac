import Foundation
import MarmotKit
import Observation

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
    /// Why the last action stopped, for the surface to present. Cleared by the surface.
    var alert: ChatActionAlert?

    @ObservationIgnored private let accountRef: String
    @ObservationIgnored private let runtime: any MarmotRuntime

    init(accountRef: String, groupIdHex: String, runtime: any MarmotRuntime) {
        self.accountRef = accountRef
        self.groupIdHex = groupIdHex
        self.runtime = runtime
    }

    var isBusy: Bool { isEnding || isDismissingFailure }

    /// Ends the group: enables disbanding first when the group predates it, then asks MDK to
    /// disband. One confirmation covers both commits, and so does one advisory consent — the user
    /// agreed to end the group, not to each step it takes.
    ///
    /// Returns `true` once MDK has durably accepted the request. Completion — everyone removed, the
    /// group terminal — arrives later through the group's own state, so `true` means "ending", not
    /// "ended". On `false`, `alert` says why, unless the user chose to wait.
    @discardableResult
    func endGroup(_ state: GroupDisbandState, advisory: GroupChangeAdvisoryPrompter?) async -> Bool {
        guard !isBusy else { return false }
        guard state.canEndGroup else {
            alert = .endGroupFailed(state.blockerMessage ?? Self.cannotEndNowMessage)
            return false
        }
        isEnding = true
        defer { isEnding = false }

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
            _ = try await performGroupChange(advisory: advisory, consents: consents) {
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
            return try await runtime.acknowledgeDisbandFailure(accountRef: accountRef, groupIdHex: groupIdHex)
        } catch is CancellationError {
            return false
        } catch {
            alert = .disbandFailureDismissFailed(error.localizedDescription)
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
