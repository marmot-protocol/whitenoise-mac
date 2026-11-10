import MarmotKit
import Testing

@testable import whitenoise_mac

/// MarmotKit 0.15's account recovery status: which chats, and whether the inbox, are still catching
/// up after time offline. The app shows "Catching up" from it and re-reads on `RecoveryStatusChanged`.
@MainActor
struct AccountRecoveryStatusTests: WorkspaceTestSupport {
    private static let account = AccountItem.samples[0]

    private func makeModel(_ runtime: FakeMarmotRuntime, showDelay: Duration = .zero) -> AccountRecoveryStatusViewModel
    {
        AccountRecoveryStatusViewModel(
            accountRef: Self.account.accountRef,
            accountIdHex: Self.account.accountIdHex,
            runtime: runtime,
            showDelay: showDelay
        )
    }

    /// MDK reports every short fetch its recovery runner makes, so a chat or the inbox shows
    /// "Catching up" only after `showDelay` without a break, hides as soon as MDK clears it, and a
    /// break starts the wait over. No step depends on how late a sleep wakes: a model that kept
    /// the old start time would show the re-reported group within the same `refresh()`.
    @Test func catchingUpShowsOnlyAfterAnUnbrokenDelayAndABreakRestartsIt() async {
        let runtime = FakeMarmotRuntime(accounts: [])
        runtime.catchingUpGroupIds = ["group"]
        runtime.inboxCatchingUp = true
        let model = makeModel(runtime, showDelay: .milliseconds(100))

        await model.refresh()
        #expect(!model.isCatchingUp)
        await Self.waitUntil { model.isCatchingUp(groupIdHex: "group") }
        #expect(model.isCatchingUp)

        runtime.catchingUpGroupIds = []
        runtime.inboxCatchingUp = false
        await model.refresh()
        #expect(!model.isCatchingUp)

        runtime.catchingUpGroupIds = ["group"]
        await model.refresh()
        #expect(!model.isCatchingUp(groupIdHex: "group"))
        #expect(!model.isCatchingUp)
        model.stop()
    }

    @Test func catchingUpGroupsAreMatchedWhateverTheirCase() async {
        let runtime = FakeMarmotRuntime(accounts: [])
        runtime.catchingUpGroupIds = ["ABCDEF"]
        let model = makeModel(runtime)

        await model.refresh()

        #expect(model.isCatchingUp)
        #expect(model.isCatchingUp(groupIdHex: "abcdef"))
        #expect(!model.isCatchingUp(groupIdHex: "other"))
        #expect(!model.inboxCatchingUp)
    }

    @Test func theInboxAloneCountsAsCatchingUp() async {
        let runtime = FakeMarmotRuntime(accounts: [])
        runtime.inboxCatchingUp = true
        let model = makeModel(runtime)

        await model.refresh()

        #expect(model.isCatchingUp)
        #expect(model.catchingUpGroupIds.isEmpty)
    }

    @Test func aFailedReadKeepsTheLastStatus() async {
        let runtime = FakeMarmotRuntime(accounts: [])
        runtime.catchingUpGroupIds = ["group"]
        let model = makeModel(runtime)
        await model.refresh()
        runtime.accountRecoveryStatusError = FakeMarmotRuntimeError.unused

        await model.refresh()

        #expect(model.isCatchingUp(groupIdHex: "group"))
    }

    @Test func aChangeEventForThisAccountReReadsAndOthersAreIgnored() async {
        let runtime = FakeMarmotRuntime(accounts: [])
        runtime.catchingUpGroupIds = ["group"]
        let model = makeModel(runtime)
        model.start()
        defer { model.stop() }
        await Self.waitUntil { runtime.accountRecoveryStatusCallCount == 1 }
        #expect(model.isCatchingUp(groupIdHex: "group"))

        runtime.catchingUpGroupIds = []
        runtime.eventHub.emit(
            .recoveryStatusChanged(accountIdHex: AccountItem.samples[1].accountIdHex, accountLabel: "other")
        )
        runtime.eventHub.emit(
            .recoveryStatusChanged(accountIdHex: Self.account.accountIdHex.uppercased(), accountLabel: "jeff")
        )
        await Self.waitUntil { !model.isCatchingUp }

        #expect(runtime.accountRecoveryStatusCallCount == 2)
        #expect(!model.isCatchingUp)
    }

    @Test func switchingAccountsDiscardsTheOldStatus() async throws {
        let runtime = FakeMarmotRuntime(accounts: [])
        runtime.catchingUpGroupIds = ["group"]
        let session = SessionState()
        await session.activate(account: AccountItem.samples[0], runtime: runtime, connectivityAvailable: true)
        let first = try #require(session.accountScope?.recoveryStatus)
        await first.refresh()
        #expect(first.catchingUpGroupIds == ["group"])

        runtime.catchingUpGroupIds = []
        await session.activate(account: AccountItem.samples[1], runtime: runtime, connectivityAvailable: true)
        let second = try #require(session.accountScope?.recoveryStatus)

        #expect(second !== first)
        #expect(second.catchingUpGroupIds.isEmpty)
        #expect(!second.isCatchingUp)
        await session.deactivate()
    }
}
