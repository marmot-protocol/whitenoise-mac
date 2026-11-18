import Foundation
import MarmotKit
import Observation
import SwiftUI

/// Watches for MDK's `DeviceUnlinked`: another of the account's devices removed this Mac, and MDK has
/// already signed the account out here. Fires once, for any signed-in account, not just the active
/// one, so the shell owns it rather than an `AccountScope`.
///
/// MDK asks hosts to say this device was unlinked and to stop showing its history. The account can't
/// sign in again as it is (`AccountUnlinked`); removing it from this Mac and signing in anew links the
/// device again. A profile left with Later is signed out, and signed-out profiles appear nowhere in
/// the app, so the notice comes back: once each launch while the profile is still here
/// (`remind(about:)`), and whenever signing in to it is refused (`present(_:)`).
/// Owned by `SessionState`, for the life of the launch.
@MainActor
@Observable
final class DeviceUnlinkMonitor {
    struct Notice: Identifiable, Equatable {
        var id: String { accountIdHex }
        let accountIdHex: String
        let accountLabel: String
    }

    /// The notice on screen. Others wait in `queue`; one alert at a time.
    private(set) var notice: Notice?
    @ObservationIgnored private var queue: [Notice] = []
    /// Accounts already raised this launch, so a launch reminder doesn't repeat one.
    @ObservationIgnored private var raised: Set<String> = []

    /// Runs until cancelled, so the shell ties it to the runtime's lifetime with `.task(id:)`.
    func observe(_ runtime: any MarmotRuntime) async {
        guard runtime.deviceGroupsEnabled else { return }
        let subscription = runtime.subscribeEvents()
        while !Task.isCancelled {
            guard let event = try? await runtime.nextEvent(subscription: subscription) else { return }
            if case .deviceUnlinked(let accountIdHex, let accountLabel) = event {
                receive(Notice(accountIdHex: accountIdHex.lowercased(), accountLabel: accountLabel))
            }
        }
    }

    /// Raises the notice for each unlinked profile still on this Mac that hasn't had it this launch.
    func remind(about accounts: [AccountItem]) {
        for account in accounts where account.unlinked {
            let id = account.accountIdHex.lowercased()
            guard !raised.contains(id) else { continue }
            receive(Notice(accountIdHex: id, accountLabel: account.accountRef))
        }
    }

    /// Raises the notice for `account` now, even if it was put off this launch: signing in to it was
    /// just refused, and deleting it is the way forward.
    func present(_ account: AccountItem) {
        receive(Notice(accountIdHex: account.accountIdHex.lowercased(), accountLabel: account.accountRef))
    }

    func receive(_ next: Notice) {
        raised.insert(next.accountIdHex)
        guard notice != next, !queue.contains(next) else { return }
        if notice == nil {
            notice = next
        } else {
            queue.append(next)
        }
    }

    func dismiss() {
        notice = queue.isEmpty ? nil : queue.removeFirst()
    }
}

nonisolated enum DeviceUnlinkPresentation {
    static func message(accountName: String?) -> String {
        guard let accountName = accountName?.trimmingCharacters(in: .whitespacesAndNewlines), !accountName.isEmpty
        else {
            return L10n.string(
                "Another of your linked devices removed this Mac, so it no longer gets updates for this profile. You can delete everything this profile kept on this Mac."
            )
        }
        return String(
            format: L10n.string(
                "Another of your linked devices removed this Mac from %@, so it no longer gets updates for that profile. You can delete everything it kept on this Mac."
            ),
            accountName)
    }
}

extension View {
    /// The "This Mac was unlinked" alert. `onRemove` removes that account from this Mac; `onLater`
    /// leaves it, signed out, and moves the app off it.
    func deviceUnlinkAlert(
        _ monitor: DeviceUnlinkMonitor,
        accountName: @escaping (DeviceUnlinkMonitor.Notice) -> String?,
        onRemove: @escaping (DeviceUnlinkMonitor.Notice) -> Void,
        onLater: @escaping (DeviceUnlinkMonitor.Notice) -> Void
    ) -> some View {
        let notice = monitor.notice
        return alert(
            L10n.string("This Mac Was Unlinked"),
            isPresented: Binding(
                get: { monitor.notice != nil },
                set: { presented in
                    if !presented, monitor.notice == notice { monitor.dismiss() }
                }
            ),
            presenting: notice
        ) { notice in
            Button(L10n.string("Delete Everything"), role: .destructive) {
                monitor.dismiss()
                onRemove(notice)
            }
            Button(L10n.string("Later"), role: .cancel) {
                monitor.dismiss()
                onLater(notice)
            }
        } message: { notice in
            // MDK's account label is an internal id, so the name comes from the shell's account list.
            Text(DeviceUnlinkPresentation.message(accountName: accountName(notice)))
        }
    }
}
