import Foundation
import MarmotKit

/// One searchable message of a conversation: its id, its author, and its text already folded by
/// `GlobalMessageSearchText.searchableText(_:)`, so a keystroke only runs substring checks.
nonisolated struct ConversationSearchEntry: Equatable, Sendable {
    let messageId: String
    /// Lowercased, the form `BlockedUsersViewModel.blockedAccountIDs` holds.
    let sender: String
    let searchableText: String
}

/// Messages the transcript does not draw, which a search must neither count nor land on: rows
/// from blocked accounts (`BlockedConversationPresentation`) and rows hidden on this device.
nonisolated struct ConversationSearchExclusions: Equatable, Sendable {
    var blockedSenders: Set<String> = []
    var hiddenMessageIds: Set<String> = []

    static let none = ConversationSearchExclusions()

    func excludes(_ entry: ConversationSearchEntry) -> Bool {
        blockedSenders.contains(entry.sender) || hiddenMessageIds.contains(entry.messageId)
    }
}

/// Reads a conversation's whole searchable history from MDK's timeline projection. Unlike the
/// transcript's window, which MarmotKit caps at a few hundred rows, this covers every message, so a
/// match count is the chat's real count rather than "what happens to be loaded".
nonisolated enum ConversationSearchCorpus {
    static let pageLimit: UInt32 = 200

    /// Every searchable message, oldest first. Blocking FFI: run it through
    /// `FFIExecutor.runCancellable`, which supplies `checkCancellation`.
    static func load(
        client: any MarmotRuntime,
        accountRef: String,
        groupIdHex: String,
        checkCancellation: @Sendable () throws -> Void
    ) throws -> [ConversationSearchEntry] {
        // Pages arrive newest first, each one oldest first inside.
        var pagesNewestFirst: [[ConversationSearchEntry]] = []
        var before: UInt64?
        var beforeMessageId: String?

        while true {
            try checkCancellation()
            let page = try client.timelineMessages(
                accountRef: accountRef,
                query: TimelineMessageQueryFfi(
                    groupIdHex: groupIdHex,
                    search: nil,
                    before: before,
                    beforeMessageId: beforeMessageId,
                    after: nil,
                    afterMessageId: nil,
                    limit: pageLimit
                )
            )
            pagesNewestFirst.append(page.messages.compactMap(entry(for:)))

            guard page.hasMoreBefore, let oldest = page.messages.first else { break }
            // A cursor that does not move would read the same page forever.
            guard oldest.timelineAt != before || oldest.messageIdHex != beforeMessageId else { break }
            before = oldest.timelineAt
            beforeMessageId = oldest.messageIdHex
        }
        return pagesNewestFirst.reversed().flatMap { $0 }
    }

    /// The same rows the account-wide search considers: chat messages that still stand.
    static func entry(for record: TimelineMessageRecordFfi) -> ConversationSearchEntry? {
        guard record.kind == 9,
            !record.deleted,
            record.invalidationStatus == nil,
            !record.messageIdHex.isEmpty
        else { return nil }
        // A row with nothing to read (media without a caption) can never match a query.
        guard record.plaintext.contains(where: { !$0.isWhitespace }) else { return nil }
        let text = GlobalMessageSearchText.searchableText(record.plaintext)
        return ConversationSearchEntry(
            messageId: record.messageIdHex,
            sender: record.sender.lowercased(),
            searchableText: text
        )
    }
}

/// Pure match finding and cursor arithmetic for in-conversation search. Matches are message ids
/// in timeline order, oldest first; the cursor starts on the newest, the one nearest the live tail.
nonisolated enum ConversationSearchEngine {
    static func matches(
        tokens: [String],
        in entries: [ConversationSearchEntry],
        excluding exclusions: ConversationSearchExclusions = .none
    ) -> [String] {
        guard !tokens.isEmpty else { return [] }
        return entries.compactMap { entry in
            guard !exclusions.excludes(entry),
                GlobalMessageSearchText.matches(searchableText: entry.searchableText, tokens: tokens)
            else { return nil }
            return entry.messageId
        }
    }

    /// A fresh query lands on the newest match.
    static func initialIndex(matchCount: Int) -> Int? {
        matchCount > 0 ? matchCount - 1 : nil
    }

    /// One step toward older matches, wrapping from the oldest back to the newest. Without a
    /// cursor the step lands on the newest match.
    static func olderIndex(from current: Int?, matchCount: Int) -> Int? {
        guard matchCount > 0 else { return nil }
        guard let current, current > 0, current < matchCount else { return matchCount - 1 }
        return current - 1
    }

    /// One step toward newer matches, wrapping from the newest back to the oldest. Without a
    /// cursor the step lands on the newest match.
    static func newerIndex(from current: Int?, matchCount: Int) -> Int? {
        guard matchCount > 0 else { return nil }
        guard let current, current >= 0, current < matchCount else { return matchCount - 1 }
        return current < matchCount - 1 ? current + 1 : 0
    }

    /// After the matches are recomputed, find the cursor's message again by id.
    static func reanchoredIndex(of messageId: String?, in matches: [String]) -> Int? {
        guard let messageId else { return nil }
        return matches.lastIndex(of: messageId)
    }

    /// The counter's position, counted from the newest match so the first one reads "1".
    static func displayPosition(index: Int, matchCount: Int) -> Int {
        matchCount - index
    }
}
