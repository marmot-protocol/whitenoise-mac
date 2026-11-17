import Foundation
import MarmotKit

/// Reads a custom emoji's image from MDK's retained copy of its source slot, the way White Noise
/// for iOS loads every inline emoji: local bytes first, then an automatic request that MDK queues
/// ahead of other automatic work, awaited until the slot is ready.
///
/// `downloadMedia`, which the emoji used before, fetches and decrypts from the media server on
/// every call and retains nothing, so each conversation open paid a network round trip per emoji.
nonisolated enum CustomEmojiRetainedBytes {
    private static let chunkSize: UInt32 = 1_048_576

    /// The slot's bytes, acquiring them through MDK when it holds none yet. Nil when MDK cannot
    /// acquire them automatically (no permission, a terminal or parked transfer) or the subscription
    /// closes before the slot is ready.
    static func acquire(
        runtime: any MarmotRuntime,
        accountRef: String,
        groupIdHex: String,
        target: AttachmentLocalTargetFfi,
        maxBytes: UInt64
    ) async throws -> Data? {
        if let data = try await read(
            runtime: runtime, accountRef: accountRef, groupIdHex: groupIdHex, target: target, maxBytes: maxBytes)
        {
            return data
        }
        let request = try await runtime.requestAutomaticAttachment(
            accountRef: accountRef, groupIdHex: groupIdHex, target: target)
        switch request.status.state.customEmojiAwaitability {
        case .ready:
            break
        case .inProgress:
            guard
                try await awaitReady(runtime: runtime, accountRef: accountRef, groupIdHex: groupIdHex, target: target)
            else { return nil }
        case .never:
            return nil
        }
        try Task.checkCancellation()
        return try await read(
            runtime: runtime, accountRef: accountRef, groupIdHex: groupIdHex, target: target, maxBytes: maxBytes)
    }

    /// The bytes MDK already retains for `target`, with no network. Nil when it holds none, when
    /// they exceed `maxBytes`, or when they become unavailable mid-read.
    static func read(
        runtime: any MarmotRuntime,
        accountRef: String,
        groupIdHex: String,
        target: AttachmentLocalTargetFfi,
        maxBytes: UInt64
    ) async throws -> Data? {
        let assets = try await runtime.attachmentLocalAssets(
            accountRef: accountRef, groupIdHex: groupIdHex, targets: [target])
        guard let asset = assets.first, let reference = asset.reference, asset.byteCount <= maxBytes else {
            return nil
        }
        var data = Data()
        data.reserveCapacity(Int(asset.byteCount))
        while true {
            try Task.checkCancellation()
            let chunk = try await runtime.readAttachmentAsset(
                accountRef: accountRef, reference: reference, offset: UInt64(data.count), limit: chunkSize)
            guard chunk.available else { return nil }
            if chunk.bytes.isEmpty {
                return UInt64(data.count) == asset.byteCount ? data : nil
            }
            guard UInt64(data.count + chunk.bytes.count) <= asset.byteCount else { return nil }
            data.append(chunk.bytes)
        }
    }

    /// Follows the slot's transfer until it is ready (true) or ends without its bytes (false).
    private static func awaitReady(
        runtime: any MarmotRuntime,
        accountRef: String,
        groupIdHex: String,
        target: AttachmentLocalTargetFfi
    ) async throws -> Bool {
        let subscription = try await runtime.subscribeAttachmentTransfers(
            accountRef: accountRef, groupIdHex: groupIdHex, targets: [target])
        return try await withTaskCancellationHandler {
            defer { runtime.cancelAttachmentTransfers(subscription: subscription) }
            while let snapshot = try await runtime.nextAttachmentTransferSnapshot(subscription: subscription) {
                try Task.checkCancellation()
                guard let status = snapshot.items.first else { return false }
                switch status.state.customEmojiAwaitability {
                case .ready: return true
                case .inProgress: continue
                case .never: return false
                }
            }
            return false
        } onCancel: {
            runtime.cancelAttachmentTransfers(subscription: subscription)
        }
    }
}

extension AttachmentTransferStateFfi {
    /// Whether an emoji load can wait on this transfer for its bytes.
    nonisolated enum EmojiAwaitability {
        case ready
        case inProgress
        /// Ended, blocked, parked or never admitted: waiting would not bring the bytes.
        case never
    }

    nonisolated var customEmojiAwaitability: EmojiAwaitability {
        switch self {
        case .ready:
            .ready
        case .queued, .downloading, .verifyingCiphertext, .decrypting, .verifyingPlaintext, .retryScheduled:
            .inProgress
        case .unavailable, .notRequested, .paused, .failed, .policyBlocked, .cancelled, .removed,
            .previouslyAcquiredUnavailable, .completedUnretained, .retryExhausted, .storageBlocked,
            .cleanedBySetting:
            .never
        }
    }
}
