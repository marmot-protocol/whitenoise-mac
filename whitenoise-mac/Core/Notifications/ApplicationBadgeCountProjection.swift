import Foundation
import MarmotKit

/// Projects MDK's per-account attention totals into the single number the Dock and the
/// ⌘-Tab switcher show on the app icon. Mirrors whitenoise-ios's projection: an account
/// contributes its unread messages plus conversations that only need attention (pending
/// invites, manual reminders), and never less than one while it has an unread conversation.
nonisolated enum ApplicationBadgeCountProjection {
    static func count<S: Sequence>(for totals: S) -> Int where S.Element == AccountAttentionTotalFfi {
        var total: UInt64 = 0
        for summary in totals {
            let (sum, overflow) = total.addingReportingOverflow(contribution(for: summary))
            total = overflow ? UInt64.max : sum
        }
        return Int(clamping: total)
    }

    static func contribution(for total: AccountAttentionTotalFfi) -> UInt64 {
        let (count, overflow) = total.unreadCount.addingReportingOverflow(total.attentionOnlyConversations)
        let boundedCount = overflow ? UInt64.max : count
        return boundedCount == 0 && total.unreadConversations > 0 ? 1 : boundedCount
    }
}
