//
//  AccountUnreadSignal.swift
//  whitenoise-mac
//
//  Row-derived unread state for the active account, used to decide when the per-account
//  unread summary behind the account rail's avatar badges has gone stale.
//

import Foundation

/// A comparable snapshot of what the active account's loaded chat rows say about unread state.
///
/// The rail's avatar badge shows the backend's per-account summary, which is refreshed far less
/// often than the rows are. Comparing two of these values answers the only question that matters
/// for keeping the badge honest: did the rows change unread since the summary was last taken?
///
/// Every count here is scoped to the account's *unarchived* chats, matching the scope of the
/// summary it guards (mdk `account_unread_total` sums `WHERE row.archived = 0`). Counting archived
/// rows as well made the two disagree in both directions: archiving an unread chat left the totals
/// identical — the row merely moved between two counted lists — so the gate suppressed the refresh
/// and the badge kept counting a chat the user had just put away, while a message landing in an
/// archived chat moved the signal and spent an FFI query on a total that could not have changed.
struct AccountUnreadSignal: Equatable, Sendable {
    /// The account the counts belong to. A switch alone makes the recorded summary stale, even
    /// when both accounts happen to hold the same totals.
    let accountId: String
    /// Unread messages across the account's unarchived chats.
    let totalUnreadCount: Int
    /// Unarchived chats flagged unread, which includes chats marked unread by hand and so carrying
    /// no count.
    let unreadChatCount: Int
    /// How many unarchived chats there are, so a chat leaving that list is noticed even when its
    /// unread messages are coincidentally replaced by another row's in the same snapshot.
    let chatCount: Int
}
