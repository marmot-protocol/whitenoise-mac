import SwiftUI

/// The files a staging batch refused, pinned to the conversation they were picked for.
///
/// `ConversationView` is not rebuilt per chat, so the notice carries the chat it belongs to and
/// only shows while that chat is on screen.
struct ComposerAttachmentRejections: Equatable {
    let chatId: String
    let items: [AttachmentRejection]
}

/// Lists every file the composer could not attach, each under its own name with its own reason,
/// above the attachments that did make it. It stays until the user dismisses it or stages again,
/// so it can be read while fixing the files it names.
struct ComposerAttachmentRejectionNotice: View {
    @Environment(\.locale) private var locale
    let rejections: [AttachmentRejection]
    let onDismiss: () -> Void

    private var intent: WNCalloutIntent { .error }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: intent.systemImage)
                .wnFont(.medium18)
                .foregroundStyle(intent.accent)
                .frame(width: 22, height: 22)

            VStack(alignment: .leading, spacing: 6) {
                Text(
                    L10n.string(
                        rejections.count == 1 ? "This file wasn't attached" : "These files weren't attached",
                        locale: locale
                    )
                )
                .wnFont(.bold14)
                .foregroundStyle(intent.accent)

                ForEach(Array(rejections.enumerated()), id: \.offset) { _, rejection in
                    ComposerAttachmentRejectionRow(rejection: rejection)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .wnFont(.bold12)
                    .foregroundStyle(intent.accent)
                    .frame(width: 22, height: 22)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .help(L10n.string("Dismiss", locale: locale))
            .accessibilityLabel(L10n.string("Dismiss", locale: locale))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(intent.background, in: .rect(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(WNColor.borderTertiary, lineWidth: 1)
        }
    }
}

private struct ComposerAttachmentRejectionRow: View {
    @Environment(\.locale) private var locale
    let rejection: AttachmentRejection

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(rejection.displayName(locale: locale))
                .wnFont(.semiBold12)
                .foregroundStyle(WNCalloutIntent.error.accent)
                .lineLimit(1)
                .truncationMode(.middle)
            Text(rejection.reasonDescription(locale: locale))
                .wnFont(.medium12)
                .foregroundStyle(WNCalloutIntent.error.detail)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }
}

#Preview("Several rejected files") {
    ComposerAttachmentRejectionNotice(
        rejections: [
            AttachmentRejection(
                source: .file(name: "holiday-video.mov"),
                reason: .tooLarge(limitBytes: OutgoingMediaDraftProcessor.maxAttachmentBytes)
            ),
            AttachmentRejection(source: .file(name: "archive.zip"), reason: .unsupportedType),
            AttachmentRejection(source: .pastedImage, reason: .unreadableImage),
            AttachmentRejection(
                source: .file(name: "photo-11.jpg"),
                reason: .attachmentLimitReached(maxCount: OutgoingMediaDraftProcessor.maxAttachmentCount)
            ),
        ],
        onDismiss: {}
    )
    .padding()
    .frame(width: 520)
}

#Preview("One rejected file") {
    ComposerAttachmentRejectionNotice(
        rejections: [
            AttachmentRejection(
                source: .file(name: "holiday-video.mov"),
                reason: .tooLarge(limitBytes: OutgoingMediaDraftProcessor.maxAttachmentBytes)
            )
        ],
        onDismiss: {}
    )
    .padding()
    .frame(width: 520)
}
