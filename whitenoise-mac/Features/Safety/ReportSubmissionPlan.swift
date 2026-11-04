import Foundation

/// Which destinations one Report Message submit sends to.
///
/// Live eligibility decides a fresh submit. Once the group has the report, a retry finishes exactly
/// what the first submit committed to — even if the message was deleted meanwhile — and never
/// reports to the group twice.
nonisolated struct ReportSubmissionPlan: Equatable, Sendable {
    let toGroup: Bool
    let toTeam: Bool

    static func plan(
        reportsToGroup: Bool,
        reportsToTeam: Bool,
        groupOutcomeRecorded: Bool,
        committedToTeam: Bool?
    ) -> ReportSubmissionPlan? {
        if groupOutcomeRecorded {
            guard committedToTeam == true else { return nil }
            return ReportSubmissionPlan(toGroup: false, toTeam: true)
        }
        guard reportsToGroup || reportsToTeam else { return nil }
        return ReportSubmissionPlan(toGroup: reportsToGroup, toTeam: reportsToTeam)
    }
}
