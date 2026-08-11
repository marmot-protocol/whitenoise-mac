//
//  MarkdownMentionRelabeling.swift
//  whitenoise-mac
//
//  Rewrites the mention tokens inside an already-rendered Markdown display model when the label
//  a mention resolves to changes — the viewer setting or clearing a private nickname.
//
//  A mention is baked into the bubble's attributed string once, off-main, when the window is
//  projected (see `MarkdownDisplayModel`), and the source AST it came from is deliberately not
//  retained. Relabelling in place is what lets a rename land on rows already on screen without
//  re-materializing the window: no snapshot of the timeline subscription, no FFI, no re-parse,
//  and no work at all for rows that do not mention the renamed person.
//
//  Every mention run carries the `nostr:<bech32>` link the projection gave it, so the person a
//  run refers to is recoverable from the rendered string itself. The accent a mention is drawn
//  in is derived from that same bech32 rather than from the label, so it survives a rename
//  untouched — as does emphasis, and the link itself.
//

import Foundation

/// The text a mention renders as. Shared by the projection (`MarkdownDisplayInlineBuilder`) and
/// by the in-place relabel below, so a renamed mention can never drift from what the next
/// re-projection of the same window would produce.
nonisolated enum MarkdownMentionText {
    /// `@Label` when a label is known, else the truncated bech32 that keeps an unresolvable
    /// reference legible and tappable.
    static func label(forBech32 bech32: String, name: String?) -> String {
        guard let name = PeerDisplayText.sanitize(name) else { return "@\(shortBech32(bech32))" }
        return "@\(PeerDisplayText.strippingBidiControls(name))"
    }

    static func shortBech32(_ bech32: String) -> String {
        guard bech32.count > 16 else { return bech32 }
        return "\(bech32.prefix(10))...\(bech32.suffix(4))"
    }
}

// `nonisolated` for the same reason the display model itself is: these are pure value
// transformations, reachable from `MessageItem`'s nonisolated mapping, and must not inherit the
// module's default main-actor isolation (`SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`).
nonisolated extension MarkdownDisplayDocument {
    /// A copy of this document with every mention of `bech32` reading as `name`'s label, or nil
    /// when the document mentions nobody by that reference. Nil rather than an equal copy on
    /// purpose: the caller uses it to leave untouched rows — the overwhelming majority on any
    /// rename — completely alone instead of churning identical values through the timeline store.
    func relabelingMention(bech32: String, name: String?) -> MarkdownDisplayDocument? {
        guard let link = MarkdownLinkPolicy.nostrURL(for: bech32) else { return nil }
        let label = MarkdownMentionText.label(forBech32: bech32, name: name)
        var didChange = false
        var relabeled: [MarkdownDisplayBlockNode] = []
        relabeled.reserveCapacity(blocks.count)
        for node in blocks {
            relabeled.append(
                MarkdownDisplayBlockNode(
                    id: node.id,
                    block: node.block.relabelingMention(link: link, label: label, didChange: &didChange)
                )
            )
        }
        guard didChange else { return nil }
        return MarkdownDisplayDocument(blocks: relabeled, truncated: truncated)
    }
}

nonisolated extension MarkdownDisplayBlock {
    /// Recurses over the block tree the same way the builder does. Blocks that cannot contain an
    /// inline run — rules, code, math — are returned as they are, so nesting costs nothing.
    fileprivate func relabelingMention(
        link: URL,
        label: String,
        didChange: inout Bool
    ) -> MarkdownDisplayBlock {
        switch self {
        case .paragraph(let text):
            return .paragraph(Self.relabeling(text, link: link, label: label, didChange: &didChange))

        case .heading(let level, let text):
            return .heading(
                level: level,
                text: Self.relabeling(text, link: link, label: label, didChange: &didChange)
            )

        case .blockQuote(let nodes):
            return .blockQuote(Self.relabeling(nodes, link: link, label: label, didChange: &didChange))

        case .list(let items):
            var relabeled: [MarkdownDisplayListItem] = []
            relabeled.reserveCapacity(items.count)
            for item in items {
                relabeled.append(
                    MarkdownDisplayListItem(
                        id: item.id,
                        marker: item.marker,
                        blocks: Self.relabeling(item.blocks, link: link, label: label, didChange: &didChange)
                    )
                )
            }
            return .list(items: relabeled)

        case .table(let header, let rows):
            var relabeledHeader: [MarkdownDisplayTableCell] = []
            relabeledHeader.reserveCapacity(header.count)
            for cell in header {
                relabeledHeader.append(
                    MarkdownDisplayTableCell(
                        id: cell.id,
                        text: Self.relabeling(cell.text, link: link, label: label, didChange: &didChange)
                    )
                )
            }
            var relabeledRows: [MarkdownDisplayTableRow] = []
            relabeledRows.reserveCapacity(rows.count)
            for row in rows {
                var cells: [MarkdownDisplayTableCell] = []
                cells.reserveCapacity(row.cells.count)
                for cell in row.cells {
                    cells.append(
                        MarkdownDisplayTableCell(
                            id: cell.id,
                            text: Self.relabeling(cell.text, link: link, label: label, didChange: &didChange)
                        )
                    )
                }
                relabeledRows.append(MarkdownDisplayTableRow(id: row.id, cells: cells))
            }
            return .table(header: relabeledHeader, rows: relabeledRows)

        case .thematicBreak, .codeBlock, .mathBlock:
            return self
        }
    }

    private static func relabeling(
        _ nodes: [MarkdownDisplayBlockNode],
        link: URL,
        label: String,
        didChange: inout Bool
    ) -> [MarkdownDisplayBlockNode] {
        var relabeled: [MarkdownDisplayBlockNode] = []
        relabeled.reserveCapacity(nodes.count)
        for node in nodes {
            relabeled.append(
                MarkdownDisplayBlockNode(
                    id: node.id,
                    block: node.block.relabelingMention(link: link, label: label, didChange: &didChange)
                )
            )
        }
        return relabeled
    }

    /// Rebuilds the string only when it actually carries a run for this person, and copies each
    /// run's attributes onto the replacement so the mention keeps its accent, weight, and link.
    private static func relabeling(
        _ text: AttributedString,
        link: URL,
        label: String,
        didChange: inout Bool
    ) -> AttributedString {
        guard
            text.runs.contains(where: { run in
                run.link == link && String(text[run.range].characters) != label
            })
        else { return text }

        var result = AttributedString()
        for run in text.runs {
            let slice = text[run.range]
            guard run.link == link, String(slice.characters) != label else {
                result.append(AttributedString(slice))
                continue
            }
            var replacement = AttributedString(label)
            replacement.setAttributes(run.attributes)
            result.append(replacement)
            didChange = true
        }
        return result
    }
}
