import Foundation
import MarmotKit
import Observation

/// One voter as the "View votes" sheet lists them under an option.
nonisolated struct PollVoter: Identifiable, Hashable, Sendable {
    let accountIdHex: String
    /// Authenticated time of the voter's effective response.
    let votedAt: UInt64
    /// Blocked voters stay listed because MDK's tally still counts them.
    let isBlocked: Bool

    var id: String { accountIdHex }
}

/// One option's section in the "View votes" sheet: the tally MDK projected for it and the voters
/// loaded so far who selected it.
nonisolated struct PollVoteGroup: Identifiable, Hashable, Sendable {
    let option: MessagePoll.Option
    let voters: [PollVoter]

    var id: String { option.id }
}

/// Pure decisions for the "View votes" sheet.
nonisolated enum PollVotesPresentation {
    static let defaultPageSize = 50
    /// MDK accepts 1–100 votes per page.
    static let pageSizeRange = 1...100

    static func clampedLimit(_ requested: Int) -> UInt32 {
        UInt32(min(pageSizeRange.upperBound, max(pageSizeRange.lowerBound, requested)))
    }

    /// Groups loaded votes under every option of `poll`, in option order. A multiple-choice voter
    /// appears under each option they selected; within an option voters keep MDK's
    /// `(votedAt, voter)` order. Options nobody picked still get a (voterless) section, so the
    /// sheet shows the whole poll.
    static func groups(
        poll: MessagePoll?,
        votes: [PollVoteFfi],
        blockedAccountIDs: Set<String>
    ) -> [PollVoteGroup] {
        guard let poll else { return [] }
        var votersByOption: [String: [PollVoter]] = [:]
        for vote in votes {
            let voter = PollVoter(
                accountIdHex: vote.voterAccountIdHex,
                votedAt: vote.votedAt,
                isBlocked: blockedAccountIDs.contains(vote.voterAccountIdHex.lowercased())
            )
            for optionId in Set(vote.optionIds) {
                votersByOption[optionId, default: []].append(voter)
            }
        }
        return poll.options.map { option in
            PollVoteGroup(option: option, voters: votersByOption[option.id] ?? [])
        }
    }
}

/// Paging state for one poll's "View votes" sheet.
///
/// MDK's `pollVotes` is a synchronous local query paged by `(votedAt, voterAccountIdHex)`. Every
/// read runs off the main thread in one task this model owns, and reads never overlap: a refresh
/// asked for while one is in flight runs after it. A hard reload cancels the task in flight, and a
/// cancelled task drops its page on arrival, so a page requested before the reload never lands in
/// the restarted list. No staleness counter is needed: both the cancellation and the check after
/// the await happen on the main actor.
///
/// The list must follow who voted for what, which the poll's row cannot always show: two voters
/// swapping options leave the tally, and so possibly the whole row, unchanged. So besides a
/// reprojected row, every poll response received in the group refreshes the list too.
@MainActor
@Observable
final class PollVotesViewModel: Identifiable {
    /// Where the next page starts: the last vote of the previous page.
    nonisolated struct Cursor: Equatable, Sendable {
        let votedAt: UInt64
        let voterAccountIdHex: String
    }

    /// One read's result: the votes, whether more follow, and where the next page starts.
    nonisolated struct Read: Sendable {
        let votes: [PollVoteFfi]
        let hasMoreAfter: Bool
        let nextCursor: Cursor?
    }

    typealias PageLoader = @Sendable (_ after: Cursor?, _ limit: UInt32) throws -> PollVotePageFfi

    /// What a failed read was doing, so `retry` repeats exactly that.
    private enum Operation {
        case firstPage
        case nextPage(Cursor)
        case refresh

        var replacesTheList: Bool {
            switch self {
            case .firstPage, .refresh: true
            case .nextPage: false
            }
        }
    }

    /// Nostr kind of a poll response (NIP-88), MDK's `MARMOT_APP_EVENT_KIND_POLL_RESPONSE`.
    nonisolated static let pollResponseKind: UInt64 = 1018
    /// A refresh re-reads at most this many pages, however many were on screen.
    nonisolated static let maxRefreshPages = 20

    let pollEventId: String
    nonisolated var id: String { pollEventId }
    /// MDK's tally for the poll, for option labels and per-option counts. Nil once the row is
    /// deleted or no longer projects a poll.
    private(set) var poll: MessagePoll?
    /// Loaded votes in MDK's order, one per voter.
    private(set) var votes: [PollVoteFfi] = []
    private(set) var hasMoreAfter = false
    private(set) var isLoading = false
    /// The last read failed. The votes already loaded stay, and `retry` repeats that read.
    private(set) var failed = false
    /// Whether any first page has come back, which is what makes an empty list mean "no votes".
    private(set) var hasLoaded = false

    @ObservationIgnored let limit: UInt32
    @ObservationIgnored private let groupIdHex: String?
    @ObservationIgnored private let loadPage: PageLoader
    @ObservationIgnored private let runtime: (any MarmotRuntime)?
    @ObservationIgnored private var nextCursor: Cursor?
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var eventsTask: Task<Void, Never>?
    @ObservationIgnored private var refreshRequested = false
    @ObservationIgnored private var failedOperation: Operation?

    init(
        pollEventId: String,
        poll: MessagePoll?,
        pageSize: Int = PollVotesPresentation.defaultPageSize,
        groupIdHex: String? = nil,
        runtime: (any MarmotRuntime)? = nil,
        loadPage: @escaping PageLoader
    ) {
        self.pollEventId = pollEventId
        self.poll = poll
        self.limit = PollVotesPresentation.clampedLimit(pageSize)
        self.groupIdHex = groupIdHex
        self.runtime = runtime
        self.loadPage = loadPage
    }

    convenience init(
        accountRef: String,
        groupIdHex: String,
        pollEventId: String,
        poll: MessagePoll?,
        runtime: any MarmotRuntime,
        pageSize: Int = PollVotesPresentation.defaultPageSize
    ) {
        self.init(
            pollEventId: pollEventId, poll: poll, pageSize: pageSize, groupIdHex: groupIdHex, runtime: runtime
        ) { cursor, limit in
            try runtime.pollVotes(
                accountRef: accountRef,
                groupIdHex: groupIdHex,
                pollEventId: pollEventId,
                afterVotedAt: cursor?.votedAt,
                afterVoterAccountIdHex: cursor?.voterAccountIdHex,
                limit: limit
            )
        }
    }

    /// "No votes yet." only once a read has said so, never on the frame before the first read.
    var showsNoVotes: Bool {
        hasLoaded && votes.isEmpty && !isLoading && !failed
    }

    func groups(blockedAccountIDs: Set<String>) -> [PollVoteGroup] {
        PollVotesPresentation.groups(poll: poll, votes: votes, blockedAccountIDs: blockedAccountIDs)
    }

    /// Reads the first page and starts following the group's poll responses. Called before the
    /// sheet is presented, so its first frame already shows the read in flight.
    func start() {
        reload()
        guard eventsTask == nil, let runtime, let groupIdHex else { return }
        let subscription = runtime.subscribeEvents()
        eventsTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let event = try? await runtime.nextEvent(subscription: subscription) else { return }
                if Self.isPollResponse(event, groupIdHex: groupIdHex) {
                    self?.refresh()
                }
            }
        }
    }

    nonisolated static func isPollResponse(_ event: MarmotEventFfi, groupIdHex: String) -> Bool {
        guard case .messageReceived(let received) = event else { return false }
        return received.message.kind == pollResponseKind
            && received.message.groupIdHex.lowercased() == groupIdHex.lowercased()
    }

    /// Reads from the first page, discarding everything loaded so far and any page in flight.
    @discardableResult
    func reload() -> Task<Void, Never> {
        task?.cancel()
        refreshRequested = false
        votes = []
        nextCursor = nil
        hasMoreAfter = false
        failed = false
        return run(.firstPage)
    }

    /// Appends the next page. Does nothing while a read is in flight or once the last page is in.
    @discardableResult
    func loadMore() -> Task<Void, Never>? {
        guard task == nil, hasMoreAfter, let nextCursor else { return nil }
        return run(.nextPage(nextCursor))
    }

    /// Re-reads what is on screen from the first page and swaps it in only once the read
    /// succeeds, so the list the user is reading never blanks. A failed refresh keeps it and
    /// offers Retry. Asked for while a read is in flight, it runs after that read.
    @discardableResult
    func refresh() -> Task<Void, Never>? {
        guard task == nil else {
            refreshRequested = true
            return nil
        }
        guard hasLoaded else { return reload() }
        return run(.refresh)
    }

    /// Repeats the read that failed.
    @discardableResult
    func retry() -> Task<Void, Never>? {
        guard task == nil, let failedOperation else { return nil }
        return run(failedOperation)
    }

    /// MDK reprojected the poll's row: its tally (and so who voted for what) may have changed.
    @discardableResult
    func reproject(poll: MessagePoll?) -> Task<Void, Never>? {
        self.poll = poll
        guard poll != nil else {
            task?.cancel()
            task = nil
            isLoading = false
            votes = []
            hasMoreAfter = false
            return nil
        }
        return refresh()
    }

    func cancel() {
        task?.cancel()
        task = nil
        eventsTask?.cancel()
        eventsTask = nil
        refreshRequested = false
        isLoading = false
    }

    private func run(_ operation: Operation) -> Task<Void, Never> {
        isLoading = true
        let loadPage = loadPage
        let limit = limit
        let target = max(votes.count, Int(limit))
        let task = Task { [weak self] in
            let result: Result<Read, Error>
            do {
                result = .success(
                    try await FFIExecutor.run {
                        switch operation {
                        case .firstPage:
                            try Self.read(after: nil, limit: limit, target: 1, loadPage: loadPage)
                        case .nextPage(let cursor):
                            try Self.read(after: cursor, limit: limit, target: 1, loadPage: loadPage)
                        case .refresh:
                            try Self.read(after: nil, limit: limit, target: target, loadPage: loadPage)
                        }
                    })
            } catch {
                result = .failure(error)
            }
            // Main actor from here on: a reload or cancel either ran before this line, and
            // cancelled this task, or runs after this page has been applied.
            guard !Task.isCancelled, let self else { return }
            self.apply(result, of: operation)
        }
        self.task = task
        return task
    }

    /// Pages from `cursor` until at least `target` votes are in, or the last page. One page when
    /// `target` is 1.
    nonisolated private static func read(
        after cursor: Cursor?,
        limit: UInt32,
        target: Int,
        loadPage: PageLoader
    ) throws -> Read {
        var collected: [PollVoteFfi] = []
        var seen = Set<String>()
        var cursor = cursor
        var hasMoreAfter = false
        for _ in 0..<maxRefreshPages {
            let page = try loadPage(cursor, limit)
            for vote in page.votes where seen.insert(vote.voterAccountIdHex).inserted {
                collected.append(vote)
            }
            if let last = page.votes.last {
                cursor = Cursor(votedAt: last.votedAt, voterAccountIdHex: last.voterAccountIdHex)
            }
            // An empty page cannot advance the cursor, so it ends paging whatever it claims.
            hasMoreAfter = page.hasMoreAfter && !page.votes.isEmpty
            if !hasMoreAfter || collected.count >= target { break }
        }
        return Read(votes: collected, hasMoreAfter: hasMoreAfter, nextCursor: cursor)
    }

    private func apply(_ result: Result<Read, Error>, of operation: Operation) {
        task = nil
        isLoading = false
        switch result {
        case .success(let read):
            switch operation {
            case .firstPage, .refresh:
                votes = read.votes
                hasLoaded = true
            case .nextPage:
                let known = Set(votes.map(\.voterAccountIdHex))
                votes.append(contentsOf: read.votes.filter { !known.contains($0.voterAccountIdHex) })
            }
            if read.nextCursor != nil || operation.replacesTheList {
                nextCursor = read.nextCursor
            }
            hasMoreAfter = read.hasMoreAfter
            failed = false
            failedOperation = nil
        case .failure:
            failed = true
            failedOperation = operation
        }
        if refreshRequested {
            refreshRequested = false
            refresh()
        }
    }
}
