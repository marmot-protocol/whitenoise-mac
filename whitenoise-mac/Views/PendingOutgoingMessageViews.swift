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
    let message: PendingOutgoingMediaMessage
    let timestampReferenceDate: Date
    let timestampLocale: Locale

    private let maxContentWidth: CGFloat = 660
    private let bubbleGutter: CGFloat = 72

    var body: some View {
        VStack(alignment: .trailing, spacing: 6) {
            content

            if message.state == .failed {
                PendingOutgoingMessageFailureActions(
                    onRetry: { workspace.retryPendingOutgoingMediaMessage(message.id) },
                    onDiscard: { workspace.discardPendingOutgoingMediaMessage(message.id) }
                )
            }
        }
        .frame(maxWidth: maxContentWidth, alignment: .trailing)
        .frame(maxWidth: .infinity, alignment: .trailing)
        .padding(.leading, bubbleGutter)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(accessibilityLabel)
    }

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
        message.state.isInFlight
    }

    /// The visual body of the bubble: the grid, then any audio/document rows. Never empty — a
    /// pending outgoing message exists only because it carries attachments.
    @ViewBuilder
    private var attachments: some View {
        VStack(alignment: .trailing, spacing: 6) {
            if !message.visualAttachments.isEmpty {
                PendingOutgoingMediaGrid(attachments: message.visualAttachments)
            }

            ForEach(message.nonvisualAttachments) { attachment in
                PendingOutgoingMediaAttachmentRow(attachment: attachment)
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
        .padding(.horizontal, 13)
        .padding(.vertical, 8)
        .background {
            UnevenRoundedRectangle(
                topLeadingRadius: 20,
                bottomLeadingRadius: 20,
                bottomTrailingRadius: 6,
                topTrailingRadius: 20,
                style: .continuous
            )
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

private struct PendingOutgoingMessageFailureActions: View {
    let onRetry: () -> Void
    let onDiscard: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Button(L10n.string("Retry"), systemImage: "arrow.clockwise", action: onRetry)
            Button(L10n.string("Remove"), systemImage: "trash", action: onDiscard)
        }
        .buttonStyle(.link)
        .wnFont(.medium10)
        .labelStyle(.titleOnly)
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

/// Audio and document attachments, which never enter the grid. Kept intentionally plain: the
/// message is still going out, so there is nothing to play or reveal yet.
private struct PendingOutgoingMediaAttachmentRow: View {
    let attachment: PendingMediaAttachment

    var body: some View {
        Group {
            if attachment.isVoiceMessage {
                voiceMessageRow
            } else {
                fileRow
            }
        }
        .foregroundStyle(AttachmentRowPalette.outgoingContent)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(width: 260, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(MessagesPalette.sentBubble)
        }
    }

    /// A recording keeps its waveform on the way out, the way the voice-draft bar showed it and
    /// the way the delivered bubble will show it. Its file name is a generated `voice-<uuid>.m4a`
    /// the user never chose, so naming it here would be worse than saying nothing.
    private var voiceMessageRow: some View {
        HStack(spacing: 10) {
            Image(systemName: "mic.fill")
                .wnFont(.semiBold14)

            ComposerAudioWaveformView(
                samples: attachment.waveformSamples,
                progress: 0,
                barColor: AttachmentRowPalette.waveformBar(isOutgoing: true),
                playedColor: AttachmentRowPalette.waveformPlayedBar(isOutgoing: true)
            )
            .frame(height: 24)

            Text(MediaDurationLabel.string(for: attachment.durationSeconds ?? 0))
                .wnFont(.semiBold10.monospacedDigit())
                .foregroundStyle(AttachmentRowPalette.detailContent)
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
                    .foregroundStyle(AttachmentRowPalette.detailContent)
            }

            Spacer(minLength: 0)
        }
    }
}
