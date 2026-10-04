//
//  RemoteMediaTransportFakes.swift
//  whitenoise-macTests
//
//  Deterministic doubles for `RemoteMediaTransport`: a virtual clock whose timers fire only when
//  a test advances it, a resolver whose answers can be held and released, and connections whose
//  every byte is scripted. Nothing here opens a socket, resolves a name, or sleeps.
//

import Foundation
import Testing

@testable import whitenoise_mac

/// Lets a test wait for a fake's state to change without polling or sleeping. Every fake bumps
/// the version after mutating; `wait(until:)` re-checks only when the version moved.
final class RemoteMediaFakeSignal: @unchecked Sendable {
    private let lock = NSLock()
    private var version = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func bump() {
        lock.lock()
        version += 1
        let ready = waiters
        waiters.removeAll()
        lock.unlock()
        ready.forEach { $0.resume() }
    }

    func wait(until predicate: () -> Bool) async {
        while true {
            let seen = currentVersion
            if predicate() { return }
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                lock.lock()
                if version != seen {
                    lock.unlock()
                    continuation.resume()
                    return
                }
                waiters.append(continuation)
                lock.unlock()
            }
        }
    }

    private var currentVersion: Int {
        lock.lock()
        defer { lock.unlock() }
        return version
    }
}

/// Virtual monotonic time. Timers fire only from `advance(by:)`, in deadline order.
final class VirtualRemoteMediaClock: RemoteMediaClock, @unchecked Sendable {
    private struct PendingTimer {
        let id: Int
        let deadline: ContinuousClock.Instant
        let action: @Sendable () -> Void
    }

    private struct Handle: RemoteMediaScheduledTimer {
        let clock: VirtualRemoteMediaClock
        let id: Int
        func cancel() { clock.cancelTimer(id) }
    }

    private let signal: RemoteMediaFakeSignal
    private let lock = NSLock()
    private let origin = ContinuousClock.now
    private var elapsed = Duration.zero
    private var timers: [PendingTimer] = []
    private var nextID = 0

    init(signal: RemoteMediaFakeSignal) {
        self.signal = signal
    }

    func now() -> ContinuousClock.Instant {
        lock.lock()
        defer { lock.unlock() }
        return origin.advanced(by: elapsed)
    }

    func schedule(
        at deadline: ContinuousClock.Instant,
        _ action: @escaping @Sendable () -> Void
    ) -> any RemoteMediaScheduledTimer {
        lock.lock()
        let id = nextID
        nextID += 1
        timers.append(PendingTimer(id: id, deadline: deadline, action: action))
        lock.unlock()
        signal.bump()
        return Handle(clock: self, id: id)
    }

    var pendingTimerCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return timers.count
    }

    func advance(by duration: Duration, fireTimers: Bool = true) {
        lock.lock()
        elapsed += duration
        let now = origin.advanced(by: elapsed)
        let due = fireTimers ? timers.filter { $0.deadline <= now }.sorted { $0.deadline < $1.deadline } : []
        if fireTimers { timers.removeAll { $0.deadline <= now } }
        lock.unlock()
        due.forEach { $0.action() }
        signal.bump()
    }

    fileprivate func cancelTimer(_ id: Int) {
        lock.lock()
        timers.removeAll { $0.id == id }
        lock.unlock()
        signal.bump()
    }
}

struct RemoteMediaFakeError: Error {}

/// What one fake connection does.
struct RemoteMediaConnectionScript: Sendable {
    enum Start: Sendable {
        case ready
        case fail
        case hold
    }

    enum End: Sendable {
        /// After the queued chunks, report a clean close.
        case eof
        /// After the queued chunks, leave `receive` pending until the test delivers or cancels.
        case hold
        case error
    }

    var start: Start = .ready
    var sendFails = false
    var chunks: [Data] = []
    var end: End = .eof

    /// Serves `response` in receive-sized chunks, then closes.
    static func serving(_ response: Data) -> RemoteMediaConnectionScript {
        RemoteMediaConnectionScript(chunks: FakeHTTP.split(response))
    }

    /// Connects and sends, then waits for the test to deliver bytes.
    static var held: RemoteMediaConnectionScript {
        RemoteMediaConnectionScript(end: .hold)
    }
}

final class FakeRemoteMediaConnection: RemoteMediaConnection, @unchecked Sendable {
    let endpoint: RemoteMediaEndpoint
    private let signal: RemoteMediaFakeSignal
    private let lock = NSLock()
    private let script: RemoteMediaConnectionScript
    private var queued: [Data]
    private var end: RemoteMediaConnectionScript.End
    private var cancelled = false
    private var pendingStart: (@Sendable ((any Error)?) -> Void)?
    private var pendingReceive: (@Sendable (RemoteMediaReceivedChunk) -> Void)?
    private var sent = Data()
    private var cancels = 0
    private var receives = 0

    init(endpoint: RemoteMediaEndpoint, script: RemoteMediaConnectionScript, signal: RemoteMediaFakeSignal) {
        self.endpoint = endpoint
        self.script = script
        self.queued = script.chunks
        self.end = script.end
        self.signal = signal
    }

    var sentText: String {
        lock.lock()
        defer { lock.unlock() }
        return String(decoding: sent, as: UTF8.self)
    }

    var cancelCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return cancels
    }

    var receiveCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return receives
    }

    var hasPendingReceive: Bool {
        lock.lock()
        defer { lock.unlock() }
        return pendingReceive != nil
    }

    var hasPendingStart: Bool {
        lock.lock()
        defer { lock.unlock() }
        return pendingStart != nil
    }

    func start(_ completion: @escaping @Sendable ((any Error)?) -> Void) {
        defer { signal.bump() }
        switch script.start {
        case .ready:
            completion(nil)
        case .fail:
            completion(RemoteMediaFakeError())
        case .hold:
            lock.lock()
            pendingStart = completion
            lock.unlock()
        }
    }

    func send(_ data: Data, _ completion: @escaping @Sendable ((any Error)?) -> Void) {
        lock.lock()
        sent.append(data)
        lock.unlock()
        completion(script.sendFails ? RemoteMediaFakeError() : nil)
        signal.bump()
    }

    func receive(maximumLength: Int, _ completion: @escaping @Sendable (RemoteMediaReceivedChunk) -> Void) {
        defer { signal.bump() }
        lock.lock()
        receives += 1
        if cancelled {
            lock.unlock()
            completion(RemoteMediaReceivedChunk(data: Data(), isComplete: false, error: RemoteMediaFakeError()))
            return
        }
        if !queued.isEmpty {
            let chunk = queued.removeFirst()
            lock.unlock()
            precondition(chunk.count <= maximumLength, "fake chunk larger than the transport asked for")
            completion(RemoteMediaReceivedChunk(data: chunk, isComplete: false, error: nil))
            return
        }
        switch end {
        case .eof:
            lock.unlock()
            completion(RemoteMediaReceivedChunk(data: Data(), isComplete: true, error: nil))
        case .error:
            lock.unlock()
            completion(RemoteMediaReceivedChunk(data: Data(), isComplete: false, error: RemoteMediaFakeError()))
        case .hold:
            pendingReceive = completion
            lock.unlock()
        }
    }

    func cancel() {
        lock.lock()
        cancels += 1
        cancelled = true
        let start = pendingStart
        let receive = pendingReceive
        pendingStart = nil
        pendingReceive = nil
        lock.unlock()
        // Like NWConnection, cancellation still answers anything outstanding, with an error.
        start?(RemoteMediaFakeError())
        receive?(RemoteMediaReceivedChunk(data: Data(), isComplete: false, error: RemoteMediaFakeError()))
        signal.bump()
    }

    /// Delivers `data` to the pending receive (or queues it), split into receive-sized chunks.
    func deliver(_ data: Data) {
        for chunk in FakeHTTP.split(data) {
            lock.lock()
            if let receive = pendingReceive {
                pendingReceive = nil
                lock.unlock()
                receive(RemoteMediaReceivedChunk(data: chunk, isComplete: false, error: nil))
            } else {
                queued.append(chunk)
                lock.unlock()
            }
        }
        signal.bump()
    }

    /// Completes a held `start`.
    func completeStart() {
        lock.lock()
        let start = pendingStart
        pendingStart = nil
        lock.unlock()
        start?(nil)
        signal.bump()
    }
}

/// Resolver and connection factory in one, recording everything the transport asks for.
final class FakeRemoteMediaNetwork: RemoteMediaResolving, RemoteMediaConnectionFactory, @unchecked Sendable {
    enum DNS: Sendable {
        case answer(RemoteMediaResolverAnswer)
        case hold
    }

    typealias Responder = @Sendable (_ endpoint: RemoteMediaEndpoint, _ index: Int) -> RemoteMediaConnectionScript

    private let signal: RemoteMediaFakeSignal
    private let lock = NSLock()
    private var dns: [String: DNS] = [:]
    private var resolves: [String] = []
    private var held: [(host: String, completion: @Sendable (RemoteMediaResolverAnswer) -> Void)] = []
    private var responder: Responder = { _, _ in .serving(FakeHTTP.response(body: Data("ok".utf8))) }
    private var made: [FakeRemoteMediaConnection] = []

    /// Answer for any host without an explicit `setDNS`.
    static let defaultAnswer = RemoteMediaResolverAnswer.addresses(["93.184.216.34"])

    init(signal: RemoteMediaFakeSignal) {
        self.signal = signal
    }

    func setDNS(_ host: String, _ behavior: DNS) {
        lock.lock()
        dns[host] = behavior
        lock.unlock()
    }

    func respond(_ responder: @escaping Responder) {
        lock.lock()
        self.responder = responder
        lock.unlock()
    }

    var resolveCalls: [String] {
        lock.lock()
        defer { lock.unlock() }
        return resolves
    }

    var heldResolutionCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return held.count
    }

    var connections: [FakeRemoteMediaConnection] {
        lock.lock()
        defer { lock.unlock() }
        return made
    }

    func resolve(host: String, completion: @escaping @Sendable (RemoteMediaResolverAnswer) -> Void) {
        lock.lock()
        resolves.append(host)
        let behavior = dns[host] ?? .answer(Self.defaultAnswer)
        if case .hold = behavior {
            held.append((host, completion))
        }
        lock.unlock()
        if case .answer(let answer) = behavior {
            completion(answer)
        }
        signal.bump()
    }

    /// Lets the oldest held `getaddrinfo` "return", even if its caller has long gone.
    func completeHeldResolution(with answer: RemoteMediaResolverAnswer) {
        lock.lock()
        let next = held.isEmpty ? nil : held.removeFirst()
        lock.unlock()
        next?.completion(answer)
        signal.bump()
    }

    func makeConnection(to endpoint: RemoteMediaEndpoint) -> any RemoteMediaConnection {
        lock.lock()
        let script = responder(endpoint, made.count)
        let connection = FakeRemoteMediaConnection(endpoint: endpoint, script: script, signal: signal)
        made.append(connection)
        lock.unlock()
        signal.bump()
        return connection
    }
}

/// A transport wired entirely to fakes.
struct RemoteMediaFakeHarness {
    let signal: RemoteMediaFakeSignal
    let clock: VirtualRemoteMediaClock
    let network: FakeRemoteMediaNetwork
    let slots: RemoteMediaDNSSlots
    let transport: RemoteMediaTransport

    init(dnsSlotLimit: Int = RemoteMediaDNSSlots.maximumConcurrentResolutions) {
        let signal = RemoteMediaFakeSignal()
        let clock = VirtualRemoteMediaClock(signal: signal)
        let network = FakeRemoteMediaNetwork(signal: signal)
        let slots = RemoteMediaDNSSlots(limit: dnsSlotLimit)
        self.signal = signal
        self.clock = clock
        self.network = network
        self.slots = slots
        self.transport = RemoteMediaTransport(
            testingResolver: network,
            connectionFactory: network,
            clock: clock,
            dnsSlots: slots
        )
    }

    func wait(until predicate: () -> Bool) async {
        await signal.wait(until: predicate)
    }

    /// Runs `fetch` in its own task so a test can drive time and the network while it waits.
    func startFetch(_ url: URL) -> Task<Result<RemoteMediaFetchResult, RemoteMediaTransportError>, Never> {
        let transport = transport
        return Task {
            await Self.outcome { try await transport.fetch(url) }
        }
    }

    static func outcome(
        _ operation: () async throws -> RemoteMediaFetchResult
    ) async -> Result<RemoteMediaFetchResult, RemoteMediaTransportError> {
        do {
            return .success(try await operation())
        } catch let error as RemoteMediaTransportError {
            return .failure(error)
        } catch {
            Issue.record("unexpected error type: \(error)")
            return .failure(.malformedResponse)
        }
    }
}

extension Result where Failure == RemoteMediaTransportError {
    var transportError: RemoteMediaTransportError? {
        if case .failure(let error) = self { return error }
        return nil
    }
}

enum FakeHTTP {
    static func response(
        status: Int = 200,
        reason: String = "OK",
        headers: [(String, String)] = [],
        body: Data = Data(),
        contentLength: Bool = true
    ) -> Data {
        var text = "HTTP/1.1 \(status) \(reason)\r\n"
        for (name, value) in headers {
            text += "\(name): \(value)\r\n"
        }
        if contentLength {
            text += "Content-Length: \(body.count)\r\n"
        }
        text += "\r\n"
        return Data(text.utf8) + body
    }

    static func redirect(status: Int = 302, to location: String) -> Data {
        response(status: status, reason: "Found", headers: [("Location", location)])
    }

    static func split(_ data: Data, size: Int = RemoteMediaTransport.receiveChunkBytes) -> [Data] {
        stride(from: 0, to: data.count, by: size).map { start in
            Data(data[(data.startIndex + start)..<(data.startIndex + min(start + size, data.count))])
        }
    }
}
