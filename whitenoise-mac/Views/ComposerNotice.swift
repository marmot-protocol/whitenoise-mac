import SwiftUI

/// Inline, persistent explanation above the message field of something the composer couldn't do
/// — a custom emoji message that was not sent, a dictation that couldn't start — with an optional
/// way out and a dismiss.
struct ComposerNotice: View {
    /// A button that resolves what the notice reports, such as opening System Settings.
    struct Action {
        let title: String
        let perform: () -> Void
    }

    let message: String
    var action: Action?
    let onDismiss: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 6) {
            Image(systemName: "exclamationmark.circle.fill")
                .foregroundStyle(WNColor.intentionErrorContent)
                .accessibilityHidden(true)
            Text(message)
                .font(.subheadline)
                .foregroundStyle(WNColor.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let action {
                Button(action.title, action: action.perform)
                    .wnSecondaryButtonStyle()
                    .controlSize(.small)
                    .fixedSize()
            }
            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .help(L10n.string("Dismiss"))
            .accessibilityLabel(L10n.string("Dismiss"))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .onAppear { AccessibilityNotification.Announcement(message).post() }
        .onChange(of: message) { _, message in AccessibilityNotification.Announcement(message).post() }
    }
}

#Preview("Composer notice") {
    VStack(spacing: 12) {
        ComposerNotice(message: CustomEmojiSendError.mixedWithAttachments.message, onDismiss: {})
        ComposerNotice(
            message: DictationFailure.permissionDenied.errorDescription ?? "",
            action: ComposerNotice.Action(title: L10n.string("Open System Settings"), perform: {}),
            onDismiss: {}
        )
    }
    .frame(width: 420)
}
