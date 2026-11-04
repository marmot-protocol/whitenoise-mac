import Foundation
import MarmotKit
import Testing

@testable import whitenoise_mac

/// Reporting users to the White Noise team (MDK's `submitModerationReport`), ported from
/// whitenoise-ios: the build's reports key, which menu actions a message offers, the Report Message
/// sheet's destinations and retry, and Block and Report.
@MainActor
private final class ReportCalls {
    var group = 0
    var team = 0
    var notices: [ModerationReportNotice] = []
}

@MainActor
struct ModerationReportTests {
    private static let me = String(repeating: "1", count: 64)
    private static let alice = String(repeating: "a", count: 64)

    private static func message(
        sender: String? = alice,
        isOutgoing: Bool = false,
        isDeleted: Bool = false,
        hasReports: Bool = false
    ) -> MessageItem {
        MessageItem(
            id: "message",
            groupIdHex: "group",
            senderAccountIdHex: sender,
            senderName: "Alice",
            body: "content",
            sentAt: .now,
            isDeleted: isDeleted,
            hasReports: hasReports,
            isOutgoing: isOutgoing
        )
    }

    private static func eligibility(
        _ message: MessageItem,
        isDirectChat: Bool = false,
        teamReportingAvailable: Bool = true
    ) -> MessageModerationEligibility {
        .resolve(
            for: message,
            isDirectChat: isDirectChat,
            teamReportingAvailable: teamReportingAvailable,
            activeAccountIdHex: me,
            canBlock: true
        )
    }

    private static func loadedReporter(
        _ runtime: FakeMarmotRuntime
    ) async -> ModerationReporter {
        let blockedUsers = BlockedUsersViewModel(accountRef: "account", runtime: runtime)
        blockedUsers.start()
        for _ in 0..<100 where !blockedUsers.isLoaded {
            await Task.yield()
        }
        return ModerationReporter(
            accountRef: "account",
            accountIdHex: me,
            runtime: runtime,
            blockedUsers: blockedUsers
        )
    }

    // MARK: Build configuration

    @Test func buildConfigIgnoresAMissingOrUnexpandedKey() {
        let key = ModerationReportBuildConfig.infoDictionaryKey
        #expect(ModerationReportBuildConfig.current(infoDictionary: [:]) == nil)
        #expect(ModerationReportBuildConfig.current(infoDictionary: [key: "  "]) == nil)
        #expect(
            ModerationReportBuildConfig.current(infoDictionary: [key: "$(WN_MODERATION_REPORT_PUBKEY)"]) == nil)
    }

    @Test func buildConfigPublishesOnlyToTheSeedRelays() {
        let config = ModerationReportBuildConfig.current(
            infoDictionary: [ModerationReportBuildConfig.infoDictionaryKey: " npub1example \n"]
        )
        #expect(config?.recipientPubkey == "npub1example")
        #expect(config?.ffi.relays == MarmotClient.seedRelays)
    }

    // MARK: Eligibility

    @Test func groupMessagesReportToTheGroupAndTheTeam() {
        let result = Self.eligibility(Self.message())
        #expect(result.reportsToGroup)
        #expect(result.reportsToTeam)
        #expect(result.canBlockAuthor)
        #expect(result.authorAccountIdHex == Self.alice)
    }

    @Test func directChatsHaveNoGroupReport() {
        let result = Self.eligibility(Self.message(), isDirectChat: true)
        #expect(!result.reportsToGroup)
        #expect(result.reportsToTeam)
        #expect(result.canReport)

        let withoutTeam = Self.eligibility(Self.message(), isDirectChat: true, teamReportingAvailable: false)
        #expect(!withoutTeam.canReport)
        // Blocking needs no report destination.
        #expect(withoutTeam.canBlockAuthor)
    }

    @Test func ownDeletedAndUnresolvedMessagesHaveNobodyToReport() {
        #expect(Self.eligibility(Self.message(isOutgoing: true)) == .none)
        #expect(Self.eligibility(Self.message(isDeleted: true)) == .none)
        #expect(Self.eligibility(Self.message(sender: Self.me)).reportsToTeam == false)

        // A row without a resolved author falls back to the display name: no key to report or block.
        let unresolved = Self.eligibility(Self.message(sender: nil))
        #expect(unresolved.reportsToGroup)
        #expect(!unresolved.reportsToTeam)
        #expect(!unresolved.canBlockAuthor)
    }

    @Test func authorKeysAreNormalized() {
        let result = Self.eligibility(Self.message(sender: Self.alice.uppercased()))
        #expect(result.authorAccountIdHex == Self.alice)
    }

    @Test func anAlreadyReportedMessageStillReachesTheTeam() {
        let result = Self.eligibility(Self.message(hasReports: true))
        #expect(!result.reportsToGroup)
        #expect(result.reportsToTeam)
    }

    // MARK: Submission plan

    @Test func aRetryAfterTheGroupReportOnlyFinishesTheTeamCopy() {
        #expect(
            ReportSubmissionPlan.plan(
                reportsToGroup: true, reportsToTeam: true, groupOutcomeRecorded: false, committedToTeam: nil)
                == ReportSubmissionPlan(toGroup: true, toTeam: true))
        #expect(
            ReportSubmissionPlan.plan(
                reportsToGroup: true, reportsToTeam: true, groupOutcomeRecorded: true, committedToTeam: true)
                == ReportSubmissionPlan(toGroup: false, toTeam: true))
        #expect(
            ReportSubmissionPlan.plan(
                reportsToGroup: true, reportsToTeam: false, groupOutcomeRecorded: true, committedToTeam: false)
                == nil)
        #expect(
            ReportSubmissionPlan.plan(
                reportsToGroup: false, reportsToTeam: false, groupOutcomeRecorded: false, committedToTeam: nil)
                == nil)
    }

    // MARK: Report Message sheet

    @Test func reportingAGroupMessageSendsToTheGroupAndTheTeam() async {
        let runtime = FakeMarmotRuntime(accounts: [])
        runtime.isModerationReportingAvailable = true
        let reporter = await Self.loadedReporter(runtime)
        let safety = GroupSafetyViewModel(
            accountRef: "account", groupIdHex: "group", runtime: runtime, moderation: reporter)
        let message = Self.message()
        let eligibility = safety.moderationEligibility(for: message, isDirectChat: false)
        let model = ReportMessageViewModel(
            eligibility: eligibility,
            dependencies: .live(
                messageId: message.id,
                authorAccountIdHex: eligibility.authorAccountIdHex,
                safety: safety,
                reporter: reporter
            )
        )
        model.reason = .impersonation
        model.explanation = "pretends to be me"

        await model.submit()

        #expect(model.isSubmitted)
        #expect(runtime.reportRequests.map(\.messageId) == ["message"])
        #expect(runtime.moderationReportRequests.count == 1)
        #expect(runtime.moderationReportRequests[0].reportedPubkey == Self.alice)
        #expect(runtime.moderationReportRequests[0].reason == .impersonation)
        #expect(runtime.moderationReportRequests[0].explanation == "pretends to be me")
        #expect(runtime.moderationReportRequests[0].origin == .report)
        #expect(reporter.notice?.kind == .success)
        #expect(
            reporter.notice?.message
                == ReportPresentation.outcome(
                    groupOutcome: ReportPresentation.groupOutcome(.published),
                    teamDisposition: .published
                ))
    }

    @Test func turningTheTeamCopyOffReportsOnlyToTheGroup() async {
        let calls = ReportCalls()
        let model = ReportMessageViewModel(
            eligibility: Self.eligibility(Self.message()),
            dependencies: ReportMessageDependencies(
                reportToGroup: { _, _ in
                    calls.group += 1
                    return .published
                },
                reportToTeam: { _, _ in
                    calls.team += 1
                    return .published
                },
                present: { _ in }
            )
        )
        model.sendsToTeam = false

        await model.submit()

        #expect(model.isSubmitted)
        #expect(calls.group == 1)
        #expect(calls.team == 0)
    }

    @Test func aDirectChatReportGoesOnlyToTheTeamWhateverTheToggleSays() async {
        let calls = ReportCalls()
        let model = ReportMessageViewModel(
            eligibility: Self.eligibility(Self.message(), isDirectChat: true),
            dependencies: ReportMessageDependencies(
                reportToGroup: { _, _ in
                    calls.group += 1
                    return .published
                },
                reportToTeam: { _, _ in
                    calls.team += 1
                    return .acceptedPending
                },
                present: { _ in }
            )
        )
        model.sendsToTeam = false
        #expect(model.reportsToTeam)

        await model.submit()

        #expect(calls.group == 0)
        #expect(calls.team == 1)
    }

    @Test func aFailedTeamCopyLocksTheReportAndRetriesWithoutReportingToTheGroupTwice() async {
        let calls = ReportCalls()
        let model = ReportMessageViewModel(
            eligibility: Self.eligibility(Self.message()),
            dependencies: ReportMessageDependencies(
                reportToGroup: { _, _ in
                    calls.group += 1
                    return .acceptedPending
                },
                reportToTeam: { _, _ in
                    calls.team += 1
                    if calls.team == 1 { throw MarmotKitError.ModerationReportRateLimited }
                    return .published
                },
                present: { calls.notices.append($0) }
            )
        )

        await model.submit()

        #expect(!model.isSubmitted)
        #expect(model.isLocked)
        #expect(
            model.error
                == ReportPresentation.teamFailure(
                    groupOutcome: ReportPresentation.groupOutcome(.acceptedPending),
                    failure: L10n.string("You’ve sent a lot of reports recently. Try again later.")
                ))
        #expect(calls.notices.isEmpty)

        await model.submit()

        #expect(model.isSubmitted)
        #expect(calls.group == 1)
        #expect(calls.team == 2)
        #expect(calls.notices.count == 1)
    }

    @Test func explanationsAreCappedAtOneThousandCharacters() {
        let model = ReportMessageViewModel(eligibility: Self.eligibility(Self.message()), dependencies: .inert)
        model.explanation = String(repeating: "x", count: 1_200)
        #expect(model.explanation.count == ReportMessageViewModel.explanationLimit)
    }

    // MARK: Block and Report

    @Test func blockAndReportReportsOnlyAfterTheBlockIsConfirmed() async {
        let runtime = FakeMarmotRuntime(accounts: [])
        runtime.isModerationReportingAvailable = true
        let reporter = await Self.loadedReporter(runtime)

        await reporter.block(accountIdHex: Self.alice, reporting: true)

        #expect(reporter.blockedUsers.isBlocked(accountID: Self.alice))
        #expect(runtime.moderationReportRequests.count == 1)
        #expect(runtime.moderationReportRequests[0].reportedPubkey == Self.alice)
        #expect(runtime.moderationReportRequests[0].reason == .other)
        #expect(runtime.moderationReportRequests[0].explanation.isEmpty)
        #expect(runtime.moderationReportRequests[0].origin == .blockAndReport)
        #expect(reporter.notice?.kind == .success)
    }

    @Test func aFailedBlockSendsNoReport() async {
        let runtime = FakeMarmotRuntime(accounts: [])
        runtime.isModerationReportingAvailable = true
        let reporter = await Self.loadedReporter(runtime)
        runtime.blockUserError = MarmotKitError.StorageClosed(details: "closed")

        await reporter.block(accountIdHex: Self.alice, reporting: true)

        #expect(!reporter.blockedUsers.isBlocked(accountID: Self.alice))
        #expect(runtime.moderationReportRequests.isEmpty)
        #expect(reporter.notice?.kind == .failure)
        #expect(reporter.notice?.title == L10n.string("Couldn't block user"))
    }

    @Test func blockingWithoutAReportsKeyOnlyBlocks() async {
        let runtime = FakeMarmotRuntime(accounts: [])
        let reporter = await Self.loadedReporter(runtime)
        #expect(!reporter.isAvailable)

        await reporter.block(accountIdHex: Self.alice, reporting: true)

        #expect(reporter.blockedUsers.isBlocked(accountID: Self.alice))
        #expect(runtime.moderationReportRequests.isEmpty)
        #expect(reporter.notice == nil)
    }

    @Test func aRefusedBlockReportIsFeedbackNotAnUndo() async {
        let runtime = FakeMarmotRuntime(accounts: [])
        runtime.isModerationReportingAvailable = true
        runtime.moderationReportError = MarmotKitError.CannotReportSelf
        let reporter = await Self.loadedReporter(runtime)

        await reporter.block(accountIdHex: Self.alice, reporting: true)

        #expect(reporter.blockedUsers.isBlocked(accountID: Self.alice))
        #expect(reporter.notice?.kind == .failure)
        #expect(reporter.notice?.message == L10n.string("You can’t report yourself."))
    }

    @Test func anOlderNoticeTimerNeverHidesANewerNotice() async {
        let reporter = await Self.loadedReporter(FakeMarmotRuntime(accounts: []))
        let first = ModerationReportNotice(kind: .success, title: "first", message: nil)
        let second = ModerationReportNotice(kind: .success, title: "second", message: nil)
        reporter.present(first)
        reporter.present(second)

        reporter.dismissNotice(first.id)
        #expect(reporter.notice == second)

        reporter.dismissNotice(second.id)
        #expect(reporter.notice == nil)
    }
}
