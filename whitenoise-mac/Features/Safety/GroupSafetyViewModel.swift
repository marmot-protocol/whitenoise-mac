import Foundation
import MarmotKit
import Observation

enum GroupSafetyError: Error, Equatable {
    case staleInvitation
}

@MainActor
@Observable
final class GroupSafetyViewModel {
    let groupIdHex: String
    private(set) var recovery: GroupRecoveryStatusFfi?
    private(set) var reports: [ContentReportFfi] = []
    private(set) var nextReportCursor: String?
    private(set) var isApplyingRecoveryDecision = false
    private(set) var isLoadingReports = false
    private(set) var isModerating = false
    private(set) var canModerate = false
    private(set) var error: String?
    /// The account's notices, for the cause behind this group's `historyNoticeIds` and for
    /// routing their dismissal. `nil` only where no account scope exists (previews).
    let historyNotices: HistoryNoticesViewModel?

    @ObservationIgnored private let accountRef: String
    @ObservationIgnored private let runtime: any MarmotRuntime

    init(
        accountRef: String,
        groupIdHex: String,
        runtime: any MarmotRuntime,
        historyNotices: HistoryNoticesViewModel? = nil
    ) {
        self.accountRef = accountRef
        self.groupIdHex = groupIdHex
        self.runtime = runtime
        self.historyNotices = historyNotices
    }

    /// This group's own "history may be incomplete" occurrences, oldest first. Empty unless the
    /// core both flags the group and names the occurrences, so there is always something to dismiss.
    var historyNoticeIds: [String] {
        guard let recovery, recovery.historyMayBeIncomplete else { return [] }
        return recovery.historyNoticeIds
    }

    var historyNoticeMessage: String {
        HistoryNoticePresentation.groupMessage(
            noticeIds: historyNoticeIds,
            notices: historyNotices?.notices ?? []
        )
    }

    var isDismissingHistoryNotice: Bool {
        historyNotices?.isDismissing(historyNoticeIds) ?? false
    }

    /// Dismisses what the user was shown, then re-reads the group's status so the flag and ids
    /// reflect the core rather than the local guess.
    func dismissHistoryNotice() async {
        let noticeIds = historyNoticeIds
        guard let historyNotices, !noticeIds.isEmpty else { return }
        await historyNotices.dismiss(noticeIds)
        await load(canModerate: canModerate)
    }

    func load(canModerate: Bool) async {
        self.canModerate = canModerate
        do {
            recovery = try await runtime.groupRecoveryStatus(accountRef: accountRef, groupIdHex: groupIdHex)
            if canModerate {
                let page = try await FFIExecutor.run { [runtime, accountRef, groupIdHex] in
                    try runtime.contentReports(
                        accountRef: accountRef,
                        groupIdHex: groupIdHex,
                        messageId: nil,
                        after: nil,
                        limit: 100
                    )
                }
                reports = page.reports
                nextReportCursor = page.nextCursor
            } else {
                reports = []
                nextReportCursor = nil
            }
            error = nil
        } catch is CancellationError {
            return
        } catch {
            self.error = error.localizedDescription
        }
    }

    func report(messageID: String, reason: ReportReasonFfi, explanation: String) async throws {
        _ = try await runtime.reportMessage(
            accountRef: accountRef,
            groupIdHex: groupIdHex,
            messageId: messageID,
            reason: reason,
            explanation: explanation
        )
    }

    func dismiss(reportIDs: [String], explanation: String) async throws {
        guard canModerate, !reportIDs.isEmpty, !isModerating else { return }
        isModerating = true
        defer { isModerating = false }
        do {
            _ = try await runtime.dismissReports(
                accountRef: accountRef,
                groupIdHex: groupIdHex,
                reportIds: reportIDs,
                explanation: explanation
            )
            reports.removeAll { reportIDs.contains($0.reportIdHex) }
            error = nil
        } catch {
            self.error = error.localizedDescription
            throw error
        }
    }

    func loadMoreReports() async {
        guard canModerate, let cursor = nextReportCursor, !isLoadingReports else { return }
        isLoadingReports = true
        defer { isLoadingReports = false }
        do {
            let page = try await FFIExecutor.run { [runtime, accountRef, groupIdHex] in
                try runtime.contentReports(
                    accountRef: accountRef,
                    groupIdHex: groupIdHex,
                    messageId: nil,
                    after: cursor,
                    limit: 100
                )
            }
            let existing = Set(reports.map(\.reportIdHex))
            reports.append(contentsOf: page.reports.filter { !existing.contains($0.reportIdHex) })
            nextReportCursor = page.nextCursor
            error = nil
        } catch is CancellationError {
            return
        } catch {
            self.error = error.localizedDescription
        }
    }

    func confirm(_ invitation: GroupRejoinInvitationFfi) async throws {
        guard containsDisplayed(invitation) else { throw GroupSafetyError.staleInvitation }
        isApplyingRecoveryDecision = true
        defer { isApplyingRecoveryDecision = false }
        do {
            recovery = try await runtime.confirmGroupRejoin(
                accountRef: accountRef,
                welcomeIdHex: invitation.welcomeIdHex,
                localStateToken: invitation.localStateToken
            )
            error = nil
        } catch {
            await load(canModerate: canModerate)
            throw error
        }
    }

    func decline(_ invitation: GroupRejoinInvitationFfi) async throws {
        guard containsDisplayed(invitation) else { throw GroupSafetyError.staleInvitation }
        isApplyingRecoveryDecision = true
        defer { isApplyingRecoveryDecision = false }
        do {
            try await runtime.declineGroupRejoin(accountRef: accountRef, welcomeIdHex: invitation.welcomeIdHex)
            recovery?.rejoinInvitations.removeAll { $0.welcomeIdHex == invitation.welcomeIdHex }
            error = nil
        } catch {
            await load(canModerate: canModerate)
            throw error
        }
    }

    @discardableResult
    func forgetLocally() async throws -> Bool {
        guard !isModerating else { return false }
        isModerating = true
        defer { isModerating = false }
        do {
            let forgotten = try await runtime.forgetGroupLocal(accountRef: accountRef, groupIdHex: groupIdHex)
            error = nil
            return forgotten
        } catch {
            self.error = error.localizedDescription
            throw error
        }
    }

    private func containsDisplayed(_ invitation: GroupRejoinInvitationFfi) -> Bool {
        recovery?.rejoinInvitations.contains {
            $0.welcomeIdHex == invitation.welcomeIdHex
                && $0.welcomerAccountIdHex == invitation.welcomerAccountIdHex
                && $0.epoch == invitation.epoch
                && $0.localStateToken == invitation.localStateToken
        } == true
    }
}
