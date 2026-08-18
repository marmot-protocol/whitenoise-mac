//
//  OutgoingMediaWarmPlaintexts.swift
//  whitenoise-mac
//
//  The plaintexts of the media this client is publishing right now, held in memory between the send
//  and the moment the published row renders them.
//

import Foundation

/// Just-sent media plaintexts, keyed by the same content-addressed cache key the published row will
/// look the attachment up by.
///
/// Not the durable copy: `cacheOutgoingMediaPlaintext` writes the same bytes into the encrypted disk
/// cache, and every later render comes from there. This hold exists for the *first* frame of the
/// published row. Reading the disk cache is asynchronous — open the container, decrypt, verify the
/// plaintext digest — so a row that lands with a cold download state spends those frames on a
/// spinner over an image this process is still holding, which is what made the sender's own bubble
/// blink from loaded back to loading as the placeholder gave way to the real row.
///
/// An entry is held from the seed that precedes the publish until the outgoing message that owns it
/// is retired, so it also survives a mid-send prune of the download-state stores.
nonisolated struct OutgoingMediaWarmPlaintexts {
    /// Default ceiling on the held bytes. One send's attachments sit far below it; the cap only
    /// bounds the pathological case of messages whose rows never arrive — an offline queue, a failed
    /// publish whose bubble the user leaves sitting there — where the hold would grow per send.
    static let defaultByteLimit = 64 * 1024 * 1024

    /// Injectable so a test can drive the overflow without allocating the real budget.
    let byteLimit: Int
    private var downloads: [MessageMediaDiskCacheKey: MessageMediaDownload] = [:]
    /// Keys in insertion order, so an overflow drops the oldest hold rather than an arbitrary one.
    private var order: [MessageMediaDiskCacheKey] = []
    private(set) var heldByteCount = 0

    init(byteLimit: Int = Self.defaultByteLimit) {
        self.byteLimit = byteLimit
    }

    var isEmpty: Bool { downloads.isEmpty }

    /// Holds one attachment's plaintext, evicting the oldest holds while the total is over budget.
    mutating func hold(_ download: MessageMediaDownload, for key: MessageMediaDiskCacheKey) {
        remove(for: key)
        downloads[key] = download
        order.append(key)
        heldByteCount += download.payload.byteCount
        while heldByteCount > byteLimit, let oldest = order.first {
            remove(for: oldest)
        }
    }

    /// The plaintext for a published row's attachment, or `nil` when this client did not send it.
    ///
    /// Deliberately non-consuming: the row that reads it may be rebuilt more than once while the
    /// send is still in flight (a reprojection that changes the message's media prunes the download
    /// state stores), and each rebuild has to find the bytes again.
    func download(for key: MessageMediaDiskCacheKey) -> MessageMediaDownload? {
        downloads[key]
    }

    mutating func remove(for key: MessageMediaDiskCacheKey) {
        guard let existing = downloads.removeValue(forKey: key) else { return }
        heldByteCount -= existing.payload.byteCount
        order.removeAll { $0 == key }
    }

    mutating func removeAll() {
        downloads.removeAll()
        order.removeAll()
        heldByteCount = 0
    }

    mutating func removeAll(forAccountId accountId: String) {
        for key in order where key.accountId == accountId {
            downloads[key] = nil
        }
        order.removeAll { $0.accountId == accountId }
        heldByteCount = order.reduce(0) { $0 + (downloads[$1]?.payload.byteCount ?? 0) }
    }
}
