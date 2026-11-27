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
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(WNColor.intentionWarningContent)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 2) {
                    Text(BlockedLeavePresentation.title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                    Text(BlockedLeavePresentation.detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 0)
            }

            if canCancel {
                HStack(spacing: 8) {
                    Button(BlockedLeavePresentation.cancelAction, action: onCancel)
                        .wnSecondaryButtonStyle()
                        .controlSize(.small)
                        .disabled(isCancelling)
                    if isCancelling {
                        ProgressView().controlSize(.small)
                    }
                }
            }

            if let failure {
                Text(failure)
                    .font(.caption)
                    .foregroundStyle(WNColor.intentionErrorContent)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(WNColor.backgroundPrimary, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(WNColor.borderTertiary, lineWidth: 1)
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
