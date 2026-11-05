import Foundation
import MarmotKit
import Observation

/// Where one Report Message submit goes. `live` binds the conversation's group report and the
/// account's White Noise path; `inert` drives previews.
struct ReportMessageDependencies {
    /// Reports the message inside the encrypted group, where its members can read it.
    var reportToGroup:
        @MainActor (_ reason: ReportReasonFfi, _ explanation: String) async throws -> SendAcceptDispositionFfi
    /// Reports the message's author privately to the White Noise team; nil when this build cannot.
    var reportToTeam:
        (@MainActor (_ reason: ReportReasonFfi, _ explanation: String) async throws -> SendAcceptDispositionFfi)?
    /// Shows the submitted report's outcome once the sheet has closed.
    var present: @MainActor (ModerationReportNotice) -> Void
}

extension ReportMessageDependencies {
    static func live(
        messageId: String,
        authorAccountIdHex: String?,
        safety: GroupSafetyViewModel,
        reporter: ModerationReporter?
    ) -> ReportMessageDependencies {
        var reportToTeam: (@MainActor (ReportReasonFfi, String) async throws -> SendAcceptDispositionFfi)?
        if let reporter, reporter.isAvailable, let authorAccountIdHex {
            reportToTeam = { reason, explanation in
                try await reporter.submit(
                    reportedAccountIdHex: authorAccountIdHex,
                    reason: reason,
                    explanation: explanation,
                    origin: .report
                )
            }
        }
        return ReportMessageDependencies(
            reportToGroup: { reason, explanation in
                try await safety.report(messageID: messageId, reason: reason, explanation: explanation)
                    .acceptDisposition
            },
            reportToTeam: reportToTeam,
            present: { notice in reporter?.present(notice) }
        )
    }

    static let inert = ReportMessageDependencies(
        reportToGroup: { _, _ in .published },
        reportToTeam: { _, _ in .published },
        present: { _ in }
    )
}

/// One Report Message sheet: the reason and explanation, where the report goes, and the submit.
///
/// A group report is shared inside the encrypted group; the White Noise copy goes privately to the
/// team through `ModerationReporter`. Either or both may apply (`MessageModerationEligibility`), and
/// a direct chat only ever has the White Noise copy. When the group report lands but the White Noise
/// copy fails, the form locks and a retry sends only the copy, so the group never gets it twice.
@MainActor
@Observable
final class ReportMessageViewModel: Identifiable {
    static let explanationLimit = 1_000

    let id = UUID()
    let reportsToGroup: Bool
    let canReportToTeam: Bool
    var reason: ReportReasonFfi = .spam
    var explanation = "" {
        didSet {
            if explanation.count > Self.explanationLimit {
                explanation = String(explanation.prefix(Self.explanationLimit))
            }
        }
    }
    /// Only offered as a choice when there is also a group report; otherwise the White Noise copy is
    /// the whole report.
    var sendsToTeam = true
    private(set) var isSending = false
    private(set) var isSubmitted = false
    private(set) var error: String?
    /// The group report's status once it landed. A retry after a failed White Noise copy must not
    /// report to the group twice.
    private(set) var groupOutcome: String?

    @ObservationIgnored private let dependencies: ReportMessageDependencies
    /// What the first submit committed to; a retry finishes exactly that.
    @ObservationIgnored private var committedToTeam: Bool?

    init(eligibility: MessageModerationEligibility, dependencies: ReportMessageDependencies) {
        self.reportsToGroup = eligibility.reportsToGroup
        self.canReportToTeam = eligibility.reportsToTeam && dependencies.reportToTeam != nil
        self.dependencies = dependencies
    }

    var reportsToTeam: Bool {
        canReportToTeam && (sendsToTeam || !reportsToGroup)
    }

    /// Once the group has the report, a retried White Noise copy must say the same thing.
    var isLocked: Bool { isSending || groupOutcome != nil }

    var plan: ReportSubmissionPlan? {
        ReportSubmissionPlan.plan(
            reportsToGroup: reportsToGroup,
            reportsToTeam: reportsToTeam,
            groupOutcomeRecorded: groupOutcome != nil,
            committedToTeam: committedToTeam
        )
    }

    var canSubmit: Bool { !isSending && !isSubmitted && plan != nil }

    func submit() async {
        guard !isSending, !isSubmitted, let plan else { return }
        if groupOutcome == nil { committedToTeam = plan.toTeam }
        let reason = reason
        let explanation = explanation
        isSending = true
        error = nil
        defer { isSending = false }

        if plan.toGroup {
            do {
                let disposition = try await dependencies.reportToGroup(reason, explanation)
                groupOutcome = ReportPresentation.groupOutcome(disposition)
            } catch is CancellationError {
                return
            } catch {
                self.error = ReportPresentation.errorMessage(for: error)
                return
            }
        }

        var teamDisposition: SendAcceptDispositionFfi?
        if plan.toTeam, let reportToTeam = dependencies.reportToTeam {
            do {
                teamDisposition = try await reportToTeam(reason, explanation)
            } catch is CancellationError {
                return
            } catch {
                self.error = ReportPresentation.teamFailure(
                    groupOutcome: groupOutcome,
                    failure: ReportPresentation.errorMessage(for: error)
                )
                return
            }
        }

        isSubmitted = true
        dependencies.present(
            ModerationReportNotice(
                kind: .success,
                title: L10n.string("Report submitted"),
                message: ReportPresentation.outcome(groupOutcome: groupOutcome, teamDisposition: teamDisposition)
            ))
    }
}
