//
//  AccountUnreadSignal.swift
//  whitenoise-mac
//
//  Row-derived unread state for the active account, used to decide when the per-account
//  unread summary behind the switcher avatar badges has gone stale.
//

import Foundation

/// A comparable snapshot of what the active account's loaded chat rows say about unread state.
///
/// The switcher avatar badge shows the backend's per-account summary, which is refreshed far less
/// often than the rows are. Comparing two of these values answers the only question that matters
/// for keeping the badge honest: did the rows change unread since the summary was last taken?
struct AccountUnreadSignal: Equatable, Sendable {
    /// The account the counts belong to. A switch alone makes the recorded summary stale, even
    /// when both accounts happen to hold the same totals.
    let accountId: String
    /// Unread messages across the account's chats, archived ones included.
    let totalUnreadCount: Int
    /// Chats flagged unread, which includes chats marked unread by hand and so carrying no count.
    let unreadChatCount: Int
}
