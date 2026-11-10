import SwiftUI

/// Explains a leave MDK cannot finish because this account is now the group's only admin, and
/// offers MDK's device-local Cancel. Replaces the composer, and sits in group info's leave section.
struct BlockedLeaveNotice: View {
    let canCancel: Bool
    let isCancelling: Bool
    let failure: String?
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .wnFont(.semiBold14)
                    .foregroundStyle(WNColor.intentionWarningContent)

                VStack(alignment: .leading, spacing: 2) {
                    Text(BlockedLeavePresentation.title)
                        .wnFont(.semiBold12)
                    Text(BlockedLeavePresentation.detail)
                        .wnFont(.medium10)
                        .foregroundStyle(WNColor.backgroundContentSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 0)
            }

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
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .glassCard()
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
