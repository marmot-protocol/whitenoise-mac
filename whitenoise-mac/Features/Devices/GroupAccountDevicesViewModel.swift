import Foundation
import MarmotKit
import Observation

/// Whether one chat lets each member's own linked devices join it, and the admin action that turns
/// that on (MDK's `marmot.group.account-devices.v1`).
///
/// A linked device is added only to chats that carry the component: older chats need an admin to
/// turn it on once, and it can never be turned off. MDK's answer is about the whole chat and never
/// names who holds it back. The change is a group commit, so it runs through
/// `GroupChangeAdvisoryRetry` with the account's shared prompter, which `ContentView` hosts: group
/// details is a pane, not a sheet.
///
/// Inert unless the runtime opened with experimental device groups. Owned per group by `AccountScope`.
@MainActor
@Observable
final class GroupAccountDevicesViewModel {
    let isAvailable: Bool
    /// Nil until read, and after a failed read: the section then shows nothing rather than a guess.
    private(set) var activation: AccountDevicesActivationFfi?
    private(set) var isEnabling = false
    private(set) var error: String?

    @ObservationIgnored private let accountRef: String
    @ObservationIgnored let groupIdHex: String
    @ObservationIgnored private let runtime: (any MarmotRuntime)?
    @ObservationIgnored private let advisory: GroupChangeAdvisoryPrompter?

    init(
        accountRef: String,
        groupIdHex: String,
        runtime: (any MarmotRuntime)?,
        advisory: GroupChangeAdvisoryPrompter?,
        isAvailable: Bool? = nil
    ) {
        self.accountRef = accountRef
        self.groupIdHex = groupIdHex
        self.runtime = runtime
        self.advisory = advisory
        self.isAvailable = isAvailable ?? (runtime?.deviceGroupsEnabled == true)
    }

    func load() async {
        guard isAvailable, let runtime else { return }
        do {
            let next = try await runtime.accountDevicesActivation(accountRef: accountRef, groupIdHex: groupIdHex)
            try Task.checkCancellation()
            activation = next
        } catch {
            // Keep the last answer; an unreadable refresh is not evidence the chat changed.
        }
    }

    /// Turns account-devices on. Call only after the user confirmed: it can't be undone.
    @discardableResult
    func enable() async -> Bool {
        guard isAvailable, let runtime, !isEnabling else { return false }
        isEnabling = true
        error = nil
        defer { isEnabling = false }
        do {
            _ = try await GroupChangeAdvisoryRetry.perform(
                prompter: advisory,
                runtime: runtime,
                accountRef: accountRef,
                groupIdHex: groupIdHex
            ) {
                try await runtime.enableAccountDevices(accountRef: accountRef, groupIdHex: groupIdHex)
            }
            await load()
            return true
        } catch is GroupChangeAdvisoryDeclined {
            // Choosing Wait is a note, not an error.
            return false
        } catch is CancellationError {
            return false
        } catch MarmotKitError.AccountDevicesActivationRefused(_, let reason) {
            // MDK checked again and said why; show that state instead of a generic failure.
            activation = reason
            return false
        } catch {
            self.error = UserFacingError.message(for: error)
            return false
        }
    }

    static func preview(_ activation: AccountDevicesActivationFfi?) -> GroupAccountDevicesViewModel {
        let model = GroupAccountDevicesViewModel(
            accountRef: "preview", groupIdHex: "preview", runtime: nil, advisory: nil, isAvailable: true)
        model.activation = activation
        return model
    }
}
