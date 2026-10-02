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
/// read runs off the main thread in one task this model owns; a reload cancels that task before
/// starting the next, and a cancelled task drops its page on arrival, so a page requested before
/// the reload never lands in the restarted list. No staleness counter is needed: both the
/// cancellation and the check after the await happen on the main actor.
@MainActor
@Observable
final class PollVotesViewModel: Identifiable {
    /// Where the next page starts: the last vote of the previous page.
    nonisolated struct Cursor: Equatable, Sendable {
        let votedAt: UInt64
        let voterAccountIdHex: String
    }

    typealias PageLoader = @Sendable (_ after: Cursor?, _ limit: UInt32) throws -> PollVotePageFfi

    let pollEventId: String
    nonisolated var id: String { pollEventId }
    /// MDK's tally for the poll, for option labels and per-option counts. Nil once the row is
    /// deleted or no longer projects a poll.
    private(set) var poll: MessagePoll?
    /// Loaded votes in MDK's order, one per voter.
    private(set) var votes: [PollVoteFfi] = []
    private(set) var hasMoreAfter = false
    private(set) var isLoading = false
    /// The last read failed. The votes already loaded stay, and `retry` resumes from them.
    private(set) var failed = false

    @ObservationIgnored let limit: UInt32
    @ObservationIgnored private let loadPage: PageLoader
    @ObservationIgnored private var nextCursor: Cursor?
    @ObservationIgnored private var task: Task<Void, Never>?

    init(
        pollEventId: String,
        poll: MessagePoll?,
        pageSize: Int = PollVotesPresentation.defaultPageSize,
        loadPage: @escaping PageLoader
    ) {
        self.pollEventId = pollEventId
        self.poll = poll
        self.limit = PollVotesPresentation.clampedLimit(pageSize)
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
        self.init(pollEventId: pollEventId, poll: poll, pageSize: pageSize) { cursor, limit in
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

    func groups(blockedAccountIDs: Set<String>) -> [PollVoteGroup] {
        PollVotesPresentation.groups(poll: poll, votes: votes, blockedAccountIDs: blockedAccountIDs)
    }

    /// Reads from the first page, discarding everything loaded so far and any page in flight.
    @discardableResult
    func reload() -> Task<Void, Never> {
        task?.cancel()
        votes = []
        nextCursor = nil
        hasMoreAfter = false
        failed = false
        return fetch(after: nil)
    }

    /// Appends the next page. Does nothing while a read is in flight or once the last page is in.
    @discardableResult
    func loadMore() -> Task<Void, Never>? {
        guard task == nil, hasMoreAfter, let nextCursor else { return nil }
        return fetch(after: nextCursor)
    }

    /// After a failure: the page that failed again, or the first page if none had loaded.
    @discardableResult
    func retry() -> Task<Void, Never>? {
        guard task == nil else { return nil }
        guard let nextCursor, !votes.isEmpty else { return reload() }
        return fetch(after: nextCursor)
    }

    /// MDK reprojected the poll's row: its tally (and so who voted for what) may have changed, so
    /// the list starts over from the first page.
    @discardableResult
    func reproject(poll: MessagePoll?) -> Task<Void, Never> {
        self.poll = poll
        return reload()
    }

    func cancel() {
        task?.cancel()
        task = nil
        isLoading = false
    }

    private func fetch(after cursor: Cursor?) -> Task<Void, Never> {
        isLoading = true
        let loadPage = loadPage
        let limit = limit
        let task = Task { [weak self] in
            let result: Result<PollVotePageFfi, Error>
            do {
                result = .success(try await FFIExecutor.run { try loadPage(cursor, limit) })
            } catch {
                result = .failure(error)
            }
            // Main actor from here on: a reload or cancel either ran before this line, and
            // cancelled this task, or runs after this page has been applied.
            guard !Task.isCancelled, let self else { return }
            self.apply(result)
        }
        self.task = task
        return task
    }

    private func apply(_ result: Result<PollVotePageFfi, Error>) {
        task = nil
        isLoading = false
        switch result {
        case .success(let page):
            let known = Set(votes.map(\.voterAccountIdHex))
            votes.append(contentsOf: page.votes.filter { !known.contains($0.voterAccountIdHex) })
            if let last = page.votes.last {
                nextCursor = Cursor(votedAt: last.votedAt, voterAccountIdHex: last.voterAccountIdHex)
            }
            // An empty page cannot advance the cursor, so it ends paging whatever it claims.
            hasMoreAfter = page.hasMoreAfter && !page.votes.isEmpty
            failed = false
        case .failure:
            failed = true
        }
    }
}
