import AppKit
import SwiftUI

extension EnvironmentValues {
    /// The search the message below is the current match of. Set by the transcript on that one
    /// row only, so every other bubble renders its text untouched.
    @Entry var messageSearchHighlight: MessageSearchHighlight? = nil
}

/// How a search hit is marked wherever one is shown — in a bubble of the conversation being
/// searched, in the "Search all messages" results and in the sidebar's message matches: a native
/// macOS find-highlight fill behind the matched words only, never a wash over the whole row or
/// blanket transcript dimming (F07, #1043).
///
/// Only colors change, never the font, so marking a bubble cannot move a line break and the
/// transcript row keeps the height it was measured at.
nonisolated enum SearchMatchHighlightStyle {
    static let nsBackground = NSColor.findHighlightColor
    static let nsContent = WNNSColor.searchHighlightContent
    static let background = Color(nsColor: .findHighlightColor)
    static let content = Color(nsColor: nsContent)

    /// `text` with every match of `highlight` marked.
    static func marking(_ text: AttributedString, with highlight: MessageSearchHighlight?) -> AttributedString {
        guard let highlight else { return text }
        let ranges = highlight.ranges(in: text)
        guard !ranges.isEmpty else { return text }
        var marked = text
        for range in ranges {
            mark(&marked, range: range)
        }
        return marked
    }

    /// A plain string with every match of `highlight` marked.
    static func marking(_ text: String, with highlight: MessageSearchHighlight?) -> AttributedString {
        marking(AttributedString(text), with: highlight)
    }

    /// A result snippet whose matched run is marked; the run around it is left to the caller's style.
    static func text(_ snippet: GlobalMessageSearchSnippet) -> Text {
        var match = AttributedString(snippet.match)
        mark(&match, range: match.startIndex..<match.endIndex)
        return Text(snippet.leading) + Text(match) + Text(snippet.trailing)
    }

    private static func mark(_ text: inout AttributedString, range: Range<AttributedString.Index>) {
        guard !range.isEmpty else { return }
        text[range].backgroundColor = background
        text[range].foregroundColor = content
    }
}

#Preview("Search match highlighter") {
    VStack(alignment: .leading, spacing: 16) {
        Text(
            SearchMatchHighlightStyle.marking(
                "Lunch at noon? Lunch is on me.", with: MessageSearchHighlight(query: "lunch"))
        )
        .font(MessageTypography.body)
        .foregroundStyle(MessageBubblePolarity.received.content)
        .padding(12)
        .background(MessageBubblePolarity.received.fill, in: .rect(cornerRadius: 14))
        Text(
            SearchMatchHighlightStyle.marking(
                "Lunch at noon? Lunch is on me.", with: MessageSearchHighlight(query: "lunch"))
        )
        .font(MessageTypography.body)
        .foregroundStyle(MessageBubblePolarity.sent.content)
        .padding(12)
        .background(MessageBubblePolarity.sent.fill, in: .rect(cornerRadius: 14))
        SearchMatchHighlightStyle.text(
            GlobalMessageSearchSnippet(leading: "Lunch at ", match: "noon", trailing: " tomorrow?")
        )
        .font(.callout)
        .foregroundStyle(.secondary)
    }
    .padding(24)
}
