import Foundation

private nonisolated final class OffMainCancellationFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }

    func check() throws {
        lock.lock()
        let isCancelled = cancelled
        lock.unlock()
        if isCancelled {
            throw CancellationError()
        }
    }
}

/// Hops blocking MarmotRuntime FFI work off the main actor.
///
/// This is app-wide infrastructure, not workspace state: it knows nothing about accounts, chats, or
/// views, and every layer that needs to call the synchronous Rust core goes through it. It lives in
/// `Core` so any layer can reach the Rust core without depending on `WorkspaceState`.
nonisolated enum FFIExecutor {
    /// Dedicated queue for blocking MarmotRuntime FFI calls. The Rust core runs
    /// synchronously (DB reads, MLS decryption); the callers are usually `@MainActor`, so
    /// calling these directly freezes the UI. We hop them onto this queue and await the
    /// result on the caller's actor. UniFFI objects are internally thread-safe.
    static let queue = DispatchQueue(
        label: "chat.whitenoise.marmot-ffi",
        qos: .userInitiated,
        attributes: .concurrent
    )

    /// Runs a blocking FFI closure off the main thread and resumes on the caller's actor.
    static func run<T>(
        _ work: @escaping @Sendable () throws -> T
    ) async throws -> T {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<T, Error>) in
            queue.async {
                continuation.resume(with: Result { try work() })
            }
        }
    }

    /// Runs blocking FFI off the main thread while exposing cancellation to the GCD closure.
    /// `Task.checkCancellation()` is only task-local; inside `queue.async` there is no current
    /// Swift task, so long synchronous loops must call the supplied checker instead.
    static func runCancellable<T>(
        _ work: @escaping @Sendable (_ checkCancellation: @escaping @Sendable () throws -> Void) throws -> T
    ) async throws -> T {
        let cancellation = OffMainCancellationFlag()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<T, Error>) in
                queue.async {
                    let checkCancellation: @Sendable () throws -> Void = {
                        try cancellation.check()
                    }
                    continuation.resume(
                        with: Result {
                            try checkCancellation()
                            let value = try work(checkCancellation)
                            try checkCancellation()
                            return value
                        }
                    )
                }
            }
        } onCancel: {
            cancellation.cancel()
        }
    }
}
