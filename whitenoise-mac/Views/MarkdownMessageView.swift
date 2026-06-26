//
//  MarkdownMessageView.swift
//  whitenoise-mac
//
//  Renders the Markdown AST that the Marmot core parses for each message
//  (`TimelineMessageRecordFfi.contentTokens`). Inline runs are flattened into an
//  `AttributedString` so a single `Text` lays them out with native wrapping;
//  block-level elements (code blocks, lists, quotes, tables) render as stacked
//  SwiftUI views. Nostr mentions/URIs are surfaced as tappable `nostr:` links.
//

import MarmotKit
import SwiftUI

struct MarkdownMessageView: View {
    let message: MessageItem

    var body: some View {
        if let document = message.contentMarkdown {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(document.blocks.enumerated()), id: \.offset) { _, block in
                    MarkdownBlockView(block: block)
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
            Text(message.body)
                .lineSpacing(2)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct MarkdownBlockView: View {
    let block: MarkdownBlockFfi

    var body: some View {
        switch block {
        case .paragraph(let inlines):
            MarkdownInlineText(inlines: inlines)

        case .heading(let level, let inlines):
            MarkdownInlineText(inlines: inlines)
                .font(Self.headingFont(for: level))
                .fontWeight(.semibold)

        case .thematicBreak:
            Divider().padding(.vertical, 2)

        case .codeBlock(_, _, let content):
            MarkdownCodeBlock(content: content)

        case .blockQuote(let blocks):
            HStack(spacing: 8) {
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(Color.secondary.opacity(0.5))
                    .frame(width: 3)
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(blocks.enumerated()), id: \.offset) { _, inner in
                        MarkdownBlockView(block: inner)
                    }
                }
                .foregroundStyle(.secondary)
            }

        case .list(let kind, _, let items):
            MarkdownListView(kind: kind, items: items)

        case .table(let alignments, let header, let rows):
            MarkdownTableView(alignments: alignments, header: header, rows: rows)

        case .mathBlock(let content):
            MarkdownCodeBlock(content: content)

        @unknown default:
            EmptyView()
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
    let inlines: [MarkdownInlineFfi]

    var body: some View {
        Text(MarkdownInlineBuilder.attributedString(from: inlines))
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
    }
}

private struct MarkdownCodeBlock: View {
    let content: String

    var body: some View {
        Text(content)
            .font(.system(.callout, design: .monospaced))
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(8)
            .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
    }
}

private struct MarkdownListView: View {
    let kind: MarkdownListKindFfi
    let items: [MarkdownListItemFfi]

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    marker(for: item, index: index)
                        .frame(minWidth: 16, alignment: .trailing)
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(Array(item.blocks.enumerated()), id: \.offset) { _, block in
                            MarkdownBlockView(block: block)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func marker(for item: MarkdownListItemFfi, index: Int) -> some View {
        if let checked = item.checked {
            Image(systemName: checked ? "checkmark.square.fill" : "square")
                .foregroundStyle(checked ? Color.accentColor : .secondary)
                .font(.callout)
        } else {
            switch kind {
            case .ordered(let start, _):
                Text("\(Int(start) + index).")
                    .foregroundStyle(.secondary)
            case .bullet:
                Text("•").foregroundStyle(.secondary)
            @unknown default:
                Text("•").foregroundStyle(.secondary)
            }
        }
    }
}

private struct MarkdownTableView: View {
    let alignments: [MarkdownAlignmentFfi]
    let header: [MarkdownTableCellFfi]
    let rows: [[MarkdownTableCellFfi]]

    var body: some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 4) {
            GridRow {
                ForEach(Array(header.enumerated()), id: \.offset) { _, cell in
                    MarkdownInlineText(inlines: cell.inlines).fontWeight(.semibold)
                }
            }
            Divider()
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                GridRow {
                    ForEach(Array(row.enumerated()), id: \.offset) { _, cell in
                        MarkdownInlineText(inlines: cell.inlines)
                    }
                }
            }
        }
        .padding(8)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
    }
}

/// Flattens inline markdown nodes into a styled `AttributedString`. SwiftUI `Text`
/// natively honours `inlinePresentationIntent` (bold/italic/strikethrough/code)
/// and `.link`, so nested emphasis composes by unioning the intent option-set.
private enum MarkdownInlineBuilder {
    static func attributedString(from inlines: [MarkdownInlineFfi]) -> AttributedString {
        var result = AttributedString()
        for inline in inlines {
            result.append(render(inline, intent: [], link: nil))
        }
        return result
    }

    private static func render(
        _ inline: MarkdownInlineFfi,
        intent: InlinePresentationIntent,
        link: URL?
    ) -> AttributedString {
        switch inline {
        case .text(let content):
            return styled(content, intent: intent, link: link)

        case .softBreak:
            return styled(" ", intent: intent, link: link)

        case .hardBreak:
            return styled("\n", intent: intent, link: link)

        case .code(let content):
            return styled(content, intent: intent.union(.code), link: link)

        case .emph(let children):
            return concat(children, intent: intent.union(.emphasized), link: link)

        case .strong(let children):
            return concat(children, intent: intent.union(.stronglyEmphasized), link: link)

        case .strikethrough(let children):
            return concat(children, intent: intent.union(.strikethrough), link: link)

        case .link(let dest, _, let children):
            return concat(children, intent: intent, link: URL(string: dest) ?? link)

        case .image(_, let title, let alt):
            // Inline images are uncommon in chat; show the alt text (or title).
            if !alt.isEmpty {
                return concat(alt, intent: intent, link: link)
            }
            return styled(title ?? "", intent: intent, link: link)

        case .autolink(let url, _):
            return styled(url, intent: intent, link: URL(string: url) ?? link)

        case .math(let content):
            return styled(content, intent: intent.union(.code), link: link)

        case .nostrMention(let entity), .nostrUri(let entity):
            return nostrEntity(entity, intent: intent)

        @unknown default:
            return AttributedString()
        }
    }

    private static func concat(
        _ inlines: [MarkdownInlineFfi],
        intent: InlinePresentationIntent,
        link: URL?
    ) -> AttributedString {
        var result = AttributedString()
        for inline in inlines {
            result.append(render(inline, intent: intent, link: link))
        }
        return result
    }

    private static func concat(
        _ text: String,
        intent: InlinePresentationIntent,
        link: URL?
    ) -> AttributedString {
        styled(text, intent: intent, link: link)
    }

    private static func styled(
        _ string: String,
        intent: InlinePresentationIntent,
        link: URL?
    ) -> AttributedString {
        var attributed = AttributedString(string)
        if !intent.isEmpty {
            attributed.inlinePresentationIntent = intent
        }
        if let link {
            attributed.link = link
        }
        return attributed
    }

    /// Render a Nostr entity (`npub`, `note`, `nevent`, …) as an accent-coloured,
    /// tappable `nostr:` link so downstream handling can resolve it.
    private static func nostrEntity(
        _ entity: MarkdownNostrEntityFfi,
        intent: InlinePresentationIntent
    ) -> AttributedString {
        var attributed = AttributedString("@\(shortBech32(entity.bech32))")
        attributed.foregroundColor = .accentColor
        if !intent.isEmpty {
            attributed.inlinePresentationIntent = intent
        }
        attributed.link = URL(string: "nostr:\(entity.bech32)")
        return attributed
    }

    private static func shortBech32(_ bech32: String) -> String {
        guard bech32.count > 16 else { return bech32 }
        return "\(bech32.prefix(10))…\(bech32.suffix(4))"
    }
}
