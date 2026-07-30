//
//  TimelineSendAcknowledgement.swift
//  whitenoise-mac
//
//  One-shot handshake between a completed send and the live timeline subscription.
//

import Foundation

/// A pending "has the core projected my send yet?" question.
///
/// A send returns a `SendSummaryFfi` immediately, but the row only reaches the transcript when
/// the subscription emits its projection. Rather than unconditionally re-materializing the whole
/// window after every send, the send path parks one of these and waits briefly for the listener
/// to report that the delta landed; the expensive authoritative re-window is then only paid when
/// the delta does *not* arrive.
///
/// Resolution is one-shot and idempotent, so the deadline and the listener can race freely.
@MainActor
final class TimelineSendAcknowledgement {
    /// Ids reported by `SendSummaryFfi`. The runtime reports the published *source* event id for
    /// some operations and the timeline row id for others, so a projection satisfies this waiter
    /// when it carries a record matching either — matching only one would silently never resolve.
    let messageIds: Set<String>

    private var continuation: CheckedContinuation<Bool, Never>?
    private var outcome: Bool?

    init(messageIds: Set<String>) {
        self.messageIds = messageIds
    }

    func matches(messageIdHex: String, sourceMessageIdHex: String?) -> Bool {
        if messageIds.contains(messageIdHex) { return true }
        guard let sourceMessageIdHex else { return false }
        return messageIds.contains(sourceMessageIdHex)
    }

    /// Suspends until `resolve(landed:)` is called. Returns immediately if it already was.
    func wait() async -> Bool {
        if let outcome { return outcome }
        return await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            if let outcome {
                continuation.resume(returning: outcome)
            } else {
                self.continuation = continuation
            }
        }
    }

    func resolve(landed: Bool) {
        guard outcome == nil else { return }
        outcome = landed
        continuation?.resume(returning: landed)
        continuation = nil
    }
}
