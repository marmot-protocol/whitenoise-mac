//
//  AttachmentHandoff.swift
//  whitenoise-mac
//
//  MDK's handoff leases: a private plaintext copy of one retained attachment, lent for a surface
//  outside the app — opening a document in another app, or saving it where the user chose. The
//  copy carries the attachment's real file name and lives under the account's `handoff/` folder
//  until it is released; MDK wipes any copy left behind on the next process start.
//
//  Ported from whitenoise-ios's `AttachmentHandoff.swift` (whitenoise-ios#1201). In-app display
//  and playback stay on `readAttachmentAsset`; only bytes MDK has no slot for (an outgoing send
//  it does not hold yet) use the host's own scratch export.
//

import Foundation
import MarmotKit
import Synchronization
import os

/// MDK's handoff release, narrowed so release retries can be tested without a runtime.
nonisolated protocol AttachmentHandoffReleasing: Sendable {
    func releaseAttachmentHandoff(lease: String) async throws
}

/// Releases through one runtime.
nonisolated struct RuntimeHandoffReleaser: AttachmentHandoffReleasing {
    let runtime: any MarmotRuntime

    func releaseAttachmentHandoff(lease: String) async throws {
        try await runtime.releaseAttachmentHandoff(lease: lease)
    }
}

/// Releases through whichever runtime is open when the release runs. Leases are process-wide,
/// but the runtime that opened one can be replaced (a relaunch of the core after an account
/// change) before the release runs.
nonisolated struct LiveRuntimeHandoffReleaser: AttachmentHandoffReleasing {
    /// No open runtime yet; a later attempt finds one.
    struct Unavailable: Error {}

    let live: @Sendable () async -> (any AttachmentHandoffReleasing)?

    func releaseAttachmentHandoff(lease: String) async throws {
        guard let runtime = await live() else { throw Unavailable() }
        try await runtime.releaseAttachmentHandoff(lease: lease)
    }
}

/// A private plaintext copy MDK lent for an OS surface. Release it when the surface is done with
/// it. Release is idempotent, and dropping the last reference releases as a backstop.
nonisolated final class AttachmentHandoffLease: Sendable {
    let url: URL
    private let lease: String
    private let releaser: any AttachmentHandoffReleasing
    private let isReleased = Mutex(false)

    init(lease: String, path: String, releaser: any AttachmentHandoffReleasing) {
        url = URL(fileURLWithPath: path, isDirectory: false)
        self.lease = lease
        self.releaser = releaser
    }

    convenience init(_ handoff: AttachmentHandoffFfi, releaser: any AttachmentHandoffReleasing) {
        self.init(lease: handoff.lease, path: handoff.path, releaser: releaser)
    }

    /// Deletes the copy; never use `url` afterwards. Returns nil when already released.
    @discardableResult
    func release() -> Task<AttachmentHandoffRelease.Outcome, Never>? {
        let isFirst = isReleased.withLock { released in
            defer { released = true }
            return !released
        }
        guard isFirst else { return nil }
        let lease = lease
        let releaser = releaser
        // Nobody cancels this task: the copy holds plaintext until MDK deletes it.
        return Task.detached(priority: .utility) {
            await AttachmentHandoffRelease.run(lease: lease, using: releaser)
        }
    }

    deinit { release() }
}

nonisolated enum AttachmentHandoffRelease {
    enum Outcome: Equatable, Sendable {
        case released
        /// A malformed lease, which no retry fixes.
        case rejected
        /// Still not released after every attempt; MDK wipes it on the next process start.
        case abandoned
    }

    static let maxAttempts = 10

    private static let log = Logger(subsystem: "com.whitenoise.media", category: "AttachmentHandoff")

    /// MDK keeps a copy it could not delete leased (`Io`). A runtime that closed under the call,
    /// or none open yet, is retried against the next open runtime.
    static func isRetryable(_ error: Error) -> Bool {
        if case MarmotKitError.Io = error { return true }
        if case MarmotKitError.StorageClosed = error { return true }
        return error is LiveRuntimeHandoffReleaser.Unavailable
    }

    /// Doubles from 250 ms up to 30 s, about 90 s in all.
    static func retryDelay(afterAttempt attempt: Int) -> Duration {
        min(.milliseconds(250 * (1 << min(max(attempt - 1, 0), 7))), .seconds(30))
    }

    static func run(
        lease: String,
        using releaser: some AttachmentHandoffReleasing,
        sleep: (Duration) async -> Void = { try? await Task.sleep(for: $0) }
    ) async -> Outcome {
        for attempt in 1...maxAttempts {
            do {
                try await releaser.releaseAttachmentHandoff(lease: lease)
                return .released
            } catch {
                guard isRetryable(error) else {
                    log.error(
                        "Attachment handoff release rejected: \(String(describing: type(of: error)), privacy: .public)"
                    )
                    return .rejected
                }
                if attempt < maxAttempts { await sleep(retryDelay(afterAttempt: attempt)) }
            }
        }
        log.error("Attachment handoff copy still not released after \(maxAttempts, privacy: .public) attempts")
        return .abandoned
    }
}

/// Why a document could not be handed to another app.
nonisolated enum AttachmentHandoffFailure: Error, Equatable {
    /// MDK holds no local copy, even after the download settled.
    case notHeldLocally
    /// No room for the plaintext copy beyond MDK's disk reserve.
    case storageFull
}

nonisolated enum AttachmentHandoffOpening {
    /// Opens from retained bytes first so a held document never passes through app memory. A miss
    /// returns nil when the host still has the bytes (this device's own send, or a download the
    /// host already holds), and otherwise acquires before one more attempt.
    static func open<Handoff>(
        handoff: () async throws -> Handoff?,
        hostHasBytes: Bool,
        acquire: () async throws -> Void
    ) async throws -> Handoff? {
        if let opened = try await handoff() { return opened }
        if hostHasBytes { return nil }
        try await acquire()
        guard let opened = try await handoff() else { throw AttachmentHandoffFailure.notHeldLocally }
        return opened
    }

    /// A copy cancelled through its control surfaces as an invalid-media error.
    static func failure(for error: Error, controlCancelled: Bool) -> Error {
        if controlCancelled { return CancellationError() }
        if case MarmotKitError.StorageFull = error { return AttachmentHandoffFailure.storageFull }
        return error
    }

    /// Awaits `call` in a task nobody cancels: cancelling a task awaiting `openAttachmentHandoff`
    /// can drop a finished lease, so a cancelled caller cancels through `control` instead.
    static func shielded<T: Sendable>(
        cancel: @escaping @Sendable () -> Void,
        _ call: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        let task = Task.detached(priority: .userInitiated) { try await call() }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            cancel()
        }
    }

    /// MDK's leased copy of one retained slot, or nil when MDK does not hold it and the host does.
    /// A lease that arrives after the caller gave up is released rather than returned.
    static func openLease(
        runtime: any MarmotRuntime,
        accountRef: String,
        groupIdHex: String,
        target: AttachmentLocalTargetFfi,
        control: MediaFileTransferControlFfi,
        releaser: any AttachmentHandoffReleasing,
        hostHasBytes: Bool,
        acquire: () async throws -> Void = {}
    ) async throws -> AttachmentHandoffLease? {
        do {
            let lease = try await open(
                handoff: {
                    try await shielded(cancel: { control.cancel() }) {
                        try await runtime.openAttachmentHandoff(
                            accountRef: accountRef, groupIdHex: groupIdHex, target: target, control: control
                        ).map { AttachmentHandoffLease($0, releaser: releaser) }
                    }
                },
                hostHasBytes: hostHasBytes,
                acquire: acquire
            )
            if let lease, Task.isCancelled || control.isCancelled() {
                lease.release()
                throw CancellationError()
            }
            return lease
        } catch {
            throw failure(for: error, controlCancelled: control.isCancelled())
        }
    }
}
