//
//  PendingOutgoingMessageViews.swift
//  whitenoise-mac
//
//  The bubble a media message wears between "sent" and "published": laid out like the real
//  outgoing row it is about to become, rendered from the plaintext still in memory, and covered by
//  a single loading treatment for the whole message rather than a badge per attachment.
//

import AppKit
import SwiftUI

/// Matches the published bubble's tile oversample so a pending preview and the row that replaces
/// it are decoded at the same resolution.
private let pendingMediaThumbnailOversample: CGFloat = 1.5

struct PendingOutgoingMessageBubble: View {
    @Environment(WorkspaceState.self) private var workspace
    @State private var isHovering = false
    @State private var isOverflowPresented = false
    @State private var overflowWidth: CGFloat = 0
    let message: PendingOutgoingMediaMessage
    let timestampReferenceDate: Date
    let timestampLocale: Locale

    private let maxContentWidth: CGFloat = 660
    private let bubbleGutter: CGFloat = 72

    var body: some View {
        VStack(alignment: .trailing, spacing: 6) {
            content

            if message.state == .failed {
                // Retry only, and in both places deliberately: the ⋯ has to be reached for, and a
                // failed send is worth answering where the failure already is. Remove stays in the
                // menu with the other destructive actions.
                MessageSendFailureActions {
                    workspace.retryPendingOutgoingMediaMessage(message.id)
                }
            }
        }
        .overlay(alignment: .leading) { overflowControl }
        .animation(.smooth(duration: 0.12), value: showsOverflowControl)
        .frame(maxWidth: maxContentWidth, alignment: .trailing)
        .frame(maxWidth: .infinity, alignment: .trailing)
        .padding(.leading, bubbleGutter)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(accessibilityLabel)
        // The whole row is the hover target, matching `MessageBubble`: the ⋯ appears when the
        // pointer is anywhere on the message, not only over the media itself.
        .contentShape(.rect)
        .onHover { isHovering = $0 }
    }

    /// The recovery menu for a send that never reached the core, in the ⋯ control every other row
    /// in the transcript carries. This was the one failed row with no ⋯ at all, whichever way its
    /// retry went: a failed retry lands it back on `.failed`, so it stayed a bubble whose only
    /// actions were the link row under it.
    ///
    /// Revealed on hover, and held open while its popover is: the pointer leaves the row to reach
    /// the menu it just opened.
    @ViewBuilder
    private var overflowControl: some View {
        if showsOverflowControl {
            Button {
                isOverflowPresented = true
            } label: {
                MessageInlineActionIcon(systemName: "ellipsis", label: L10n.string("More"))
            }
            .buttonStyle(.plain)
            .help(L10n.string("More"))
            .popover(isPresented: $isOverflowPresented, arrowEdge: .bottom) {
                MessageOverflowMenu(
                    actions: MessageRowAction.all(for: message, workspace: workspace) {
                        isOverflowPresented = false
                    }
                )
            }
            // Pushed clear of the bubble by the width SwiftUI measured, the way `MessageBubble`
            // places its own hover strip — `.alignmentGuide` does not survive the `ViewBuilder`
            // conditional above it, and would leave the control drawn on top of the message.
            .onGeometryChange(for: CGFloat.self) { proxy in
                proxy.size.width
            } action: { width in
                overflowWidth = width
            }
            .offset(x: -(overflowWidth + Self.overflowBubbleGap))
            .opacity(overflowWidth > 0 ? 1 : 0)
            .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .trailing)))
        }
    }

    /// Failed sends only: a message still on its way out has nothing to retry and no cancellation
    /// story in the core, so an open menu would offer two actions that do nothing.
    private var showsOverflowControl: Bool {
        message.state == .failed && (isHovering || isOverflowPresented)
    }

    /// Breathing room between the ⋯ control and the bubble edge, matching `MessageBubble`.
    private static let overflowBubbleGap: CGFloat = 8

    private var accessibilityLabel: String {
        message.state == .failed ? L10n.string("Not delivered") : L10n.string("Sending")
    }

    @ViewBuilder
    private var content: some View {
        VStack(alignment: .trailing, spacing: 6) {
            // One dimmer and one spinner for the message, never one per file: the user pressed
            // Send once, so there is one thing to wait for. The spinner is centered on the media
            // alone rather than on the whole row — a caption or the timestamp footer below the
            // grid would otherwise drag the overlay's midpoint down off the image. The dim is
            // applied per part instead of to the stack so it does not fade the spinner with it.
            //
            // An audio-only message opts out of both: its row shows the wait in the well the play
            // button lands in (`inlineLoadingAudioAttachment`), which is where a listener already
            // looks. A large spinner floated over that single short row on top of it would be the
            // same send announced twice, and the dim would fade the inline one along with the row.
            attachments
                .opacity(dimsForSend ? 0.55 : 1)
                .overlay(alignment: .center) {
                    if dimsForSend {
                        ProgressView()
                            .controlSize(.large)
                            .accessibilityLabel(L10n.string("Sending"))
                    }
                }

            if message.caption.isEmpty {
                metadata
                    .padding(.horizontal, 5)
                    .opacity(dimsForSend ? 0.55 : 1)
            } else {
                PendingOutgoingMessageCaption(caption: message.caption) { metadata }
                    .opacity(dimsForSend ? 0.55 : 1)
            }
        }
    }

    private var dimsForSend: Bool {
        message.state.isInFlight && message.inlineLoadingAudioAttachment == nil
    }

    /// The visual body of the bubble: the grid, then any audio/document rows. Never empty — a
    /// pending outgoing message exists only because it carries attachments.
    @ViewBuilder
    private var attachments: some View {
        VStack(alignment: .trailing, spacing: 6) {
            if let audio = message.inlineLoadingAudioAttachment {
                PendingOutgoingAudioRow(
                    attachment: audio,
                    isFailed: message.state == .failed,
                    onRetry: { workspace.retryPendingOutgoingMediaMessage(message.id) }
                )
            } else {
                if !message.visualAttachments.isEmpty {
                    PendingOutgoingMediaGrid(attachments: message.visualAttachments)
                }

                ForEach(message.nonvisualAttachments) { attachment in
                    PendingOutgoingMediaAttachmentRow(attachment: attachment)
                }
            }
        }
    }

    private var metadata: some View {
        PendingOutgoingMessageMetadata(
            createdAt: message.createdAt,
            isFailed: message.state == .failed,
            timestampReferenceDate: timestampReferenceDate,
            timestampLocale: timestampLocale
        )
    }
}

/// Caption surface for a pending message, matching the sent bubble's fill and corner treatment so
/// the row does not visibly change shape when the real message replaces it.
private struct PendingOutgoingMessageCaption<Metadata: View>: View {
    let caption: String
    @ViewBuilder let metadata: () -> Metadata

    var body: some View {
        VStack(alignment: .trailing, spacing: 2) {
            Text(caption)
                .wnFont(.medium16)
                .foregroundStyle(MessagesPalette.sentBubbleContent)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)

            metadata()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background {
            // The bubble's own shape, not a copy of it: the invariant this surface exists for is
            // that a pending row and the committed message that replaces it are the same shape.
            MessageBubbleShape()
                .fill(MessagesPalette.sentBubble)
        }
        .frame(maxWidth: 540, alignment: .trailing)
    }
}

/// Timestamp plus delivery marker, matching `MessageBubble.compactMetadata` — a pending row is a
/// send that has not been confirmed yet, so it wears the same clock the core-committed ones do.
private struct PendingOutgoingMessageMetadata: View {
    let createdAt: Date
    let isFailed: Bool
    let timestampReferenceDate: Date
    let timestampLocale: Locale

    var body: some View {
        HStack(spacing: 4) {
            Text(
                DisplayText.messageTimestamp(
                    for: createdAt,
                    now: timestampReferenceDate,
                    locale: timestampLocale
                )
            )
            .monospacedDigit()

            Image(systemName: isFailed ? "exclamationmark.circle.fill" : "clock")
                .foregroundStyle(isFailed ? WNColor.backgroundContentDestructiveSecondary : tint)
        }
        .wnFont(.medium10)
        .foregroundStyle(tint)
    }

    /// The same token `MessageBubble.compactMetadata` uses, and for the same reason: the neutral
    /// `400`/`500` step is the one rung that clears the sent bubble and the transcript surface
    /// alike, so a pending row and the delivered row that replaces it read identically. That is
    /// what retired the `isOnBubbleFill` flag this used to branch on.
    private var tint: Color {
        WNColor.backgroundContentTertiary
    }
}

/// Grid of locally staged previews, using the published bubble's own row/tile geometry
/// (`MessageMediaGridPresentation`) so the layout does not shift when the real row lands.
private struct PendingOutgoingMediaGrid: View {
    let attachments: [PendingMediaAttachment]

    private let maxWidth: CGFloat = 360
    private let spacing: CGFloat = 3
    private let cornerRadius: CGFloat = 10

    var body: some View {
        VStack(alignment: .leading, spacing: spacing) {
            ForEach(rows) { row in
                HStack(spacing: spacing) {
                    ForEach(row.attachments) { attachment in
                        PendingOutgoingMediaTile(
                            attachment: attachment,
                            sideLength: row.side,
                            hiddenCount: attachment.id == visibleAttachments.last?.id ? hiddenCount : 0
                        )
                    }
                }
            }
        }
        .frame(
            width: maxWidth,
            height: MessageMediaGridPresentation.gridHeight(
                totalCount: attachments.count,
                maxWidth: maxWidth,
                spacing: spacing
            ),
            alignment: .topLeading
        )
        .clipShape(.rect(cornerRadius: cornerRadius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .strokeBorder(WNColor.borderTertiary, lineWidth: 1)
        }
    }

    private var visibleAttachments: [PendingMediaAttachment] {
        Array(attachments.prefix(MessageMediaGridPresentation.visibleCount(totalCount: attachments.count)))
    }

    private var hiddenCount: Int {
        MessageMediaGridPresentation.hiddenCount(totalCount: attachments.count)
    }

    private var rows: [PendingOutgoingMediaGridRow] {
        let visible = visibleAttachments
        return MessageMediaGridPresentation.rowRanges(totalCount: attachments.count)
            .enumerated()
            .compactMap { index, range in
                guard !range.isEmpty, range.upperBound <= visible.count else { return nil }
                return PendingOutgoingMediaGridRow(
                    id: index,
                    side: MessageMediaGridPresentation.tileSide(
                        rowCount: range.count,
                        maxWidth: maxWidth,
                        spacing: spacing
                    ),
                    attachments: Array(visible[range])
                )
            }
    }
}

private struct PendingOutgoingMediaGridRow: Identifiable {
    let id: Int
    let side: CGFloat
    let attachments: [PendingMediaAttachment]
}

private struct PendingOutgoingMediaTile: View {
    @Environment(\.displayScale) private var displayScale
    let attachment: PendingMediaAttachment
    let sideLength: CGFloat
    let hiddenCount: Int

    @State private var preview: NSImage?

    var body: some View {
        ZStack {
            WNColor.backgroundTertiary

            if let preview {
                Image(nsImage: preview)
                    .resizable()
                    .scaledToFill()
                    .frame(width: sideLength, height: sideLength)
                    .clipped()
                    .accessibilityLabel(attachment.fileName)
            } else {
                Image(systemName: attachment.kind.systemImageName)
                    .wnFont(.semiBold24)
                    .foregroundStyle(WNColor.backgroundContentTertiary)
            }

            if hiddenCount > 0 {
                WNColor.overlayTertiary
                Text(verbatim: "+\(hiddenCount)")
                    .wnFont(.bold18)
                    .foregroundStyle(WNColor.fillContentQuaternary)
            }
        }
        .frame(width: sideLength, height: sideLength)
        .clipped()
        .task(id: attachment.id) {
            await loadPreview()
        }
    }

    private func loadPreview() async {
        let data = attachment.data
        let maxPixelSize = ceil(sideLength * max(1, displayScale) * pendingMediaThumbnailOversample)
        preview = await Task.detached(priority: .utility) {
            PendingMediaDraftThumbnailDecoder.image(from: data, maxPixelSize: maxPixelSize)
        }.value
    }
}

/// A lone audio attachment on its way out, wearing the delivered player's exact geometry with a
/// spinner where the play button will be.
///
/// It renders through `MessageAudioAttachmentPlaceholder` — the same row a not-yet-downloaded
/// audio uses — rather than a shape of its own, which is the only way the row is guaranteed not to
/// resize when the published message replaces it. The waveform and duration are the real ones: the
/// sender recorded this audio, so unlike a download this side already knows both.
private struct PendingOutgoingAudioRow: View {
    let attachment: PendingMediaAttachment
    let isFailed: Bool
    let onRetry: () -> Void

    var body: some View {
        MessageAudioAttachmentPlaceholder(
            isOutgoing: true,
            accessibilityLabel: isFailed ? L10n.string("Not delivered") : L10n.string("Sending"),
            bars: bars,
            durationLabel: attachment.durationSeconds.map(MediaDurationLabel.string(for:))
                ?? MediaDurationLabel.placeholder,
            retryAction: isFailed ? onRetry : nil,
            retryHelp: L10n.string("Retry")
        )
    }

    /// An audio *file* the user attached carries no samples — nothing analysed it — so it falls
    /// back to the same flat bars a download shows until its payload lands.
    private var bars: [ComposerAudioWaveformBar] {
        attachment.waveformSamples.isEmpty
            ? ComposerAudioWaveformPresentation.fallbackPlaybackBars
            : ComposerAudioWaveformPresentation.bars(for: attachment.waveformSamples)
    }
}

/// Document attachments, and audio travelling alongside them, which never enter the grid. Kept
/// intentionally plain: the message is still going out, so there is nothing to play or reveal yet.
///
/// A recording never reaches here — it takes the composer over on its own, so it is always the
/// message's only attachment and always renders as `PendingOutgoingAudioRow`.
private struct PendingOutgoingMediaAttachmentRow: View {
    let attachment: PendingMediaAttachment

    var body: some View {
        fileRow
            .foregroundStyle(AttachmentRowPalette.outgoingContent)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .frame(width: 260, alignment: .leading)
            .background {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(MessagesPalette.sentBubble)
            }
    }

    private var fileRow: some View {
        HStack(spacing: 10) {
            Image(systemName: attachment.kind.systemImageName)
                .wnFont(.semiBold16)

            VStack(alignment: .leading, spacing: 2) {
                Text(attachment.fileName)
                    .wnFont(.medium14)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(attachment.durationLabel ?? attachment.sizeLabel)
                    .wnFont(.medium10.monospacedDigit())
                    .foregroundStyle(AttachmentRowPalette.detailContent(isOutgoing: true))
            }

            Spacer(minLength: 0)
        }
    }
}
