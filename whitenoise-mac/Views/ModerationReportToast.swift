import SwiftUI

/// Transient outcome of a report or a Block and Report, pinned beside the download toast.
///
/// The sheet or dialog that started it has closed by the time MDK answers, so this is the only
/// place the outcome can show. Non-interactive, like `MediaDownloadFeedbackToast`: it floats over
/// the transcript and must never swallow a click meant for it.
struct ModerationReportToast: View {
    static let displayDuration: Duration = .seconds(5)

    let reporter: ModerationReporter?

    var body: some View {
        Group {
            if let reporter, let notice = reporter.notice {
                ModerationReportToastContent(notice: notice)
                    .padding(.leading, 16)
                    .padding(.bottom, 16)
                    .transition(.move(edge: .leading).combined(with: .opacity))
                    .task(id: notice.id) {
                        try? await Task.sleep(for: Self.displayDuration)
                        guard !Task.isCancelled else { return }
                        reporter.dismissNotice(notice.id)
                    }
            }
        }
        .allowsHitTesting(false)
        .animation(.smooth(duration: 0.2), value: reporter?.notice)
    }
}

struct ModerationReportToastContent: View {
    let notice: ModerationReportNotice

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: notice.kind == .success ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(
                    notice.kind == .success ? WNColor.intentionSuccessContent : WNColor.intentionWarningContent
                )

            VStack(alignment: .leading, spacing: 2) {
                Text(notice.title)
                    .wnFont(.medium12)
                    .foregroundStyle(WNColor.backgroundContentPrimary)
                if let message = notice.message {
                    Text(message)
                        .wnFont(.medium12)
                        .foregroundStyle(WNColor.backgroundContentSecondary)
                }
            }
            .multilineTextAlignment(.leading)
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        // Glass first, cap second, as in `MediaDownloadFeedbackToastContent`: capping before the
        // background would paint a full-width card behind a short title.
        .glassCard(cornerRadius: 10)
        .frame(maxWidth: 320, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

#Preview("Report submitted") {
    ModerationReportToastContent(
        notice: ModerationReportNotice(
            kind: .success,
            title: "Report submitted",
            message: "Sent to the group. Sent to the White Noise team."
        )
    )
    .padding()
}

#Preview("Report not sent") {
    ModerationReportToastContent(
        notice: ModerationReportNotice(
            kind: .failure,
            title: "Report not sent",
            message: "You’ve sent a lot of reports recently. Try again later."
        )
    )
    .padding()
}

/// A queued send MDK dropped once its group settled (`QueuedIntentRefused`). Same chrome and
/// placement as the report toast; non-interactive for the same reason.
struct RefusedIntentToast: View {
    let model: RefusedIntentNoticesViewModel?

    var body: some View {
        Group {
            if let model, let notice = model.notice {
                ModerationReportToastContent(notice: notice)
                    .padding(.leading, 16)
                    .padding(.bottom, 16)
                    .transition(.move(edge: .leading).combined(with: .opacity))
                    .task(id: notice.id) {
                        try? await Task.sleep(for: RefusedIntentNoticesViewModel.displayDuration)
                        guard !Task.isCancelled else { return }
                        model.dismissNotice(notice.id)
                    }
            }
        }
        .allowsHitTesting(false)
        .animation(.smooth(duration: 0.2), value: model?.notice)
    }
}

#Preview("Queued change refused") {
    ModerationReportToastContent(
        notice: ModerationReportNotice(
            kind: .failure,
            title: RefusedIntentPresentation.title(intentKind: "invite"),
            message: RefusedIntentPresentation.message(reason: "not_group_admin")
        )
    )
    .padding()
}
