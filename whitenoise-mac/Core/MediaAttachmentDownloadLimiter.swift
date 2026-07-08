//
//  MediaAttachmentDownloadLimiter.swift
//  whitenoise-mac
//

import Foundation

/// Bounds concurrent attachment downloads so opening a media-heavy chat cannot spawn
/// unbounded FFI `downloadMedia` calls.
nonisolated enum MediaAttachmentDownloadConcurrency {
    static let maxConcurrentDownloads = 4

    /// Wall-clock ceiling for one attachment's resolve+download FFI while holding a limiter slot.
    /// Matches `RemoteImageURLPolicy.downloadResourceTimeout` so stalled relay fetches cannot
    /// occupy all download slots indefinitely.
    static let defaultFfiDownloadTimeoutNanoseconds: UInt64 = 60 * 1_000_000_000

    #if DEBUG
        static var ffiDownloadTimeoutNanoseconds: UInt64 = defaultFfiDownloadTimeoutNanoseconds
    #else
        static let ffiDownloadTimeoutNanoseconds: UInt64 = defaultFfiDownloadTimeoutNanoseconds
    #endif
}

nonisolated struct MediaAttachmentDownloadTimeoutError: LocalizedError {
    var errorDescription: String? {
        L10n.string("Attachment download timed out")
    }
}

nonisolated func withMediaAttachmentDownloadTimeout<T>(
    nanoseconds: UInt64 = MediaAttachmentDownloadConcurrency.ffiDownloadTimeoutNanoseconds,
    operation: @escaping @Sendable () async throws -> T
) async throws -> T {
    try Task.checkCancellation()
    let race = MediaAttachmentDownloadTimeoutRace(
        nanoseconds: nanoseconds,
        operation: operation
    )
    return try await race.value()
}

private nonisolated final class MediaAttachmentDownloadTimeoutRace<T>: @unchecked Sendable {
    private let nanoseconds: UInt64
    private let operation: @Sendable () async throws -> T
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, Error>?
    private var finished = false
    private var operationTask: Task<Void, Never>?
    private var timeoutTask: Task<Void, Never>?

    init(
        nanoseconds: UInt64,
        operation: @escaping @Sendable () async throws -> T
    ) {
        self.nanoseconds = nanoseconds
        self.operation = operation
    }

    func value() async throws -> T {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                start(continuation)
            }
        } onCancel: {
            finish(.failure(CancellationError()))
        }
    }

    private func start(_ continuation: CheckedContinuation<T, Error>) {
        lock.lock()
        guard !finished else {
            lock.unlock()
            continuation.resume(throwing: CancellationError())
            return
        }

        self.continuation = continuation
        let operationTask = Task { [operation, weak self] in
            do {
                self?.finish(.success(try await operation()))
            } catch {
                self?.finish(.failure(error))
            }
        }
        let timeoutTask = Task { [nanoseconds, weak self] in
            do {
                try await Task.sleep(nanoseconds: nanoseconds)
                self?.finish(.failure(MediaAttachmentDownloadTimeoutError()))
            } catch is CancellationError {
                // Expected when the download wins or the caller is cancelled.
            } catch {
                self?.finish(.failure(error))
            }
        }
        self.operationTask = operationTask
        self.timeoutTask = timeoutTask
        lock.unlock()
    }

    private func finish(_ result: Result<T, Error>) {
        lock.lock()
        guard !finished else {
            lock.unlock()
            return
        }
        finished = true
        let continuation = self.continuation
        self.continuation = nil
        let operationTask = self.operationTask
        let timeoutTask = self.timeoutTask
        self.operationTask = nil
        self.timeoutTask = nil
        lock.unlock()

        operationTask?.cancel()
        timeoutTask?.cancel()
        continuation?.resume(with: result)
    }
}

actor MediaAttachmentDownloadLimiter {
    static let shared = MediaAttachmentDownloadLimiter(
        maxConcurrent: MediaAttachmentDownloadConcurrency.maxConcurrentDownloads
    )

    private struct QueuedWaiter {
        let id: UUID
        let continuation: CheckedContinuation<Void, Error>
    }

    private let maxConcurrent: Int
    private var inFlight = 0
    private var waiters: [QueuedWaiter] = []

    init(maxConcurrent: Int) {
        self.maxConcurrent = max(1, maxConcurrent)
    }

    func acquire() async throws {
        try Task.checkCancellation()
        if inFlight < maxConcurrent {
            inFlight += 1
            return
        }

        let waiterID = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                } else {
                    waiters.append(QueuedWaiter(id: waiterID, continuation: continuation))
                }
            }
        } onCancel: {
            Task { await self.cancelQueuedWaiter(id: waiterID) }
        }
        if Task.isCancelled {
            release()
            throw CancellationError()
        }
    }

    func release() {
        if let waiter = waiters.first {
            waiters.removeFirst()
            waiter.continuation.resume()
        } else {
            inFlight -= 1
        }
    }

    #if DEBUG
        func queuedWaiterCount() -> Int {
            waiters.count
        }
    #endif

    private func cancelQueuedWaiter(id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        let waiter = waiters.remove(at: index)
        waiter.continuation.resume(throwing: CancellationError())
    }
}
