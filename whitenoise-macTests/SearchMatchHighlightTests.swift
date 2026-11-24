//
//  SearchMatchHighlightTests.swift
//  whitenoise-macTests
//
//  The highlighter mark on a search match: which words of a message it covers, that it changes
//  only colors, and that only the transcript row of the current match carries it.
//

import Foundation
import SwiftUI
import Testing

@testable import whitenoise_mac

struct SearchMatchHighlightTests {
    private static func marked(_ text: AttributedString) -> [String] {
        text.runs.compactMap { run in
            run.backgroundColor == SearchMatchHighlightStyle.background
                ? String(text[run.range].characters) : nil
        }
    }

    @Test func aQueryWithoutWordsHighlightsNothing() {
        #expect(MessageSearchHighlight(query: "  ?! ") == nil)
        #expect(SearchMatchHighlightStyle.marking("Lunch at noon", with: nil).runs.count == 1)
    }

    @Test func everyOccurrenceOfEveryTokenIsFoundCaseInsensitively() {
        let highlight = MessageSearchHighlight(query: "LUNCH noon")
        let text = "Lunch at noon? lunch is at NOON."
        let words = highlight?.ranges(in: text).map { String(text[$0]) }
        #expect(words == ["Lunch", "noon", "lunch", "NOON"])
    }

    @Test func onlyTheMatchedWordsAreMarked() {
        let highlight = MessageSearchHighlight(query: "lunch")
        let marked = SearchMatchHighlightStyle.marking("Lunch at noon? Lunch is on me.", with: highlight)
        #expect(Self.marked(marked) == ["Lunch", "Lunch"])
        #expect(String(marked.characters) == "Lunch at noon? Lunch is on me.")
    }

    @Test func markingKeepsTheRunsItLandsOn() {
        var text = AttributedString("Read the spec at ")
        var link = AttributedString("spec.example")
        link.link = URL(string: "https://spec.example")
        text.append(link)

        let marked = SearchMatchHighlightStyle.marking(text, with: MessageSearchHighlight(query: "spec"))

        #expect(Self.marked(marked) == ["spec", "spec"])
        // The marked word inside the link is still a link.
        #expect(marked.runs.contains { $0.link != nil && $0.backgroundColor == SearchMatchHighlightStyle.background })
    }

    @Test func markingChangesColorsOnlyNeverTheFont() {
        let marked = SearchMatchHighlightStyle.marking("Lunch at noon", with: MessageSearchHighlight(query: "noon"))
        #expect(marked.runs.allSatisfy { $0.attributes[AttributeScopes.SwiftUIAttributes.FontAttribute.self] == nil })
        #expect(marked.runs.contains { $0.foregroundColor == SearchMatchHighlightStyle.content })
    }

    @Test func aMatchWithDiacriticsIsNotMarkedWhereTheSearchWouldNotMatch() {
        // The corpus folds case but not diacritics, so the mark does too.
        let highlight = MessageSearchHighlight(query: "cafe")
        let text = "Café or cafe?"
        #expect(highlight?.ranges(in: text).map { String(text[$0]) } == ["cafe"])
    }

    @Test func onlyTheCurrentMatchRowCarriesTheHighlight() {
        let highlight = MessageSearchHighlight(query: "lunch")
        let items = ["a", "b", "c"].map { id in
            TimelineMessageDisplayItem(
                message: MessageItem(id: id, senderName: "Ana", body: "lunch", sentAt: Date(), isOutgoing: false),
                dayLabel: nil)
        }
        let rows = TranscriptRow.rows(
            displayItems: items,
            paging: .empty,
            pendingOutgoingRows: [],
            unreadDividerMessageId: nil,
            searchMatchMessageId: "b",
            searchHighlight: highlight,
            context: TranscriptRowContext(
                canVoteInPolls: true, showsDebugMetadata: false, isSelectionMode: false, localeIdentifier: "en",
                referenceDay: 0)
        )
        let highlights = rows.compactMap { row -> MessageSearchHighlight?? in
            guard case .message(_, _, let searchHighlight, _, _, _) = row else { return nil }
            return .some(searchHighlight)
        }
        #expect(highlights == [nil, highlight, nil])
    }

    @Test func aNewQueryChangesTheMatchRow() {
        let item = TimelineMessageDisplayItem(
            message: MessageItem(id: "a", senderName: "Ana", body: "lunch noon", sentAt: Date(), isOutgoing: false),
            dayLabel: nil)
        let context = TranscriptRowContext(
            canVoteInPolls: true, showsDebugMetadata: false, isSelectionMode: false, localeIdentifier: "en",
            referenceDay: 0)
        let lunch = TranscriptRow.message(
            item, showsUnreadDivider: false, searchHighlight: MessageSearchHighlight(query: "lunch"),
            context: context)
        let noon = TranscriptRow.message(
            item, showsUnreadDivider: false, searchHighlight: MessageSearchHighlight(query: "noon"),
            context: context)
        #expect(lunch != noon)
    }
}
