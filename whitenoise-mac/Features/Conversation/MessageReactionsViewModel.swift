import Foundation
import MarmotKit
import Observation

/// Every reaction on one message, grouped by emoji, as the reaction details popover lists them.
/// Built either from the conversation window's bounded preview or from MDK's complete
/// `messageReactions` read.
nonisolated struct MessageReactionDetails: Hashable {
    /// One pill per emoji. `count` can exceed `senders.count` only in a window preview.
    let reactions: [MessageReaction]
    /// Emoji kinds the conversation window left out. Always 0 after a complete read.
    var omittedKinds: Int = 0
    /// Exact total across every kind, including omitted ones.
    var totalCount: Int

    init(reactions: [MessageReaction], omittedKinds: Int = 0, totalCount: Int? = nil) {
        self.reactions = reactions
        self.omittedKinds = omittedKinds
        self.totalCount = totalCount ?? reactions.reduce(0) { $0 + $1.count }
    }

    /// The window's preview for `message`, with its own pending react/un-react applied.
    init(projectedFrom message: MessageItem) {
        self.init(
            reactions: message.reactions,
            omittedKinds: message.omittedReactionKinds,
            totalCount: message.reactionTotalCount
        )
    }

    /// Whether some reactor is missing: a kind the window left out, or an emoji whose count
    /// names more people than its preview lists.
    var isTruncated: Bool {
        omittedKinds > 0 || reactions.contains { $0.count > $0.senders.count }
    }

    /// Whether removing the viewer's reaction may remove more than one emoji: MarmotKit's
    /// unreact retracts every reaction the account holds on the message.
    var unreactMayRemoveSeveralReactions: Bool {
        reactions.lazy.filter(\.isOwn).count > 1
    }

    /// The emoji the viewer holds among these reactions. In the popover this is the complete read,
    /// so it includes an own kind the window preview left out.
    var selectedEmojis: Set<String> {
        MessageReactionPick.selectedEmojis(in: reactions)
    }

    /// What picking `emoji` does, resolved against these reactions rather than the window preview,
    /// so an own kind only the complete read lists is taken back instead of re-sent as a no-op.
    func pick(_ emoji: String) -> MessageReactionPick {
        MessageReactionPick.resolve(emoji: emoji, reactions: reactions)
    }
}

/// Pure decisions for the reaction details popover.
nonisolated enum MessageReactionDetailsPresentation {
    enum Content: Equatable {
        /// The first read is in flight and no complete list is known yet.
        case loading
        /// The read failed. The popover shows fixed copy: an FFI error's description is a Swift
        /// debug dump, never user copy.
        case failed
        /// No reactions, or MDK no longer exposes the message.
        case empty
        /// `refreshFailed` is set when a later re-read failed; the list is the last complete read.
        case details(MessageReactionDetails, refreshFailed: Bool)

        /// The reactions this content lists, for re-validating a pick made from it: none once the
        /// list is empty, and nil while nothing is known, so the caller falls back to the preview.
        var listedReactions: [MessageReaction]? {
            switch self {
            case .details(let details, _): details.reactions
            case .empty: []
            case .loading, .failed: nil
            }
        }
    }

    /// A spinner appears only when the first read is slower than this, so a fast local read
    /// never flashes one.
    static let loadingIndicatorDelay: Duration = .milliseconds(300)

    /// What the popover shows. `projected` is the conversation window's preview for the message,
    /// carrying the viewer's pending react/un-react. Before the first read completes, a preview
    /// that is already complete is shown as is, so a small tally opens without any wait.
    static func content(
        phase: MessageReactionsViewModel.Phase,
        hasLoaded: Bool,
        reactions: [TimelineUserReactionFfi],
        projected: MessageReactionDetails?,
        me: String
    ) -> Content {
        let failed = phase == .failed
        guard hasLoaded else {
            if failed { return .failed }
            if let projected, !projected.reactions.isEmpty, !projected.isTruncated {
                return .details(projected, refreshFailed: false)
            }
            return .loading
        }
        let details = completeDetails(reactions, projected: projected, me: me)
        if details.reactions.isEmpty {
            if failed { return .failed }
            return .empty
        }
        return .details(details, refreshFailed: failed)
    }

    /// Groups MDK's complete per-sender reactions by emoji.
    ///
    /// The viewer's own reactions follow the window projection, which already carries a react or
    /// un-react the core has applied locally but not yet re-read. When the window lists every
    /// reaction kind, an emoji it no longer has is dropped too, so a read finished just before a
    /// newer revision doesn't briefly resurrect a removed reaction.
    ///
    /// Emojis keep the window's order, so a pill does not jump under the pointer; kinds only the
    /// read knows follow, most reacted first.
    static func completeDetails(
        _ reactions: [TimelineUserReactionFfi],
        projected: MessageReactionDetails?,
        me: String
    ) -> MessageReactionDetails {
        var others: [String: [String]] = [:]
        var mineInRead: Set<String> = []
        var earliest: [String: (reactedAt: UInt64, id: String)] = [:]
        for reaction in reactions where !reaction.emoji.isEmpty && !reaction.sender.isEmpty {
            if reaction.sender == me {
                mineInRead.insert(reaction.emoji)
            } else if others[reaction.emoji]?.contains(reaction.sender) != true {
                others[reaction.emoji, default: []].append(reaction.sender)
            }
            if !reaction.reactionMessageIdHex.isEmpty {
                let candidate = (reactedAt: reaction.reactedAt, id: reaction.reactionMessageIdHex)
                if let current = earliest[reaction.emoji],
                    (current.reactedAt, current.id) <= (candidate.reactedAt, candidate.id)
                {
                    continue
                }
                earliest[reaction.emoji] = candidate
            }
        }

        let projectedReactions = projected?.reactions ?? []
        let projectedByEmoji = Dictionary(
            projectedReactions.map { ($0.emoji, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let listsEveryKind = projected.map { $0.omittedKinds == 0 } ?? false

        var emojis = Set(others.keys).union(mineInRead)
        emojis.formUnion(projectedReactions.filter(\.isOwn).map(\.emoji))
        if listsEveryKind {
            emojis.formIntersection(projectedByEmoji.keys)
        }

        var groups: [MessageReaction] = []
        for emoji in emojis {
            let mine: Bool
            if let projectedReaction = projectedByEmoji[emoji] {
                mine = projectedReaction.isOwn
            } else {
                mine = !listsEveryKind && mineInRead.contains(emoji)
            }
            var senders = others[emoji] ?? []
            if mine, !me.isEmpty { senders.append(me) }
            guard !senders.isEmpty else { continue }
            groups.append(
                MessageReaction(
                    emoji: emoji,
                    count: senders.count,
                    isOwn: mine,
                    senders: senders,
                    reactionMessageIdHex: projectedByEmoji[emoji]?.reactionMessageIdHex ?? earliest[emoji]?.id
                ))
        }
        let windowOrder = Dictionary(
            projectedReactions.enumerated().map { ($0.element.emoji, $0.offset) },
            uniquingKeysWith: { first, _ in first }
        )
        groups.sort { lhs, rhs in
            switch (windowOrder[lhs.emoji], windowOrder[rhs.emoji]) {
            case (let left?, let right?): return left < right
            case (.some, nil): return true
            case (nil, .some): return false
            case (nil, nil): return lhs.count == rhs.count ? lhs.emoji < rhs.emoji : lhs.count > rhs.count
            }
        }
        return MessageReactionDetails(reactions: groups)
    }

    /// The emoji filters the popover can offer, or nil while there is no list.
    static func availableEmojis(in content: Content) -> [String]? {
        guard case .details(let details, _) = content else { return nil }
        return details.reactions.map(\.emoji)
    }

    /// Keeps the selected filter while the list is unknown (so the pill the person clicked
    /// survives loading) and falls back to "All" once the list no longer has that emoji.
    static func selection(_ selected: String?, availableEmojis: [String]?) -> String? {
        guard let selected, let availableEmojis else { return selected }
        return availableEmojis.contains(selected) ? selected : nil
    }
}

/// Loads MDK's complete reaction list for one message while its details popover is open.
///
/// `messageReactions` is a synchronous local read, so it runs off the main thread in one task this
/// model owns, and reads never overlap: a refresh asked for while one is in flight runs after it.
/// The model is created per message and cancelled when the popover closes, the message changes or
/// the account's conversation goes away. A cancelled task drops its result on arrival — the
/// cancellation and the check after the await both happen on the main actor — so no staleness
/// counter is needed.
@MainActor
@Observable
final class MessageReactionsViewModel: Identifiable {
    nonisolated enum Phase: Equatable {
        case idle
        case loading
        case loaded
        case failed
    }

    typealias Loader = @Sendable () throws -> [TimelineUserReactionFfi]

    let messageIdHex: String
    nonisolated var id: String { messageIdHex }
    /// The viewing account, whose reactions follow the window projection rather than the read.
    let viewerAccountIdHex: String
    /// The last complete read. Kept through a refresh until the refresh succeeds.
    private(set) var reactions: [TimelineUserReactionFfi] = []
    /// Whether `reactions` holds a completed read.
    private(set) var hasLoaded = false
    private(set) var phase: Phase = .idle
    /// True once the first read has taken longer than the spinner delay.
    private(set) var showsLoadingIndicator = false

    @ObservationIgnored private let load: Loader
    @ObservationIgnored private let loadingIndicatorDelay: Duration
    @ObservationIgnored private var task: Task<Void, Never>?
    /// The most recent read, kept after `cancel()` so a test can await a discarded read to its end
    /// and prove it published nothing, rather than sleeping and hoping it already ran.
    @ObservationIgnored private(set) var lastRead: Task<Void, Never>?
    @ObservationIgnored private var indicatorTask: Task<Void, Never>?
    @ObservationIgnored private var refreshRequested = false

    init(
        messageIdHex: String,
        viewerAccountIdHex: String,
        loadingIndicatorDelay: Duration = MessageReactionDetailsPresentation.loadingIndicatorDelay,
        load: @escaping Loader
    ) {
        self.messageIdHex = messageIdHex
        self.viewerAccountIdHex = viewerAccountIdHex
        self.loadingIndicatorDelay = loadingIndicatorDelay
        self.load = load
    }

    convenience init(
        accountRef: String,
        groupIdHex: String,
        messageIdHex: String,
        viewerAccountIdHex: String,
        runtime: any MarmotRuntime
    ) {
        self.init(messageIdHex: messageIdHex, viewerAccountIdHex: viewerAccountIdHex) {
            try runtime.messageReactions(accountRef: accountRef, groupIdHex: groupIdHex, messageIdHex: messageIdHex)
        }
    }

    /// What the popover shows against the window's current preview for the message.
    func content(projected: MessageReactionDetails?) -> MessageReactionDetailsPresentation.Content {
        MessageReactionDetailsPresentation.content(
            phase: phase,
            hasLoaded: hasLoaded,
            reactions: reactions,
            projected: projected,
            me: viewerAccountIdHex
        )
    }

    /// Every reactor the complete read named, for profile resolution.
    var reactorAccountIds: Set<String> {
        Set(reactions.map(\.sender).filter { !$0.isEmpty })
    }

    /// Reads the list. Called before the popover is presented, so its first frame already shows
    /// the read in flight.
    @discardableResult
    func start() -> Task<Void, Never>? {
        refresh()
    }

    /// Re-reads the list, keeping the last one on screen until the read succeeds. Asked for while
    /// a read is in flight, it runs after that read.
    @discardableResult
    func refresh() -> Task<Void, Never>? {
        guard task == nil else {
            refreshRequested = true
            return nil
        }
        return run()
    }

    /// Repeats the read that failed.
    @discardableResult
    func retry() -> Task<Void, Never>? {
        guard case .failed = phase else { return nil }
        return refresh()
    }

    /// The popover closed, or the message or account it was for went away. A read in flight
    /// publishes nothing.
    func cancel() {
        task?.cancel()
        task = nil
        indicatorTask?.cancel()
        indicatorTask = nil
        refreshRequested = false
        if phase == .loading { phase = hasLoaded ? .loaded : .idle }
    }

    private func run() -> Task<Void, Never> {
        phase = .loading
        startLoadingIndicatorIfNeeded()
        let load = load
        let task = Task { [weak self] in
            let result: Result<[TimelineUserReactionFfi], Error>
            do {
                result = .success(try await FFIExecutor.run { try load() })
            } catch {
                result = .failure(error)
            }
            // Main actor from here on: a cancel either ran before this line, and cancelled this
            // task, or runs after this read has been applied.
            guard !Task.isCancelled, let self else { return }
            self.apply(result)
        }
        self.task = task
        lastRead = task
        return task
    }

    private func apply(_ result: Result<[TimelineUserReactionFfi], Error>) {
        task = nil
        switch result {
        case .success(let reactions):
            self.reactions = reactions
            hasLoaded = true
            phase = .loaded
        case .failure:
            phase = .failed
        }
        indicatorTask?.cancel()
        indicatorTask = nil
        showsLoadingIndicator = false
        if refreshRequested {
            refreshRequested = false
            refresh()
        }
    }

    /// Only a first read (or a retry of one) can leave the popover with nothing to show.
    private func startLoadingIndicatorIfNeeded() {
        guard !hasLoaded, indicatorTask == nil else { return }
        let delay = loadingIndicatorDelay
        indicatorTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self, self.phase == .loading, !self.hasLoaded else { return }
            self.showsLoadingIndicator = true
        }
    }
}
