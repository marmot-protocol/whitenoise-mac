import Foundation
import MarmotKit

/// A pending leave MDK cannot finish because this account became the group's last active admin
/// after the leave was accepted (two admins left at once, say). MarmotKit 0.15 reports it as
/// `leaveBlocked` and offers `cancelLeave`, which clears the leave on this device only and makes
/// the chat read as joined again. MDK never retries or reverses the leave by itself.
///
/// Chat rows keep reading it as leaving; the composer and group info explain it and offer Cancel.
/// Wording is shared with iOS.
nonisolated enum BlockedLeavePresentation {
    static var title: String { L10n.string("Can't leave: you're the only admin") }
    static var detail: String {
        L10n.string("Cancel leaving to keep using this chat, then make another member an admin before you leave.")
    }
    static var cancelAction: String { L10n.string("Cancel Leaving") }

    static func isBlocked(leaveRequestPending: Bool, leaveBlocked: Bool) -> Bool {
        leaveRequestPending && leaveBlocked
    }
}

/// Runs `cancelLeave` and re-reads either way, so the surface shows what MDK settled on rather
/// than what the click assumed.
enum BlockedLeaveCancellation {
    enum Outcome: Equatable {
        case rejoined
        /// MDK refused with `LeaveNotBlocked`: the leave finished, or stopped being blocked,
        /// between the read and the click.
        case noLongerBlocked
        case cancelled
        case failed(String)
    }

    @MainActor
    static func perform(
        cancelLeave: () async throws -> Void,
        refresh: () async -> Void
    ) async -> Outcome {
        do {
            try await cancelLeave()
        } catch {
            await refresh()
            if Task.isCancelled || error is CancellationError { return .cancelled }
            if let error = error as? MarmotKitError, case .LeaveNotBlocked = error {
                return .noLongerBlocked
            }
            return .failed(UserFacingError.message(for: error))
        }
        await refresh()
        return .rejoined
    }

    /// The line to show under the notice after an attempt, or nil when there is nothing to say.
    static func failureMessage(for outcome: Outcome) -> String? {
        switch outcome {
        case .rejoined, .cancelled:
            nil
        case .noLongerBlocked:
            L10n.string("This leave is no longer blocked.")
        case .failed(let message):
            message
        }
    }
}
