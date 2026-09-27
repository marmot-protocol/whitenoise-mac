//
//  AvatarAssetReads.swift
//  whitenoise-mac
//
//  The one way the app reads MDK's retained avatar bytes, inside the limits the core enforces.
//

import Foundation
import MarmotKit

/// Reads avatar bytes MDK has already acquired, within the core's per-call limits.
///
/// `read_avatar_assets` rejects the **whole call** — not the excess — when it is handed more than
/// 16 references or a byte budget above 16 MiB (`MAX_AVATAR_BATCH_ITEMS` /
/// `MAX_AVATAR_BATCH_BYTES` in mdk's `runtime/avatar_access.rs`). Every call site used to ask for
/// 32 MiB, so every read threw, each site swallowed the error as "fall back to the URL", and the
/// "Load Remote Profile Images" preference then blanked the URL: no peer avatar drew anywhere, with
/// nothing logged. Keeping the arithmetic here is what stops a call site from getting it wrong again.
nonisolated enum AvatarAssetReads {
    static let maxBatchItems = 16
    static let maxBatchBytes: UInt64 = 16 * 1_024 * 1_024

    /// MDK serves bytes for `.stale` assets too — the previous picture, kept while a refresh is
    /// pending — and iOS draws them. Only `.ready`/`.stale` references are worth reading.
    static func isReadable(_ availability: AvatarAvailabilityFfi) -> Bool {
        availability == .ready || availability == .stale
    }

    /// The payload a view may draw: readable, not budget-deferred, and non-empty. Its id carries
    /// the content revision because decoded images are cached by payload id, and a refreshed
    /// picture keeps the reference of the stale one it replaces.
    static func drawablePayload(_ bytes: AvatarBytesFfi?) -> DownloadedMediaPayload? {
        guard let bytes, isReadable(bytes.availability), !bytes.deferred, !bytes.bytes.isEmpty else {
            return nil
        }
        return DownloadedMediaPayload(id: "\(bytes.reference)#\(bytes.contentRevision)", data: bytes.bytes)
    }

    /// The distinct readable references among `assets`, in first-seen order.
    static func readableReferences(_ assets: [AvatarAssetFfi?]) -> [String] {
        var seen = Set<String>()
        return assets.compactMap { asset -> String? in
            guard let asset, isReadable(asset.availability), let reference = asset.reference,
                seen.insert(reference).inserted
            else { return nil }
            return reference
        }
    }

    /// Splits `items` into core-sized batches.
    static func batches<T>(_ items: [T]) -> [[T]] {
        stride(from: 0, to: items.count, by: maxBatchItems).map {
            Array(items[$0..<min($0 + maxBatchItems, items.count)])
        }
    }

    /// Reads `references` in batches the core accepts, keyed by reference. An entry the core defers because an earlier
    /// image in its batch used up the budget is retried on its own, where it gets the full budget.
    static func read(
        runtime: any MarmotRuntime,
        accountRef: String,
        references: [String]
    ) async throws -> [String: AvatarBytesFfi] {
        var result: [String: AvatarBytesFfi] = [:]
        var deferred: [String] = []
        for batch in batches(Array(Set(references)).sorted()) {
            let payloads = try await runtime.readAvatarAssets(
                accountRef: accountRef, references: batch, maxBytes: maxBatchBytes
            )
            try Task.checkCancellation()
            for payload in payloads {
                if payload.deferred {
                    deferred.append(payload.reference)
                } else {
                    result[payload.reference] = payload
                }
            }
        }
        // A batch of one gets the whole budget, so a retry can only defer an image larger than
        // 16 MiB, which the core will never serve; it is left to the placeholder.
        for reference in deferred {
            let payloads = try await runtime.readAvatarAssets(
                accountRef: accountRef, references: [reference], maxBytes: maxBatchBytes
            )
            try Task.checkCancellation()
            for payload in payloads where !payload.deferred {
                result[payload.reference] = payload
            }
        }
        return result
    }
}
