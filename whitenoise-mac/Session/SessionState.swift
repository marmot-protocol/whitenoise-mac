import Foundation
import MarmotKit
import Observation

/// Per-launch state. The shell replaces `accountScope` whenever the selected
/// identity changes, making account teardown a lifetime boundary rather than a
/// checklist of fields to reset on `WorkspaceState`.
@MainActor
@Observable
final class SessionState {
    private(set) var accountScope: AccountScope?
    /// The app shell has two independent task owners (bootstrap and account-id observation), so
    /// cancelling either task cannot supersede an activation already suspended in old-scope
    /// revocation. This ticket lets only the most recent caller install a replacement scope.
    @ObservationIgnored private var activationToken = UUID()

    func activate(
        account: AccountItem?,
        runtime: (any MarmotRuntime)?,
        connectivityAvailable: Bool,
        relayListsDidChange: @escaping @MainActor () -> Void = {},
        attachmentsDidChange: @escaping @MainActor () async -> Void = {}
    ) async {
        guard let account, let runtime else {
            await deactivate()
            return
        }
        guard accountScope?.account.id != account.id else { return }

        let ticket = UUID()
        activationToken = ticket
        let previous = accountScope
        accountScope = nil
        await previous?.cancelAll()
        guard activationToken == ticket, !Task.isCancelled else { return }
        let scope = AccountScope(
            account: account,
            runtime: runtime,
            relayListsDidChange: relayListsDidChange,
            attachmentsDidChange: attachmentsDidChange
        )
        accountScope = scope
        scope.start(connectivityAvailable: connectivityAvailable)
        await updateProductAnalyticsActivity(.accountChanged)
    }

    /// The Dock / ⌘-Tab badge. MDK's attention snapshot covers every signed-in account, so the
    /// active scope's model carries the whole total. Between scopes (an account switch) the
    /// count is unknown (`nil`) and the badge keeps its last value, unless the account it left
    /// was signed out or removed (see `DockBadgeController.activeAccountDidChange`); with nobody
    /// signed in it clears.
    func applicationBadgeCount(hasSignedInAccounts: Bool) -> Int? {
        if let accountScope {
            return accountScope.attentionModel.applicationBadgeCount
        }
        return hasSignedInAccounts ? nil : 0
    }

    func updateConnectivity(available: Bool) {
        accountScope?.updateConnectivity(available: available)
    }

    /// Product activity is best-effort and contains no account or content labels. MarmotKit
    /// applies the current combined consent before recording or exporting it.
    func updateProductAnalyticsActivity(_ activity: ProductAnalyticsActivityFfi) async {
        guard let runtime = accountScope?.runtime else { return }
        do {
            try await runtime.setProductAnalyticsActivity(activity: activity)
        } catch is CancellationError {
            return
        } catch {
            // Lifecycle reporting cannot block account activation or app suspension.
        }
    }

    func deactivate() async {
        activationToken = UUID()
        let previous = accountScope
        accountScope = nil
        await previous?.cancelAll()
    }
}
