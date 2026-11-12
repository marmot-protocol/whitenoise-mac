import Foundation
import MarmotKit

/// Pure rules for selecting several chats in the chat list, kept free of SwiftUI and of state so
/// every bulk decision is unit-testable. The rules mirror `whitenoise-ios`'s `ChatListSelection`,
/// which was itself written to match Android, so a mixed selection resolves the same way on every
/// client.
nonisolated enum ChatListSelection {
    enum BulkArchiveAction: Equatable {
        case archive
        case unarchive
    }

    /// Unarchive only when every selected chat is already archived; a mixed selection archives all.
    static func bulkArchiveAction(archivedFlags: [Bool]) -> BulkArchiveAction {
        if !archivedFlags.isEmpty, archivedFlags.allSatisfy({ $0 }) {
            return .unarchive
        }
        return .archive
    }

    /// Unmute only when every selected chat is already muted; a mixed selection mutes all.
    static func bulkMuteMutes(mutedFlags: [Bool]) -> Bool {
        mutedFlags.isEmpty || !mutedFlags.allSatisfy { $0 }
    }

    static func toggling(_ selected: Set<String>, id: String) -> Set<String> {
        selected.contains(id) ? selected.subtracting([id]) : selected.union([id])
    }

    /// Drop selections that fell off the visible (filter/search) list, so a bulk action never
    /// touches a chat the user can no longer see.
    static func reconcile(_ selected: Set<String>, visibleIds: Set<String>) -> Set<String> {
        selected.intersection(visibleIds)
    }

    static func allSelected(_ selected: Set<String>, visibleIds: Set<String>) -> Bool {
        !visibleIds.isEmpty && visibleIds.isSubset(of: selected)
    }

    static func togglingAll(_ selected: Set<String>, visibleIds: Set<String>) -> Set<String> {
        allSelected(selected, visibleIds: visibleIds) ? [] : visibleIds
    }

    /// `selected` in `order`, then any selected id `order` does not carry, so a batch walks the
    /// chats top to bottom and still reaches every one the user picked.
    static func ordered(_ selected: Set<String>, by order: [String]) -> [String] {
        let listed = order.filter { selected.contains($0) }
        return listed + selected.subtracting(listed).sorted()
    }

    /// Shift-click: add every row between the anchor and `id`, inclusive, in list order. The Mac's
    /// counterpart to dragging a selection on iOS. Without a usable anchor it selects only `id`.
    static func extending(
        _ selected: Set<String>,
        from anchor: String?,
        to id: String,
        in orderedIds: [String]
    ) -> Set<String> {
        guard let end = orderedIds.firstIndex(of: id) else { return selected }
        guard let anchor, let start = orderedIds.firstIndex(of: anchor) else {
            return selected.union([id])
        }
        return selected.union(orderedIds[min(start, end)...max(start, end)])
    }

    /// The selected chats that can be left. A chat whose membership already ended, or whose leave is
    /// already in flight, is skipped rather than blocking the batch: there is nothing left to do
    /// for it, which is how iOS treats a settled leave.
    ///
    /// A chat whose End Group run is in flight (`endingGroupIds`) is skipped too, as its row menu
    /// disables Leave: the disband is a commit the row cannot see yet, and a leave would race it.
    static func leaveTargets(_ chats: [ChatItem], endingGroupIds: Set<String> = []) -> [ChatItem] {
        chats.filter { ChatDestructiveActions.action(for: $0) == .leave && !endingGroupIds.contains($0.id) }
    }
}

/// What the chat list is showing, as the selection needs it: the MDK query behind it (a view, plus
/// the search filter while searching), whether the rows are a bounded window over that query, and
/// the rows in order.
nonisolated struct ChatListSelectionScope: Equatable {
    var query: ChatListViewQueryFfi
    var isWindowed: Bool
    var visibleIds: [String]
}
