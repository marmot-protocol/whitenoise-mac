import SwiftUI

/// Report and Block for one message row, shared by the context menu and the hover strip's overflow
/// so both offer the same actions (`MessageRowAction.all`).
struct MessageModerationActions {
    let eligibility: MessageModerationEligibility
    let report: () -> Void
    let block: () -> Void
}

/// The author a picked Block is waiting on confirmation for.
struct MessageBlockTarget: Identifiable, Equatable {
    let accountIdHex: String
    var id: String { accountIdHex }
}

extension View {
    /// The Report Message sheet and the Block confirmation a message row opens. Owned by the row
    /// because the menu that picked them is gone by the time either shows.
    func messageModerationPresentations(
        report: Binding<ReportMessageViewModel?>,
        blockTarget: Binding<MessageBlockTarget?>,
        reporter: ModerationReporter?
    ) -> some View {
        modifier(
            MessageModerationPresentations(report: report, blockTarget: blockTarget, reporter: reporter)
        )
    }
}

private struct MessageModerationPresentations: ViewModifier {
    @Binding var report: ReportMessageViewModel?
    @Binding var blockTarget: MessageBlockTarget?
    let reporter: ModerationReporter?

    func body(content: Content) -> some View {
        content
            .sheet(item: $report) { model in
                ReportMessageSheet(model: model, dismiss: { report = nil })
            }
            .blockUserConfirmation(target: $blockTarget, reporter: reporter)
    }
}

extension View {
    /// "Block this user?" with Block User and — when this build can reach the White Noise team —
    /// Block and Report. The report is sent only after the block is confirmed.
    func blockUserConfirmation(
        target: Binding<MessageBlockTarget?>,
        reporter: ModerationReporter?
    ) -> some View {
        confirmationDialog(
            L10n.string("Block this user?"),
            isPresented: Binding(
                get: { target.wrappedValue != nil },
                set: { isPresented in
                    if !isPresented { target.wrappedValue = nil }
                }
            ),
            titleVisibility: .visible,
            presenting: target.wrappedValue
        ) { target in
            if let reporter {
                if reporter.isAvailable {
                    Button(L10n.string("Block and Report"), role: .destructive) {
                        reporter.startBlocking(accountIdHex: target.accountIdHex, reporting: true)
                    }
                }
                Button(L10n.string("Block User"), role: .destructive) {
                    reporter.startBlocking(accountIdHex: target.accountIdHex, reporting: false)
                }
            }
            Button(L10n.string("Cancel"), role: .cancel) {}
        } message: { _ in
            BlockUserConfirmationMessage(reportsToTeam: reporter?.isAvailable == true)
        }
    }
}

struct BlockUserConfirmationMessage: View {
    let reportsToTeam: Bool

    var body: some View {
        if reportsToTeam {
            Text(L10n.string("You won't see their messages. Block and Report also notifies the White Noise team."))
        } else {
            Text(L10n.string("You won't see their messages."))
        }
    }
}

#Preview("Block confirmation message") {
    VStack(alignment: .leading, spacing: 12) {
        BlockUserConfirmationMessage(reportsToTeam: true)
        BlockUserConfirmationMessage(reportsToTeam: false)
    }
    .padding()
    .frame(width: 360)
}
