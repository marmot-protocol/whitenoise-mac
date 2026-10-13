//
//  MarkdownTimestampRefresh.swift
//  whitenoise-mac
//
//  Re-formats the `<t:…>` timestamp runs (MarmotKit 0.13) inside an already-rendered Markdown
//  display model. The projection formats each timestamp once, off-main, when the window is mapped;
//  MDK's guide asks hosts to format at render time instead, refreshing on locale, time zone and
//  clock changes and keeping visible `relative` timestamps ticking. Every timestamp run carries
//  its instant and style as a `MarkdownTimestampAttribute`, so a view can rewrite just those runs
//  for the moment it draws, the way `MarkdownMentionRelabeling` rewrites mention runs.
//

import Foundation
import MarmotKit

/// The instant and style a timestamp run was rendered from.
nonisolated struct MarkdownTimestampValue: Hashable, Sendable {
    let unixSeconds: Int64
    let style: MarkdownTimestampStyleFfi
}

nonisolated enum MarkdownTimestampAttribute: AttributedStringKey {
    typealias Value = MarkdownTimestampValue
    static let name = "whitenoise.markdownTimestamp"
}

/// What kind of re-formatting a document's timestamps need, if any.
nonisolated enum MarkdownTimestampContent: Equatable, Sendable {
    /// No timestamp runs: the view draws the document as projected.
    case none
    /// Only absolute styles: they change with the locale or time zone, never with the clock.
    case absolute
    /// At least one `relative` run, which also changes as time passes.
    case relative

    init(scanning blocks: [MarkdownDisplayBlockNode]) {
        var content = MarkdownTimestampContent.none
        MarkdownDisplayBlock.visitInlineText(in: blocks) { text in
            for run in text.runs {
                guard let value = run[MarkdownTimestampAttribute.self] else { continue }
                if case .relative = value.style {
                    content = .relative
                    return false
                }
                content = .absolute
            }
            return true
        }
        self = content
    }
}

nonisolated extension MarkdownDisplayDocument {
    /// A copy with every timestamp run re-formatted for `now`, `locale` and `timeZone`, or this
    /// document unchanged when it has no timestamps.
    func refreshingTimestamps(
        now: Date,
        locale: Locale = AppLanguage.currentLocale,
        timeZone: TimeZone = .autoupdatingCurrent
    ) -> MarkdownDisplayDocument {
        guard timestamps != .none else { return self }
        let refreshed = MarkdownDisplayBlock.mappingInlineText(in: blocks) { text in
            Self.refreshing(text, now: now, locale: locale, timeZone: timeZone)
        }
        return MarkdownDisplayDocument(blocks: refreshed, truncated: truncated, timestamps: timestamps)
    }

    /// The instants of every `relative` timestamp run, so a view can tick faster near them.
    var relativeTimestampDates: [Date] {
        guard timestamps == .relative else { return [] }
        var dates: [Date] = []
        MarkdownDisplayBlock.visitInlineText(in: blocks) { text in
            for run in text.runs {
                guard let value = run[MarkdownTimestampAttribute.self], case .relative = value.style else { continue }
                dates.append(Date(timeIntervalSince1970: TimeInterval(value.unixSeconds)))
            }
            return true
        }
        return dates
    }

    /// Rebuilds the string only when it carries a timestamp run, copying each run's attributes
    /// onto its replacement so emphasis, links and the timestamp tag itself survive.
    private static func refreshing(
        _ text: AttributedString,
        now: Date,
        locale: Locale,
        timeZone: TimeZone
    ) -> AttributedString {
        guard text.runs.contains(where: { $0[MarkdownTimestampAttribute.self] != nil }) else { return text }
        var result = AttributedString()
        for run in text.runs {
            guard let value = run[MarkdownTimestampAttribute.self] else {
                result.append(AttributedString(text[run.range]))
                continue
            }
            var replacement = AttributedString(
                MarkdownTimestampFormatter.text(
                    unixSeconds: value.unixSeconds,
                    style: value.style,
                    now: now,
                    locale: locale,
                    timeZone: timeZone
                )
            )
            replacement.setAttributes(run.attributes)
            result.append(replacement)
        }
        return result
    }
}

nonisolated extension MarkdownDisplayBlock {
    /// Calls `visit` with every inline string in `nodes`, depth first; returns false as soon as
    /// `visit` does, which stops the walk.
    @discardableResult
    fileprivate static func visitInlineText(
        in nodes: [MarkdownDisplayBlockNode],
        _ visit: (AttributedString) -> Bool
    ) -> Bool {
        for node in nodes {
            guard node.block.visitInlineText(visit) else { return false }
        }
        return true
    }

    private func visitInlineText(_ visit: (AttributedString) -> Bool) -> Bool {
        switch self {
        case .paragraph(let text), .heading(_, let text):
            return visit(text)
        case .blockQuote(let nodes):
            return Self.visitInlineText(in: nodes, visit)
        case .list(let items):
            for item in items {
                guard Self.visitInlineText(in: item.blocks, visit) else { return false }
            }
            return true
        case .table(let header, let rows):
            for cell in header + rows.flatMap(\.cells) {
                guard visit(cell.text) else { return false }
            }
            return true
        case .thematicBreak, .codeBlock, .mathBlock:
            return true
        }
    }

    /// `nodes` with `transform` applied to every inline string, keeping block and cell ids.
    fileprivate static func mappingInlineText(
        in nodes: [MarkdownDisplayBlockNode],
        _ transform: (AttributedString) -> AttributedString
    ) -> [MarkdownDisplayBlockNode] {
        nodes.map { MarkdownDisplayBlockNode(id: $0.id, block: $0.block.mappingInlineText(transform)) }
    }

    private func mappingInlineText(_ transform: (AttributedString) -> AttributedString) -> MarkdownDisplayBlock {
        switch self {
        case .paragraph(let text):
            return .paragraph(transform(text))
        case .heading(let level, let text):
            return .heading(level: level, text: transform(text))
        case .blockQuote(let nodes):
            return .blockQuote(Self.mappingInlineText(in: nodes, transform))
        case .list(let items):
            return .list(
                items: items.map {
                    MarkdownDisplayListItem(
                        id: $0.id, marker: $0.marker, blocks: Self.mappingInlineText(in: $0.blocks, transform))
                })
        case .table(let header, let rows):
            return .table(
                header: header.map { MarkdownDisplayTableCell(id: $0.id, text: transform($0.text)) },
                rows: rows.map { row in
                    MarkdownDisplayTableRow(
                        id: row.id,
                        cells: row.cells.map { MarkdownDisplayTableCell(id: $0.id, text: transform($0.text)) })
                }
            )
        case .thematicBreak, .codeBlock, .mathBlock:
            return self
        }
    }
}
