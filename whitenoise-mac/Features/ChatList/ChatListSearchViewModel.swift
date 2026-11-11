import Foundation
import MarmotKit
import Observation

/// The chat list's search, run by MDK. The matching set is `chatListQueryIds` over the drawer's
/// view with `Any[Text, MessageText]` (`ChatListSearchQuery.matches`). A window refuses
/// `MessageText`, so the rows are drawn by `openChatListQueryWindow` over a `GroupIds` node that
/// lists those ids, in the same view. Select All and the bulk actions read `matchesQuery`, the
/// same value that produced the ids, so list, count and selection agree.
///
/// Past `ChatListSearchQuery.maxShownMatches` (500, MDK's `GroupIds` limit) the window shows the
/// first 500 in display order and `isTruncated` asks the drawer to say so; Select All still
/// counts and selects every match.
///
/// The match set is read once per query. The window keeps the rows it shows live (a chat archived
/// out of the view leaves it), but a chat that starts matching later appears on the next query.
///
/// Owned by `AccountScope`, so switching accounts cancels a search instead of resetting it.
@MainActor
@Observable
final class ChatListSearchViewModel {
    enum Phase: Equatable {
        /// No search text.
        case inactive
        /// Waiting on MDK — the debounce, or `ChatPresentationNotReady` while presentation is
        /// still being prepared. No rows are shown, so nothing partial passes as a result.
        case searching
        case ready
        case failed
    }

    private(set) var phase: Phase = .inactive
    /// The query whose ids are the matches; `nil` when there is no search.
    private(set) var matchesQuery: ChatListViewQueryFfi?
    /// Every match, in display order, from `chatListQueryIds`.
    private(set) var matchIds: [String] = []
    /// The window's rows: the first page of the shown matches, more as the list pages forward.
    private(set) var rows: [PresentedChatRowFfi] = []
    private(set) var hasMoreRows = false
    /// Earlier matches the window let go of while paging forward: MDK retains at most 200 rows
    /// around the visible anchor, so scrolling back up pages them in again.
    private(set) var hasEarlierRows = false

    var isTruncated: Bool { matchIds.count > ChatListSearchQuery.maxShownMatches }

    @ObservationIgnored private let accountRef: String
    @ObservationIgnored private let runtime: (any MarmotRuntime)?
    @ObservationIgnored private let debounce: Duration
    @ObservationIgnored private let retryDelay: Duration
    @ObservationIgnored private(set) var loadTask: Task<Void, Never>?
    @ObservationIgnored private(set) var windowTask: Task<Void, Never>?
    /// The last window command (anchor or page). Each command waits for the one before it and
    /// runs on the latest installed sequence, the way the main list's window does.
    @ObservationIgnored private(set) var windowCommandTask: Task<Void, Never>?
    @ObservationIgnored private var pagingDirections: Set<ChatListPageDirectionFfi> = []
    @ObservationIgnored private var windowSubscription: ChatListWindowSubscription?
    @ObservationIgnored private var windowSnapshot: ChatListWindowSnapshotFfi?

    /// `debounce` spaces queries while the user types and `retryDelay` is the first wait before a
    /// failed window read or page is tried again; tests pass `.zero` for both.
    init(
        accountRef: String,
        runtime: (any MarmotRuntime)?,
        debounce: Duration = .milliseconds(200),
        retryDelay: Duration = .milliseconds(250)
    ) {
        self.accountRef = accountRef
        self.runtime = runtime
        self.debounce = debounce
        self.retryDelay = retryDelay
    }

    /// Runs `text` over `view`. Blank text ends the search; the same query again does nothing.
    func search(_ text: String, view: ChatListViewFfi) {
        let query = ChatListSearchQuery.matches(text: text, view: view)
        guard query != matchesQuery else { return }
        cancel()
        matchesQuery = query
        matchIds = []
        rows = []
        hasMoreRows = false
        hasEarlierRows = false
        guard let query else {
            phase = .inactive
            return
        }
        phase = .searching
        guard let runtime else {
            phase = .failed
            return
        }
        let accountRef = accountRef
        let debounce = debounce
        loadTask = Task { [weak self] in
            do {
                if debounce > .zero { try await Task.sleep(for: debounce) }
                let ids = try await ChatListNotReadyRetry.run {
                    try await runtime.chatListQueryIds(accountRef: accountRef, query: query)
                }
                try Task.checkCancellation()
                try await self?.show(ids, for: query, runtime: runtime)
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled, let self else { return }
                self.phase = .failed
            }
        }
    }

    /// Loads the window's next page when the last row scrolls into view.
    func pageForward() {
        page(.forward)
    }

    /// Pages back in the matches the window let go of when the first row scrolls into view.
    func pageBackward() {
        page(.backward)
    }

    /// Tells MDK which match is on screen. The window retains rows around this anchor, so paging
    /// forward keeps the rows the user is looking at and lets go of the ones scrolled past.
    func setVisibleAnchor(groupIdHex: String) {
        guard let snapshot = windowSnapshot,
            snapshot.rows.contains(where: { $0.row.groupIdHex == groupIdHex })
        else { return }
        if case .retained(let current, _) = snapshot.anchor, current == groupIdHex { return }
        enqueueWindowCommand { subscription, sequence in
            try await subscription.setVisibleAnchor(sequence: sequence, groupIdHex: groupIdHex)
        }
    }

    /// One page in `direction`, unless the window has nothing more that way or a page that way is
    /// already queued.
    private func page(_ direction: ChatListPageDirectionFfi) {
        guard let snapshot = windowSnapshot, !pagingDirections.contains(direction) else { return }
        guard direction == .forward ? snapshot.hasMoreAfter : snapshot.hasMoreBefore else { return }
        pagingDirections.insert(direction)
        enqueueWindowCommand(
            maxAttempts: ChatListWindowRetry.maxPageAttempts,
            { subscription, sequence in
                try await subscription.page(
                    sequence: sequence,
                    direction: direction,
                    count: ChatListSearchQuery.windowRows
                )
            },
            whenDone: { [weak self] in self?.pagingDirections.remove(direction) }
        )
    }

    /// Queues `operation` behind the previous window command, so anchor and page commands reach
    /// MDK one at a time and each carries the sequence of the snapshot installed before it runs.
    /// A retryable failure is tried again, up to `maxAttempts` in all, on the sequence installed
    /// by then (a stale sequence is the common case); a final refusal or cancellation is not.
    @discardableResult
    private func enqueueWindowCommand(
        maxAttempts: Int = 1,
        _ operation:
            @escaping @Sendable (ChatListWindowSubscription, UInt64) async throws -> ChatListWindowSnapshotFfi,
        whenDone: (@MainActor () -> Void)? = nil
    ) -> Task<Void, Never>? {
        guard let subscription = windowSubscription else {
            whenDone?()
            return nil
        }
        let previous = windowCommandTask
        let retryDelay = retryDelay
        let command = Task { [weak self] in
            defer { whenDone?() }
            await previous?.value
            var attempt = 1
            while true {
                guard let self, !Task.isCancelled, self.windowSubscription === subscription,
                    let sequence = self.windowSnapshot?.sequence
                else { return }
                do {
                    let next = try await operation(subscription, sequence)
                    guard !Task.isCancelled, self.windowSubscription === subscription else { return }
                    self.install(next)
                    return
                } catch {
                    guard attempt < maxAttempts, ChatListWindowRetry.isRetryable(error) else { return }
                }
                try? await Task.sleep(for: ChatListWindowRetry.delay(afterAttempt: attempt, initial: retryDelay))
                attempt += 1
            }
        }
        windowCommandTask = command
        return command
    }

    /// Ends the search. Called when the owning account scope ends.
    func stop() {
        cancel()
        matchesQuery = nil
        matchIds = []
        rows = []
        hasMoreRows = false
        hasEarlierRows = false
        phase = .inactive
    }

    private func cancel() {
        loadTask?.cancel()
        loadTask = nil
        windowTask?.cancel()
        windowTask = nil
        windowCommandTask?.cancel()
        windowCommandTask = nil
        pagingDirections = []
        windowSubscription = nil
        windowSnapshot = nil
    }

    private func show(_ ids: [String], for query: ChatListViewQueryFfi, runtime: any MarmotRuntime) async throws {
        guard matchesQuery == query else { return }
        matchIds = ids
        guard !ids.isEmpty else {
            phase = .ready
            return
        }
        let windowQuery = ChatListSearchQuery.window(showing: ids, view: query.view)
        let subscription = try await runtime.openChatListQueryWindow(
            accountRef: accountRef,
            query: windowQuery,
            initialRows: ChatListSearchQuery.windowRows
        )
        try Task.checkCancellation()
        guard matchesQuery == query, let initial = runtime.chatListWindowSnapshot(subscription: subscription) else {
            return
        }
        windowSubscription = subscription
        install(initial)
        phase = .ready
        observeWindow(subscription, generation: initial.subscriptionGeneration, for: query, windowQuery, runtime)
    }

    /// Installs the window's snapshots as MDK pushes them. A retryable read failure reopens the
    /// same window with the main list's backoff, keeping the rows on screen meanwhile; a final
    /// refusal, the end of the stream, a new subscription generation or cancellation stop
    /// observing, and the rows already shown stay until the next query opens a fresh window.
    private func observeWindow(
        _ subscription: ChatListWindowSubscription,
        generation: String,
        for query: ChatListViewQueryFfi,
        _ windowQuery: ChatListViewQueryFfi,
        _ runtime: any MarmotRuntime
    ) {
        let accountRef = accountRef
        let retryDelay = retryDelay
        windowTask = Task { [weak self] in
            var subscription = subscription
            var generation = generation
            var attempt = 0
            while !Task.isCancelled {
                do {
                    while let next = try await runtime.nextChatListWindowSnapshot(subscription: subscription) {
                        guard !Task.isCancelled, let self, self.windowSubscription === subscription,
                            next.subscriptionGeneration == generation
                        else { return }
                        attempt = 0
                        self.install(next)
                    }
                    return
                } catch {
                    guard !Task.isCancelled, ChatListWindowRetry.isRetryable(error) else { return }
                }
                // Reopen until a window opens or the failure turns out to be final.
                while true {
                    attempt += 1
                    do {
                        try await Task.sleep(for: ChatListWindowRetry.delay(afterAttempt: attempt, initial: retryDelay))
                    } catch {
                        return
                    }
                    guard let self, self.matchesQuery == query, self.windowSubscription === subscription else {
                        return
                    }
                    do {
                        let reopened = try await runtime.openChatListQueryWindow(
                            accountRef: accountRef,
                            query: windowQuery,
                            initialRows: ChatListSearchQuery.windowRows
                        )
                        try Task.checkCancellation()
                        guard self.matchesQuery == query, self.windowSubscription === subscription,
                            let initial = runtime.chatListWindowSnapshot(subscription: reopened)
                        else { return }
                        subscription = reopened
                        generation = initial.subscriptionGeneration
                        self.windowSubscription = reopened
                        self.install(initial, reopening: true)
                        break
                    } catch {
                        guard !Task.isCancelled, ChatListWindowRetry.isRetryable(error) else { return }
                    }
                }
            }
        }
    }

    /// Installs `snapshot` unless an older one than what is shown. A reopened window starts its
    /// own sequence, so its first snapshot replaces whatever the failed one showed.
    private func install(_ snapshot: ChatListWindowSnapshotFfi, reopening: Bool = false) {
        if !reopening, let current = windowSnapshot, snapshot.sequence < current.sequence { return }
        windowSnapshot = snapshot
        rows = snapshot.rows
        hasMoreRows = snapshot.hasMoreAfter
        hasEarlierRows = snapshot.hasMoreBefore
    }
}
