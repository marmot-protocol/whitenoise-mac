import Foundation
import MarmotKit
import SwiftUI

/// npub/nprofile bech32 → known display name, keyed as the entity carries it (`entity.bech32`).
/// Empty when no roster is loaded, in which case mentions keep their truncated-bech32 fallback.
/// Injected through the builder so the transformation stays pure and off-main.
typealias MarkdownMentionNames = [String: String]

// Pure FFI → display-model transformation (built off-main while mapping a timeline window,
// read on the main actor by the views). Marked `nonisolated` so it does not inherit the
// module's default main-actor isolation — otherwise constructing it from `MessageItem.init`
// (nonisolated) warns about calling a main-actor initializer from a nonisolated context.

nonisolated struct MarkdownDisplayDocument {
    let blocks: [MarkdownDisplayBlockNode]
    let truncated: Bool

    /// A single paragraph can share its final line with compact message metadata.
    /// More elaborate block layouts keep their own independent flow so lists,
    /// tables, and code blocks are never flattened just to save vertical space.
    var inlineParagraph: AttributedString? {
        guard !truncated,
            blocks.count == 1,
            case .paragraph(let text) = blocks[0].block
        else { return nil }
        return text
    }

    /// Block quotes, lists, and inline emphasis/link/image-alt all recurse over the
    /// `MarkdownDocumentFfi` AST, which is derived from untrusted peer message content.
    /// Bound the Swift-side recursion so attacker-chosen nesting cannot overflow the
    /// stack. 32 matches the media JSON traversal guard in `Core/MarmotMapping.swift`.
    /// Past the limit, the over-depth remainder collapses to empty safe display rather
    /// than preserving nested structure.
    fileprivate static let maxDepth = 32

    /// Upper bound on SwiftUI-producing display nodes per message (top-level and nested
    /// blocks, list items, table rows, and table cells). Inline AST nodes collapse into a
    /// single `AttributedString`/`Text` and do not consume slots. Prevents attacker-crafted
    /// wide tables or long lists from materializing thousands of non-lazy `Grid`/`ForEach`
    /// children in one bubble.
    static let maxDisplayNodes = 256

    init(document: MarkdownDocumentFfi, mentionNames: MarkdownMentionNames = [:]) {
        var swiftTruncated = false
        var budget = MarkdownDisplayBudget(limit: Self.maxDisplayNodes)
        self.blocks = Self.makeBlocks(
            from: document.blocks,
            remainingDepth: Self.maxDepth,
            mentionNames: mentionNames,
            budget: &budget,
            truncated: &swiftTruncated
        )
        self.truncated = document.truncated || swiftTruncated || budget.didTruncate
    }

    fileprivate static func makeBlocks(
        from blocks: [MarkdownBlockFfi],
        remainingDepth: Int,
        mentionNames: MarkdownMentionNames,
        budget: inout MarkdownDisplayBudget,
        truncated: inout Bool
    ) -> [MarkdownDisplayBlockNode] {
        guard remainingDepth > 0 else {
            truncated = truncated || !blocks.isEmpty
            return []
        }
        var result: [MarkdownDisplayBlockNode] = []
        for (index, block) in blocks.enumerated() {
            guard budget.takeOne() else { break }
            result.append(
                MarkdownDisplayBlockNode(
                    id: index,
                    block: MarkdownDisplayBlock(
                        block,
                        remainingDepth: remainingDepth,
                        mentionNames: mentionNames,
                        budget: &budget,
                        truncated: &truncated
                    )
                )
            )
        }
        return result
    }
}

nonisolated fileprivate struct MarkdownDisplayBudget {
    private(set) var remaining: Int
    private(set) var didTruncate = false

    init(limit: Int) {
        remaining = limit
    }

    /// Reserves up to `count` display-node slots; returns how many were granted.
    mutating func take(_ count: Int) -> Int {
        guard count > 0 else { return 0 }
        if remaining <= 0 {
            didTruncate = true
            return 0
        }
        let granted = min(count, remaining)
        remaining -= granted
        if granted < count {
            didTruncate = true
        }
        return granted
    }

    mutating func takeOne() -> Bool {
        take(1) == 1
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

    fileprivate init(
        _ block: MarkdownBlockFfi,
        remainingDepth: Int,
        mentionNames: MarkdownMentionNames,
        budget: inout MarkdownDisplayBudget,
        truncated: inout Bool
    ) {
        switch block {
        case .paragraph(let inlines):
            self = .paragraph(
                MarkdownDisplayInlineBuilder.attributedString(
                    from: inlines,
                    remainingDepth: remainingDepth,
                    mentionNames: mentionNames,
                    truncated: &truncated
                )
            )
        case .heading(let level, let inlines):
            self = .heading(
                level: level,
                text: MarkdownDisplayInlineBuilder.attributedString(
                    from: inlines,
                    remainingDepth: remainingDepth,
                    mentionNames: mentionNames,
                    truncated: &truncated
                )
            )
        case .thematicBreak:
            self = .thematicBreak
        case .codeBlock(_, _, let content):
            self = .codeBlock(PeerDisplayText.strippingBidiControls(content))
        case .blockQuote(let blocks):
            self = .blockQuote(
                MarkdownDisplayDocument.makeBlocks(
                    from: blocks,
                    remainingDepth: remainingDepth - 1,
                    mentionNames: mentionNames,
                    budget: &budget,
                    truncated: &truncated
                )
            )
        case .listBlock(let kind, _, let items):
            self = .list(
                items: Self.listItems(
                    kind: kind,
                    items: items,
                    remainingDepth: remainingDepth,
                    mentionNames: mentionNames,
                    budget: &budget,
                    truncated: &truncated
                )
            )
        case .table(_, let header, let rows):
            let headerCount = budget.take(header.count)
            let displayHeader = Self.tableCells(
                from: Array(header.prefix(headerCount)),
                remainingDepth: remainingDepth,
                mentionNames: mentionNames,
                truncated: &truncated
            )
            var displayRows: [MarkdownDisplayTableRow] = []
            for (rowIndex, row) in rows.enumerated() {
                guard budget.takeOne() else { break }
                let cellCount = budget.take(row.count)
                let cells = Self.tableCells(
                    from: Array(row.prefix(cellCount)),
                    remainingDepth: remainingDepth,
                    mentionNames: mentionNames,
                    truncated: &truncated
                )
                displayRows.append(MarkdownDisplayTableRow(id: rowIndex, cells: cells))
            }
            self = .table(header: displayHeader, rows: displayRows)
        case .mathBlock(let content):
            self = .mathBlock(PeerDisplayText.strippingBidiControls(content))
        @unknown default:
            self = .paragraph(AttributedString())
        }
    }

    private static func listItems(
        kind: MarkdownListKindFfi,
        items: [MarkdownListItemFfi],
        remainingDepth: Int,
        mentionNames: MarkdownMentionNames,
        budget: inout MarkdownDisplayBudget,
        truncated: inout Bool
    ) -> [MarkdownDisplayListItem] {
        var result: [MarkdownDisplayListItem] = []
        for (index, item) in items.enumerated() {
            guard budget.takeOne() else { break }
            result.append(
                MarkdownDisplayListItem(
                    id: index,
                    marker: listMarker(kind: kind, item: item, index: index),
                    blocks: MarkdownDisplayDocument.makeBlocks(
                        from: item.blocks,
                        remainingDepth: remainingDepth - 1,
                        mentionNames: mentionNames,
                        budget: &budget,
                        truncated: &truncated
                    )
                )
            )
        }
        return result
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

    private static func tableCells(
        from cells: [MarkdownTableCellFfi],
        remainingDepth: Int,
        mentionNames: MarkdownMentionNames,
        truncated: inout Bool
    ) -> [MarkdownDisplayTableCell] {
        cells.enumerated().map { index, cell in
            MarkdownDisplayTableCell(
                id: index,
                text: MarkdownDisplayInlineBuilder.attributedString(
                    from: cell.inlines,
                    remainingDepth: remainingDepth,
                    mentionNames: mentionNames,
                    truncated: &truncated
                )
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
    static func attributedString(
        from inlines: [MarkdownInlineFfi],
        remainingDepth: Int,
        mentionNames: MarkdownMentionNames = [:]
    ) -> AttributedString {
        var truncated = false
        return attributedString(
            from: inlines,
            remainingDepth: remainingDepth,
            mentionNames: mentionNames,
            truncated: &truncated
        )
    }

    fileprivate static func attributedString(
        from inlines: [MarkdownInlineFfi],
        remainingDepth: Int,
        mentionNames: MarkdownMentionNames,
        truncated: inout Bool
    ) -> AttributedString {
        guard remainingDepth > 0 else {
            truncated = truncated || !inlines.isEmpty
            return AttributedString()
        }
        var result = AttributedString()
        for inline in inlines {
            result.append(
                render(
                    inline,
                    intent: [],
                    link: nil,
                    remainingDepth: remainingDepth,
                    mentionNames: mentionNames,
                    truncated: &truncated
                )
            )
        }
        return result
    }

    private static func render(
        _ inline: MarkdownInlineFfi,
        intent: InlinePresentationIntent,
        link: URL?,
        remainingDepth: Int,
        mentionNames: MarkdownMentionNames,
        truncated: inout Bool
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
            return concat(
                children,
                intent: intent.union(.emphasized),
                link: link,
                remainingDepth: remainingDepth - 1,
                mentionNames: mentionNames,
                truncated: &truncated
            )
        case .strong(let children):
            return concat(
                children,
                intent: intent.union(.stronglyEmphasized),
                link: link,
                remainingDepth: remainingDepth - 1,
                mentionNames: mentionNames,
                truncated: &truncated
            )
        case .strikethrough(let children):
            return concat(
                children,
                intent: intent.union(.strikethrough),
                link: link,
                remainingDepth: remainingDepth - 1,
                mentionNames: mentionNames,
                truncated: &truncated
            )
        case .link(let dest, _, let children):
            return concat(
                children, intent: intent, link: MarkdownLinkPolicy.sanitizedURL(from: dest),
                remainingDepth: remainingDepth - 1,
                mentionNames: mentionNames,
                truncated: &truncated
            )
        case .image(_, let title, let alt):
            if !alt.isEmpty {
                return concat(
                    alt,
                    intent: intent,
                    link: link,
                    remainingDepth: remainingDepth - 1,
                    mentionNames: mentionNames,
                    truncated: &truncated
                )
            }
            return styled(title ?? "", intent: intent, link: link)
        case .autolink(let url, _):
            return styled(url, intent: intent, link: MarkdownLinkPolicy.sanitizedURL(from: url))
        case .math(let content):
            return styled(content, intent: intent.union(.code), link: link)
        case .nostrMention(let entity), .nostrUri(let entity):
            return nostrEntity(entity, intent: intent, mentionNames: mentionNames)
        @unknown default:
            return AttributedString()
        }
    }

    private static func concat(
        _ inlines: [MarkdownInlineFfi],
        intent: InlinePresentationIntent,
        link: URL?,
        remainingDepth: Int,
        mentionNames: MarkdownMentionNames,
        truncated: inout Bool
    ) -> AttributedString {
        guard remainingDepth > 0 else {
            truncated = truncated || !inlines.isEmpty
            return AttributedString()
        }
        var result = AttributedString()
        for inline in inlines {
            result.append(
                render(
                    inline,
                    intent: intent,
                    link: link,
                    remainingDepth: remainingDepth,
                    mentionNames: mentionNames,
                    truncated: &truncated
                )
            )
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
        var attributed = AttributedString(PeerDisplayText.strippingBidiControls(string))
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
        intent: InlinePresentationIntent,
        mentionNames: MarkdownMentionNames
    ) -> AttributedString {
        let shortReference = shortBech32(entity.bech32)
        let displayText: String
        var isMention = false
        switch entity.hrp {
        case .npub, .nprofile:
            // A known group member renders as "@Display Name"; otherwise the truncated bech32
            // keeps the reference legible and tappable.
            if let name = PeerDisplayText.sanitize(mentionNames[entity.bech32]) {
                displayText = "@\(name)"
            } else {
                displayText = "@\(shortReference)"
            }
            isMention = true
        case .note, .nevent, .naddr, .nrelay:
            displayText = shortReference
        @unknown default:
            displayText = shortReference
        }
        // No baked foreground color: the bubble owns `.tint` so the linked reference stays visible
        // on both sent and received. A mention is set off by a subtle background pill (Signal's
        // treatment) rather than bold weight or a color — `.primary` adapts to light/dark and the
        // low alpha reads as a soft highlight over either bubble fill.
        var attributed = AttributedString(displayText)
        if !intent.isEmpty {
            attributed.inlinePresentationIntent = intent
        }
        if isMention {
            attributed.backgroundColor = Color.primary.opacity(0.14)
        }
        if let link = MarkdownLinkPolicy.nostrURL(for: entity.bech32) {
            attributed.link = link
        }
        return attributed
    }

    private static func shortBech32(_ bech32: String) -> String {
        guard bech32.count > 16 else { return bech32 }
        return "\(bech32.prefix(10))...\(bech32.suffix(4))"
    }
}
