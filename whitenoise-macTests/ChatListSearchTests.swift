//
//  ChatListSearchTests.swift
//  whitenoise-macTests
//
//  Chat-list search runs in MDK: `chatListQueryIds` over `Any[Text, MessageText]` picks the
//  matches, a `GroupIds` window draws them, and Select All and bulk actions read the same query.
//

import Foundation
import MarmotKit
import Testing

@testable import whitenoise_mac

struct ChatListSearchTests {
    // MARK: - Query construction

    @Test func aSearchMatchesTitlesAndMessageTextInTheBaseView() {
        let query = ChatListSearchQuery.matches(text: "  Book club \n", view: .archived)
        #expect(
            query
                == ChatListViewQueryFfi(
                    view: .archived,
                    filter: [.any(children: [1, 2]), .text(text: "Book club"), .messageText(text: "Book club")]
                ))
        #expect(ChatListSearchQuery.matches(text: "   ", view: .chats) == nil)
        #expect(ChatListSearchQuery.matches(text: "", view: .chats) == nil)
    }

    @MainActor
    @Test func everyDrawerTabSearchesItsOwnView() {
        #expect(ChatListFilter.active.chatListView == .chats)
        #expect(ChatListFilter.unread.chatListView == .unread)
        #expect(ChatListFilter.archived.chatListView == .archived)
        #expect(ChatListFilter.left.chatListView == .left)
    }

    /// The text appears twice, and MDK allows 1024 bytes across both nodes.
    @Test func searchTextIsCutToHalfOfMDKsTextBudgetOnACharacterBoundary() throws {
        let query = try #require(ChatListSearchQuery.matches(text: String(repeating: "é", count: 400), view: .chats))
        guard case .text(let text) = query.filter[1] else {
            Issue.record("Expected a Text node")
            return
        }
        #expect(text.utf8.count == 512)
        #expect(text == String(repeating: "é", count: 256))
    }

    @Test func theResultsWindowListsIdsAndNeverMessageText() {
        let ids = (0..<600).map { "g\($0)" }
        let window = ChatListSearchQuery.window(showing: ids, view: .unread)
        #expect(window.view == .unread)
        #expect(window.filter == [.groupIds(groupIds: Array(ids.prefix(500)))])
    }

    // MARK: - Search model

    @MainActor
    @Test func resultsAreTheIdsMDKMatchedNotAHostFilter() async throws {
        let runtime = searchRuntime(groupIds: ["a", "b", "c"])
        let query = try #require(ChatListSearchQuery.matches(text: "chat", view: .chats))
        // Every fixture is titled "Chat …"; MDK picks only two, and only those are shown.
        runtime.chatListQueryIdsByQuery[query] = ["c", "a"]
        let search = ChatListSearchViewModel(accountRef: "account", runtime: runtime, debounce: .zero)

        search.search("chat", view: .chats)
        #expect(search.phase == .searching)
        await search.loadTask?.value

        #expect(search.phase == .ready)
        #expect(search.matchesQuery == query)
        #expect(search.matchIds == ["c", "a"])
        #expect(Set(search.rows.map(\.row.groupIdHex)) == ["a", "c"])
        #expect(runtime.chatListQueryIdsCalls == [query])
        #expect(
            runtime.openChatListQueryWindowCalls.map(\.query) == [
                ChatListSearchQuery.window(showing: ["c", "a"], view: .chats)
            ])
    }

    /// The old host filter matched a row's localized subtitle, so "direct" found every DM.
    @MainActor
    @Test func typingDirectNoLongerMatchesEveryDirectMessage() async throws {
        let runtime = searchRuntime(groupIds: ["dm-1", "dm-2"], isDirect: true)
        let search = ChatListSearchViewModel(accountRef: "account", runtime: runtime, debounce: .zero)

        search.search("direct", view: .chats)
        await search.loadTask?.value

        #expect(search.phase == .ready)
        #expect(search.matchIds.isEmpty)
        #expect(search.rows.isEmpty)
        #expect(runtime.openChatListQueryWindowCalls.isEmpty)
    }

    @MainActor
    @Test func blankTextEndsTheSearchWithoutAskingMDK() async throws {
        let runtime = searchRuntime(groupIds: ["a"])
        let search = ChatListSearchViewModel(accountRef: "account", runtime: runtime, debounce: .zero)

        search.search("  ", view: .chats)

        #expect(search.phase == .inactive)
        #expect(search.matchesQuery == nil)
        #expect(runtime.chatListQueryIdsCalls.isEmpty)
    }

    @MainActor
    @Test func aSearchWaitsOutChatPresentationNotReadyWithoutShowingRows() async throws {
        let runtime = searchRuntime(groupIds: ["a"])
        let query = try #require(ChatListSearchQuery.matches(text: "chat", view: .chats))
        runtime.chatListQueryIdsByQuery[query] = ["a"]
        runtime.chatListQueryErrors = [MarmotKitError.ChatPresentationNotReady]
        let search = ChatListSearchViewModel(accountRef: "account", runtime: runtime, debounce: .zero)

        search.search("chat", view: .chats)
        #expect(search.phase == .searching)
        #expect(search.rows.isEmpty)
        await search.loadTask?.value

        #expect(runtime.chatListQueryIdsCalls.count == 2)
        #expect(search.phase == .ready)
        #expect(search.rows.map(\.row.groupIdHex) == ["a"])
    }

    @MainActor
    @Test func aRefusedQueryFailsTheSearchInsteadOfShowingNothingAsAResult() async throws {
        let runtime = searchRuntime(groupIds: ["a"])
        runtime.chatListQueryErrors = [MarmotKitError.InvalidChatListQuery(reason: .textTooLong)]
        let search = ChatListSearchViewModel(accountRef: "account", runtime: runtime, debounce: .zero)

        search.search("chat", view: .chats)
        await search.loadTask?.value

        #expect(search.phase == .failed)
        #expect(search.rows.isEmpty)
    }

    /// MDK takes at most 500 ids in a `GroupIds` node: the window shows the first 500 in display
    /// order and flags the rest, while Select All still reaches every match.
    @MainActor
    @Test func pastFiveHundredMatchesTheWindowShowsTheFirstFiveHundredAndSaysSo() async throws {
        let ids = (0..<600).map { "g\($0)" }
        let runtime = searchRuntime(groupIds: Array(ids.prefix(3)))
        let query = try #require(ChatListSearchQuery.matches(text: "g", view: .chats))
        runtime.chatListQueryIdsByQuery[query] = ids
        let search = ChatListSearchViewModel(accountRef: "account", runtime: runtime, debounce: .zero)

        search.search("g", view: .chats)
        await search.loadTask?.value

        #expect(search.phase == .ready)
        #expect(search.isTruncated)
        #expect(search.matchIds.count == 600)
        let window = try #require(runtime.openChatListQueryWindowCalls.first?.query)
        #expect(window.filter == [.groupIds(groupIds: Array(ids.prefix(500)))])

        let selection = ChatListSelectionViewModel(accountRef: "account", runtime: runtime)
        selection.updateVisibleChats(search.rows.map(\.row.groupIdHex), query: query, isWindowed: true)
        selection.begin(with: "g0")
        await selection.viewIdsTask?.value
        selection.toggleAll()
        #expect(selection.orderedSelection.count == 600)
    }

    // MARK: - Paging the results window

    /// MDK retains at most 200 rows around the visible anchor. Paging forward follows the anchor
    /// the rows on screen set, every command runs on the sequence the one before it installed,
    /// and the rows the window let go of page back in from the top.
    @MainActor
    @Test func pagingFollowsTheVisibleAnchorOneCommandAtATime() async throws {
        let search = try await pagedSearch { runtime in
            runtime.chatListQueryWindowPages = [
                pagedSnapshot(sequence: 3, rows: ["b", "c"], hasMoreBefore: true, hasMoreAfter: false)
            ]
        }
        #expect(search.model.hasMoreRows)
        #expect(!search.model.hasEarlierRows)

        search.model.setVisibleAnchor(groupIdHex: "b")
        search.model.pageForward()
        // A second appearance of the last row while the page is queued asks for nothing more.
        search.model.pageForward()
        await search.model.windowCommandTask?.value

        #expect(search.window.commands == [.anchor("b", sequence: 1), .page(.forward, sequence: 2)])
        #expect(search.model.rows.map(\.row.groupIdHex) == ["b", "c"])
        #expect(!search.model.hasMoreRows)
        #expect(search.model.hasEarlierRows)

        search.model.pageBackward()
        await search.model.windowCommandTask?.value
        #expect(search.window.commands.last == .page(.backward, sequence: 3))
    }

    @MainActor
    @Test func anAnchorOutsideTheWindowIsNeverSent() async throws {
        let search = try await pagedSearch()

        search.model.setVisibleAnchor(groupIdHex: "c")
        await search.model.windowCommandTask?.value

        #expect(search.window.commands.isEmpty)
    }

    /// The last row's `onAppear` does not fire again while it stays on screen, so a page that
    /// failed once and was dropped would leave the later matches unreachable.
    @MainActor
    @Test func aFailedPageIsTriedAgainUntilItLands() async throws {
        let search = try await pagedSearch { runtime in
            runtime.chatListQueryWindowPageErrors = [
                MarmotKitError.AccountWorkerBusy, MarmotKitError.ChatWindowStale,
            ]
            runtime.chatListQueryWindowPages = [
                pagedSnapshot(sequence: 2, rows: ["b", "c"], hasMoreBefore: true, hasMoreAfter: false)
            ]
        }

        search.model.pageForward()
        await search.model.windowCommandTask?.value

        #expect(search.window.commands == Array(repeating: .page(.forward, sequence: 1), count: 3))
        #expect(search.model.rows.map(\.row.groupIdHex) == ["b", "c"])
    }

    @MainActor
    @Test func aPageThatKeepsFailingStopsAfterABoundedNumberOfAttempts() async throws {
        let search = try await pagedSearch { runtime in
            runtime.chatListQueryWindowPageErrors = Array(
                repeating: MarmotKitError.Io(details: "disk"), count: ChatListWindowRetry.maxPageAttempts + 1)
        }

        search.model.pageForward()
        await search.model.windowCommandTask?.value

        #expect(search.window.commands.count == ChatListWindowRetry.maxPageAttempts)
        #expect(search.model.rows.map(\.row.groupIdHex) == ["a", "b"])
    }

    /// MDK refuses a malformed page the same way every time, so it is not retried, and the next
    /// appearance of the last row may still ask again.
    @MainActor
    @Test func aRefusedPageIsNotRetriedButCanBeAskedForAgain() async throws {
        let search = try await pagedSearch { runtime in
            runtime.chatListQueryWindowPageErrors = [MarmotKitError.ChatWindowInvalidLimit]
        }

        search.model.pageForward()
        await search.model.windowCommandTask?.value
        #expect(search.window.commands == [.page(.forward, sequence: 1)])

        search.model.pageForward()
        await search.model.windowCommandTask?.value
        #expect(search.window.commands == [.page(.forward, sequence: 1), .page(.forward, sequence: 1)])
    }

    // MARK: - Observing the results window

    /// A transient read failure used to end observation for the rest of the query, so the rows
    /// shown stopped following archives and renames. The same window is reopened instead.
    @MainActor
    @Test func aRetryableWindowReadFailureReopensTheSameWindow() async throws {
        let search = try await pagedSearch { runtime in
            runtime.chatListQueryWindowNextErrors = [MarmotKitError.Io(details: "disk")]
            runtime.chatListQueryWindowEndsWhenExhausted = true
        }

        await search.model.windowTask?.value

        let opened = search.runtime.openChatListQueryWindowCalls.map(\.query)
        #expect(opened.count == 2)
        #expect(Set(opened).count == 1)
        #expect(search.model.phase == .ready)
        #expect(search.model.rows.map(\.row.groupIdHex) == ["a", "b"])
        // Commands now go to the reopened window.
        search.model.pageForward()
        await search.model.windowCommandTask?.value
        #expect(search.window.commands.isEmpty)
        #expect(search.runtime.chatListQueryWindows.last?.commands == [.page(.forward, sequence: 1)])
    }

    @MainActor
    @Test func aRefusedWindowReadStopsObservingAndKeepsTheRowsShown() async throws {
        let search = try await pagedSearch { runtime in
            runtime.chatListQueryWindowNextErrors = [MarmotKitError.ChatWindowQuery(details: "refused")]
        }

        await search.model.windowTask?.value

        #expect(search.runtime.openChatListQueryWindowCalls.count == 1)
        #expect(search.model.phase == .ready)
        #expect(search.model.rows.map(\.row.groupIdHex) == ["a", "b"])
    }

    // MARK: - Selection during a search

    @MainActor
    @Test func selectAllDuringASearchCountsEveryMatchMDKReports() async throws {
        let runtime = searchRuntime(groupIds: ["a", "b", "c", "d"])
        let query = try #require(ChatListSearchQuery.matches(text: "chat", view: .chats))
        runtime.chatListQueryIdsByQuery[query] = ["a", "b", "d"]
        let selection = ChatListSelectionViewModel(accountRef: "account", runtime: runtime)
        // Only the window's first rows are on screen.
        selection.updateVisibleChats(["a", "b"], query: query, isWindowed: true)

        selection.begin(with: "a")
        await selection.viewIdsTask?.value
        selection.toggleAll()

        #expect(runtime.chatListQueryIdsCalls == [query])
        #expect(runtime.chatListIdsCallCount == 0)
        #expect(selection.selectedIds == ["a", "b", "d"])
        #expect(selection.orderedSelection == ["a", "b", "d"])
    }

    @MainActor
    @Test func aBulkActionDuringASearchRevalidatesWithTheSameQueryAndDropsVanishedChats() async throws {
        let runtime = searchRuntime(groupIds: ["a", "b"])
        let query = try #require(ChatListSearchQuery.matches(text: "chat", view: .chats))
        runtime.chatListQueryIdsByQuery[query] = ["a", "b"]
        let selection = ChatListSelectionViewModel(accountRef: "account", runtime: runtime)
        selection.updateVisibleChats(["a", "b"], query: query, isWindowed: true)
        selection.begin(with: "a")
        selection.toggle("b")
        await selection.viewIdsTask?.value
        // "a" stopped matching between the pick and the click.
        runtime.chatListQueryIdsByQuery[query] = ["b"]

        await selection.setArchived(true, groupIds: selection.orderedSelection)?.value

        #expect(runtime.revalidateChatListQueryIdsCalls.map(\.query) == [query])
        #expect(runtime.revalidateChatListQueryIdsCalls.first?.groupIds == ["a", "b"])
        #expect(runtime.revalidateChatListIdsCalls.isEmpty)
        #expect(runtime.setGroupArchivedCallCount == 1)
        #expect(!selection.isActive)
    }

    @MainActor
    @Test func bulkActionsStayDisabledUntilTheSearchsMatchesAreReady() async throws {
        let runtime = searchRuntime(groupIds: ["a", "b"])
        let query = try #require(ChatListSearchQuery.matches(text: "chat", view: .chats))
        runtime.chatListQueryIdsByQuery[query] = ["a", "b"]
        runtime.chatListQueryErrors = [MarmotKitError.ChatPresentationNotReady]
        let selection = ChatListSelectionViewModel(accountRef: "account", runtime: runtime)
        selection.updateVisibleChats(["a"], query: query, isWindowed: true)

        selection.begin(with: "a")
        #expect(!selection.isScopeReady)
        #expect(!selection.canToggleAll)

        await selection.viewIdsTask?.value
        #expect(runtime.chatListQueryIdsCalls.count == 2)
        #expect(selection.isScopeReady)
        #expect(selection.canToggleAll)
    }
}

// MARK: - Fixtures

/// A search over "a", "b" and "c" whose window shows the first two, with MDK's sequence moving
/// on every command. `configure` scripts the runtime before the window opens.
@MainActor
private func pagedSearch(
    configure: (FakeMarmotRuntime) -> Void = { _ in }
) async throws -> (model: ChatListSearchViewModel, runtime: FakeMarmotRuntime, window: FakeChatListWindowSubscription) {
    let runtime = searchRuntime(groupIds: ["a", "b", "c"])
    let query = try #require(ChatListSearchQuery.matches(text: "chat", view: .chats))
    runtime.chatListQueryIdsByQuery[query] = ["a", "b", "c"]
    runtime.chatListQueryWindowRowLimit = 2
    runtime.chatListQueryWindowAdvancesSequence = true
    configure(runtime)
    let model = ChatListSearchViewModel(accountRef: "account", runtime: runtime, debounce: .zero, retryDelay: .zero)
    model.search("chat", view: .chats)
    await model.loadTask?.value
    #expect(model.rows.map(\.row.groupIdHex) == ["a", "b"])
    let window = try #require(runtime.chatListQueryWindows.last)
    return (model, runtime, window)
}

/// A results-window snapshot drawing `rows` from the fixture groups.
@MainActor
private func pagedSnapshot(
    sequence: UInt64,
    rows ids: [String],
    hasMoreBefore: Bool,
    hasMoreAfter: Bool
) -> ChatListWindowSnapshotFfi {
    ChatListWindowSnapshotFfi(
        subscriptionGeneration: "query-window-1",
        sequence: sequence,
        view: .chats,
        rows: searchRuntime(groupIds: ids).presentedChatRows(groupIds: ids),
        hasMoreBefore: hasMoreBefore,
        hasMoreAfter: hasMoreAfter,
        anchor: .top
    )
}

/// Groups titled "Chat <id>" the fake lists in every view they belong to.
@MainActor
private func searchRuntime(groupIds: [String], isDirect: Bool = false) -> FakeMarmotRuntime {
    let runtime = FakeMarmotRuntime(accounts: [desktopAccount()])
    for groupIdHex in groupIds {
        var group = messageGroup()
        group.groupIdHex = groupIdHex
        group.name = isDirect ? "" : "Chat \(groupIdHex)"
        runtime.installGroupDetailsRecord(GroupDetailsFfi(group: group, members: []))
    }
    return runtime
}
