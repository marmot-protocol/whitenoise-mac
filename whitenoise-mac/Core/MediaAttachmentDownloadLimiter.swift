//
//  MediaAttachmentDownloadLimiter.swift
//  whitenoise-mac
//

import Foundation

/// Bounds concurrent attachment downloads so opening a media-heavy chat cannot spawn
/// unbounded FFI `downloadMedia` calls.
enum MediaAttachmentDownloadConcurrency {
    static let maxConcurrentDownloads = 4
}

actor MediaAttachmentDownloadLimiter {
    static let shared = MediaAttachmentDownloadLimiter(
        maxConcurrent: MediaAttachmentDownloadConcurrency.maxConcurrentDownloads
    )

    private let maxConcurrent: Int
    private var inFlight = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(maxConcurrent: Int) {
        self.maxConcurrent = max(1, maxConcurrent)
    }

    func acquire() async {
        if inFlight < maxConcurrent {
            inFlight += 1
            return
        }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func release() {
        if let waiter = waiters.first {
            waiters.removeFirst()
            waiter.resume()
        } else {
            inFlight -= 1
        }
    }
}
