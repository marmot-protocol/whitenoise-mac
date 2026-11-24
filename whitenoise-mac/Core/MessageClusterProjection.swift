import Foundation

/// Where a transcript row sits in a run of consecutive messages from one person.
///
/// Consecutive messages from the same author sit close together, with more room before the next
/// run. A group's incoming run names its sender above the first bubble and puts their avatar
/// beside the last one, and a run's routine timestamp is drawn only at its end. Mirrors White
/// Noise for iOS (whitenoise-ios#1366) so the two transcripts group the same messages.
nonisolated struct MessageClusterPosition: Hashable, Sendable {
    var startsCluster: Bool
    var endsCluster: Bool

    /// A row that neither continues nor is continued: every notice, loading row and lone message.
    static let standalone = MessageClusterPosition(startsCluster: true, endsCluster: true)

    /// Whether this row draws its timestamp footer. Only the run's last row does, unless the row
    /// has something of its own to say: a deletion, an edit, a report, or a send that is still
    /// going out, did not go out, or may not have reached everyone.
    func showsFooter(
        isDeleted: Bool,
        isEdited: Bool,
        hasReports: Bool,
        indicator: MessageDeliveryIndicator
    ) -> Bool {
        if endsCluster || isDeleted || isEdited || hasReports { return true }
        switch indicator {
        case .sending, .failed, .warning: return true
        case .none, .delivered: return false
        }
    }
}

nonisolated enum MessageClusterProjection {
    /// A pause longer than this starts a new run, even from the same person.
    static let maximumGap: TimeInterval = 5 * 60

    /// Who a row is from, for grouping. Every outgoing row is the local account's — including one
    /// sent from a linked device — so outgoing rows compare as one author.
    enum Author: Hashable, Sendable {
        case me
        case peer(String)
    }

    /// One groupable row.
    struct Entry: Hashable, Sendable {
        let author: Author
        let sentAt: Date
        /// Something drawn above this row separates it from the one before: the unread divider,
        /// or the boundary between imported history and live messages.
        let followsBoundary: Bool

        init(author: Author, sentAt: Date, followsBoundary: Bool = false) {
            self.author = author
            self.sentAt = sentAt
            self.followsBoundary = followsBoundary
        }

        /// The entry for a transcript message, or nil for a row that never groups (notices,
        /// membership changes, a malformed poll). Chat bubbles, poll cards and unsupported-event
        /// cards group, as on iOS.
        init?(message: MessageItem, followsBoundary: Bool) {
            let groups =
                message.presentation.isChatBubble
                || (message.presentation == .poll && message.poll != nil)
                || message.unsupportedEvent != nil
            guard groups else { return nil }
            self.init(
                author: message.isOutgoing ? .me : .peer(message.senderAccountIdHex.lowercased()),
                sentAt: message.sentAt,
                followsBoundary: followsBoundary
            )
        }
    }

    /// The position of each row, index for index. A nil entry breaks the run on both sides.
    static func positions(
        for entries: [Entry?],
        calendar: Calendar = .autoupdatingCurrent
    ) -> [MessageClusterPosition] {
        var result = Array(repeating: MessageClusterPosition.standalone, count: entries.count)
        var previous: (index: Int, entry: Entry)?
        for (index, entry) in entries.enumerated() {
            guard let entry else {
                previous = nil
                continue
            }
            if let previous, continues(previous.entry, with: entry, calendar: calendar) {
                result[previous.index].endsCluster = false
                result[index].startsCluster = false
            }
            previous = (index, entry)
        }
        return result
    }

    static func continues(_ previous: Entry, with next: Entry, calendar: Calendar) -> Bool {
        guard !next.followsBoundary, previous.author == next.author else { return false }
        let gap = next.sentAt.timeIntervalSince(previous.sentAt)
        return gap >= 0 && gap <= maximumGap && calendar.isDate(previous.sentAt, inSameDayAs: next.sentAt)
    }
}
