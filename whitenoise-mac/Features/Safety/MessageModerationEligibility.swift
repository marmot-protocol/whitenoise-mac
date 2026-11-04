import Foundation

/// Which report and block actions a message's menu offers.
///
/// - A group report is shared with the group's members, so a direct chat has none: it would go
///   only to the person being reported.
/// - A report to the White Noise team needs this build's reports key and someone else's live
///   message with a valid author key — your own messages and deleted ones have nothing to report.
/// - Blocking needs no report destination; only "Block and Report" does.
nonisolated struct MessageModerationEligibility: Equatable, Sendable {
    let reportsToGroup: Bool
    let reportsToTeam: Bool
    let canBlockAuthor: Bool
    /// The author's normalized account id, when there is someone else to report or block.
    let authorAccountIdHex: String?

    var canReport: Bool { reportsToGroup || reportsToTeam }

    static let none = MessageModerationEligibility(
        reportsToGroup: false, reportsToTeam: false, canBlockAuthor: false, authorAccountIdHex: nil
    )

    static func resolve(
        for message: MessageItem,
        isDirectChat: Bool,
        teamReportingAvailable: Bool,
        activeAccountIdHex: String?,
        canBlock: Bool
    ) -> MessageModerationEligibility {
        let author = otherAuthor(of: message, activeAccountIdHex: activeAccountIdHex)
        return MessageModerationEligibility(
            reportsToGroup: message.canReport && !isDirectChat,
            reportsToTeam: teamReportingAvailable && author != nil,
            canBlockAuthor: author != nil && canBlock,
            authorAccountIdHex: author
        )
    }

    /// The author of someone else's live chat message, or nil when there is nobody to act on.
    static func otherAuthor(of message: MessageItem, activeAccountIdHex: String?) -> String? {
        guard message.supportsChatActions, !message.isOutgoing,
            let author = normalizedAccountId(message.senderAccountIdHex)
        else { return nil }
        return author == normalizedAccountId(activeAccountIdHex) ? nil : author
    }

    /// A 32-byte hex account id, lowercased; nil for anything else (a row without a resolved
    /// author falls back to its display name).
    static func normalizedAccountId(_ value: String?) -> String? {
        guard let value else { return nil }
        let normalized = value.lowercased()
        guard normalized.count == 64, normalized.allSatisfy({ $0.isASCII && $0.isHexDigit }) else { return nil }
        return normalized
    }
}
