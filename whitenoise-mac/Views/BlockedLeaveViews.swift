import SwiftUI

/// Explains a leave MDK cannot finish because this account is now the group's only admin, and
/// offers MDK's device-local Cancel. Replaces the composer, and sits in group info's leave section.
struct BlockedLeaveNotice: View {
    let canCancel: Bool
    let isCancelling: Bool
    let failure: String?
    let onCancel: () -> Void

    var body: some View {
        // The action sits under the callout, never inside it, as `HistoryNoticeBanner` does.
        VStack(alignment: .leading, spacing: 8) {
            WNCallout(
                title: BlockedLeavePresentation.title,
                message: BlockedLeavePresentation.detail,
                intent: .warning
            )

            if canCancel {
                HStack(spacing: 8) {
                    Button(BlockedLeavePresentation.cancelAction, action: onCancel)
                        .buttonStyle(.wnSecondary)
                        .controlSize(.small)
                        .disabled(isCancelling)
                    if isCancelling {
                        ProgressView().controlSize(.small)
                    }
                }
            }

            if let failure {
                Text(failure)
                    .wnFont(.medium10)
                    .foregroundStyle(WNColor.intentionErrorContent)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityIdentifier("composer.blockedLeave")
    }
}

#Preview("Blocked leave") {
    BlockedLeaveNotice(canCancel: true, isCancelling: false, failure: nil, onCancel: {})
        .padding()
        .frame(width: 520)
}

#Preview("Cancel failed") {
    BlockedLeaveNotice(
        canCancel: true, isCancelling: false, failure: "This leave is no longer blocked.", onCancel: {}
    )
    .padding()
    .frame(width: 520)
}
