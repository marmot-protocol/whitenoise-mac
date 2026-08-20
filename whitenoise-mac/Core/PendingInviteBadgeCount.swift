//
//  PendingInviteBadgeCount.swift
//  whitenoise-mac
//
//  Which chat rows an account's avatar badge counts as an unanswered invitation.
//
//  The badge used to show unread messages alone, which left an invitation invisible on it: an
//  unaccepted invite has no timeline, so it contributes nothing to the unread total no matter how
//  long it sits there. Each one is worth +1 instead, the way the chat row already gives it the
//  unread slot's `+` badge.
//
//  The rule lives here because two callers must agree on it and they hold different types: the
//  active account counts its loaded `ChatItem` rows, and every other account is counted straight
//  off the `ChatListRowFfi` rows a one-shot chat-list read returns.
//

import Foundation
import MarmotKit

/// The badge's definition of an unanswered invitation, kept in step with the core's own
/// `attention_only_conversations` aggregate (mdk `account_unread_total`).
///
/// That query counts a row when `pending_confirmation` is set, and only while the row is
/// unarchived and the local account's membership is neither `left` nor `removed`. Both
/// exclusions matter for the badge as much as for the core's total: an archived invite has been
/// put away deliberately, and an ended membership supersedes a pending invite outright — the
/// sidebar row draws "Left"/"Removed" in place of the invite badge for exactly that reason
/// (`ChatRowStatus`), so a badge counting it would point at a row that never mentions an invite.
nonisolated enum PendingInviteBadgeCount {
    /// Whether one row adds itself to the badge.
    ///
    /// `isArchived` is a parameter rather than read off the row because the active account keeps
    /// its archived chats in a separate list, where the flag is carried by the list and not by the
    /// item.
    static func counts(pendingConfirmation: Bool, isArchived: Bool, membership: ChatSelfMembership) -> Bool {
        pendingConfirmation && !isArchived && membership == .member
    }

    /// Unanswered invitations among an account's unarchived chat items.
    static func count(inUnarchived chats: [ChatItem]) -> Int {
        chats.count { chat in
            counts(
                pendingConfirmation: chat.pendingConfirmation,
                isArchived: false,
                membership: chat.selfMembership
            )
        }
    }

    /// Unanswered invitations among the raw chat-list rows of an account whose items are not
    /// loaded. Rows arrive unmapped, so the archived flag is read from the row itself — a
    /// `includeArchived: false` read should carry none, but the caller does not have to trust that.
    static func count(inRows rows: [ChatListRowFfi]) -> Int {
        rows.count { row in
            counts(
                pendingConfirmation: row.pendingConfirmation,
                isArchived: row.archived,
                membership: ChatSelfMembership(row.selfMembership)
            )
        }
    }
}
