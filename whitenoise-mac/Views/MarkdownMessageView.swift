//
//  MarkdownMessageView.swift
//  whitenoise-mac
//
//  Renders the precomputed Markdown display model held by MessageItem. Inline
//  attributed strings and stable block ids are built when the message is mapped,
//  keeping SwiftUI body/layout passes cheap while the transcript scrolls.
//

import SwiftUI

struct MarkdownMessageView: View {
    let message: MessageItem
    var trailingMetadata: Text?

    init(message: MessageItem, trailingMetadata: Text? = nil) {
        self.message = message
        self.trailingMetadata = trailingMetadata
    }

    var body: some View {
        if let inlineParagraph = message.contentMarkdown?.inlineParagraph {
            textWithMetadata(Text(inlineParagraph))
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
        } else if let document = message.contentMarkdown {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(document.blocks) { block in
                    MarkdownBlockView(block: block.block)
                }
                if document.truncated {
                    Text(L10n.string("… (message truncated)"))
                        .wnFont(.medium10)
                        .foregroundStyle(WNColor.backgroundContentSecondary)
                }
            }
            .fixedSize(horizontal: false, vertical: true)
        } else {
            // Fallback for bubbles the core didn't tokenise (or non-Markdown rows).
            // NB: do not add `.textSelection` here (nor in the inline/code views below).
            // Selection is gated once, on hover, at the bubble level (MessageBubble's
            // `.textSelection(isSelectable ? …)`), so only the single active bubble is backed
            // by a selection NSView. Enabling it per-Text across the whole transcript backs
            // every Text with an NSView selection overlay, which destabilises the
            // ScrollView/LazyVStack scroll-anchor resolution into a multi-second main-thread
            // layout loop on send (Instruments: continuous SelectionOverlay.updateNSView /
            // ScrollViewAdjustedState.adjustOffsetIfNeeded). See whitenoise-mac#205.
            textWithMetadata(Text(message.rawBubbleDisplayBody))
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func textWithMetadata(_ body: Text) -> Text {
        guard let trailingMetadata else { return body }
        return body + trailingMetadata
    }
}

private struct MarkdownBlockView: View {
    let block: MarkdownDisplayBlock

    var body: some View {
        switch block {
        case .paragraph(let text):
            MarkdownInlineText(text: text)

        case .heading(let level, let text):
            MarkdownInlineText(text: text)
                .wnFont(Self.headingStyle(for: level))

        case .thematicBreak:
            Divider().padding(.vertical, 2)

        case .codeBlock(let content):
            MarkdownCodeBlock(content: content)

        case .blockQuote(let blocks):
            HStack(spacing: 8) {
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(WNColor.borderTertiary)
                    .frame(width: 3)
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(blocks) { inner in
                        MarkdownBlockView(block: inner.block)
                    }
                }
                .foregroundStyle(WNColor.backgroundContentSecondary)
            }

        case .list(let items):
            MarkdownListView(items: items)

        case .table(let header, let rows):
            MarkdownTableView(header: header, rows: rows)

        case .mathBlock(let content):
            MarkdownCodeBlock(content: content)
        }
    }

    /// Headings carry their weight in the rung itself. Manrope ships as three separate
    /// faces rather than as a weight axis, so stacking `.fontWeight(.semibold)` on top of
    /// a rung would ask the renderer to synthesize an emboldened Medium instead of using
    /// the SemiBold face that is already in the bundle.
    private static func headingStyle(for level: UInt8) -> WNTextStyle {
        switch level {
        case 1: return .semiBold18
        case 2: return .semiBold16
        case 3: return .semiBold14
        default: return .semiBold14
        }
    }
}

/// Renders a run of inline nodes as a single wrapping `Text`.
private struct MarkdownInlineText: View {
    let text: AttributedString

    var body: some View {
        // No `.textSelection(.enabled)` — see the note in MarkdownMessageView.body.
        Text(text)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// The fenced-code and math-block pair, named so the contrast between the two can be asserted
/// against the same values the view draws.
nonisolated enum MarkdownCodeBlockPalette {
    /// `backgroundContentSecondary` as a *fill* looks odd written down, but it is what the other
    /// clients set behind code: the neutral `500`/`400` step is the one mid-gray that reads as a
    /// distinct block against the sent bubble and the received bubble alike, in both appearances. A
    /// wash keyed off `.primary` cannot, because it changes direction between them while the sent
    /// bubble does too.
    static let fill = WNColor.backgroundContentSecondary

    /// Named rather than inherited, for two reasons. A code block nested in a block quote inherits
    /// the quote's `backgroundContentSecondary` — the block's own fill — so its text was drawn in
    /// exactly the color behind it and disappeared. And the app-wide `backgroundContentPrimary` it
    /// inherits everywhere else only clears 2.52:1 on this mid-gray in dark appearance, where
    /// `fillContentPrimary` clears 7.85:1 (4.74:1 in light). One named token fixes both: the block
    /// reads the same whatever it is nested in.
    static let content = WNColor.fillContentPrimary

    /// The AppKit twins of the two above, so the contrast between them can be asserted on the
    /// dynamic colors themselves rather than on a snapshot frozen by `NSColor(someSwiftUIColor)` —
    /// see the note on that conversion in `WNNSColor`.
    static let nsFill = WNNSColor.backgroundContentSecondary
    static let nsContent = WNNSColor.fillContentPrimary
}

private struct MarkdownCodeBlock: View {
    let content: String

    var body: some View {
        // No `.textSelection(.enabled)` — see the note in MarkdownMessageView.body.
        Text(content)
            .font(.system(.callout, design: .monospaced))
            .foregroundStyle(MarkdownCodeBlockPalette.content)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(8)
            .background(
                MarkdownCodeBlockPalette.fill,
                in: RoundedRectangle(cornerRadius: 6, style: .continuous))
    }
}

private struct MarkdownListView: View {
    let items: [MarkdownDisplayListItem]

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(items) { item in
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    marker(item.marker)
                        .frame(minWidth: 16, alignment: .trailing)
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(item.blocks) { block in
                            MarkdownBlockView(block: block.block)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func marker(_ marker: MarkdownDisplayListMarker) -> some View {
        switch marker {
        case .checkbox(let checked):
            Image(systemName: checked ? "checkmark.square.fill" : "square")
                .foregroundStyle(
                    checked ? WNColor.intentionSuccessContent : WNColor.backgroundContentSecondary
                )
                .wnFont(.medium12)
        case .text(let text):
            Text(text).foregroundStyle(WNColor.backgroundContentSecondary)
        }
    }
}

private struct MarkdownTableView: View {
    let header: [MarkdownDisplayTableCell]
    let rows: [MarkdownDisplayTableRow]

    var body: some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 4) {
            GridRow {
                ForEach(header) { cell in
                    MarkdownInlineText(text: cell.text).wnFont(.semiBold16)
                }
            }
            Divider()
            ForEach(rows) { row in
                GridRow {
                    ForEach(row.cells) { cell in
                        MarkdownInlineText(text: cell.text)
                    }
                }
            }
        }
        .padding(8)
        .overlay {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .stroke(WNColor.borderTertiary, lineWidth: 1)
        }
    }
}
