import AppKit
import SwiftUI

/// Transient confirmation for an attachment download, pinned to the window's bottom-leading
/// corner.
///
/// It is the only feedback the gesture gives — a remembered folder takes the file without any
/// panel — and the only way back to what was saved, through its Show in Finder button. It floats
/// over the transcript and the image gallery, so only the card itself takes clicks; the padding
/// around it never does.
struct MediaDownloadFeedbackToast: View {
    static let displayDuration: Duration = .seconds(4)

    @Environment(WorkspaceState.self) private var workspace
    /// The timer holds while the pointer is on the card, so Show in Finder is still there when the
    /// pointer arrives.
    @State private var isHovering = false

    var body: some View {
        Group {
            if let feedback = workspace.mediaDownloadFeedback {
                MediaDownloadFeedbackToastContent(feedback: feedback)
                    .onHover { isHovering = $0 }
                    .onDisappear { isHovering = false }
                    .padding(.leading, 16)
                    .padding(.bottom, 16)
                    .transition(.move(edge: .leading).combined(with: .opacity))
                    // A new value (another gesture folded in) or the pointer leaving restarts it.
                    .task(id: DismissalTimer(feedback: feedback, isHovering: isHovering)) {
                        guard !isHovering else { return }
                        try? await Task.sleep(for: Self.displayDuration)
                        guard !Task.isCancelled else { return }
                        workspace.dismissMediaDownloadFeedback()
                    }
            }
        }
        .animation(.smooth(duration: 0.2), value: workspace.mediaDownloadFeedback)
    }
}

private struct DismissalTimer: Equatable {
    let feedback: MediaDownloadFeedback
    let isHovering: Bool
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
                // Decorative: the sentence beside it already says whether anything failed.
                .accessibilityHidden(true)

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
            .accessibilityElement(children: .combine)

            if !feedback.savedFileURLs.isEmpty {
                Button(L10n.string("Show in Finder")) {
                    NSWorkspace.shared.activateFileViewerSelecting(feedback.savedFileURLs)
                }
                .buttonStyle(.link)
                .wnFont(.medium12)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        // Glass first, cap second. `frame(maxWidth:)` fills whatever it is proposed, so capping
        // before the background paints a 320pt card behind "1 file downloaded"; capping after
        // leaves the card hugging its text and only bounds how wide a long translation may wrap.
        .glassCard(cornerRadius: 10)
        .frame(maxWidth: 320, alignment: .leading)
        .accessibilityElement(children: .contain)
    }
}

#Preview {
    MediaDownloadFeedbackToastContent(
        feedback: MediaDownloadFeedback(
            savedFileURLs: [URL(filePath: "/Users/preview/Downloads/photo.jpg")],
            failedCount: 1
        )
    )
    .padding()
}
