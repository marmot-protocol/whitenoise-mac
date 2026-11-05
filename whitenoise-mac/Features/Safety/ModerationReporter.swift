import Foundation
import MarmotKit
import Observation

/// Transient feedback for a report or a Block and Report, shown by `ModerationReportToast`.
nonisolated struct ModerationReportNotice: Identifiable, Equatable, Sendable {
    enum Kind: Equatable, Sendable { case success, failure }

    let id = UUID()
    let kind: Kind
    let title: String
    let message: String?
}

/// The account's path to the White Noise moderation team, ported from whitenoise-ios.
///
/// Private reports go through MDK's `submitModerationReport`: a NIP-56 report gift-wrapped to this
/// build's reports key (`ModerationReportBuildConfig`), sent only on explicit user action. It is
/// additive to the in-group `reportMessage`, which stays the admins' path. MDK sends only the
/// reported key, the reason and the optional explanation — never message, group or relay ids.
/// Every report-to-White-Noise affordance is gated on `isAvailable`; Block itself never is.
///
/// Owned by `AccountScope`, so a Block and Report still in flight is cancelled with the account and
/// can never post its feedback under the next one.
@MainActor
@Observable
final class ModerationReporter {
    let accountIdHex: String
    let isAvailable: Bool
    let blockedUsers: BlockedUsersViewModel
    private(set) var notice: ModerationReportNotice?

    @ObservationIgnored private let accountRef: String
    @ObservationIgnored private let runtime: any MarmotRuntime
    /// The Block (and Report) the user last confirmed, kept so the scope can cancel it and a test
    /// can await it.
    @ObservationIgnored private(set) var blockTask: Task<Void, Never>?

    init(accountRef: String, accountIdHex: String, runtime: any MarmotRuntime, blockedUsers: BlockedUsersViewModel) {
        self.accountRef = accountRef
        self.accountIdHex = accountIdHex
        self.runtime = runtime
        self.blockedUsers = blockedUsers
        self.isAvailable = runtime.moderationReportingAvailable()
    }

    func stop() {
        blockTask?.cancel()
        blockTask = nil
    }

    /// Whether the author of `accountIdHex` may be blocked from here right now.
    func canBlock(accountIdHex: String) -> Bool {
        !blockedUsers.isBlocked(accountID: accountIdHex) && blockedUsers.canMutate(accountID: accountIdHex)
    }

    /// Sends a private report to the White Noise team. A retained outcome (`acceptedPending`,
    /// `completionUnknown`) is queued by MDK and retried on catch-up: report it as waiting and never
    /// resubmit it.
    func submit(
        reportedAccountIdHex: String,
        reason: ReportReasonFfi,
        explanation: String,
        origin: ModerationReportOriginFfi
    ) async throws -> SendAcceptDispositionFfi {
        try await runtime.submitModerationReport(
            accountRef: accountRef,
            reportedPubkey: reportedAccountIdHex,
            reason: reason,
            explanation: explanation,
            origin: origin
        ).acceptDisposition
    }

    /// Starts a confirmed Block, or Block and Report, owned by this scope.
    func startBlocking(accountIdHex: String, reporting: Bool) {
        blockTask?.cancel()
        blockTask = Task { [weak self] in
            await self?.block(accountIdHex: accountIdHex, reporting: reporting)
        }
    }

    /// Blocks, then — for Block and Report — reports to the White Noise team only once the block is
    /// confirmed. The block already happened by then, so a failed report is feedback rather than
    /// anything to undo. Block and Report has no user-chosen reason, so it reports `other` with no
    /// explanation.
    func block(accountIdHex: String, reporting: Bool) async {
        await blockedUsers.setBlocked(true, accountID: accountIdHex)
        guard !Task.isCancelled else { return }
        // The block list can unload while the confirmation is open, and then `setBlocked` returns
        // without an error, so an unconfirmed block must not stay silent.
        guard blockedUsers.isBlocked(accountID: accountIdHex) else {
            present(
                ModerationReportNotice(
                    kind: .failure,
                    title: L10n.string("Couldn't block user"),
                    message: blockedUsers.error ?? L10n.string("Please try again.")
                ))
            return
        }
        guard reporting, isAvailable else { return }
        do {
            let disposition = try await submit(
                reportedAccountIdHex: accountIdHex,
                reason: .other,
                explanation: "",
                origin: .blockAndReport
            )
            try Task.checkCancellation()
            present(
                ModerationReportNotice(
                    kind: .success,
                    title: L10n.string("Report submitted"),
                    message: ReportPresentation.teamOutcome(disposition)
                ))
        } catch is CancellationError {
            return
        } catch {
            present(
                ModerationReportNotice(
                    kind: .failure,
                    title: L10n.string("Report not sent"),
                    message: ReportPresentation.errorMessage(for: error)
                ))
        }
    }

    func present(_ notice: ModerationReportNotice) {
        self.notice = notice
    }

    /// Clears `id` only if it is still the notice on screen, so a timer for an older notice never
    /// hides a newer one.
    func dismissNotice(_ id: ModerationReportNotice.ID) {
        guard notice?.id == id else { return }
        notice = nil
    }
}
