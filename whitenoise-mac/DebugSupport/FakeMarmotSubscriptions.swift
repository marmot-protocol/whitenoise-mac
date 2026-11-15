// coverage:ignore-file
//  Test support compiled into DEBUG app builds alongside `FakeMarmotRuntime`, which needs it.
//  See that file for why it lives in the app target. Ignored by coverage: it is a test double.

#if DEBUG
    import Foundation
    import MarmotKit

    nonisolated final class FakePresentedChatListSubscription: PresentedChatListSubscription, @unchecked Sendable {
        private let initial: PresentedChatListUpdateFfi?
        private var updates: [PresentedChatListUpdateFfi]
        private let endsWhenExhausted: Bool
        private let recordSnapshot: @Sendable () -> Void

        required init(unsafeFromRawPointer pointer: UnsafeMutableRawPointer) {
            initial = nil
            updates = []
            endsWhenExhausted = false
            recordSnapshot = {}
            super.init(unsafeFromRawPointer: pointer)
        }

        init(
            initial: PresentedChatListUpdateFfi,
            updates: [PresentedChatListUpdateFfi] = [],
            endsWhenExhausted: Bool = false,
            recordSnapshot: @escaping @Sendable () -> Void = {}
        ) {
            self.initial = initial
            self.updates = updates
            self.endsWhenExhausted = endsWhenExhausted
            self.recordSnapshot = recordSnapshot
            super.init(noPointer: NoPointer())
        }

        override func snapshot() -> PresentedChatListUpdateFfi? {
            recordSnapshot()
            return initial
        }

        override func next() async throws -> PresentedChatListUpdateFfi? {
            guard !updates.isEmpty else {
                if endsWhenExhausted { return nil }
                return await awaitSubscriptionCancellation()
            }
            return updates.removeFirst()
        }
    }

    nonisolated final class FakeChatListWindowSubscription: ChatListWindowSubscription, @unchecked Sendable {
        /// One anchor or page command, with the sequence it was sent against.
        enum Command: Equatable {
            case anchor(String, sequence: UInt64)
            case page(ChatListPageDirectionFfi, sequence: UInt64)
        }

        private let lock = NSLock()
        private var current: ChatListWindowSnapshotFfi?
        private var updates: [ChatListWindowSnapshotFfi]
        private var pages: [ChatListWindowSnapshotFfi]
        private var pageErrors: [Error]
        private var nextErrors: [Error]
        private var recordedCommands: [Command] = []
        private let advancesSequence: Bool
        private let endsWhenExhausted: Bool

        /// Every anchor and page command, in the order they reached the window.
        var commands: [Command] { lock.withLock { recordedCommands } }

        required init(unsafeFromRawPointer pointer: UnsafeMutableRawPointer) {
            current = nil
            updates = []
            pages = []
            pageErrors = []
            nextErrors = []
            advancesSequence = false
            endsWhenExhausted = false
            super.init(unsafeFromRawPointer: pointer)
        }

        /// `pageErrors` and `nextErrors` are thrown first, one per call. With `advancesSequence`, an
        /// anchor or unscripted page answers with the next sequence, as MDK installs a new snapshot
        /// for every accepted command. With `endsWhenExhausted`, `next()` ends instead of waiting.
        init(
            initial: ChatListWindowSnapshotFfi,
            updates: [ChatListWindowSnapshotFfi] = [],
            pages: [ChatListWindowSnapshotFfi] = [],
            pageErrors: [Error] = [],
            nextErrors: [Error] = [],
            advancesSequence: Bool = false,
            endsWhenExhausted: Bool = false
        ) {
            current = initial
            self.updates = updates
            self.pages = pages
            self.pageErrors = pageErrors
            self.nextErrors = nextErrors
            self.advancesSequence = advancesSequence
            self.endsWhenExhausted = endsWhenExhausted
            super.init(noPointer: NoPointer())
        }

        override func snapshot() -> ChatListWindowSnapshotFfi? {
            current
        }

        override func next() async throws -> ChatListWindowSnapshotFfi? {
            if !nextErrors.isEmpty { throw nextErrors.removeFirst() }
            guard !updates.isEmpty else {
                if endsWhenExhausted { return nil }
                return await awaitSubscriptionCancellation()
            }
            let next = updates.removeFirst()
            current = next
            return next
        }

        override func page(sequence: UInt64, direction: ChatListPageDirectionFfi, count: UInt32) async throws
            -> ChatListWindowSnapshotFfi
        {
            lock.withLock { recordedCommands.append(.page(direction, sequence: sequence)) }
            if !pageErrors.isEmpty { throw pageErrors.removeFirst() }
            guard var current else { throw FakeMarmotRuntimeError.unused }
            guard !pages.isEmpty else {
                guard advancesSequence else { return current }
                current.sequence += 1
                self.current = current
                return current
            }
            let next = pages.removeFirst()
            self.current = next
            return next
        }

        override func returnToTop(sequence: UInt64) async throws -> ChatListWindowSnapshotFfi {
            guard let current else { throw FakeMarmotRuntimeError.unused }
            return current
        }

        override func setVisibleAnchor(sequence: UInt64, groupIdHex: String) async throws -> ChatListWindowSnapshotFfi {
            lock.withLock { recordedCommands.append(.anchor(groupIdHex, sequence: sequence)) }
            guard var current else { throw FakeMarmotRuntimeError.unused }
            guard advancesSequence else { return current }
            let index = current.rows.firstIndex { $0.row.groupIdHex == groupIdHex } ?? 0
            current.sequence += 1
            current.anchor = .retained(groupIdHex: groupIdHex, index: UInt32(index))
            self.current = current
            return current
        }
    }

    nonisolated final class FakeAccountAttentionSubscription: AccountAttentionSubscription, @unchecked Sendable {
        private let initial: AccountAttentionSnapshotFfi?
        private var updates: [AccountAttentionSnapshotFfi]

        required init(unsafeFromRawPointer pointer: UnsafeMutableRawPointer) {
            initial = nil
            updates = []
            super.init(unsafeFromRawPointer: pointer)
        }

        init(initial: AccountAttentionSnapshotFfi, updates: [AccountAttentionSnapshotFfi] = []) {
            self.initial = initial
            self.updates = updates
            super.init(noPointer: NoPointer())
        }

        override func snapshot() -> AccountAttentionSnapshotFfi? {
            initial
        }

        override func next() async throws -> AccountAttentionSnapshotFfi? {
            guard !updates.isEmpty else { return await awaitSubscriptionCancellation() }
            return updates.removeFirst()
        }
    }

    /// Fans test-pushed runtime events out to every live `FakeEventsSubscription`, like the core's
    /// broadcast firehose. An event emitted before anyone subscribes is dropped, as it would be there.
    nonisolated final class FakeEventHub: @unchecked Sendable {
        private let lock = NSLock()
        private var continuations: [UUID: AsyncStream<MarmotEventFfi>.Continuation] = [:]

        var subscriberCount: Int {
            lock.withLock { continuations.count }
        }

        func subscribe() -> FakeEventsSubscription {
            let id = UUID()
            let (stream, continuation) = AsyncStream<MarmotEventFfi>.makeStream()
            continuation.onTermination = { [weak self] _ in
                guard let self else { return }
                _ = self.lock.withLock { self.continuations.removeValue(forKey: id) }
            }
            lock.withLock { continuations[id] = continuation }
            return FakeEventsSubscription(stream: stream)
        }

        func emit(_ event: MarmotEventFfi) {
            let targets = lock.withLock { Array(continuations.values) }
            for continuation in targets {
                continuation.yield(event)
            }
        }
    }

    nonisolated final class FakeEventsSubscription: EventsSubscription, @unchecked Sendable {
        private var iterator: AsyncStream<MarmotEventFfi>.AsyncIterator?

        required init(unsafeFromRawPointer pointer: UnsafeMutableRawPointer) {
            iterator = nil
            super.init(unsafeFromRawPointer: pointer)
        }

        init(stream: AsyncStream<MarmotEventFfi>) {
            iterator = stream.makeAsyncIterator()
            super.init(noPointer: NoPointer())
        }

        override func next() async -> MarmotEventFfi? {
            await iterator?.next()
        }
    }

    nonisolated final class FakeConversationWindowSubscription: ConversationWindowSubscription, @unchecked Sendable {
        private var current: ConversationWindowSnapshotFfi?
        private var updates: [ConversationWindowSnapshotFfi]
        private let updateDelayNanoseconds: UInt64
        private(set) var cancelled = false
        /// Window commands in call order (`anchor:<id>`, `page:older`, `page:newer`, `latest`), so a
        /// test can assert that a visible anchor was reported before a page.
        private(set) var commands: [String] = []
        /// Fails this many `page` calls with `ConversationWindowStale` before answering.
        var stalePagesRemaining = 0
        /// Fails this many `returnToLatest` calls with `ConversationWindowStale` before answering.
        var staleReturnsRemaining = 0
        /// Fails this many `jumpToMessage` calls with `ConversationWindowStale` before answering.
        var staleJumpsRemaining = 0
        private(set) var jumpCount = 0
        /// Every `jumpToMessage` fails with this (after any stale replies) when set.
        var jumpError: Error?
        /// Holds the first `jumpToMessage` while armed, so a test can look at the model mid-jump.
        let jumpGate = AsyncFfiGate()
        /// What `returnToLatest` answers with, and makes current; the current snapshot when nil.
        var latestSnapshot: ConversationWindowSnapshotFfi?
        /// Runs before a stale `page` reply is thrown, for a command racing that page.
        var beforeStalePage: (@MainActor () async -> Void)?

        required init(unsafeFromRawPointer pointer: UnsafeMutableRawPointer) {
            current = nil
            updates = []
            updateDelayNanoseconds = 0
            super.init(unsafeFromRawPointer: pointer)
        }

        init(
            initial: ConversationWindowSnapshotFfi,
            updates: [ConversationWindowSnapshotFfi] = [],
            updateDelayNanoseconds: UInt64 = 0
        ) {
            current = initial
            self.updates = updates
            self.updateDelayNanoseconds = updateDelayNanoseconds
            super.init(noPointer: NoPointer())
        }

        override func cancel() async {
            cancelled = true
        }

        override func snapshot() -> ConversationWindowSnapshotFfi? {
            current
        }

        override func next() async throws -> ConversationWindowSnapshotFfi? {
            guard !updates.isEmpty else { return await awaitSubscriptionCancellation() }
            if updateDelayNanoseconds > 0 {
                try await Task.sleep(nanoseconds: updateDelayNanoseconds)
            }
            guard !Task.isCancelled, !cancelled else { throw CancellationError() }
            let next = updates.removeFirst()
            current = next
            return next
        }

        override func jumpToMessage(
            revision: ConversationWindowRevisionFfi,
            messageIdHex: String,
            timeoutMs: UInt32
        ) async throws -> ConversationWindowSnapshotFfi {
            jumpCount += 1
            await jumpGate.passIfArmed()
            if staleJumpsRemaining > 0 {
                staleJumpsRemaining -= 1
                throw MarmotKitError.ConversationWindowStale
            }
            if let jumpError { throw jumpError }
            guard let current else { throw FakeMarmotRuntimeError.unused }
            return current
        }

        override func page(
            revision: ConversationWindowRevisionFfi,
            direction: ConversationPageDirectionFfi,
            count: UInt32,
            timeoutMs: UInt32
        ) async throws -> ConversationWindowSnapshotFfi {
            commands.append(direction == .newer ? "page:newer" : "page:older")
            if stalePagesRemaining > 0 {
                stalePagesRemaining -= 1
                if let beforeStalePage { await beforeStalePage() }
                throw MarmotKitError.ConversationWindowStale
            }
            guard let current else { throw FakeMarmotRuntimeError.unused }
            return current
        }

        override func returnToLatest(
            revision: ConversationWindowRevisionFfi,
            timeoutMs: UInt32
        ) async throws -> ConversationWindowSnapshotFfi {
            commands.append("latest")
            if staleReturnsRemaining > 0 {
                staleReturnsRemaining -= 1
                throw MarmotKitError.ConversationWindowStale
            }
            if let latestSnapshot { current = latestSnapshot }
            guard let current else { throw FakeMarmotRuntimeError.unused }
            return current
        }

        override func setVisibleAnchor(
            revision: ConversationWindowRevisionFfi,
            messageIdHex: String,
            timeoutMs: UInt32
        ) async throws -> ConversationWindowSnapshotFfi {
            commands.append("anchor:\(messageIdHex)")
            guard let current else { throw FakeMarmotRuntimeError.unused }
            return current
        }
    }

    nonisolated final class FakeAttachmentTransferSubscription: AttachmentTransferSubscription, @unchecked Sendable {
        private let lock = NSLock()
        private var snapshots: [AttachmentTransferSnapshotFfi]
        private let updateDelayNanoseconds: UInt64
        private(set) var cancelled = false

        required init(unsafeFromRawPointer pointer: UnsafeMutableRawPointer) {
            snapshots = []
            updateDelayNanoseconds = 0
            super.init(unsafeFromRawPointer: pointer)
        }

        init(snapshots: [AttachmentTransferSnapshotFfi], updateDelayNanoseconds: UInt64 = 0) {
            self.snapshots = snapshots
            self.updateDelayNanoseconds = updateDelayNanoseconds
            super.init(noPointer: NoPointer())
        }

        override func cancel() {
            lock.withLock { cancelled = true }
        }

        override func next() async throws -> AttachmentTransferSnapshotFfi? {
            if updateDelayNanoseconds > 0 {
                try await Task.sleep(nanoseconds: updateDelayNanoseconds)
            }
            try Task.checkCancellation()
            return lock.withLock { () -> AttachmentTransferSnapshotFfi? in
                guard !cancelled, !snapshots.isEmpty else { return nil }
                return snapshots.removeFirst()
            }
        }
    }

    nonisolated final class FakeBlockListSubscription: BlockListSubscription, @unchecked Sendable {
        private var current: BlockListSnapshotFfi?
        private var updates: [BlockListSnapshotFfi]

        required init(unsafeFromRawPointer pointer: UnsafeMutableRawPointer) {
            current = nil
            updates = []
            super.init(unsafeFromRawPointer: pointer)
        }

        init(initial: BlockListSnapshotFfi, updates: [BlockListSnapshotFfi]) {
            current = initial
            self.updates = updates
            super.init(noPointer: NoPointer())
        }

        override func snapshot() -> BlockListSnapshotFfi? { current }

        override func next() async -> BlockListSnapshotFfi? {
            guard !updates.isEmpty else { return await awaitSubscriptionCancellation() }
            let replacement = updates.removeFirst()
            current = replacement
            return replacement
        }
    }

    nonisolated final class FakeOnboardingSubscription: OnboardingSubscription, @unchecked Sendable {
        private var current: OnboardingSnapshotFfi
        private var updates: [OnboardingSnapshotFfi]
        /// Snapshots `deliver` sends once `updates` has run out, the way MarmotKit reports a command's
        /// progress while it is still running.
        private let live = AsyncStream.makeStream(of: OnboardingSnapshotFfi.self)

        required init(unsafeFromRawPointer pointer: UnsafeMutableRawPointer) {
            current = OnboardingSnapshotFfi(
                accountIdHex: "",
                recoveryEpoch: nil,
                revision: 0,
                ready: false,
                steps: [],
                proposal: nil,
                singleDeviceNotice: nil,
                cancellationPending: false
            )
            updates = []
            super.init(unsafeFromRawPointer: pointer)
        }

        init(initial: OnboardingSnapshotFfi, updates: [OnboardingSnapshotFfi]) {
            current = initial
            self.updates = updates
            super.init(noPointer: NoPointer())
        }

        /// Sends `snapshot` to whoever is waiting on `next()`, now or on its next call.
        func deliver(_ snapshot: OnboardingSnapshotFfi) {
            live.continuation.yield(snapshot)
        }

        override func snapshot() -> OnboardingSnapshotFfi { current }

        override func next() async -> OnboardingSnapshotFfi? {
            let replacement: OnboardingSnapshotFfi
            if !updates.isEmpty {
                replacement = updates.removeFirst()
            } else {
                // Ends with nil once the observing task is cancelled, like `awaitSubscriptionCancellation`.
                var iterator = live.stream.makeAsyncIterator()
                guard let delivered = await iterator.next() else { return nil }
                replacement = delivered
            }
            current = replacement
            return replacement
        }
    }

    nonisolated enum FakeTimelinePaginationError: Error {
        case staleSubscription
    }

    nonisolated final class FakeTimelineMessagesSubscription: TimelineMessagesSubscription, @unchecked Sendable {
        private var fullSet: TimelinePageFfi
        private let limit: Int
        private let windowCap: Int
        private var lo: Int
        private var hi: Int
        private var updates: [TimelineSubscriptionUpdateFfi]
        private let updateDelayNanoseconds: UInt64
        private let endsWhenExhausted: Bool
        private let recordSnapshot: () -> Void
        private(set) var paginateBackwardsCount = 0
        private(set) var paginateForwardsCount = 0
        /// Issue #529 regression support: when armed, the first `paginateBackwards` or
        /// `paginateForwards` call suspends until `releasePaginationGate()` is invoked.
        var paginationGateEnabled = false
        private(set) var didReachPaginationGate = false
        private var paginationGateContinuation: CheckedContinuation<Void, Never>?
        /// When set with `paginationGateEnabled`, the paginate call throws after the gate releases.
        var throwsAfterPaginationGate = false

        required init(unsafeFromRawPointer pointer: UnsafeMutableRawPointer) {
            self.fullSet = emptyTimelinePage()
            self.limit = 100
            self.windowCap = 200
            self.lo = 0
            self.hi = 0
            self.updates = []
            self.updateDelayNanoseconds = 0
            self.endsWhenExhausted = true
            self.recordSnapshot = {}
            super.init(unsafeFromRawPointer: pointer)
        }

        init(
            messages: [TimelineMessageRecordFfi],
            limit: Int,
            windowCap: Int,
            updates: [TimelineSubscriptionUpdateFfi] = [],
            updateDelayNanoseconds: UInt64 = 0,
            endsWhenExhausted: Bool = false,
            recordSnapshot: @escaping () -> Void = {}
        ) {
            var page = TimelinePageFfi(messages: messages, hasMoreBefore: false, hasMoreAfter: false)
            page.sortCanonical()
            self.fullSet = page
            self.limit = max(1, limit)
            self.windowCap = max(1, windowCap)
            self.hi = page.messages.count
            self.lo = max(0, page.messages.count - max(1, limit))
            self.updates = updates
            self.updateDelayNanoseconds = updateDelayNanoseconds
            self.endsWhenExhausted = endsWhenExhausted
            self.recordSnapshot = recordSnapshot
            super.init(noPointer: NoPointer())
        }

        private func windowPage() -> TimelinePageFfi {
            let count = fullSet.messages.count
            let clampedHi = min(max(hi, 0), count)
            let clampedLo = min(max(lo, 0), clampedHi)
            return TimelinePageFfi(
                messages: Array(fullSet.messages[clampedLo..<clampedHi]),
                hasMoreBefore: clampedLo > 0,
                hasMoreAfter: clampedHi < count
            )
        }

        override func snapshot() -> TimelinePageFfi? {
            recordSnapshot()
            return windowPage()
        }

        override func paginateBackwards(count: UInt32) async throws -> TimelinePageFfi {
            paginateBackwardsCount += 1
            await passPaginationGateIfArmed()
            if throwsAfterPaginationGate {
                throw FakeTimelinePaginationError.staleSubscription
            }
            lo = max(0, lo - Int(count))
            if hi - lo > windowCap { hi = lo + windowCap }
            return windowPage()
        }

        override func paginateForwards(count: UInt32) async throws -> TimelinePageFfi {
            paginateForwardsCount += 1
            await passPaginationGateIfArmed()
            if throwsAfterPaginationGate {
                throw FakeTimelinePaginationError.staleSubscription
            }
            hi = min(fullSet.messages.count, hi + Int(count))
            if hi - lo > windowCap { lo = hi - windowCap }
            return windowPage()
        }

        private func passPaginationGateIfArmed() async {
            guard paginationGateEnabled, paginationGateContinuation == nil, !didReachPaginationGate else { return }
            didReachPaginationGate = true
            await withCheckedContinuation { continuation in
                paginationGateContinuation = continuation
            }
        }

        func releasePaginationGate() {
            paginationGateContinuation?.resume()
            paginationGateContinuation = nil
        }

        /// Dequeue the next queued signal, mutate the fake's server-side `fullSet` and
        /// re-window `lo`/`hi` exactly as the runtime's `recv()` does, and hand back both the
        /// original update (so `nextUpdate()` can surface the raw `.projection`) and the
        /// re-materialized window (what a `.page`/`snapshot()` observes). Shared by `next()`
        /// and `nextUpdate()` so both stay faithful to the same windowing contract.
        private func consumeSignalApplyingWindow() -> (update: TimelineSubscriptionUpdateFfi, page: TimelinePageFfi) {
            let update = updates.removeFirst()
            let priorSpan = hi - lo
            let wasAnchored = hi >= fullSet.messages.count
            switch update {
            case .page(let page):
                // A head `.page` refresh never replaces a scrolled-back (detached) window.
                if wasAnchored {
                    for message in page.messages {
                        if let index = fullSet.messages.firstIndex(where: { $0.messageIdHex == message.messageIdHex }) {
                            fullSet.messages[index] = message
                        } else {
                            fullSet.messages.append(message)
                        }
                    }
                    fullSet.sortCanonical()
                }
            case .projection(update: let runtimeUpdate):
                fullSet.applyProjectionUpdate(runtimeUpdate.update)
            }
            let count = fullSet.messages.count
            if wasAnchored {
                hi = count
                lo = max(0, hi - max(limit, priorSpan))
                if hi - lo > windowCap { lo = hi - windowCap }
            } else {
                hi = min(hi, count)
                lo = min(lo, hi)
            }
            return (update, windowPage())
        }

        override func next() async -> TimelinePageFfi? {
            guard !updates.isEmpty else {
                if endsWhenExhausted { return nil }
                return await awaitSubscriptionCancellation()
            }
            if updateDelayNanoseconds > 0 {
                try? await Task.sleep(nanoseconds: updateDelayNanoseconds)
            }
            return consumeSignalApplyingWindow().page
        }

        override func nextUpdate() async -> TimelineSubscriptionUpdateFfi? {
            guard !updates.isEmpty else {
                if endsWhenExhausted { return nil }
                return await awaitSubscriptionCancellation()
            }
            if updateDelayNanoseconds > 0 {
                try? await Task.sleep(nanoseconds: updateDelayNanoseconds)
            }
            let (update, page) = consumeSignalApplyingWindow()
            // Mirror the runtime: a refresh surfaces the re-materialized window as a `.page`,
            // while a projection surfaces the raw delta for the client to apply incrementally.
            switch update {
            case .page:
                return .page(page: page)
            case .projection:
                return update
            }
        }
    }

    nonisolated final class FakeNotificationsSubscription: NotificationsSubscription, @unchecked Sendable {
        private let endsImmediately: Bool

        required init(unsafeFromRawPointer pointer: UnsafeMutableRawPointer) {
            self.endsImmediately = true
            super.init(unsafeFromRawPointer: pointer)
        }

        init(endsImmediately: Bool = false) {
            self.endsImmediately = endsImmediately
            super.init(noPointer: NoPointer())
        }

        override func next() async -> NotificationUpdateFfi? {
            if endsImmediately { return nil }
            return await awaitSubscriptionCancellation()
        }
    }

    /// Replays a scripted web-of-trust search. Unlike the runtime subscriptions there is no
    /// `snapshot()` — a search has no initial state, only results as each radius resolves.
    ///
    /// Once the script is exhausted this suspends until cancelled rather than returning `nil`, so a
    /// test can distinguish "the search ended" from "the host stopped asking". `recordNextUpdate`
    /// counts every call, which is how the release-without-draining contract becomes assertable.
    nonisolated final class FakeUserSearchSubscription: UserSearchSubscription, @unchecked Sendable {
        private var updates: [UserSearchUpdateFfi]
        private let updateDelayNanoseconds: UInt64
        private let recordNextUpdate: () -> Void

        required init(unsafeFromRawPointer pointer: UnsafeMutableRawPointer) {
            self.updates = []
            self.updateDelayNanoseconds = 0
            self.recordNextUpdate = {}
            super.init(unsafeFromRawPointer: pointer)
        }

        init(
            updates: [UserSearchUpdateFfi],
            updateDelayNanoseconds: UInt64 = 0,
            recordNextUpdate: @escaping () -> Void = {}
        ) {
            self.updates = updates
            self.updateDelayNanoseconds = updateDelayNanoseconds
            self.recordNextUpdate = recordNextUpdate
            super.init(noPointer: NoPointer())
        }

        override func nextUpdate() async -> UserSearchUpdateFfi? {
            recordNextUpdate()
            guard !updates.isEmpty else {
                return await awaitSubscriptionCancellation()
            }
            if updateDelayNanoseconds > 0 {
                do {
                    try await Task.sleep(nanoseconds: updateDelayNanoseconds)
                } catch {
                    return nil
                }
            }
            return updates.removeFirst()
        }
    }
    nonisolated extension TimelinePageFfi {
        mutating func sortCanonical() {
            messages.sort {
                if $0.timelineAt != $1.timelineAt { return $0.timelineAt < $1.timelineAt }
                return $0.messageIdHex < $1.messageIdHex
            }
        }

        mutating func applyProjectionUpdate(_ update: TimelineProjectionUpdateFfi) {
            if update.changes.isEmpty {
                for message in update.messages {
                    upsert(message)
                }
            } else {
                for change in update.changes {
                    switch change {
                    case .upsert(trigger: _, let message):
                        upsert(message)
                    case .remove(let messageIdHex, reason: _):
                        messages.removeAll { $0.messageIdHex == messageIdHex }
                    }
                }
            }
            messages.sort {
                if $0.timelineAt != $1.timelineAt { return $0.timelineAt < $1.timelineAt }
                return $0.messageIdHex < $1.messageIdHex
            }
        }

        private mutating func upsert(_ message: TimelineMessageRecordFfi) {
            if let index = messages.firstIndex(where: { $0.messageIdHex == message.messageIdHex }) {
                messages[index] = message
            } else {
                messages.append(message)
            }
        }
    }
#endif
