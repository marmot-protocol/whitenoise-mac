//
//  RemoteMediaTransport.swift
//  whitenoise-mac
//
//  The pinned HTTPS GET used for every peer-controlled remote image/media URL. It admits the
//  URL, resolves the name once, admits the complete answer set, dials only those numeric
//  addresses while TLS still authenticates the original name, and parses the response with
//  explicit bounds. There is no URLSession fallback. See docs/remote-media-transport.md.
//

import Foundation

// MARK: - Clock

/// Cancellable one-shot timer handle.
nonisolated protocol RemoteMediaScheduledTimer: Sendable {
    func cancel()
}

/// Monotonic time plus one-shot timers, injectable so deadline/idle races can be driven by a
/// virtual clock in tests instead of real sleeps.
nonisolated protocol RemoteMediaClock: Sendable {
    func now() -> ContinuousClock.Instant
    /// Calls `action` once at or after `deadline` unless the returned handle is cancelled first.
    /// Must not call `action` synchronously from inside `schedule`.
    func schedule(
        at deadline: ContinuousClock.Instant,
        _ action: @escaping @Sendable () -> Void
    ) -> any RemoteMediaScheduledTimer
}

nonisolated struct SystemRemoteMediaClock: RemoteMediaClock {
    private nonisolated struct TaskTimer: RemoteMediaScheduledTimer {
        let task: Task<Void, Never>
        func cancel() { task.cancel() }
    }

    func now() -> ContinuousClock.Instant { ContinuousClock.now }

    func schedule(
        at deadline: ContinuousClock.Instant,
        _ action: @escaping @Sendable () -> Void
    ) -> any RemoteMediaScheduledTimer {
        TaskTimer(
            task: Task.detached(priority: .utility) {
                do {
                    try await Task.sleep(until: deadline, clock: .continuous)
                } catch {
                    return
                }
                action()
            })
    }
}

// MARK: - Completion gate

/// Bridges one callback-based operation to one continuation, exactly once.
///
/// Completion can come from the operation, the timer, or task cancellation, in any order and on
/// any thread — including *before* the continuation is installed (a pre-cancelled task, a timer
/// that fired first). The lock only records the outcome; the continuation is always resumed
/// outside it.
nonisolated final class RemoteMediaCompletionGate<Value: Sendable>: @unchecked Sendable {
    private enum State {
        case waiting
        case installed(CheckedContinuation<Value, any Error>)
        case delivered(Result<Value, any Error>)
        case finished
    }

    private let lock = NSLock()
    private var state = State.waiting

    var isPending: Bool {
        lock.lock()
        defer { lock.unlock() }
        switch state {
        case .waiting, .installed: return true
        case .delivered, .finished: return false
        }
    }

    /// Installs the awaiting continuation. Returns `true` when the operation should now start;
    /// `false` when an outcome was already recorded (the continuation has been resumed with it).
    func install(_ continuation: CheckedContinuation<Value, any Error>) -> Bool {
        lock.lock()
        switch state {
        case .waiting:
            state = .installed(continuation)
            lock.unlock()
            return true
        case .delivered(let result):
            state = .finished
            lock.unlock()
            continuation.resume(with: result)
            return false
        case .installed, .finished:
            lock.unlock()
            continuation.resume(throwing: RemoteMediaTransportError.cancelled)
            return false
        }
    }

    /// Records `result` if nothing else has. Returns `true` for the single winning call.
    @discardableResult
    func complete(_ result: Result<Value, any Error>) -> Bool {
        lock.lock()
        switch state {
        case .waiting:
            state = .delivered(result)
            lock.unlock()
            return true
        case .installed(let continuation):
            state = .finished
            lock.unlock()
            continuation.resume(with: result)
            return true
        case .delivered, .finished:
            lock.unlock()
            return false
        }
    }
}

// MARK: - Connection seam

nonisolated struct RemoteMediaReceivedChunk: Sendable {
    let data: Data
    /// The peer closed its sending side.
    let isComplete: Bool
    let error: (any Error)?
}

/// One TLS connection to one numeric endpoint. Every completion must be called at most once,
/// may arrive on any thread, and must eventually arrive (with an error) after `cancel()`.
nonisolated protocol RemoteMediaConnection: AnyObject, Sendable {
    func start(_ completion: @escaping @Sendable ((any Error)?) -> Void)
    func send(_ data: Data, _ completion: @escaping @Sendable ((any Error)?) -> Void)
    func receive(maximumLength: Int, _ completion: @escaping @Sendable (RemoteMediaReceivedChunk) -> Void)
    func cancel()
}

nonisolated protocol RemoteMediaConnectionFactory: Sendable {
    func makeConnection(to endpoint: RemoteMediaEndpoint) -> any RemoteMediaConnection
}

// MARK: - Concurrency slots

/// A per-host cap on in-flight fetches so a screen of avatars from one host queues cleanly
/// instead of opening dozens of simultaneous TLS handshakes, while a slow host cannot block
/// fetches to other hosts.
nonisolated final class RemoteMediaFetchSlots: @unchecked Sendable {
    static let maximumConcurrentFetchesPerHost = 6
    static let processWide = RemoteMediaFetchSlots(limitPerHost: maximumConcurrentFetchesPerHost)

    private struct HostState {
        var inUse = 0
        var queue: [(UUID, @Sendable () -> Void)] = []
    }

    let limitPerHost: Int
    private let lock = NSLock()
    private var hosts: [RemoteMediaRequestTarget.Origin: HostState] = [:]
    #if DEBUG
        private let onStateChange: (@Sendable () -> Void)?

        init(limitPerHost: Int, onStateChange: (@Sendable () -> Void)? = nil) {
            self.limitPerHost = max(1, limitPerHost)
            self.onStateChange = onStateChange
        }
    #else
        init(limitPerHost: Int) {
            self.limitPerHost = max(1, limitPerHost)
        }
    #endif

    private func notifyStateChange() {
        #if DEBUG
            onStateChange?()
        #endif
    }

    func inUseCount(for origin: RemoteMediaRequestTarget.Origin) -> Int {
        lock.lock()
        defer { lock.unlock() }
        return hosts[origin]?.inUse ?? 0
    }

    func queuedCount(for origin: RemoteMediaRequestTarget.Origin) -> Int {
        lock.lock()
        defer { lock.unlock() }
        return hosts[origin]?.queue.count ?? 0
    }

    /// Grants a slot immediately (returning `nil`) or enqueues `grant` in FIFO order and returns
    /// a cancellation ticket.
    func request(
        for origin: RemoteMediaRequestTarget.Origin,
        _ grant: @escaping @Sendable () -> Void
    ) -> UUID? {
        lock.lock()
        var state = hosts[origin] ?? HostState()
        if state.inUse < limitPerHost, state.queue.isEmpty {
            state.inUse += 1
            hosts[origin] = state
            lock.unlock()
            notifyStateChange()
            grant()
            return nil
        }
        let ticket = UUID()
        state.queue.append((ticket, grant))
        hosts[origin] = state
        lock.unlock()
        notifyStateChange()
        return ticket
    }

    func cancelWaiter(_ ticket: UUID, for origin: RemoteMediaRequestTarget.Origin) {
        lock.lock()
        guard var state = hosts[origin] else {
            lock.unlock()
            return
        }
        state.queue.removeAll { $0.0 == ticket }
        if state.inUse == 0, state.queue.isEmpty {
            hosts.removeValue(forKey: origin)
        } else {
            hosts[origin] = state
        }
        lock.unlock()
        notifyStateChange()
    }

    func release(for origin: RemoteMediaRequestTarget.Origin) {
        lock.lock()
        guard var state = hosts[origin] else {
            lock.unlock()
            return
        }
        state.inUse = max(0, state.inUse - 1)
        let next: (@Sendable () -> Void)?
        if !state.queue.isEmpty {
            next = state.queue.removeFirst().1
            state.inUse += 1
        } else {
            next = nil
        }
        if state.inUse == 0, state.queue.isEmpty {
            hosts.removeValue(forKey: origin)
        } else {
            hosts[origin] = state
        }
        lock.unlock()
        notifyStateChange()
        next?()
    }
}

/// Ensures one fetch-slot request releases its queued ticket or acquired slot at most once, even
/// when cancellation or deadline expiration races the slot grant.
private nonisolated final class RemoteMediaFetchPermit: @unchecked Sendable {
    private enum State {
        case pending(UUID?)
        case acquired
        case released
    }

    private let origin: RemoteMediaRequestTarget.Origin
    private let slots: RemoteMediaFetchSlots
    private let lock = NSLock()
    private var state = State.pending(nil)

    init(origin: RemoteMediaRequestTarget.Origin, slots: RemoteMediaFetchSlots) {
        self.origin = origin
        self.slots = slots
    }

    func install(_ ticket: UUID?) {
        guard let ticket else { return }
        lock.lock()
        switch state {
        case .pending:
            state = .pending(ticket)
            lock.unlock()
        case .acquired:
            lock.unlock()
        case .released:
            lock.unlock()
            slots.cancelWaiter(ticket, for: origin)
        }
    }

    /// Transitions a pending permit to acquired. Returns `false` if already abandoned, in which
    /// case the caller must immediately release the slot back to `slots`.
    func markAcquired() -> Bool {
        lock.lock()
        switch state {
        case .pending:
            state = .acquired
            lock.unlock()
            return true
        case .acquired, .released:
            lock.unlock()
            return false
        }
    }

    func release() {
        lock.lock()
        let previous = state
        state = .released
        lock.unlock()
        switch previous {
        case .pending(let ticket?):
            slots.cancelWaiter(ticket, for: origin)
        case .acquired:
            slots.release(for: origin)
        case .pending(nil), .released:
            break
        }
    }
}

// MARK: - Transport

nonisolated struct RemoteMediaFetchResult: Sendable {
    /// The URL whose response this is — the last redirect hop.
    let url: URL
    let body: Data
    let head: RemoteMediaHTTPResponseHead
}

nonisolated struct RemoteMediaTransport: Sendable {
    /// Total budget for one fetch: DNS, every address attempt, and every redirect hop.
    static let totalDeadline = Duration.seconds(RemoteImageURLPolicy.downloadResourceTimeout)
    /// Maximum gap between real network progress (connected, request sent, non-empty bytes
    /// received). Progress resets it; it never extends `totalDeadline`.
    static let idleTimeout = Duration.seconds(RemoteImageURLPolicy.downloadStallTimeout)
    static let maximumRedirects = 5
    static let receiveChunkBytes = 64 * 1024

    static let live = RemoteMediaTransport(
        resolver: SystemRemoteMediaResolver(),
        connectionFactory: NetworkRemoteMediaConnectionFactory(),
        clock: SystemRemoteMediaClock(),
        dnsSlots: .processWide,
        fetchSlots: .processWide
    )

    private let resolver: any RemoteMediaResolving
    private let connectionFactory: any RemoteMediaConnectionFactory
    private let clock: any RemoteMediaClock
    private let dnsSlots: RemoteMediaDNSSlots
    private let fetchSlots: RemoteMediaFetchSlots

    private init(
        resolver: any RemoteMediaResolving,
        connectionFactory: any RemoteMediaConnectionFactory,
        clock: any RemoteMediaClock,
        dnsSlots: RemoteMediaDNSSlots,
        fetchSlots: RemoteMediaFetchSlots
    ) {
        self.resolver = resolver
        self.connectionFactory = connectionFactory
        self.clock = clock
        self.dnsSlots = dnsSlots
        self.fetchSlots = fetchSlots
    }

    #if DEBUG
        /// Test seam: substitutes the resolver, the socket layer, and time. Admission, answer
        /// validation, framing and every bound still run unchanged.
        init(
            testingResolver resolver: any RemoteMediaResolving,
            connectionFactory: any RemoteMediaConnectionFactory,
            clock: any RemoteMediaClock,
            dnsSlots: RemoteMediaDNSSlots,
            fetchSlots: RemoteMediaFetchSlots = RemoteMediaFetchSlots(
                limitPerHost: RemoteMediaFetchSlots.maximumConcurrentFetchesPerHost)
        ) {
            self.init(
                resolver: resolver,
                connectionFactory: connectionFactory,
                clock: clock,
                dnsSlots: dnsSlots,
                fetchSlots: fetchSlots
            )
        }
    #endif

    /// Fetches `url`, following at most `maximumRedirects` redirects. Every hop — including a
    /// same-host one — is re-admitted by `RemoteImageURLPolicy`, re-resolved, and re-admitted
    /// by answer set.
    @concurrent
    func fetch(_ url: URL, accept: String = "*/*") async throws -> RemoteMediaFetchResult {
        // Established before DNS, shared by every address and every hop.
        let deadline = clock.now().advanced(by: Self.totalDeadline)
        var current = url
        var redirects = 0
        while true {
            if Task.isCancelled { throw RemoteMediaTransportError.cancelled }
            guard clock.now() < deadline else { throw RemoteMediaTransportError.deadlineExceeded }
            guard RemoteImageURLPolicy.isAllowed(current) else { throw RemoteMediaTransportError.disallowedURL }
            let target = try RemoteMediaRequestTarget(url: current)
            let exchange = try await withFetchSlot(for: target.origin, deadline: deadline) {
                let addresses = try await admittedAddresses(for: target, deadline: deadline)
                let request = RemoteMediaHTTPRequest.bytes(for: target, accept: accept)
                return try await exchange(
                    request: request, addresses: addresses, target: target, deadline: deadline)
            }
            let status = exchange.head.statusCode
            switch status {
            case 301, 302, 303, 307, 308:
                redirects += 1
                guard redirects <= Self.maximumRedirects else { throw RemoteMediaTransportError.tooManyRedirects }
                current = try Self.redirectURL(from: exchange.head, relativeTo: current)
            case _ where Self.isAcceptedSuccess(status):
                return RemoteMediaFetchResult(url: current, body: exchange.body, head: exchange.head)
            default:
                throw RemoteMediaTransportError.httpStatus(status)
            }
        }
    }

    private func withFetchSlot<Value>(
        for origin: RemoteMediaRequestTarget.Origin,
        deadline: ContinuousClock.Instant,
        operation: () async throws -> Value
    ) async throws -> Value {
        let slots = fetchSlots
        let permit = RemoteMediaFetchPermit(origin: origin, slots: slots)
        try await awaitOperation(
            until: deadline,
            timeoutError: .deadlineExceeded,
            abandon: { permit.release() },
            start: { (gate: RemoteMediaCompletionGate<Void>) in
                let ticket = slots.request(for: origin) {
                    guard permit.markAcquired() else {
                        slots.release(for: origin)
                        return
                    }
                    if !gate.complete(.success(())) {
                        permit.release()
                    }
                }
                permit.install(ticket)
            }
        )
        defer { permit.release() }
        return try await operation()
    }

    /// `2xx` except `206`: no range was requested, so a partial body is never the image.
    static func isAcceptedSuccess(_ status: Int) -> Bool {
        (200...299).contains(status) && status != 206
    }

    static func redirectURL(from head: RemoteMediaHTTPResponseHead, relativeTo base: URL) throws -> URL {
        let locations = head.values(for: "location")
        guard locations.count == 1, !locations[0].isEmpty,
            let resolved = URL(string: locations[0], relativeTo: base)?.absoluteURL
        else { throw RemoteMediaTransportError.invalidRedirect }
        return resolved
    }

    // MARK: Resolution

    private func admittedAddresses(
        for target: RemoteMediaRequestTarget,
        deadline: ContinuousClock.Instant
    ) async throws -> [RemoteMediaAddress] {
        switch target.origin {
        case .address(let address):
            return [address]
        case .name(let host):
            let resolver = self.resolver
            let slots = dnsSlots
            let ticket = RemoteMediaDNSWaitTicket()
            let answer = try await awaitOperation(
                until: deadline,
                timeoutError: .deadlineExceeded,
                abandon: { ticket.cancel(slots: slots) },
                start: { (gate: RemoteMediaCompletionGate<RemoteMediaResolverAnswer>) in
                    // Held until the worker actually returns, even after caller cancellation.
                    let queued = slots.request { admitted in
                        guard admitted else {
                            gate.complete(.failure(RemoteMediaTransportError.dnsUnavailable))
                            return
                        }
                        guard gate.isPending else {
                            slots.release()
                            return
                        }
                        resolver.resolve(host: host) { answer in
                            slots.release()
                            // A late answer loses to timeout/cancel; it can never initiate a dial.
                            gate.complete(.success(answer))
                        }
                    }
                    ticket.install(queued, slots: slots)
                }
            )
            return try RemoteMediaResolution.admittedAddresses(answer)
        }
    }

    // MARK: Exchange

    private struct Exchange {
        let head: RemoteMediaHTTPResponseHead
        let body: Data
    }

    /// Marks an attempt failure that happened before any response byte was processed, which is
    /// the only kind that may move on to the next admitted address.
    private struct RetryableAttemptFailure: Error {
        let underlying: RemoteMediaTransportError
    }

    private func exchange(
        request: Data,
        addresses: [RemoteMediaAddress],
        target: RemoteMediaRequestTarget,
        deadline: ContinuousClock.Instant
    ) async throws -> Exchange {
        var lastError = RemoteMediaTransportError.connectionFailed
        for address in addresses {
            if Task.isCancelled { throw RemoteMediaTransportError.cancelled }
            guard clock.now() < deadline else { throw RemoteMediaTransportError.deadlineExceeded }
            let endpoint = RemoteMediaEndpoint(
                address: address,
                port: target.port,
                tlsServerName: target.tlsServerName
            )
            let connection = connectionFactory.makeConnection(to: endpoint)
            do {
                defer { connection.cancel() }
                return try await exchange(on: connection, request: request, deadline: deadline)
            } catch let failure as RetryableAttemptFailure {
                lastError = failure.underlying
            }
        }
        throw lastError
    }

    private func exchange(
        on connection: any RemoteMediaConnection,
        request: Data,
        deadline: ContinuousClock.Instant
    ) async throws -> Exchange {
        var lastProgress = clock.now()
        let abandon: @Sendable () -> Void = { connection.cancel() }

        func stage<Value: Sendable>(
            retryable: Bool,
            _ start: (RemoteMediaCompletionGate<Value>) -> Void
        ) async throws -> Value {
            let idleDeadline = lastProgress.advanced(by: Self.idleTimeout)
            let bound = min(idleDeadline, deadline)
            let timeoutError: RemoteMediaTransportError = bound < deadline ? .idleTimeout : .deadlineExceeded
            do {
                return try await awaitOperation(
                    until: bound, timeoutError: timeoutError, abandon: abandon, start: start)
            } catch let error as RemoteMediaTransportError {
                // Cancellation and the global deadline end the whole fetch; only a stall or a
                // socket/TLS failure before any response byte may try the next address.
                if retryable, error != .cancelled, error != .deadlineExceeded {
                    throw RetryableAttemptFailure(underlying: error)
                }
                throw error
            }
        }

        try await stage(retryable: true) { (gate: RemoteMediaCompletionGate<Void>) in
            connection.start { error in
                if error == nil {
                    gate.complete(.success(()))
                } else {
                    gate.complete(.failure(RemoteMediaTransportError.connectionFailed))
                }
            }
        }
        lastProgress = clock.now()

        try await stage(retryable: true) { (gate: RemoteMediaCompletionGate<Void>) in
            connection.send(request) { error in
                if error == nil {
                    gate.complete(.success(()))
                } else {
                    gate.complete(.failure(RemoteMediaTransportError.connectionFailed))
                }
            }
        }
        lastProgress = clock.now()

        var parser = RemoteMediaHTTPResponseParser()
        var receivedAnyByte = false
        while true {
            let chunk = try await stage(
                retryable: !receivedAnyByte
            ) { (gate: RemoteMediaCompletionGate<RemoteMediaReceivedChunk>) in
                connection.receive(maximumLength: Self.receiveChunkBytes) { chunk in
                    if chunk.error != nil {
                        gate.complete(.failure(RemoteMediaTransportError.connectionFailed))
                    } else {
                        gate.complete(.success(chunk))
                    }
                }
            }

            var progress = RemoteMediaHTTPResponseParser.Progress.needsMoreData
            if chunk.data.isEmpty, chunk.isComplete, !receivedAnyByte {
                // Closed before saying anything: a transport failure, not an HTTP one.
                throw RetryableAttemptFailure(underlying: .prematureEOF)
            }
            if !chunk.data.isEmpty {
                guard chunk.data.count <= Self.receiveChunkBytes else {
                    throw RemoteMediaTransportError.malformedResponse
                }
                receivedAnyByte = true
                lastProgress = clock.now()
                progress = try parser.consume(chunk.data)
            }

            if progress == .headReceived, let head = parser.head {
                guard Self.isAcceptedSuccess(head.statusCode) else {
                    // Redirects and errors close right after the head; their bodies are never
                    // drained, framed, or buffered.
                    return Exchange(head: head, body: Data())
                }
                progress = try parser.beginBody()
            }

            if progress != .complete, chunk.isComplete {
                progress = try parser.finishAtEOF()
            }

            if progress == .complete, let head = parser.head {
                guard !Task.isCancelled else { throw RemoteMediaTransportError.cancelled }
                guard clock.now() < deadline else { throw RemoteMediaTransportError.deadlineExceeded }
                return Exchange(head: head, body: parser.body)
            }
            if chunk.isComplete {
                throw RemoteMediaTransportError.prematureEOF
            }
        }
    }

    // MARK: Waiting

    /// Waits for one callback-based operation, bounded by `until` and by task cancellation,
    /// without ever waiting for the operation itself to wind down.
    ///
    /// A timeout or cancellation completes the gate first and then calls `abandon` (closing the
    /// socket); any completion the operation delivers afterwards is dropped by the gate.
    private func awaitOperation<Value: Sendable>(
        until bound: ContinuousClock.Instant,
        timeoutError: RemoteMediaTransportError,
        abandon: @escaping @Sendable () -> Void,
        start: (RemoteMediaCompletionGate<Value>) -> Void
    ) async throws -> Value {
        if Task.isCancelled { throw RemoteMediaTransportError.cancelled }
        guard clock.now() < bound else {
            abandon()
            throw timeoutError
        }
        let gate = RemoteMediaCompletionGate<Value>()
        let timer = clock.schedule(at: bound) {
            if gate.complete(.failure(timeoutError)) { abandon() }
        }
        defer { timer.cancel() }
        let value = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Value, any Error>) in
                if gate.install(continuation) {
                    start(gate)
                }
            }
        } onCancel: {
            if gate.complete(.failure(RemoteMediaTransportError.cancelled)) { abandon() }
        }
        // Timer delivery may be delayed by executor pressure: time, not callback order, wins.
        if Task.isCancelled {
            abandon()
            throw RemoteMediaTransportError.cancelled
        }
        guard clock.now() < bound else {
            abandon()
            throw timeoutError
        }
        return value
    }
}
