import Foundation
import MarmotKit
import SwiftUI

/// What MDK's sign-out-and-wipe left undone, worded for the user. Shown after the account is gone,
/// so the shell hosts it: the sign-out sheet and the Delete Profile page leave with the account.
///
/// Nil when there is nothing to say: everything was handed off or left and the local copy is gone.
/// `siblingsNotReached` is always said, even when everything else was clean, because the other
/// devices may still list this one until the user removes it from one of them.
nonisolated struct AccountWipeReport: Identifiable, Equatable {
    let id = UUID()
    let lines: [String]

    init?(outcome: WipeOutcomeFfi) {
        var lines: [String] = []
        if outcome.siblingsNotReached {
            lines.append(
                L10n.string(
                    "Your other devices couldn’t be reached. They may still list this device until you remove it from one of them."
                ))
        }
        if outcome.groupsLeftToSiblings > 0 {
            lines.append(
                String(
                    format: L10n.string("Chats left to your other devices to finish: %lld."),
                    Int64(outcome.groupsLeftToSiblings)))
        }
        if !outcome.groupLeaveFailures.isEmpty {
            lines.append(
                String(
                    format: L10n.string("Chats this device couldn’t leave: %lld."),
                    Int64(outcome.groupLeaveFailures.count)))
        }
        if !outcome.localCleanup.completed {
            lines.append(L10n.string("Some of this profile’s data couldn’t be removed from this device."))
        }
        guard !lines.isEmpty else { return nil }
        self.lines = lines
    }

    static func == (lhs: AccountWipeReport, rhs: AccountWipeReport) -> Bool { lhs.id == rhs.id }
}

extension View {
    func accountWipeReportAlert(_ session: SessionState) -> some View {
        let report = session.wipeReport
        return alert(
            L10n.string("Signed Out"),
            isPresented: Binding(
                get: { session.wipeReport != nil },
                set: { presented in
                    if !presented { session.wipeReport = nil }
                }
            ),
            presenting: report
        ) { _ in
            Button(L10n.string("OK"), role: .cancel) { session.wipeReport = nil }
        } message: { report in
            Text(report.lines.joined(separator: "\n\n"))
        }
    }
}
