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

/// A file the composer refused, drawn in the staging strip as the tile it would have been, tinted
/// red so it reads as a problem at a glance. The reason is one click away (and on hover) behind
/// the small info badge rather than spelled out above the composer, so a refused file costs the
/// strip one tile. The strip's red X on the corner is the only X: it dismisses the tile.
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
                    .font(.title3)
                Text(rejection.displayName(locale: locale))
                    .font(.caption2)
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .multilineTextAlignment(.center)
            }
            .foregroundStyle(WNColor.intentionErrorContent)
            .padding(.horizontal, 8)
            .frame(width: tileSize.width, height: tileSize.height)
            .background {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(WNColor.intentionErrorBackground)
            }
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(WNColor.borderDestructiveSecondary, lineWidth: 1)
            }
            // The one free corner: the strip's dismiss X takes the top trailing one, and a bottom
            // badge would sit on a two-line file name.
            .overlay(alignment: .topLeading) {
                RejectedAttachmentInfoBadge()
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

/// The small "i" on a refused tile's corner: the reason is behind it. Deliberately not an X, which
/// the strip already puts on the tile to dismiss it; two would read as two ways to remove it.
private struct RejectedAttachmentInfoBadge: View {
    var body: some View {
        Image(systemName: "info.circle.fill")
            .font(.caption.weight(.semibold))
            .symbolRenderingMode(.palette)
            // Two-layer glyph: a white "i" punched into a red disc.
            .foregroundStyle(WNColor.fillContentQuaternary, WNColor.fillDestructive)
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
                .font(.headline)
                .foregroundStyle(WNColor.intentionErrorContent)
            Text(rejection.displayName(locale: locale))
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(WNColor.textPrimary)
                .lineLimit(1)
                .truncationMode(.middle)
            Text(rejection.reasonDescription(locale: locale))
                .font(.subheadline)
                .foregroundStyle(.secondary)
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
