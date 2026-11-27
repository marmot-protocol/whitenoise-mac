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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// The timer holds while the pointer is on the card or the toast has keyboard or VoiceOver
    /// focus, so Show in Finder is still there when the user reaches it.
    @State private var isHovering = false
    @State private var isToastFocused = false

    private var isHeld: Bool {
        isHovering || isToastFocused
    }

    var body: some View {
        Group {
            if let feedback = workspace.mediaDownloadFeedback {
                MediaDownloadFeedbackToastContent(feedback: feedback) { isToastFocused = $0 }
                    .onHover { isHovering = $0 }
                    .onDisappear {
                        isHovering = false
                        isToastFocused = false
                    }
                    .padding(.leading, 16)
                    .padding(.bottom, 16)
                    .transition(reduceMotion ? .opacity : .move(edge: .leading).combined(with: .opacity))
                    // A new value (another gesture folded in), or the pointer or focus leaving,
                    // restarts it.
                    .task(id: DismissalTimer(feedback: feedback, isHeld: isHeld)) {
                        guard !isHeld else { return }
                        try? await Task.sleep(for: Self.displayDuration)
                        // SwiftUI cancels this task on the next update, not when the state changes,
                        // so a gesture folded in, or a hover or focus arriving, just as the timer
                        // wakes must not be dismissed with it.
                        guard !Task.isCancelled, !isHeld, workspace.mediaDownloadFeedback == feedback
                        else { return }
                        workspace.dismissMediaDownloadFeedback()
                    }
            }
        }
        .animation(reduceMotion ? .none : .smooth(duration: 0.2), value: workspace.mediaDownloadFeedback)
    }
}

private struct DismissalTimer: Equatable {
    let feedback: MediaDownloadFeedback
    let isHeld: Bool
}

struct MediaDownloadFeedbackToastContent: View {
    @Environment(\.locale) private var locale
    @FocusState private var isButtonKeyboardFocused: Bool
    @AccessibilityFocusState private var isButtonAccessibilityFocused: Bool
    /// VoiceOver reads the status before it reaches the button, so focus there holds the toast too.
    @AccessibilityFocusState private var isStatusAccessibilityFocused: Bool
    let feedback: MediaDownloadFeedback
    /// Whether the toast holds keyboard or VoiceOver focus.
    var focusChanged: (Bool) -> Void = { _ in }

    private var isFocused: Bool {
        isButtonKeyboardFocused || isButtonAccessibilityFocused || isStatusAccessibilityFocused
    }

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
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.primary)
                }
                if feedback.failedCount > 0 {
                    Text(
                        L10n.plural(
                            "%lld files couldn't be downloaded", Int64(feedback.failedCount),
                            locale: locale)
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }
            .multilineTextAlignment(.leading)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityElement(children: .combine)
            .accessibilityFocused($isStatusAccessibilityFocused)

            if !feedback.savedFileURLs.isEmpty {
                Button(L10n.string("Show in Finder")) {
                    NSWorkspace.shared.activateFileViewerSelecting(feedback.savedFileURLs)
                }
                .buttonStyle(.link)
                .font(.subheadline)
                .focused($isButtonKeyboardFocused)
                .accessibilityFocused($isButtonAccessibilityFocused)
            }
        }
        .onChange(of: isFocused) { _, focused in focusChanged(focused) }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        // Material first, cap second. `frame(maxWidth:)` fills whatever it is proposed, so capping
        // before the background paints a 320pt card behind "1 file downloaded"; capping after
        // leaves the card hugging its text and only bounds how wide a long translation may wrap.
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(WNColor.borderTertiary, lineWidth: 1)
        }
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
