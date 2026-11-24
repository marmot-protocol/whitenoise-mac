//
//  NotificationResponseRouterTests.swift
//  whitenoise-macTests
//
//  Where a click on a banner lands when the chats are not on screen yet: during launch, and
//  over the onboarding panes (Add Profile, a new identity's sign-up or setup).
//

import Foundation
import MarmotKit
import Testing

@testable import whitenoise_mac

@MainActor
@Suite(.serialized)
struct NotificationResponseRouterTests {
    private static let primary = AccountSummaryFfi(
        label: "primary-account",
        accountIdHex: "1111111111111111111111111111111111111111111111111111111111111111",
        localSigning: true,
        externalSigning: false,
        signedOut: false,
        running: true,
        unlinked: false
    )
    private static let invited = AccountSummaryFfi(
        label: "invited-account",
        accountIdHex: "2222222222222222222222222222222222222222222222222222222222222222",
        localSigning: true,
        externalSigning: false,
        signedOut: false,
        running: true,
        unlinked: false
    )

    /// Two signed-in identities; the invite's chat belongs to the second.
    private static func runtime() -> FakeMarmotRuntime {
        let runtime = FakeMarmotRuntime(accounts: [primary, invited])
        runtime.installDirectGroup(
            directGroup(),
            selfAccountIdHex: invited.accountIdHex,
            otherAccountIdHex: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
            otherDisplayName: "Alice",
            otherProfile: UserProfileMetadataFfi(
                name: "alice", displayName: "Alice", about: nil, picture: nil, nip05: nil, lud16: nil
            )
        )
        return runtime
    }

    private static let inviteClick = [
        "groupIdHex": "direct-group",
        "accountIdHex": invited.accountIdHex,
        "accountRef": invited.label,
    ]

    private func withPrimaryActive(_ body: () async throws -> Void) async rethrows {
        let previous = UserDefaults.standard.object(forKey: WorkspaceState.activeAccountKey)
        defer { restoreDefault(previous, forKey: WorkspaceState.activeAccountKey) }
        UserDefaults.standard.set(Self.primary.label, forKey: WorkspaceState.activeAccountKey)
        try await body()
    }

    /// The reported bug: with Add Profile open, a click switched identity and selected the chat
    /// behind the sign-up pane, so the user stayed on Sign Up. It now leaves onboarding the way
    /// Cancel does and opens the invite on the account it was for.
    @Test func clickDuringAddProfileLeavesOnboardingForTheInvitedAccountsChat() async throws {
        try await withPrimaryActive {
            let runtime = Self.runtime()
            let state = WorkspaceState(clientFactory: { runtime })
            await state.bootstrap()
            #expect(state.activeAccountId == Self.primary.label)

            state.showAccountOnboarding()
            state.showSignUp()
            #expect(state.phase == .onboarding)
            #expect(state.authenticationMode == .signUp)

            let router = NotificationResponseRouter(workspace: state) { nil }
            router.route(Self.inviteClick)

            #expect(state.phase == .ready)
            #expect(state.authenticationMode == .landing)
            #expect(state.activeAccountId == Self.invited.label)
            #expect(state.selection == .chat("direct-group"))
            #expect(router.pendingResponse == nil)
        }
    }

    /// A click from a quit app arrives while `bootstrap()` is still loading accounts. It used to
    /// match nothing and be dropped as "no longer available"; it is held until the chats show.
    @Test func clickDuringLaunchOpensTheChatOnceBootstrapFinishes() async throws {
        try await withPrimaryActive {
            let runtime = Self.runtime()
            let state = WorkspaceState(clientFactory: { runtime })
            #expect(state.phase == .bootstrapping)

            let router = NotificationResponseRouter(workspace: state) { nil }
            router.route(Self.inviteClick)
            #expect(router.pendingResponse == Self.inviteClick)
            #expect(
                state.backgroundStatus
                    != L10n.string("This notification is for an account or chat that is no longer available.")
            )

            await state.bootstrap()
            #expect(state.phase == .ready)
            router.phaseDidChange()

            #expect(router.pendingResponse == nil)
            #expect(state.activeAccountId == Self.invited.label)
            #expect(state.selection == .chat("direct-group"))
        }
    }

    /// A new identity's setup is never skipped for a banner: the click waits, and the chat opens
    /// once the setup has finished and the chats are on screen.
    @Test func clickDuringAnUnfinishedSetupWaitsForTheChats() async throws {
        try await withPrimaryActive {
            let runtime = Self.runtime()
            let state = WorkspaceState(clientFactory: { runtime })
            await state.bootstrap()
            state.phase = .onboarding
            let selectionBefore = state.selection

            let setup = await OnboardingFixtures.coordinator(
                OnboardingFixtures.snapshot(steps: [OnboardingFixtures.step(.relays, .checking)])
            )
            #expect(OnboardingView.showsAccountSetup(setup))

            let router = NotificationResponseRouter(workspace: state) { setup }
            router.route(Self.inviteClick)

            #expect(state.phase == .onboarding)
            #expect(state.selection == selectionBefore)
            #expect(state.activeAccountId == Self.primary.label)
            #expect(router.pendingResponse == Self.inviteClick)

            state.phase = .ready
            router.phaseDidChange()

            #expect(router.pendingResponse == nil)
            #expect(state.activeAccountId == Self.invited.label)
            #expect(state.selection == .chat("direct-group"))
        }
    }

    /// With nothing signed in there are no chats to open; the click leaves the pane alone.
    @Test func clickWithNothingSignedInStaysOnOnboarding() async throws {
        let state = WorkspaceState(clientFactory: { FakeMarmotRuntime(accounts: []) })
        await state.bootstrap()
        #expect(state.phase == .onboarding)

        let router = NotificationResponseRouter(workspace: state) { nil }
        router.route(Self.inviteClick)

        #expect(state.phase == .onboarding)
        #expect(state.selection == nil)
        #expect(router.pendingResponse == nil)
    }
}
