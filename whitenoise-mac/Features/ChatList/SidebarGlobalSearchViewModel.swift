import Foundation
import Observation

/// Coordinates sidebar search mode visibility against chat-list bulk selection without mutating or
/// clearing `ChatListSelectionViewModel` when viewing individual global message matches (#1043).
nonisolated enum SidebarSearchModeSelectionPolicy {
    /// Bulk chat controls (`ChatListSelectAllRow`, `ChatListSelectionBar`, row checkmarks) are shown
    /// only in the chat list — never over individual global-message search results.
    static func showsBulkSelectionControls(
        isSelectionActive: Bool,
        isGlobalMessageSearchActive: Bool
    ) -> Bool {
        isSelectionActive && !isGlobalMessageSearchActive
    }
}

/// Carries a global search result's query into the opened conversation so the jumped-to match stays
/// highlighted and ready for `⌘G` / `⇧⌘G` navigation. Keyed by the exact navigation request and
/// message id so a bailed-out or superseded jump cannot hand its query to a different navigation.
nonisolated struct PendingConversationSearchQuery: Equatable, Sendable {
    let requestId: UUID
    let groupId: String
    let messageId: String
    let query: String
}

/// Sidebar-hosted global individual-message search (`⇧⌘F` / sidebar search button, #1043).
///
/// Owned by `AccountScope` so switching or signing out of an account tears down search tasks and
/// state automatically without a manual reset checklist. Runs `GlobalMessageSearchEngine.search`
/// off the main actor with task cancellation as the staleness guard, keeps a truthful 50-match cap
/// indicator, and preserves the chat list's own search query, filter, bulk selection, and any
/// in-progress New Chat / New Group draft underneath until the user returns.
@MainActor
@Observable
final class SidebarGlobalSearchViewModel {
    typealias SearchRunner =
        @MainActor (_ query: String, _ checkCancellation: @escaping @Sendable () throws -> Void) async throws ->
        [GlobalMessageSearchResult]

    private(set) var isActive = false
    private(set) var results: [GlobalMessageSearchResult] = []
    private(set) var isSearching = false
    private(set) var error: String?
    private(set) var focusRequest = UUID()
    var selectedResultID: String?
    var pendingConversationSearch: PendingConversationSearchQuery?

    var query = "" {
        didSet {
            guard isActive, query != oldValue else { return }
            scheduleSearch()
        }
    }

    var hasQuery: Bool {
        !GlobalMessageSearchText.tokens(in: query).isEmpty
    }

    /// Truthful limit notice: `GlobalMessageSearchEngine.search` caps output at 50 newest matches.
    var isTruncated: Bool {
        !isSearching && error == nil && results.count >= GlobalMessageSearchEngine.resultLimit
    }

    var showsResults: Bool {
        hasQuery && !isSearching && error == nil && !results.isEmpty
    }

    @ObservationIgnored private let searchRunner: SearchRunner?
    @ObservationIgnored private let debounce: Duration
    @ObservationIgnored private var searchTask: Task<Void, Never>?

    init(
        debounce: Duration = .milliseconds(250),
        searchRunner: SearchRunner? = nil
    ) {
        self.debounce = debounce
        self.searchRunner = searchRunner
    }

    func activate(initialQuery: String? = nil) {
        focusRequest = UUID()
        let trimmedInitial = initialQuery?.trimmingCharacters(in: .whitespacesAndNewlines)
        if !isActive {
            isActive = true
            error = nil
            if let trimmedInitial, !trimmedInitial.isEmpty {
                if query != trimmedInitial {
                    query = trimmedInitial
                } else {
                    scheduleSearch()
                }
            } else if hasQuery {
                scheduleSearch()
            }
        } else if let trimmedInitial, !trimmedInitial.isEmpty, query != trimmedInitial {
            query = trimmedInitial
        }
    }

    func dismiss() {
        searchTask?.cancel()
        searchTask = nil
        isActive = false
        query = ""
        results = []
        isSearching = false
        error = nil
        selectedResultID = nil
    }

    func stop() {
        dismiss()
        pendingConversationSearch = nil
    }

    func invalidate(clearQuery: Bool, restartIfActive: Bool = false) {
        searchTask?.cancel()
        searchTask = nil
        results = []
        selectedResultID = nil
        error = nil
        isSearching = false
        if clearQuery {
            query = ""
        } else if restartIfActive, isActive, hasQuery {
            scheduleSearch()
        }
    }

    /// Called when the account's visible active chats change (e.g., a chat is deleted, archived,
    /// or added) so results from removed chats are never kept on screen and an active search
    /// re-runs against the current chat roster.
    func handleVisibleChatsChanged(visibleGroupIds: Set<String>) {
        if isActive {
            invalidate(clearQuery: false, restartIfActive: true)
        } else if !results.isEmpty {
            results.removeAll { !visibleGroupIds.contains($0.groupId) }
            selectedResultID = GlobalMessageSearchSelection.reanchored(
                selectedResultID,
                in: results.map(\.id),
                whileSearching: false
            )
        }
        if let pending = pendingConversationSearch, !visibleGroupIds.contains(pending.groupId) {
            pendingConversationSearch = nil
        }
    }

    func retry() {
        guard isActive, hasQuery else { return }
        scheduleSearch(debounceOverride: .zero)
    }

    @discardableResult
    func moveSelection(down: Bool) -> Bool {
        guard showsResults else { return false }
        let ids = results.map(\.id)
        let target =
            down
            ? GlobalMessageSearchSelection.next(after: selectedResultID, in: ids)
            : GlobalMessageSearchSelection.previous(before: selectedResultID, in: ids)
        guard let target else { return false }
        selectedResultID = target
        return true
    }

    func selectedResult() -> GlobalMessageSearchResult? {
        guard showsResults, let selectedResultID else { return nil }
        return results.first { $0.id == selectedResultID }
    }

    func recordConversationSearchJump(target: GlobalMessageNavigationTarget, query: String) {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            pendingConversationSearch = nil
            return
        }
        pendingConversationSearch = PendingConversationSearchQuery(
            requestId: target.requestId,
            groupId: target.groupId,
            messageId: target.messageId,
            query: trimmed
        )
    }

    func consumeConversationSearchJump(for target: GlobalMessageNavigationTarget) -> String? {
        guard let pending = pendingConversationSearch,
            pending.requestId == target.requestId,
            pending.groupId == target.groupId,
            pending.messageId == target.messageId
        else { return nil }
        pendingConversationSearch = nil
        return pending.query
    }

    private func scheduleSearch(debounceOverride: Duration? = nil) {
        searchTask?.cancel()
        searchTask = nil
        error = nil

        let currentQuery = query
        guard !GlobalMessageSearchText.tokens(in: currentQuery).isEmpty else {
            results = []
            selectedResultID = nil
            isSearching = false
            return
        }

        guard let searchRunner else {
            results = []
            selectedResultID = nil
            isSearching = false
            return
        }

        results = []
        isSearching = true
        selectedResultID = nil
        let waitDuration = debounceOverride ?? debounce
        searchTask = Task { [weak self] in
            do {
                if waitDuration > .zero {
                    try await Task.sleep(for: waitDuration)
                }
                guard let self, !Task.isCancelled else { return }
                let found = try await searchRunner(currentQuery) {
                    try Task.checkCancellation()
                }
                guard !Task.isCancelled, self.isActive, self.query == currentQuery else { return }
                self.results = found
                self.isSearching = false
                self.error = nil
                self.searchTask = nil
                self.selectedResultID = GlobalMessageSearchSelection.reanchored(
                    self.selectedResultID,
                    in: found.map(\.id),
                    whileSearching: false
                )
            } catch is CancellationError {
                return
            } catch {
                guard let self, !Task.isCancelled, self.isActive, self.query == currentQuery else { return }
                self.error = UserFacingError.message(for: error)
                self.results = []
                self.isSearching = false
                self.searchTask = nil
                self.selectedResultID = nil
            }
        }
    }
}
