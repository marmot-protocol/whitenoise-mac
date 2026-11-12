import MarmotKit
import Testing

@testable import whitenoise_mac

/// MarmotKit 0.15 `QueuedIntentRefused`: a send that waited for its group to settle was dropped.
/// Nothing retries it, so the user gets a toast — once per intent, for this account only.
@MainActor
struct RefusedIntentNoticesTests: WorkspaceTestSupport {
    private static let account = AccountItem.samples[0]

    private static func refused(
        account: AccountItem? = nil, intentId: String = "intent-1", kind: String = "invite",
        reason: String = "not_group_admin", artifact: OversizedArtifactFfi? = nil,
        sizeClass: EventSizeClassFfi? = nil
    ) -> MarmotEventFfi {
        .groupEvent(
            accountIdHex: (account ?? Self.account).accountIdHex,
            accountLabel: "jeff",
            groupIdHex: "group",
            event: .queuedIntentRefused(
                intentIdHex: intentId, intentKind: kind, reason: reason, artifact: artifact, sizeClass: sizeClass)
        )
    }

    @Test func aRefusalShowsItsKindAndReason() async {
        let runtime = FakeMarmotRuntime(accounts: [])
        let model = RefusedIntentNoticesViewModel(accountIdHex: Self.account.accountIdHex, runtime: runtime)
        model.start()
        defer { model.stop() }

        runtime.eventHub.emit(Self.refused())
        await Self.waitUntil { model.notice != nil }

        #expect(model.notice?.title == RefusedIntentPresentation.title(intentKind: "invite"))
        #expect(model.notice?.message == RefusedIntentPresentation.message(reason: "not_group_admin"))
    }

    @Test func aRepeatedDeliveryOfTheSameIntentIsAnnouncedOnce() {
        let model = RefusedIntentNoticesViewModel(accountIdHex: Self.account.accountIdHex, runtime: nil)

        #expect(model.announce(intentIdHex: "ABC", intentKind: "leave", reason: "x"))
        let first = model.notice
        #expect(!model.announce(intentIdHex: "abc", intentKind: "leave", reason: "x"))
        #expect(model.notice == first)
        #expect(model.announce(intentIdHex: "def", intentKind: "leave", reason: "x"))
    }

    @Test func otherAccountsAndOtherGroupEventsAreIgnored() async {
        let runtime = FakeMarmotRuntime(accounts: [])
        let model = RefusedIntentNoticesViewModel(accountIdHex: Self.account.accountIdHex, runtime: runtime)
        model.start()
        defer { model.stop() }

        runtime.eventHub.emit(Self.refused(account: AccountItem.samples[1], intentId: "other"))
        // A matching event after the ignored one proves it was consumed and skipped.
        runtime.eventHub.emit(Self.refused(intentId: "mine", kind: "app_message"))
        await Self.waitUntil { model.notice != nil }

        #expect(model.notice?.title == RefusedIntentPresentation.title(intentKind: "app_message"))
    }

    @Test func unknownKindsAndReasonsFallBackToGeneralWording() {
        #expect(
            RefusedIntentPresentation.title(intentKind: "something_new")
                == RefusedIntentPresentation.title(intentKind: "another_new"))
        #expect(
            RefusedIntentPresentation.message(reason: "something_new")
                != RefusedIntentPresentation.message(reason: "not_a_member"))
    }

    /// MarmotKit 0.16.0: a change no relay would take for size is retired once, naming the
    /// artifact. A Welcome refused by the invitee's inbox relays reads differently from a commit.
    @Test func anOversizedRefusalNamesWhatWasTooLarge() async {
        let runtime = FakeMarmotRuntime(accounts: [])
        let model = RefusedIntentNoticesViewModel(accountIdHex: Self.account.accountIdHex, runtime: runtime)
        model.start()
        defer { model.stop() }

        runtime.eventHub.emit(
            Self.refused(reason: "event_too_large", artifact: .welcome, sizeClass: .from64To128Kib))
        await Self.waitUntil { model.notice != nil }

        let welcome = RefusedIntentPresentation.message(reason: "event_too_large", artifact: .welcome)
        let commit = RefusedIntentPresentation.message(reason: "event_too_large", artifact: .commit)
        #expect(model.notice?.message == welcome)
        #expect(welcome != commit)
        #expect(commit != RefusedIntentPresentation.message(reason: "something_new"))
    }
}
