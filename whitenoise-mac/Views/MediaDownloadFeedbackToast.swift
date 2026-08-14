import SwiftUI

/// Transient confirmation for an attachment download, pinned to the window's bottom-leading
/// corner.
///
/// It is the only feedback the gesture gives: the file lands in the Downloads folder without a
/// save panel, so without this the click would look like nothing happened. Non-interactive by
/// design — it floats over the transcript and the image gallery, and must never swallow a click
/// meant for either.
struct MediaDownloadFeedbackToast: View {
    @Environment(WorkspaceState.self) private var workspace

    var body: some View {
        Group {
            if let feedback = workspace.mediaDownloadFeedback {
                MediaDownloadFeedbackToastContent(feedback: feedback)
                    .padding(.leading, 16)
                    .padding(.bottom, 16)
                    .transition(.move(edge: .leading).combined(with: .opacity))
            }
        }
        .allowsHitTesting(false)
        .animation(.smooth(duration: 0.2), value: workspace.mediaDownloadFeedback)
    }
}

struct MediaDownloadFeedbackToastContent: View {
    @Environment(\.locale) private var locale
    let feedback: MediaDownloadFeedback

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: feedback.hasFailures ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                .foregroundStyle(
                    feedback.hasFailures ? WNColor.intentionWarningContent : WNColor.intentionSuccessContent
                )

            VStack(alignment: .leading, spacing: 2) {
                if feedback.savedCount > 0 {
                    Text(
                        L10n.plural(
                            "%lld files downloaded", Int64(feedback.savedCount), locale: locale)
                    )
                    .wnFont(.medium12)
                    .foregroundStyle(WNColor.backgroundContentPrimary)
                }
                if feedback.failedCount > 0 {
                    Text(
                        L10n.plural(
                            "%lld files couldn't be downloaded", Int64(feedback.failedCount),
                            locale: locale)
                    )
                    .wnFont(.medium12)
                    .foregroundStyle(WNColor.backgroundContentSecondary)
                }
            }
            .multilineTextAlignment(.leading)
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        // Glass first, cap second. `frame(maxWidth:)` fills whatever it is proposed, so capping
        // before the background paints a 320pt card behind "1 file downloaded"; capping after
        // leaves the card hugging its text and only bounds how wide a long translation may wrap.
        .glassCard(cornerRadius: 10)
        .frame(maxWidth: 320, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}
