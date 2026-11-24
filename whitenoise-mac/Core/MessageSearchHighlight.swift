import Foundation

/// The words a message search is looking for, as the ranges of a text to mark. Built from the same
/// tokens the search matches with (`GlobalMessageSearchText.tokens(in:)`), so what is marked is
/// what made the message a match: every occurrence of every token, compared the way the folded
/// corpus compares (case-insensitively, but not across diacritics).
nonisolated struct MessageSearchHighlight: Hashable, Sendable {
    let tokens: [String]

    init(tokens: [String]) {
        self.tokens = tokens.filter { !$0.isEmpty }
    }

    /// Nil when the query has nothing searchable in it.
    init?(query: String) {
        let tokens = GlobalMessageSearchText.tokens(in: query)
        guard !tokens.isEmpty else { return nil }
        self.init(tokens: tokens)
    }

    /// Every occurrence of every token in `text`, in text order. Ranges of different tokens may
    /// overlap; marking both just marks their union.
    func ranges(in text: String) -> [Range<String.Index>] {
        var found: [Range<String.Index>] = []
        for token in tokens {
            var start = text.startIndex
            while start < text.endIndex,
                let range = text.range(of: token, options: .caseInsensitive, range: start..<text.endIndex)
            {
                found.append(range)
                start = range.upperBound
            }
        }
        return found.sorted { $0.lowerBound < $1.lowerBound }
    }

    /// `ranges(in:)` for an attributed text, so a rendered message keeps its runs.
    func ranges(in text: AttributedString) -> [Range<AttributedString.Index>] {
        var found: [Range<AttributedString.Index>] = []
        for token in tokens {
            var start = text.startIndex
            while start < text.endIndex,
                let range = text[start..<text.endIndex].range(of: token, options: .caseInsensitive)
            {
                found.append(range)
                start = range.upperBound
            }
        }
        return found.sorted { $0.lowerBound < $1.lowerBound }
    }
}
