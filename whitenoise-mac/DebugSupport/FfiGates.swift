// coverage:ignore-file
//  Test support compiled into DEBUG app builds alongside `FakeMarmotRuntime`, which needs it.
//  See that file for why it lives in the app target. Ignored by coverage: it is a test double.

#if DEBUG
    import Foundation

    nonisolated final class BlockingFfiGate: @unchecked Sendable {
        private let lock = NSLock()
        private var enabled = false
        private var semaphore: DispatchSemaphore?
        private var reached = false

        var isEnabled: Bool {
            get { lock.withLock { enabled } }
            set { lock.withLock { enabled = newValue } }
        }

        var didReach: Bool {
            lock.withLock { reached }
        }

        func passIfArmed() {
            let semaphore = lock.withLock { () -> DispatchSemaphore? in
                guard enabled, self.semaphore == nil, !reached else { return nil }
                reached = true
                let semaphore = DispatchSemaphore(value: 0)
                self.semaphore = semaphore
                return semaphore
            }
            semaphore?.wait()
        }

        func release() {
            let semaphore = lock.withLock { () -> DispatchSemaphore? in
                let semaphore = self.semaphore
                self.semaphore = nil
                return semaphore
            }
            semaphore?.signal()
        }
    }

    nonisolated final class AsyncFfiGate: @unchecked Sendable {
        private let lock = NSLock()
        private var enabled = false
        private var reached = false
        private var released = false
        private var continuation: CheckedContinuation<Void, Never>?
        private var reachWaiters: [CheckedContinuation<Void, Never>] = []

        var isEnabled: Bool {
            get { lock.withLock { enabled } }
            set { lock.withLock { enabled = newValue } }
        }

        var didReach: Bool {
            lock.withLock { reached }
        }

        func passIfArmed() async {
            let shouldSuspend = lock.withLock {
                enabled && continuation == nil && !reached
            }
            guard shouldSuspend else { return }
            await withCheckedContinuation { continuation in
                let (resumeImmediately, waiters) = lock.withLock { () -> (Bool, [CheckedContinuation<Void, Never>]) in
                    self.continuation = continuation
                    reached = true
                    let waiters = reachWaiters
                    reachWaiters = []
                    if released {
                        self.continuation = nil
                        return (true, waiters)
                    }
                    return (false, waiters)
                }
                waiters.forEach { $0.resume() }
                if resumeImmediately {
                    continuation.resume()
                }
            }
        }

        /// Returns once an armed call has parked on the gate — a handle to await instead of polling
        /// `didReach`.
        func waitUntilReached() async {
            await withCheckedContinuation { waiter in
                let alreadyReached = lock.withLock { () -> Bool in
                    if reached { return true }
                    reachWaiters.append(waiter)
                    return false
                }
                if alreadyReached { waiter.resume() }
            }
        }

        func release() {
            let continuation = lock.withLock { () -> CheckedContinuation<Void, Never>? in
                released = true
                let continuation = self.continuation
                self.continuation = nil
                return continuation
            }
            continuation?.resume()
        }
    }
#endif
