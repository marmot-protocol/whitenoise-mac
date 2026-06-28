import Foundation
import MarmotKit
import SwiftUI

// Pure FFI → display-model transformation (built off-main while mapping a timeline window,
// read on the main actor by the views). Marked `nonisolated` so it does not inherit the
// module's default main-actor isolation — otherwise constructing it from `MessageItem.init`
// (nonisolated) warns about calling a main-actor initializer from a nonisolated context.

nonisolated struct MarkdownDisplayDocument {
    let blocks: [MarkdownDisplayBlockNode]
    let truncated: Bool

    init(document: MarkdownDocumentFfi) {
        self.blocks = Self.makeBlocks(from: document.blocks)
        self.truncated = document.truncated
    }

    fileprivate static func makeBlocks(from blocks: [MarkdownBlockFfi]) -> [MarkdownDisplayBlockNode] {
        blocks.enumerated().map { index, block in
            MarkdownDisplayBlockNode(id: index, block: MarkdownDisplayBlock(block))
        }
    }
}

nonisolated struct MarkdownDisplayBlockNode: Identifiable {
    let id: Int
    let block: MarkdownDisplayBlock
}

nonisolated enum MarkdownDisplayBlock {
    case paragraph(AttributedString)
    case heading(level: UInt8, text: AttributedString)
    case thematicBreak
    case codeBlock(String)
    case blockQuote([MarkdownDisplayBlockNode])
    case list(items: [MarkdownDisplayListItem])
    case table(header: [MarkdownDisplayTableCell], rows: [MarkdownDisplayTableRow])
    case mathBlock(String)

    init(_ block: MarkdownBlockFfi) {
        switch block {
        case .paragraph(let inlines):
            self = .paragraph(MarkdownDisplayInlineBuilder.attributedString(from: inlines))
        case .heading(let level, let inlines):
            self = .heading(level: level, text: MarkdownDisplayInlineBuilder.attributedString(from: inlines))
        case .thematicBreak:
            self = .thematicBreak
        case .codeBlock(_, _, let content):
            self = .codeBlock(content)
        case .blockQuote(let blocks):
            self = .blockQuote(MarkdownDisplayDocument.makeBlocks(from: blocks))
        case .list(let kind, _, let items):
            self = .list(items: Self.listItems(kind: kind, items: items))
        case .table(_, let header, let rows):
            self = .table(
                header: Self.tableCells(from: header),
                rows: rows.enumerated().map { rowIndex, row in
                    MarkdownDisplayTableRow(id: rowIndex, cells: Self.tableCells(from: row))
                }
            )
        case .mathBlock(let content):
            self = .mathBlock(content)
        @unknown default:
            self = .paragraph(AttributedString())
        }
    }

    private static func listItems(
        kind: MarkdownListKindFfi,
        items: [MarkdownListItemFfi]
    ) -> [MarkdownDisplayListItem] {
        items.enumerated().map { index, item in
            MarkdownDisplayListItem(
                id: index,
                marker: listMarker(kind: kind, item: item, index: index),
                blocks: MarkdownDisplayDocument.makeBlocks(from: item.blocks)
            )
        }
    }

    private static func listMarker(
        kind: MarkdownListKindFfi,
        item: MarkdownListItemFfi,
        index: Int
    ) -> MarkdownDisplayListMarker {
        if let checked = item.checked {
            return .checkbox(checked)
        }
        switch kind {
        case .ordered(let start, _):
            return .text("\(Int(start) + index).")
        case .bullet:
            return .text("•")
        @unknown default:
            return .text("•")
        }
    }

    private static func tableCells(from cells: [MarkdownTableCellFfi]) -> [MarkdownDisplayTableCell] {
        cells.enumerated().map { index, cell in
            MarkdownDisplayTableCell(
                id: index,
                text: MarkdownDisplayInlineBuilder.attributedString(from: cell.inlines)
            )
        }
    }
}

nonisolated struct MarkdownDisplayListItem: Identifiable {
    let id: Int
    let marker: MarkdownDisplayListMarker
    let blocks: [MarkdownDisplayBlockNode]
}

nonisolated enum MarkdownDisplayListMarker {
    case checkbox(Bool)
    case text(String)
}

nonisolated struct MarkdownDisplayTableCell: Identifiable {
    let id: Int
    let text: AttributedString
}

nonisolated struct MarkdownDisplayTableRow: Identifiable {
    let id: Int
    let cells: [MarkdownDisplayTableCell]
}

nonisolated enum MarkdownDisplayInlineBuilder {
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
        return "\(bech32.prefix(10))...\(bech32.suffix(4))"
    }
}
