import MarmotKit
import SwiftUI

/// One "history may be incomplete" notice with the user's dismissal.
///
/// A plain-value view: the caller resolves the wording and owns the dismissal, so the same
/// banner serves the account list and a group's recovery section.
struct HistoryNoticeBanner: View {
    let message: String
    let isDismissing: Bool
    let onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .trailing, spacing: 8) {
            WNCallout(
                title: L10n.string("History may be incomplete"),
                message: message,
                intent: .warning
            )

            Button(L10n.string("Dismiss"), action: onDismiss)
                .buttonStyle(.wnSecondary)
                .controlSize(.small)
                .disabled(isDismissing)
        }
    }
}

/// The account-wide notices (those with no group), stacked under the chat list header.
///
/// Deliberately inside the drawer rather than on the window's top edge, which belongs to
/// `BackgroundStatusBanner` and the offline band.
struct AccountHistoryNoticesView: View {
    let model: HistoryNoticesViewModel

    var body: some View {
        let notices = model.accountNotices
        if !notices.isEmpty {
            VStack(spacing: 8) {
                ForEach(notices, id: \.noticeId) { notice in
                    HistoryNoticeBanner(
                        message: HistoryNoticePresentation.message(for: notice.cause),
                        isDismissing: model.dismissing.contains(notice.noticeId),
                        onDismiss: { Task { await model.dismiss([notice.noticeId]) } }
                    )
                }
                if let error = model.error {
                    Text(error)
                        .wnFont(.medium12)
                        .foregroundStyle(WNColor.intentionErrorContent)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
        }
    }
}

#Preview("Banner") {
    HistoryNoticeBanner(
        message: HistoryNoticePresentation.message(for: .deliveryLoss),
        isDismissing: false,
        onDismiss: {}
    )
    .padding()
    .frame(width: 320)
}

#Preview("Dismissing") {
    HistoryNoticeBanner(
        message: HistoryNoticePresentation.message(for: .maintenanceBoundary),
        isDismissing: true,
        onDismiss: {}
    )
    .padding()
    .frame(width: 320)
}

#Preview("Account notices") {
    AccountHistoryNoticesView(
        model: .preview(notices: [
            HistoryNoticeFfi(noticeId: "a", cause: .deliveryLoss, groupIdHex: nil, parkedAtMs: nil),
            HistoryNoticeFfi(noticeId: "b", cause: .incrementalHistory, groupIdHex: nil, parkedAtMs: nil),
            HistoryNoticeFfi(noticeId: "c", cause: .epochGap, groupIdHex: "group", parkedAtMs: nil),
        ])
    )
    .frame(width: 320)
}
