//
//  WorkspaceState+SharedMedia.swift
//  whitenoise-mac
//
//  Group "Shared Media" browser: the media records for a conversation (via the `listMedia` FFI)
//  and a self-contained decrypt loader for its thumbnails/files, kept separate from the message
//  timeline's per-message download-state machine so the two never contend on keys or caches.
//

import Foundation
import MarmotKit

@MainActor
extension WorkspaceState {
    /// Cache bounds for decrypted thumbnails: a hard entry count, a cumulative byte budget, and a
    /// per-entry ceiling so a single large image can't dominate memory. File-save payloads bypass
    /// the cache entirely (see `sharedMediaData(cache:)`).
    private static let sharedMediaCacheEntryLimit = 80
    private static let sharedMediaCacheByteBudget = 48 * 1024 * 1024
    private static let sharedMediaCacheMaxEntryBytes = 8 * 1024 * 1024

    func loadSharedMedia(groupIdHex: String) async {
        guard let client, let activeAccount, !groupIdHex.isEmpty else { return }
        // A fresh open of another group clears the previous list so stale thumbnails never flash.
        if sharedMediaGroupId != groupIdHex {
            sharedMediaProjection = .empty
            clearSharedMediaThumbnailCache()
        }
        sharedMediaGroupId = groupIdHex
        sharedMediaError = nil
        isLoadingSharedMedia = true
        sharedMediaLoadGeneration &+= 1
        let generation = sharedMediaLoadGeneration
        // Only the still-current load owns the spinner, so a superseded call can't clear it early
        // and flash a false empty state for the newer one.
        defer {
            if generation == sharedMediaLoadGeneration {
                isLoadingSharedMedia = false
            }
        }

        let accountId = activeAccount.id
        let accountRef = activeAccount.accountRef
        do {
            let projection = try await FFIExecutor.run {
                let records = try client.listMedia(accountRef: accountRef, groupIdHex: groupIdHex, limit: nil)
                return GroupSharedMediaProjection(records: records)
            }
            // The list FFI suspends this actor; drop a superseded/stale result.
            guard generation == sharedMediaLoadGeneration,
                activeAccountId == accountId, sharedMediaGroupId == groupIdHex
            else { return }
            sharedMediaProjection = projection
        } catch {
            guard generation == sharedMediaLoadGeneration,
                activeAccountId == accountId, sharedMediaGroupId == groupIdHex
            else { return }
            sharedMediaError = error.localizedDescription
        }
    }

    func clearSharedMedia() {
        sharedMediaGroupId = nil
        sharedMediaProjection = .empty
        sharedMediaError = nil
        // Supersede any in-flight load so its result/error can't land in the torn-down state.
        sharedMediaLoadGeneration &+= 1
        isLoadingSharedMedia = false
        clearSharedMediaThumbnailCache()
    }

    func clearSharedMediaThumbnailCache() {
        sharedMediaThumbnailCache.removeAll()
        sharedMediaThumbnailCacheOrder.removeAll()
        sharedMediaThumbnailCacheBytes = 0
    }

    /// Decrypt one shared-media reference's bytes. Honors the media-display privacy gate before a
    /// cache hit and again after the download, and re-checks the captured account/group so a
    /// download completing after an account/group switch cannot leak plaintext into the new state.
    /// Pass `cache: false` for file saves so large documents never sit in the thumbnail cache.
    func sharedMediaData(
        for reference: MediaAttachmentReferenceFfi,
        groupIdHex: String,
        cache: Bool = true
    ) async -> Data? {
        guard let client, let activeAccount, !groupIdHex.isEmpty else { return nil }
        let accountId = activeAccount.id
        let cacheGeneration = mediaCacheGeneration
        guard isMediaDisplayAllowed(forAccountId: accountId, groupIdHex: groupIdHex) else { return nil }
        let cacheKey = sharedMediaCacheKey(accountId: accountId, groupIdHex: groupIdHex, reference: reference)
        if cache, let cacheKey, let cached = sharedMediaThumbnailCache[cacheKey] {
            return cached
        }
        let accountRef = activeAccount.accountRef
        do {
            let download = try await MediaAttachmentDownloadLimiter.shared.withPermit {
                try await client.downloadMedia(
                    accountRef: accountRef,
                    groupIdHex: groupIdHex,
                    reference: reference
                )
            }
            // The download suspended this actor; a switch/teardown may have occurred. Re-check the
            // captured account/group and the privacy gate before returning or caching plaintext.
            guard mediaCacheGeneration == cacheGeneration,
                activeAccountId == accountId, sharedMediaGroupId == groupIdHex,
                isMediaDisplayAllowed(forAccountId: accountId, groupIdHex: groupIdHex)
            else { return nil }
            if cache, let cacheKey {
                cacheSharedMediaData(download.plaintext, key: cacheKey)
            }
            return download.plaintext
        } catch {
            return nil
        }
    }

    private func sharedMediaCacheKey(
        accountId: String,
        groupIdHex: String,
        reference: MediaAttachmentReferenceFfi
    ) -> String? {
        let hash = reference.plaintextSha256.lowercased()
        guard !hash.isEmpty else { return nil }
        return "\(accountId)\u{1F}\(groupIdHex)\u{1F}\(hash)"
    }

    private func cacheSharedMediaData(_ data: Data, key: String) {
        guard data.count <= Self.sharedMediaCacheMaxEntryBytes else { return }
        // Evict oldest until under both the entry-count and byte budgets.
        while sharedMediaThumbnailCache[key] == nil,
            !sharedMediaThumbnailCacheOrder.isEmpty,
            sharedMediaThumbnailCache.count >= Self.sharedMediaCacheEntryLimit
                || sharedMediaThumbnailCacheBytes + data.count > Self.sharedMediaCacheByteBudget
        {
            let oldest = sharedMediaThumbnailCacheOrder.removeFirst()
            if let removed = sharedMediaThumbnailCache.removeValue(forKey: oldest) {
                sharedMediaThumbnailCacheBytes -= removed.count
            }
        }
        if let existing = sharedMediaThumbnailCache[key] {
            sharedMediaThumbnailCacheBytes -= existing.count
        } else {
            sharedMediaThumbnailCacheOrder.append(key)
        }
        sharedMediaThumbnailCache[key] = data
        sharedMediaThumbnailCacheBytes += data.count
    }
}
