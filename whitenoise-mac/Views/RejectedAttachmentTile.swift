import SwiftUI

/// The files a staging batch refused, pinned to the conversation they were picked for.
///
/// `ConversationView` is not rebuilt per chat, so the set carries the chat it belongs to and
/// only shows while that chat is on screen.
struct ComposerAttachmentRejections: Equatable {
    /// One refused file. The id keeps a tile's popover with its own file when a neighbor is
    /// dismissed, which an index would not.
    struct Item: Identifiable, Equatable {
        let id: UUID
        let rejection: AttachmentRejection
    }

    let chatId: String
    private(set) var items: [Item]

    init(chatId: String, rejections: [AttachmentRejection]) {
        self.chatId = chatId
        self.items = rejections.map { Item(id: UUID(), rejection: $0) }
    }

    mutating func remove(_ id: Item.ID) {
        items.removeAll { $0.id == id }
    }
}

/// A file the composer refused, drawn in the staging strip as the tile it would have been,
/// with the red X a failed upload would end on. The reason is one click away (and on hover)
/// rather than spelled out above the composer, so a refused file costs the strip one tile.
struct RejectedAttachmentTile: View {
    @Environment(\.locale) private var locale
    let rejection: AttachmentRejection
    let tileSize: CGSize

    @State private var isExplanationPresented = false

    var body: some View {
        let reason = rejection.reasonDescription(locale: locale)

        Button {
            isExplanationPresented.toggle()
        } label: {
            VStack(spacing: 5) {
                Image(systemName: rejection.mediaKind.systemImageName)
                    .wnFont(.semiBold18)
                Text(rejection.displayName(locale: locale))
                    .wnFont(.medium10)
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .multilineTextAlignment(.center)
            }
            .foregroundStyle(WNColor.backgroundContentTertiary)
            .padding(.horizontal, 8)
            .frame(width: tileSize.width, height: tileSize.height)
            .background {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(WNColor.fillSecondary)
            }
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(WNColor.borderDestructiveSecondary, lineWidth: 1)
            }
            // Where an uploading tile shows its spinner, so the two read as one control that
            // ended differently.
            .overlay(alignment: .bottomTrailing) {
                RejectedAttachmentFailureBadge()
                    .padding(5)
            }
            .clipShape(.rect(cornerRadius: 8, style: .continuous))
            .contentShape(.rect(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .help(reason)
        .accessibilityLabel(
            "\(rejection.displayName(locale: locale)), \(L10n.string("This file wasn't attached", locale: locale))"
        )
        .accessibilityHint(reason)
        .popover(isPresented: $isExplanationPresented, arrowEdge: .top) {
            // A popover does not inherit the injected locale; hand it over explicitly.
            RejectedAttachmentExplanation(rejection: rejection)
                .environment(\.locale, locale)
        }
    }
}

/// The red disc a failed tile ends on. Same size, place and colors as the retry badge an upload
/// that failed after staging wears, but an X: there is nothing to retry, the file itself was refused.
private struct RejectedAttachmentFailureBadge: View {
    var body: some View {
        Image(systemName: "xmark")
            .wnFont(.bold12)
            .foregroundStyle(WNColor.fillContentQuaternary)
            .frame(width: 24, height: 24)
            .background(WNColor.fillDestructive, in: .circle)
            .shadow(color: .black.opacity(0.12), radius: 4, y: 1)
            .accessibilityHidden(true)
    }
}

/// Why a file was refused: what the tile's popover says.
struct RejectedAttachmentExplanation: View {
    @Environment(\.locale) private var locale
    let rejection: AttachmentRejection

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(L10n.string("This file wasn't attached", locale: locale))
                .wnFont(.bold14)
                .foregroundStyle(WNColor.backgroundContentDestructive)
            Text(rejection.displayName(locale: locale))
                .wnFont(.semiBold12)
                .foregroundStyle(WNColor.backgroundContentPrimary)
                .lineLimit(1)
                .truncationMode(.middle)
            Text(rejection.reasonDescription(locale: locale))
                .wnFont(.medium12)
                .foregroundStyle(WNColor.backgroundContentSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .frame(width: 260, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

#Preview("Rejected tiles") {
    let tileSize = CGSize(width: 74, height: 74)
    HStack(spacing: 8) {
        RejectedAttachmentTile(
            rejection: AttachmentRejection(
                source: .file(name: "holiday-video.mov"),
                reason: .tooLarge(limitBytes: OutgoingMediaDraftProcessor.maxAttachmentBytes)
            ),
            tileSize: tileSize
        )
        RejectedAttachmentTile(
            rejection: AttachmentRejection(source: .file(name: "installer.exe"), reason: .unsupportedType),
            tileSize: tileSize
        )
        RejectedAttachmentTile(
            rejection: AttachmentRejection(source: .pastedImage, reason: .unreadableImage),
            tileSize: tileSize
        )
    }
    .padding()
}

#Preview("Explanation") {
    RejectedAttachmentExplanation(
        rejection: AttachmentRejection(
            source: .file(name: "holiday-video.mov"),
            reason: .tooLarge(limitBytes: OutgoingMediaDraftProcessor.maxAttachmentBytes)
        )
    )
}
