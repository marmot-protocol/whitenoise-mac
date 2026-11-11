//
//  ConversationSearchTests.swift
//  whitenoise-macTests
//
//  Search within one conversation: reading the chat's history into a corpus, matching it, and
//  the cursor the reader steps through the matches with.
//

import Foundation
import MarmotKit
import Testing

@testable import whitenoise_mac

private struct CorpusLoadFailure: Error {}

/// A corpus the test can swap between reads, standing in for history that changes.
private nonisolated final class MutableCorpus: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [ConversationSearchEntry]
    private var failure: Error?
    private(set) var loads = 0

    init(_ entries: [ConversationSearchEntry]) {
        self.entries = entries
    }

    func replace(with entries: [ConversationSearchEntry]) {
        lock.withLock { self.entries = entries }
    }

    func fail(with error: Error?) {
        lock.withLock { failure = error }
    }

    var loadCount: Int { lock.withLock { loads } }

    func load() throws -> [ConversationSearchEntry] {
        try lock.withLock {
            loads += 1
            if let failure { throw failure }
            return entries
        }
    }
}

private func entry(_ id: String, _ text: String, sender: String = "peer") -> ConversationSearchEntry {
    ConversationSearchEntry(
        messageId: id,
        sender: sender,
        searchableText: GlobalMessageSearchText.searchableText(text)
    )
}

@MainActor
private func makeSearch(_ corpus: MutableCorpus) -> ConversationSearchViewModel {
    ConversationSearchViewModel(
        loadCorpus: { _ in try corpus.load() },
        queryDebounce: .zero,
        refreshDebounce: .zero
    )
}

@MainActor
private func waitUntil(
    _ condition: () -> Bool,
    sourceLocation: SourceLocation = #_sourceLocation
) async {
    let deadline = ContinuousClock.now + .seconds(10)
    while !condition() {
        guard ContinuousClock.now < deadline else {
            Issue.record("Timed out waiting for the search to settle", sourceLocation: sourceLocation)
            return
        }
        try? await Task.sleep(for: .milliseconds(2))
    }
}

struct ConversationSearchTests {
    // MARK: Engine

    @Test func cursorStartsOnTheNewestMatchAndWrapsBothWays() {
        #expect(ConversationSearchEngine.initialIndex(matchCount: 0) == nil)
        #expect(ConversationSearchEngine.initialIndex(matchCount: 3) == 2)

        #expect(ConversationSearchEngine.olderIndex(from: 2, matchCount: 3) == 1)
        #expect(ConversationSearchEngine.olderIndex(from: 0, matchCount: 3) == 2)
        #expect(ConversationSearchEngine.olderIndex(from: nil, matchCount: 3) == 2)
        #expect(ConversationSearchEngine.olderIndex(from: nil, matchCount: 0) == nil)

        #expect(ConversationSearchEngine.newerIndex(from: 1, matchCount: 3) == 2)
        #expect(ConversationSearchEngine.newerIndex(from: 2, matchCount: 3) == 0)
        #expect(ConversationSearchEngine.newerIndex(from: nil, matchCount: 3) == 2)
        #expect(ConversationSearchEngine.newerIndex(from: 7, matchCount: 3) == 2)

        #expect(ConversationSearchEngine.displayPosition(index: 2, matchCount: 3) == 1)
        #expect(ConversationSearchEngine.displayPosition(index: 0, matchCount: 3) == 3)
        #expect(ConversationSearchEngine.reanchoredIndex(of: "b", in: ["a", "b", "c"]) == 1)
        #expect(ConversationSearchEngine.reanchoredIndex(of: "z", in: ["a", "b", "c"]) == nil)
    }

    /// The account-wide search's folding: case and Unicode normalization, not diacritics.
    @Test func matchingFoldsCaseAndNormalizationAndSkipsWhatTheTranscriptHides() {
        let entries = [
            entry("a", "Lunch at the CAFÉ?"),
            entry("b", "unrelated"),
            entry("c", "café tomorrow", sender: "blocked"),
            entry("d", "the cafe\u{0301} again"),
            entry("f", "plain cafe is a different word"),
            entry("e", "Café, hidden on this device"),
        ]
        let tokens = GlobalMessageSearchText.tokens(in: "café")

        #expect(ConversationSearchEngine.matches(tokens: tokens, in: entries) == ["a", "c", "d", "e"])
        #expect(
            ConversationSearchEngine.matches(
                tokens: tokens,
                in: entries,
                excluding: ConversationSearchExclusions(blockedSenders: ["blocked"], hiddenMessageIds: ["e"])
            ) == ["a", "d"])
        #expect(ConversationSearchEngine.matches(tokens: [], in: entries).isEmpty)
    }

    // MARK: Corpus

    @Test func corpusReadsTheWholeHistoryOldestFirstAndKeepsOnlyStandingChatMessages() throws {
        let runtime = FakeMarmotRuntime(accounts: [desktopAccount()])
        let sender = desktopAccount().accountIdHex.uppercased()
        var records = (0..<450).map { index in
            timelineMessage(
                id: String(format: "%064x", index),
                groupIdHex: "group",
                sender: sender,
                plaintext: "message \(index)",
                recordedAt: UInt64(1_000 + index)
            )
        }
        records[10] = timelineMessage(
            id: records[10].messageIdHex, groupIdHex: "group", sender: sender, plaintext: "gone",
            recordedAt: 1_010, deleted: true)
        records[11] = timelineMessage(
            id: records[11].messageIdHex, groupIdHex: "group", sender: sender, plaintext: "lost branch",
            recordedAt: 1_011, invalidationStatus: "LosingBranch")
        records[12] = timelineMessage(
            id: records[12].messageIdHex, groupIdHex: "group", sender: sender, plaintext: "renamed",
            kind: 1210, recordedAt: 1_012)
        records[13] = timelineMessage(
            id: records[13].messageIdHex, groupIdHex: "group", sender: sender, plaintext: "  ",
            recordedAt: 1_013)
        runtime.installTimelinePage(
            TimelinePageFfi(messages: records, hasMoreBefore: false, hasMoreAfter: false),
            groupIdHex: "group"
        )

        let corpus = try ConversationSearchCorpus.load(
            client: runtime,
            accountRef: "Desktop Account",
            groupIdHex: "group",
            checkCancellation: {}
        )

        let expectedIds = records.enumerated()
            .filter { ![10, 11, 12, 13].contains($0.offset) }
            .map(\.element.messageIdHex)
        #expect(corpus.map(\.messageId) == expectedIds)
        #expect(corpus.allSatisfy { $0.sender == sender.lowercased() })
        #expect(runtime.timelineMessageQueries.count == 3)
        #expect(runtime.timelineMessageQueries.allSatisfy { $0.groupIdHex == "group" && $0.search == nil })
    }

    @Test func corpusLoadStopsWhenCancelled() {
        let runtime = FakeMarmotRuntime(accounts: [desktopAccount()])
        #expect(throws: CancellationError.self) {
            try ConversationSearchCorpus.load(
                client: runtime,
                accountRef: "Desktop Account",
                groupIdHex: "group",
                checkCancellation: { throw CancellationError() }
            )
        }
        #expect(runtime.timelineMessageQueries.isEmpty)
    }

    // MARK: View model

    @MainActor
    @Test func typingLandsOnTheNewestMatchAndSteppingWalksOlderThenWraps() async {
        let corpus = MutableCorpus([
            entry("m1", "pizza tonight?"),
            entry("m2", "no"),
            entry("m3", "PIZZA is good"),
            entry("m4", "ok, pizza it is"),
        ])
        let search = makeSearch(corpus)
        search.activate()
        search.query = "pizza"
        await waitUntil { search.navigation != nil }

        #expect(search.matches == ["m1", "m3", "m4"])
        #expect(search.currentMatchMessageId == "m4")
        #expect(search.displayPosition == 1)
        #expect(search.navigation?.messageId == "m4")
        #expect(!search.isSearching)

        search.goToOlderMatch()
        #expect(search.navigation?.messageId == "m3")
        #expect(search.displayPosition == 2)
        search.goToOlderMatch()
        search.goToOlderMatch()
        #expect(search.navigation?.messageId == "m4")

        let previous = search.navigation
        search.goToNewerMatch()
        #expect(search.navigation?.messageId == "m1")
        search.goToNewerMatch()
        search.goToNewerMatch()
        #expect(search.navigation?.messageId == "m4")
        #expect(search.navigation != previous)
        #expect(corpus.loadCount == 1)
    }

    @MainActor
    @Test func newHistoryRecountsWithoutMovingTheReader() async {
        let corpus = MutableCorpus([entry("m1", "deploy friday"), entry("m2", "deploy monday")])
        let search = makeSearch(corpus)
        search.activate()
        search.query = "deploy"
        await waitUntil { search.matches.count == 2 }
        search.goToOlderMatch()
        let navigation = search.navigation
        #expect(search.currentMatchMessageId == "m1")

        corpus.replace(with: [entry("m1", "deploy friday"), entry("m2", "deploy monday"), entry("m3", "deploy now")])
        search.historyDidChange()
        await waitUntil { search.matches.count == 3 }

        #expect(search.currentMatchMessageId == "m1")
        #expect(search.displayPosition == 3)
        #expect(search.navigation == navigation)
    }

    @MainActor
    @Test func blockingASenderRecountsTheOpenSearch() async {
        let corpus = MutableCorpus([entry("m1", "hello", sender: "spammer"), entry("m2", "hello there")])
        let search = makeSearch(corpus)
        search.activate()
        search.query = "hello"
        await waitUntil { search.matches.count == 2 }

        search.exclusions = ConversationSearchExclusions(blockedSenders: ["spammer"])
        await waitUntil { search.matches.count == 1 }

        #expect(search.matches == ["m2"])
        #expect(search.currentMatchMessageId == "m2")
    }

    @MainActor
    @Test func anUnreachableMatchIsDroppedFromTheCount() async {
        let corpus = MutableCorpus([entry("m1", "tax form"), entry("m2", "tax return"), entry("m3", "tax due")])
        let search = makeSearch(corpus)
        search.activate()
        search.query = "tax"
        await waitUntil { search.matches.count == 3 }

        search.matchUnavailable("m3")

        #expect(search.matches == ["m1", "m2"])
        #expect(search.currentMatchMessageId == "m2")
        #expect(search.displayPosition == 1)
    }

    @MainActor
    @Test func droppingTheCurrentMatchBringsTheNextOneOnScreen() async {
        let corpus = MutableCorpus([entry("m1", "tax form"), entry("m2", "tax return"), entry("m3", "tax due")])
        let search = makeSearch(corpus)
        search.activate()
        search.query = "tax"
        await waitUntil { search.navigation?.messageId == "m3" }
        let failed = search.navigation

        search.matchUnavailable("m3")

        #expect(search.currentMatchMessageId == "m2")
        #expect(search.navigation?.messageId == "m2")
        #expect(search.navigation?.id != failed?.id)
    }

    @MainActor
    @Test func aDropAfterSteppingOlderMovesOnToTheNextOlderMatch() async {
        let corpus = MutableCorpus([entry("m1", "tax form"), entry("m2", "tax return"), entry("m3", "tax due")])
        let search = makeSearch(corpus)
        search.activate()
        search.query = "tax"
        await waitUntil { search.navigation?.messageId == "m3" }

        search.goToOlderMatch()
        search.matchUnavailable("m2")
        #expect(search.navigation?.messageId == "m1")

        // From the oldest, older wraps to the newest, as a step would.
        search.matchUnavailable("m1")
        #expect(search.matches == ["m3"])
        #expect(search.navigation?.messageId == "m3")
    }

    @MainActor
    @Test func aDropAfterSteppingNewerMovesOnToTheNextNewerMatch() async {
        let corpus = MutableCorpus([
            entry("m1", "tax form"), entry("m2", "tax return"), entry("m3", "tax due"), entry("m4", "tax paid"),
        ])
        let search = makeSearch(corpus)
        search.activate()
        search.query = "tax"
        await waitUntil { search.navigation?.messageId == "m4" }
        search.goToOlderMatch()
        search.goToOlderMatch()
        search.goToOlderMatch()

        search.goToNewerMatch()
        #expect(search.navigation?.messageId == "m2")
        search.matchUnavailable("m2")
        #expect(search.navigation?.messageId == "m3")

        // From the newest, newer wraps to the oldest, as a step would.
        search.goToNewerMatch()
        search.matchUnavailable("m4")
        #expect(search.matches == ["m1", "m3"])
        #expect(search.navigation?.messageId == "m1")
    }

    @MainActor
    @Test func droppingAnotherMatchLeavesTheTranscriptWhereItIs() async {
        let corpus = MutableCorpus([entry("m1", "tax form"), entry("m2", "tax return"), entry("m3", "tax due")])
        let search = makeSearch(corpus)
        search.activate()
        search.query = "tax"
        await waitUntil { search.navigation?.messageId == "m3" }
        let shown = search.navigation

        search.matchUnavailable("m1")

        #expect(search.matches == ["m2", "m3"])
        #expect(search.currentMatchMessageId == "m3")
        #expect(search.navigation == shown)
    }

    @MainActor
    @Test func droppingTheOnlyMatchClearsTheCursorWithoutNavigating() async {
        let corpus = MutableCorpus([entry("m1", "tax form")])
        let search = makeSearch(corpus)
        search.activate()
        search.query = "tax"
        await waitUntil { search.navigation?.messageId == "m1" }
        let shown = search.navigation

        search.matchUnavailable("m1")

        #expect(search.matches.isEmpty)
        #expect(search.currentIndex == nil)
        #expect(search.navigation == shown)
    }

    @MainActor
    @Test func endingTheSearchClearsItAndTheNextOpenRereadsHistory() async {
        let corpus = MutableCorpus([entry("m1", "keys")])
        let search = makeSearch(corpus)
        search.activate()
        search.query = "keys"
        await waitUntil { search.navigation != nil }

        search.end()

        #expect(!search.isActive)
        #expect(search.query.isEmpty)
        #expect(search.matches.isEmpty)
        #expect(search.currentMatchMessageId == nil)
        #expect(search.navigation == nil)

        search.query = "keys"
        #expect(search.matches.isEmpty)

        search.query = ""
        search.activate()
        search.query = "keys"
        await waitUntil { search.navigation != nil }
        #expect(corpus.loadCount == 2)
    }

    @MainActor
    @Test func aHistoryReadFailureFailsTheSearchInsteadOfSpinning() async {
        let corpus = MutableCorpus([])
        corpus.fail(with: CorpusLoadFailure())
        let search = makeSearch(corpus)
        search.activate()
        search.query = "anything"
        await waitUntil { search.didFail }

        #expect(search.didFail)
        #expect(!search.isSearching)
        #expect(search.matches.isEmpty)
        #expect(!search.canStep)
    }

    @MainActor
    @Test func aBlankQueryHasNoMatchesAndNoStatus() async {
        let corpus = MutableCorpus([entry("m1", "anything")])
        let search = makeSearch(corpus)
        search.activate()
        search.query = "   "
        await waitUntil { corpus.loadCount == 1 }

        #expect(!search.hasQuery)
        #expect(search.matches.isEmpty)
        #expect(search.displayPosition == nil)
        #expect(search.navigation == nil)
    }
}
