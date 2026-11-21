import Foundation
import MarmotKit
import Observation
import SwiftUI

/// Link requests for the signed-in profiles that aren't active. The active profile's requests are
/// its `DeviceLinkingViewModel`'s; this watches the rest, so a new device asking to link another
/// profile is answered from here rather than staying invisible until the user switches to it.
///
/// It reads each profile's link snapshot once, then again only on that profile's own
/// `DeviceLinkChanged`. It never answers a request: Review switches to the profile, whose own
/// model then presents the request, and comparing and linking stay bound to that profile.
/// Owned by `SessionState`, for the life of the runtime.
@MainActor
@Observable
final class ProfileLinkRequestsMonitor {
    struct Request: Identifiable, Equatable {
        var id: String { accountIdHex }
        let accountIdHex: String
        let profileName: String
    }

    /// Profiles with a request that needs an answer, by account id: their prompt ids.
    private(set) var pending: [String: [String]] = [:]
    /// The request the shell's alert shows.
    private(set) var alert: Request?

    /// Prompts the user put off with Not Now this launch; they are not raised again.
    @ObservationIgnored private var putOff: Set<String> = []

    /// Runs until cancelled. The shell restarts it when the runtime or the set of signed-in profiles
    /// changes: a profile signed in meanwhile may have had its one `DeviceLinkChanged` before it was
    /// listed, so every start reads each profile again, and drops what a signed-out profile had.
    func observe(_ runtime: any MarmotRuntime, accounts: @escaping @MainActor () -> [AccountItem]) async {
        guard runtime.deviceGroupsEnabled else { return }
        let subscription = runtime.subscribeEvents()
        let signedIn = Set(accounts().filter { !$0.signedOut }.map { $0.accountIdHex.lowercased() })
        pending = pending.filter { signedIn.contains($0.key) }
        if let alert, !signedIn.contains(alert.accountIdHex) { self.alert = nil }
        for account in accounts() {
            await refresh(account, runtime: runtime)
        }
        while !Task.isCancelled {
            guard let event = try? await runtime.nextEvent(subscription: subscription) else { return }
            guard case .deviceLinkChanged(let accountIdHex, _) = event else { continue }
            let id = accountIdHex.lowercased()
            if let account = accounts().first(where: { $0.accountIdHex.lowercased() == id }) {
                await refresh(account, runtime: runtime)
            }
        }
    }

    /// Requests for profiles other than `activeAccountIdHex`, with their names, for Settings → Devices.
    func requests(excluding activeAccountIdHex: String?, accounts: [AccountItem]) -> [Request] {
        let active = activeAccountIdHex?.lowercased()
        return accounts.compactMap { account in
            let id = account.accountIdHex.lowercased()
            guard id != active, pending[id]?.isEmpty == false else { return nil }
            return Request(accountIdHex: id, profileName: account.displayName)
        }
    }

    /// Raises the alert for the first other profile with a request not put off, unless one is up.
    func presentIfNeeded(activeAccountIdHex: String?, accounts: [AccountItem]) {
        guard alert == nil else { return }
        let active = activeAccountIdHex?.lowercased()
        alert =
            accounts.lazy.compactMap { account -> Request? in
                let id = account.accountIdHex.lowercased()
                guard id != active, let prompts = self.pending[id],
                    prompts.contains(where: { !self.putOff.contains($0) })
                else { return nil }
                return Request(accountIdHex: id, profileName: account.displayName)
            }.first
    }

    /// Not Now: the request stays listed in Settings → Devices, but this launch doesn't raise it again.
    func putOffAlert() {
        guard let alert else { return }
        putOff.formUnion(pending[alert.accountIdHex] ?? [])
        self.alert = nil
    }

    /// Review: the alert closes; the shell switches to the profile, whose model shows the request.
    func takeAlert() -> Request? {
        defer { alert = nil }
        return alert
    }

    private func refresh(_ account: AccountItem, runtime: any MarmotRuntime) async {
        let id = account.accountIdHex.lowercased()
        // A replaced observer's read can finish after its successor pruned or re-read this profile,
        // so a cancelled one writes nothing.
        guard !account.signedOut, !Task.isCancelled,
            let snapshot = try? await runtime.deviceLinkSnapshot(accountRef: account.accountRef),
            !Task.isCancelled
        else { return }
        let prompts = snapshot.prompts.filter { DeviceLinkPresentation.needsAttention($0.state) }.map(\.promptId)
        pending[id] = prompts.isEmpty ? nil : prompts
        if let alert, alert.accountIdHex == id, prompts.isEmpty {
            self.alert = nil
        }
    }
}

extension View {
    /// "A device wants to link <Profile>": Review switches to that profile.
    func profileLinkRequestAlert(
        _ monitor: ProfileLinkRequestsMonitor, onReview: @escaping (ProfileLinkRequestsMonitor.Request) -> Void
    ) -> some View {
        let request = monitor.alert
        return alert(
            L10n.string("Link a New Device?"),
            isPresented: Binding(
                get: { monitor.alert != nil },
                set: { presented in
                    if !presented, monitor.alert != nil { monitor.putOffAlert() }
                }
            ),
            presenting: request
        ) { _ in
            Button(L10n.string("Review")) {
                if let taken = monitor.takeAlert() { onReview(taken) }
            }
            Button(L10n.string("Not Now"), role: .cancel) { monitor.putOffAlert() }
        } message: { request in
            Text(ProfileLinkRequestsPresentation.message(profileName: request.profileName))
        }
    }
}

nonisolated enum ProfileLinkRequestsPresentation {
    static func message(profileName: String) -> String {
        String(format: L10n.string("A device wants to link %@."), profileName)
    }
}
