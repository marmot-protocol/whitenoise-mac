import Foundation
import Observation

/// A request to bring one search match on screen. Every step makes a new one, so stepping back to
/// a match already visited still reads as a change.
struct ConversationSearchNavigation: Equatable, Identifiable {
    let id = UUID()
    let messageId: String
}

/// In-conversation message search: the query, every match in the chat's history, and the cursor the
/// reader steps through them with. Owned by `ConversationViewModel`, so it lives and dies with the
/// conversation.
///
/// The chat's history is read once per search session into a folded corpus, off the main actor;
/// each keystroke then filters that corpus in memory, off the main actor too. The transcript only
/// learns about a match through `navigation`, which it answers by jumping its window there.
@MainActor
@Observable
final class ConversationSearchViewModel {
    typealias CorpusLoader =
        @Sendable (_ checkCancellation: @escaping @Sendable () throws -> Void) throws -> [ConversationSearchEntry]

    private(set) var isActive = false
    /// Matching message ids in timeline order, oldest first.
    private(set) var matches: [String] = []
    private(set) var currentIndex: Int?
    /// The history is still being read, or a query is waiting on its matches.
    private(set) var isSearching = false
    /// Reading the history failed; the search has nothing to match against.
    private(set) var didFail = false
    /// The match the transcript should bring on screen next.
    private(set) var navigation: ConversationSearchNavigation?
    /// Changes whenever the search is (re)opened, so the field can take focus again.
    private(set) var focusRequest = UUID()

    var query = "" {
        didSet {
            guard isActive, query != oldValue else { return }
            scrollsOnNextResult = true
            scheduleMatching(debounce: queryDebounce)
        }
    }

    /// What the transcript is not drawing. Changing it recounts without moving the reader.
    var exclusions: ConversationSearchExclusions = .none {
        didSet {
            guard isActive, exclusions != oldValue else { return }
            scheduleMatching(debounce: .zero)
        }
    }

    @ObservationIgnored private let loadCorpus: CorpusLoader
    @ObservationIgnored private let queryDebounce: Duration
    @ObservationIgnored private let refreshDebounce: Duration
    @ObservationIgnored private var corpus: [ConversationSearchEntry]?
    /// Reads the history. Cancelling it is the whole staleness story: a newer read replaces it, and
    /// `end()` drops it, so a late corpus never lands.
    @ObservationIgnored private var corpusTask: Task<Void, Never>?
    /// Filters the corpus for the current query, replaced (cancelled) by every newer keystroke.
    @ObservationIgnored private var matchTask: Task<Void, Never>?
    /// The next result moves the reader to its newest match: true after the query changed, false
    /// for a recount (new messages, a block) that should leave the reader where they are.
    @ObservationIgnored private var scrollsOnNextResult = false

    init(
        loadCorpus: @escaping CorpusLoader,
        queryDebounce: Duration = .milliseconds(120),
        refreshDebounce: Duration = .milliseconds(400)
    ) {
        self.loadCorpus = loadCorpus
        self.queryDebounce = queryDebounce
        self.refreshDebounce = refreshDebounce
    }

    convenience init(runtime: any MarmotRuntime, accountRef: String, groupIdHex: String) {
        self.init { checkCancellation in
            try ConversationSearchCorpus.load(
                client: runtime,
                accountRef: accountRef,
                groupIdHex: groupIdHex,
                checkCancellation: checkCancellation
            )
        }
    }

    var hasQuery: Bool {
        !GlobalMessageSearchText.tokens(in: query).isEmpty
    }

    var currentMatchMessageId: String? {
        guard let currentIndex, matches.indices.contains(currentIndex) else { return nil }
        return matches[currentIndex]
    }

    /// "1" is the newest match; nil without a cursor.
    var displayPosition: Int? {
        guard let currentIndex, matches.indices.contains(currentIndex) else { return nil }
        return ConversationSearchEngine.displayPosition(index: currentIndex, matchCount: matches.count)
    }

    var canStep: Bool {
        isActive && !matches.isEmpty
    }

    // MARK: Lifetime

    /// Opens the search, or puts focus back in its field when it is already open.
    func activate() {
        focusRequest = UUID()
        guard !isActive else { return }
        isActive = true
        didFail = false
        reloadCorpus(after: .zero)
    }

    func end() {
        guard isActive else { return }
        isActive = false
        corpusTask?.cancel()
        corpusTask = nil
        matchTask?.cancel()
        matchTask = nil
        corpus = nil
        query = ""
        matches = []
        currentIndex = nil
        navigation = nil
        isSearching = false
        didFail = false
        scrollsOnNextResult = false
    }

    /// The chat's history changed (an arrival, an edit, a deletion). An open search re-reads it,
    /// coalescing bursts, and recounts without moving the reader.
    func historyDidChange() {
        guard isActive else { return }
        reloadCorpus(after: refreshDebounce)
    }

    // MARK: Stepping

    func goToOlderMatch() {
        step(to: ConversationSearchEngine.olderIndex(from: currentIndex, matchCount: matches.count))
    }

    func goToNewerMatch() {
        step(to: ConversationSearchEngine.newerIndex(from: currentIndex, matchCount: matches.count))
    }

    /// The transcript could not bring `messageId` into its window (deleted since the history was
    /// read, or expired). Forget it so the counter stops promising it.
    func matchUnavailable(_ messageId: String) {
        guard isActive, let index = matches.lastIndex(of: messageId) else { return }
        corpus?.removeAll { $0.messageId == messageId }
        matches.remove(at: index)
        if let currentIndex, currentIndex >= index {
            self.currentIndex = matches.isEmpty ? nil : max(currentIndex - 1, 0)
        }
    }

    private func step(to index: Int?) {
        guard isActive, let index else { return }
        currentIndex = index
        requestNavigation()
    }

    private func requestNavigation() {
        guard let messageId = currentMatchMessageId else { return }
        navigation = ConversationSearchNavigation(messageId: messageId)
    }

    // MARK: Matching

    private func reloadCorpus(after delay: Duration) {
        corpusTask?.cancel()
        if hasQuery, corpus == nil { isSearching = true }
        let loadCorpus = loadCorpus
        corpusTask = Task { [weak self] in
            do {
                if delay > .zero { try await Task.sleep(for: delay) }
                let entries = try await FFIExecutor.runCancellable { checkCancellation in
                    try loadCorpus(checkCancellation)
                }
                guard let self, !Task.isCancelled else { return }
                self.corpusTask = nil
                self.corpus = entries
                self.didFail = false
                self.scheduleMatching(debounce: .zero)
            } catch is CancellationError {
                return
            } catch {
                guard let self, !Task.isCancelled else { return }
                self.corpusTask = nil
                // A failed refresh keeps the history already read; only a first read fails the search.
                if self.corpus == nil {
                    self.didFail = true
                    self.isSearching = false
                }
            }
        }
    }

    private func scheduleMatching(debounce: Duration) {
        matchTask?.cancel()
        matchTask = nil
        let tokens = GlobalMessageSearchText.tokens(in: query)
        guard !tokens.isEmpty else {
            matches = []
            currentIndex = nil
            isSearching = false
            return
        }
        // Without a corpus the read in flight schedules this again when it lands.
        guard let corpus else {
            isSearching = !didFail
            return
        }
        isSearching = true
        let exclusions = exclusions
        matchTask = Task { [weak self] in
            if debounce > .zero {
                do { try await Task.sleep(for: debounce) } catch { return }
            }
            let found = await Task.detached(priority: .userInitiated) {
                ConversationSearchEngine.matches(tokens: tokens, in: corpus, excluding: exclusions)
            }.value
            guard let self, !Task.isCancelled else { return }
            self.matchTask = nil
            self.apply(found)
        }
    }

    private func apply(_ found: [String]) {
        let anchor = currentMatchMessageId
        matches = found
        isSearching = false
        if scrollsOnNextResult {
            scrollsOnNextResult = false
            currentIndex = ConversationSearchEngine.initialIndex(matchCount: found.count)
            requestNavigation()
        } else {
            currentIndex =
                ConversationSearchEngine.reanchoredIndex(of: anchor, in: found)
                ?? ConversationSearchEngine.initialIndex(matchCount: found.count)
        }
    }
}
