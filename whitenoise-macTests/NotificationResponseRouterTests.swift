//
//  NotificationResponseRouterTests.swift
//  whitenoise-macTests
//
//  Where a click on a banner lands when the chats are not on screen yet: during launch, and
//  over the onboarding panes (Add Profile, a new identity's sign-up or setup).
//

import Foundation
import MarmotKit
import Observation
import Testing

@testable import whitenoise_mac

@MainActor
@Suite(.serialized)
struct NotificationResponseRouterTests: WorkspaceTestSupport {
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

            let clock = TestNow()
            let router = NotificationResponseRouter(workspace: state, now: { clock.date }) { nil }
            router.route(Self.inviteClick)
            #expect(router.pendingResponse == Self.inviteClick)
            // A slow launch does not expire the click: the user is still waiting on it.
            clock.date += NotificationResponseRouter.setupHoldLifetime * 10
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

    /// The shell replays on `.onChange(of: phase)`, and `activateReadyState()` sets `.ready`
    /// *before* its own notification, chat-list and deep-link awaits. So the replay runs inside
    /// bootstrap, not after it: the switch it makes has to survive bootstrap's remaining reloads.
    @Test func clickDuringLaunchReplayedAsThePhaseFlipsOpensTheChat() async throws {
        try await withPrimaryActive {
            let runtime = Self.runtime()
            let state = WorkspaceState(clientFactory: { runtime })
            let router = NotificationResponseRouter(workspace: state) { nil }
            router.route(Self.inviteClick)

            let replay = ReplayProbe()
            Self.onFirstReady(state) {
                replay.ranBeforeBootstrapReturned = !replay.bootstrapReturned
                router.phaseDidChange()
            }
            await state.bootstrap()
            replay.bootstrapReturned = true

            #expect(replay.ranBeforeBootstrapReturned == true, "the replay must land inside bootstrap")
            #expect(router.pendingResponse == nil)
            #expect(state.activeAccountId == Self.invited.label)
            #expect(state.selection == .chat("direct-group"))
            await Self.waitUntil { state.chatsByAccount[Self.invited.label]?.isEmpty == false }
            #expect(state.chatsByAccount[Self.invited.label]?.contains { $0.id == "direct-group" } == true)
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
            #expect(setup.isWalkingThroughSetup)

            let router = NotificationResponseRouter(workspace: state) { setup }
            router.route(Self.inviteClick)

            #expect(state.phase == .onboarding)
            #expect(state.selection == selectionBefore)
            #expect(state.activeAccountId == Self.primary.label)
            #expect(router.pendingResponse == Self.inviteClick)
            #expect(setup.hasConfirmedOpenChats == false, "an unfinished setup is never skipped")

            state.phase = .ready
            router.phaseDidChange()

            #expect(router.pendingResponse == nil)
            #expect(state.activeAccountId == Self.invited.label)
            #expect(state.selection == .chat("direct-group"))
        }
    }

    /// The usual way an invite is clicked: a freshly signed-up identity finished its setup and sits
    /// on "You’re ready to chat". The click presses Open Chats for the user and opens the invite
    /// once the shell has taken the phase to `.ready`.
    @Test func clickOnAFinishedSetupOpensTheChatsThenTheInvite() async throws {
        try await withPrimaryActive {
            let runtime = Self.runtime()
            let state = WorkspaceState(clientFactory: { runtime })
            await state.bootstrap()
            state.phase = .onboarding

            let setupRuntime = FakeMarmotRuntime(accounts: [])
            let setup = await OnboardingFixtures.coordinator(
                OnboardingFixtures.snapshot(steps: [OnboardingFixtures.step(.relays, .checking)]),
                runtime: setupRuntime
            )
            setupRuntime.onboardingState = OnboardingFixtures.snapshot(
                steps: [OnboardingFixtures.step(.relays, .passed)], ready: true, revision: 5
            )
            await setup.run()
            #expect(setup.hasShownIncompleteSetup)
            #expect(setup.isDurablyReady)
            #expect(setup.hasConfirmedOpenChats == false)

            let router = NotificationResponseRouter(workspace: state) { setup }
            router.route(Self.inviteClick)

            #expect(setup.hasConfirmedOpenChats)
            #expect(setup.canEnterChats)
            #expect(router.pendingResponse == Self.inviteClick)
            #expect(state.phase == .onboarding)
            #expect(state.activeAccountId == Self.primary.label)

            state.phase = .ready
            router.phaseDidChange()

            #expect(router.pendingResponse == nil)
            #expect(state.activeAccountId == Self.invited.label)
            #expect(state.selection == .chat("direct-group"))
        }
    }

    /// A sign-in or sign-up in flight picks the active identity itself; a click then is dropped
    /// rather than switching identity under it.
    @Test func clickDuringASignInInFlightIsDropped() async throws {
        try await withPrimaryActive {
            let runtime = Self.runtime()
            let state = WorkspaceState(clientFactory: { runtime })
            await state.bootstrap()
            state.showAccountOnboarding()
            state.showSignUp()
            state.authenticationActivity = .signUp
            defer { state.authenticationActivity = nil }
            #expect(state.isAuthenticating)
            let selectionBefore = state.selection
            // The new identity's checkpoint already shows while its sign-in finishes; without the
            // in-flight check the click would be held for that setup and replayed afterwards.
            let setup = await OnboardingFixtures.coordinator(
                OnboardingFixtures.snapshot(steps: [OnboardingFixtures.step(.relays, .checking)])
            )
            #expect(setup.isWalkingThroughSetup)

            let router = NotificationResponseRouter(workspace: state) { setup }
            router.route(Self.inviteClick)

            #expect(router.pendingResponse == nil)
            #expect(state.phase == .onboarding)
            #expect(state.authenticationMode == .signUp)
            #expect(state.activeAccountId == Self.primary.label)
            #expect(state.selection == selectionBefore)
        }
    }

    /// A slow setup — a relay or KeyPackage check on a bad network — still running just short of
    /// the lifetime keeps its click: the user is still waiting on it, and Open Chats opens it.
    @Test func aClickHeldForASetupStillRunningJustBeforeItsLifetimeOpensTheChat() async throws {
        try await withPrimaryActive {
            let runtime = Self.runtime()
            let state = WorkspaceState(clientFactory: { runtime })
            await state.bootstrap()
            state.phase = .onboarding

            let setup = await OnboardingFixtures.coordinator(
                OnboardingFixtures.snapshot(steps: [OnboardingFixtures.step(.relays, .checking)])
            )
            let clock = TestNow()
            let router = NotificationResponseRouter(workspace: state, now: { clock.date }) { setup }
            router.route(Self.inviteClick)
            #expect(router.pendingResponse == Self.inviteClick)
            #expect(setup.isDurablyReady == false, "the setup is still running")

            clock.date += NotificationResponseRouter.setupHoldLifetime - 1
            state.phase = .ready
            router.phaseDidChange()

            #expect(router.pendingResponse == nil)
            #expect(state.activeAccountId == Self.invited.label)
            #expect(state.selection == .chat("direct-group"))
        }
    }

    /// A click whose setup is still on screen after the lifetime is stale by the time the chats
    /// show; it is dropped instead of jumping to an old invite.
    @Test func aClickHeldForASetupExpires() async throws {
        try await withPrimaryActive {
            let runtime = Self.runtime()
            let state = WorkspaceState(clientFactory: { runtime })
            await state.bootstrap()
            state.phase = .onboarding
            let selectionBefore = state.selection

            let setup = await OnboardingFixtures.coordinator(
                OnboardingFixtures.snapshot(steps: [OnboardingFixtures.step(.relays, .checking)])
            )
            let clock = TestNow()
            let router = NotificationResponseRouter(workspace: state, now: { clock.date }) { setup }
            router.route(Self.inviteClick)
            #expect(router.pendingResponse == Self.inviteClick)

            clock.date += NotificationResponseRouter.setupHoldLifetime
            state.phase = .ready
            router.phaseDidChange()

            #expect(router.pendingResponse == nil)
            #expect(state.activeAccountId == Self.primary.label)
            #expect(state.selection == selectionBefore)
        }
    }

    /// A held click that is routed again without reaching the chats — a phase change that lands
    /// back in onboarding — keeps its original deadline rather than starting a new one.
    @Test func reholdingAClickKeepsItsOriginalExpiry() async throws {
        try await withPrimaryActive {
            let runtime = Self.runtime()
            let state = WorkspaceState(clientFactory: { runtime })
            await state.bootstrap()
            state.phase = .onboarding
            let selectionBefore = state.selection

            let setup = await OnboardingFixtures.coordinator(
                OnboardingFixtures.snapshot(steps: [OnboardingFixtures.step(.relays, .checking)])
            )
            let clock = TestNow()
            let router = NotificationResponseRouter(workspace: state, now: { clock.date }) { setup }
            router.route(Self.inviteClick)

            clock.date += NotificationResponseRouter.setupHoldLifetime - 1
            router.phaseDidChange()
            #expect(router.pendingResponse == Self.inviteClick, "still onboarding, so held again")

            clock.date += 1
            state.phase = .ready
            router.phaseDidChange()

            #expect(router.pendingResponse == nil)
            #expect(state.activeAccountId == Self.primary.label)
            #expect(state.selection == selectionBefore)
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

    /// Runs `body` on the main actor at the first hop after `state.phase` becomes `.ready` — where
    /// SwiftUI's `.onChange(of: phase)` runs, while whoever set it may still be suspended.
    private static func onFirstReady(_ state: WorkspaceState, _ body: @escaping @MainActor @Sendable () -> Void) {
        withObservationTracking {
            _ = state.phase
        } onChange: {
            Task { @MainActor in
                if state.phase == .ready { body() } else { onFirstReady(state, body) }
            }
        }
    }
}

@MainActor
private final class TestNow {
    var date = Date(timeIntervalSince1970: 1_800_000_000)
}

@MainActor
private final class ReplayProbe {
    var bootstrapReturned = false
    var ranBeforeBootstrapReturned: Bool?
}
