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
    /// Cap for the decrypted-thumbnail cache; the grid only shows a bounded window, and this keeps
    /// a scroll-through from pinning every image's plaintext in memory.
    private static let sharedMediaCacheLimit = 80

    func loadSharedMedia(groupIdHex: String) async {
        guard let client, let activeAccount, !groupIdHex.isEmpty else { return }
        // A fresh open of another group clears the previous list so stale thumbnails never flash.
        if sharedMediaGroupId != groupIdHex {
            sharedMediaRecords = []
            sharedMediaThumbnailCache.removeAll()
        }
        sharedMediaGroupId = groupIdHex
        sharedMediaError = nil
        isLoadingSharedMedia = true
        defer { isLoadingSharedMedia = false }

        let accountId = activeAccount.id
        let accountRef = activeAccount.accountRef
        do {
            let records = try await runOffMain {
                try client.listMedia(accountRef: accountRef, groupIdHex: groupIdHex, limit: nil)
            }
            // The list FFI suspends this actor; drop the result if the user moved on.
            guard activeAccountId == accountId, sharedMediaGroupId == groupIdHex else { return }
            sharedMediaRecords = records
        } catch {
            guard activeAccountId == accountId, sharedMediaGroupId == groupIdHex else { return }
            sharedMediaError = error.localizedDescription
        }
    }

    func clearSharedMedia() {
        sharedMediaGroupId = nil
        sharedMediaRecords = []
        sharedMediaError = nil
        isLoadingSharedMedia = false
        sharedMediaThumbnailCache.removeAll()
    }

    /// Decrypt one shared-media reference's bytes, honoring the media-display privacy gate and the
    /// shared download limiter. Cached by plaintext hash so repeated grid passes don't re-decrypt.
    func sharedMediaData(for reference: MediaAttachmentReferenceFfi, groupIdHex: String) async -> Data? {
        let cacheKey = reference.plaintextSha256.lowercased()
        if !cacheKey.isEmpty, let cached = sharedMediaThumbnailCache[cacheKey] {
            return cached
        }
        guard let client, let activeAccount, !groupIdHex.isEmpty,
            isMediaDisplayAllowed(forAccountId: activeAccount.id, groupIdHex: groupIdHex)
        else { return nil }
        let accountRef = activeAccount.accountRef
        do {
            try await MediaAttachmentDownloadLimiter.shared.acquire()
            defer { Task { await MediaAttachmentDownloadLimiter.shared.release() } }
            let download = try await client.downloadMedia(
                accountRef: accountRef,
                groupIdHex: groupIdHex,
                reference: reference
            )
            cacheSharedMediaData(download.plaintext, key: cacheKey)
            return download.plaintext
        } catch {
            return nil
        }
    }

    private func cacheSharedMediaData(_ data: Data, key: String) {
        guard !key.isEmpty else { return }
        if sharedMediaThumbnailCache.count >= Self.sharedMediaCacheLimit,
            let oldest = sharedMediaThumbnailCacheOrder.first
        {
            sharedMediaThumbnailCache[oldest] = nil
            sharedMediaThumbnailCacheOrder.removeFirst()
        }
        if sharedMediaThumbnailCache[key] == nil {
            sharedMediaThumbnailCacheOrder.append(key)
        }
        sharedMediaThumbnailCache[key] = data
    }
}
