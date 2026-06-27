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

    var body: some View {
        if let document = message.contentMarkdown {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(document.blocks) { block in
                    MarkdownBlockView(block: block.block)
                }
                if document.truncated {
                    Text("… (message truncated)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
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
            Text(message.body)
                .lineSpacing(2)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
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
                .font(Self.headingFont(for: level))
                .fontWeight(.semibold)

        case .thematicBreak:
            Divider().padding(.vertical, 2)

        case .codeBlock(let content):
            MarkdownCodeBlock(content: content)

        case .blockQuote(let blocks):
            HStack(spacing: 8) {
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(Color.secondary.opacity(0.5))
                    .frame(width: 3)
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(blocks) { inner in
                        MarkdownBlockView(block: inner.block)
                    }
                }
                .foregroundStyle(.secondary)
            }

        case .list(let items):
            MarkdownListView(items: items)

        case .table(let header, let rows):
            MarkdownTableView(header: header, rows: rows)

        case .mathBlock(let content):
            MarkdownCodeBlock(content: content)
        }
    }

    private static func headingFont(for level: UInt8) -> Font {
        switch level {
        case 1: return .title2
        case 2: return .title3
        case 3: return .headline
        default: return .body
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

private struct MarkdownCodeBlock: View {
    let content: String

    var body: some View {
        // No `.textSelection(.enabled)` — see the note in MarkdownMessageView.body.
        Text(content)
            .font(.system(.callout, design: .monospaced))
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(8)
            .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
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
                .foregroundStyle(checked ? Color.accentColor : .secondary)
                .font(.callout)
        case .text(let text):
            Text(text).foregroundStyle(.secondary)
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
                    MarkdownInlineText(text: cell.text).fontWeight(.semibold)
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
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
    }
}
