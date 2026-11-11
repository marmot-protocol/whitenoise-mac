import Foundation
import MarmotKit

/// The MDK chat-list queries the sidebar's search runs on. Matching happens in MDK, never in the
/// host, so the rows on screen, the Select All count and the bulk actions' revalidation all read
/// the same query.
nonisolated enum ChatListSearchQuery {
    /// MDK refuses more than 500 group ids in a query, so the results window lists at most this
    /// many matches; the drawer says so when there are more.
    static let maxShownMatches = 500
    /// MDK allows 1024 bytes of text across all text nodes, and the search text appears twice.
    static let maxTextBytes = 512
    /// The search window's first page; MDK accepts 1–100.
    static let windowRows: UInt32 = 100

    /// A view with no filter: what `chatListIds` and `revalidateChatListIds` read.
    static func unfiltered(_ view: ChatListViewFfi) -> ChatListViewQueryFfi {
        ChatListViewQueryFfi(view: view, filter: [])
    }

    /// The query whose ids are the search's matches: chats in `view` whose title, group name,
    /// description or direct-chat peer profile name contains the text (`Text`), or that hold a
    /// visible message containing it (`MessageText`). `nil` for blank text, which is no search.
    ///
    /// MDK's `Text` does not see app-local contact nicknames (an MDK request is pending), so a
    /// chat is not found by a nickname set only on this device. That regression is accepted. Do
    /// not "fix" it by filtering in the host again: a host filter would disagree with the ids
    /// Select All counts and bulk actions revalidate against.
    static func matches(text: String, view: ChatListViewFfi) -> ChatListViewQueryFfi? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let needle = truncated(trimmed, toUTF8Bytes: maxTextBytes)
        return ChatListViewQueryFfi(
            view: view,
            filter: [.any(children: [1, 2]), .text(text: needle), .messageText(text: needle)]
        )
    }

    /// The window that draws the matches. A window refuses `MessageText`, so it lists the ids
    /// the matching query returned instead, capped at `maxShownMatches`.
    static func window(showing ids: [String], view: ChatListViewFfi) -> ChatListViewQueryFfi {
        ChatListViewQueryFfi(view: view, filter: [.groupIds(groupIds: Array(ids.prefix(maxShownMatches)))])
    }

    /// `text` cut to at most `limit` UTF-8 bytes on a character boundary.
    static func truncated(_ text: String, toUTF8Bytes limit: Int) -> String {
        guard text.utf8.count > limit else { return text }
        var result = ""
        var bytes = 0
        for character in text {
            let size = String(character).utf8.count
            guard bytes + size <= limit else { break }
            result.append(character)
            bytes += size
        }
        return result
    }
}

/// Retries a chat-list read while MDK reports `ChatPresentationNotReady`: it fails rather than
/// return a partial list while base rows, or the presentation a text query reads, are still being
/// prepared. Any other error, and cancellation, end the retry at once.
nonisolated enum ChatListNotReadyRetry {
    static func run<T>(
        isolation: isolated (any Actor)? = #isolation,
        initialDelay: Duration = .milliseconds(250),
        maxDelay: Duration = .seconds(4),
        maxAttempts: Int = .max,
        _ read: () async throws -> T
    ) async throws -> T {
        var delay = initialDelay
        var attempt = 1
        while true {
            do {
                return try await read()
            } catch MarmotKitError.ChatPresentationNotReady where attempt < maxAttempts {
                try await Task.sleep(for: delay)
                delay = min(delay * 2, maxDelay)
                attempt += 1
            }
        }
    }
}

extension ChatListFilter {
    /// The MDK view this drawer tab draws: the base view of its search, Select All and
    /// revalidation.
    var chatListView: ChatListViewFfi {
        switch self {
        case .active: .chats
        case .unread: .unread
        case .archived: .archived
        case .left: .left
        }
    }
}

/// Which chat-list window failures are worth another attempt. MDK refuses a malformed request (a
/// bad limit, an anchor outside the window, a query it cannot run) the same way every time, so
/// those are final; anything else (a sequence that moved on, a busy or closed store, presentation
/// still being prepared) can pass on a later try.
nonisolated enum ChatListWindowRetry {
    /// Attempts at one page before it is dropped. The last row's `onAppear` does not fire again
    /// while the row stays on screen, so a dropped page is only asked for again on a scroll.
    static let maxPageAttempts = 4

    static func isRetryable(_ error: Error) -> Bool {
        if error is CancellationError { return false }
        guard let error = error as? MarmotKitError else { return true }
        switch error {
        case .ChatWindowInvalidLimit, .ChatWindowAnchorOutside, .ChatWindowQuery, .InvalidChatListQuery:
            return false
        default:
            return true
        }
    }

    /// Doubles from `initial` up to 4 s, the backoff the main list's window reopens with.
    static func delay(afterAttempt attempt: Int, initial: Duration) -> Duration {
        min(initial * (1 << min(max(attempt - 1, 0), 4)), .seconds(4))
    }
}
