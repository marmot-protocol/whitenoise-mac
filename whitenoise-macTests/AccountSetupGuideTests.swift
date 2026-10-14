//
//  AccountSetupGuideTests.swift
//  whitenoise-macTests
//

import AppKit
import MarmotKit
import SwiftUI
import Testing

@testable import whitenoise_mac

/// The guided account setup after Sign In: which step the pane is about, which of its actions
/// become the pane's buttons, that a walked-through setup ends on Open Chats instead of jumping
/// to the chat list, and that its tallest states still fit the smallest window.
@Suite(.serialized) @MainActor struct AccountSetupGuideTests {

    // MARK: - Focus and progress

    @Test func theFirstOpenStepIsInFocusAndCountsItsPosition() {
        let guide = AccountSetupGuide(
            snapshot: Self.snapshot(steps: [
                Self.step(.profile, .passed),
                Self.step(.follows, .skipped),
                Self.step(.relays, .checking),
                Self.step(.inboxRelays, .pending),
            ]),
            recoveryRequired: false
        )

        #expect(guide.phase == .working(Self.step(.relays, .checking)))
        #expect(guide.focusedStep?.step == .relays)
        #expect(guide.completedCount == 2)
        #expect(guide.position == 3)
        #expect(guide.actions.isEmpty)
        #expect(guide.titleKey == "Getting ready to chat")
    }

    @Test func aStepThatNeedsTheUserTurnsTheGuideToAttention() {
        let relays = Self.step(
            .relays, .retryableFailure,
            actions: [.continueWithout, .editDiscoveryRelays, .useRecommendedRelays, .retry]
        )
        let guide = AccountSetupGuide(
            snapshot: Self.snapshot(steps: [Self.step(.profile, .passed), relays, Self.step(.keyPackage, .pending)]),
            recoveryRequired: false
        )

        #expect(guide.phase == .attention(relays))
        #expect(guide.titleKey == "A little more to do")
        // Ordered by importance, not by the order MarmotKit listed them: the pane makes the first
        // its primary button and the second its secondary.
        #expect(guide.actions == [.retry, .useRecommendedRelays, .editDiscoveryRelays, .continueWithout(.relays)])
        #expect(AccountSetupGuide.statusKey(relays) == "Fix to continue")
    }

    @Test func skippingTheProfileReadsAsNotNowAndAsOptional() {
        let profile = Self.step(.profile, .needsInput, actions: [.continueWithout, .retry])

        #expect(AccountSetupGuide.actions(for: profile) == [.retry, .continueWithout(.profile)])
        #expect(AccountSetupGuide.Action.continueWithout(.profile).titleKey == "Not Now")
        #expect(AccountSetupGuide.Action.continueWithout(.follows).titleKey == "Continue")
        #expect(AccountSetupGuide.statusKey(profile) == "Review or skip")
    }

    @Test func continueAnywayIsOnlyOfferedForTheSingleDeviceStep() {
        let device = Self.step(.singleDevice, .needsInput, actions: [.continueAnyway])
        let relays = Self.step(.relays, .needsInput, actions: [.continueAnyway, .retry])

        #expect(AccountSetupGuide.actions(for: device) == [.continueAnyway])
        #expect(AccountSetupGuide.statusKey(device) == "Review to continue")
        #expect(AccountSetupGuide.actions(for: relays) == [.retry])
    }

    @Test func recoveryOutranksCancellationWhichOutranksReady() {
        let ready = Self.snapshot(steps: [Self.step(.profile, .passed)], ready: true)
        var cancelling = ready
        cancelling.cancellationPending = true

        #expect(AccountSetupGuide(snapshot: ready, recoveryRequired: false).phase == .ready)
        #expect(AccountSetupGuide(snapshot: ready, recoveryRequired: false).position == 1)
        #expect(AccountSetupGuide(snapshot: cancelling, recoveryRequired: false).phase == .cancelling)
        #expect(AccountSetupGuide(snapshot: cancelling, recoveryRequired: true).phase == .recovery)
    }

    /// Every key the guide hands the pane is in the catalog, so no step shows English in a
    /// translated build.
    @Test func everyGuideKeyIsInTheCatalog() throws {
        let steps: [OnboardingStepFfi] = [.profile, .follows, .relays, .inboxRelays, .singleDevice, .keyPackage]
        var keys = steps.flatMap { [AccountSetupGuide.titleKey($0), AccountSetupGuide.descriptionKey($0)] }
        let actions: [AccountSetupGuide.Action] = [
            .approveRepair, .continueAnyway, .retry, .useRecommendedRelays, .editDiscoveryRelays,
            .continueWithout(.profile), .continueWithout(.relays), .cancelRepair,
        ]
        keys += actions.map(\.titleKey)
        let phases: [(OnboardingSnapshotFfi?, Bool)] = [
            (Self.snapshot(steps: [Self.step(.profile, .checking)]), false),
            (Self.snapshot(steps: [Self.step(.profile, .needsInput)]), false),
            (Self.snapshot(steps: [], ready: true), false),
            (nil, true),
        ]
        for (snapshot, recovery) in phases {
            let guide = AccountSetupGuide(snapshot: snapshot, recoveryRequired: recovery)
            keys += [guide.titleKey, guide.subtitleKey]
        }

        let german = try #require(Bundle.main.path(forResource: "de", ofType: "lproj").flatMap(Bundle.init(path:)))
        for key in keys {
            #expect(german.localizedString(forKey: key, value: nil, table: nil) != key, "untranslated: \(key)")
        }
    }

    // MARK: - Open Chats

    @Test func aWalkedThroughSetupWaitsForOpenChats() async {
        let runtime = FakeMarmotRuntime(accounts: [])
        runtime.onboardingState = Self.snapshot(steps: [Self.step(.relays, .checking)])
        let model = OnboardingCoordinator(accountRef: "account", runtime: runtime)

        await model.run()
        #expect(model.canEnterChats == false)

        runtime.onboardingState = Self.snapshot(steps: [Self.step(.relays, .passed)], ready: true, revision: 5)
        await model.run()

        #expect(model.isDurablyReady)
        #expect(model.canEnterChats == false)

        model.openChats()
        #expect(model.canEnterChats)
    }

    @Test func anAlreadyReadyCheckpointGoesStraightIn() async {
        let runtime = FakeMarmotRuntime(accounts: [])
        runtime.onboardingState = Self.snapshot(steps: [Self.step(.relays, .passed)], ready: true)
        let model = OnboardingCoordinator(accountRef: "account", runtime: runtime)

        await model.run()

        #expect(model.canEnterChats)
    }

    @Test func openChatsDoesNothingBeforeTheCheckpointIsReady() async {
        let runtime = FakeMarmotRuntime(accounts: [])
        runtime.onboardingState = Self.snapshot(steps: [Self.step(.relays, .checking)])
        let model = OnboardingCoordinator(accountRef: "account", runtime: runtime)

        await model.run()
        model.openChats()

        #expect(model.hasConfirmedOpenChats == false)
        #expect(model.canEnterChats == false)
    }

    // MARK: - Fit

    /// The pane's tallest states — a failing step with findings and three actions, the recovery
    /// explanation, and the finished summary — drawn at their floor still fit the smallest window.
    @Test func theTallestSetupStatesFitTheSmallestWindow() async throws {
        let attention = Self.snapshot(steps: [
            Self.step(.profile, .passed),
            Self.step(.follows, .skipped),
            Self.step(
                .relays, .retryableFailure,
                findings: [
                    .init(issue: .unreachable, endpoint: "wss://relay.example.com"),
                    .init(issue: .timedOut, endpoint: "wss://another-relay.example.com"),
                ],
                actions: [.retry, .useRecommendedRelays, .editDiscoveryRelays, .continueWithout]
            ),
            Self.step(.inboxRelays, .pending),
            Self.step(.singleDevice, .pending),
            Self.step(.keyPackage, .pending),
        ])
        let ready = Self.snapshot(
            steps: [OnboardingStepFfi.profile, .follows, .relays, .inboxRelays, .singleDevice, .keyPackage]
                .map { Self.step($0, .passed) },
            ready: true
        )
        var recovery = attention
        recovery.recoveryEpoch = "epoch"

        for (name, snapshot) in [("attention", attention), ("ready", ready), ("recovery", recovery)] {
            let runtime = FakeMarmotRuntime(accounts: [])
            runtime.onboardingState = snapshot
            let model = OnboardingCoordinator(accountRef: "account", runtime: runtime)
            await model.run()

            let pane = AccountSetupView(model: model)
                .environment(WorkspaceState.preview())
                .frame(width: Self.minimumWindowWidth)
            let height = try #require(ImageRenderer(content: pane).nsImage?.size.height)
            #expect(height <= Self.minimumWindowHeight, "the \(name) state needs \(height)pt")
        }
    }

    // MARK: - Fixtures

    private static let minimumWindowWidth: CGFloat = 940
    private static let minimumWindowHeight: CGFloat = 620

    private static func step(
        _ step: OnboardingStepFfi,
        _ status: OnboardingStatusFfi,
        findings: [OnboardingFindingFfi] = [],
        actions: [OnboardingActionFfi] = []
    ) -> OnboardingStepStateFfi {
        OnboardingStepStateFfi(step: step, status: status, findings: findings, actions: actions, checkedAt: nil)
    }

    private static func snapshot(
        steps: [OnboardingStepStateFfi],
        ready: Bool = false,
        revision: UInt64 = 1
    ) -> OnboardingSnapshotFfi {
        OnboardingSnapshotFfi(
            accountIdHex: "account-id",
            recoveryEpoch: nil,
            revision: revision,
            ready: ready,
            steps: steps,
            proposal: nil,
            singleDeviceNotice: nil,
            cancellationPending: false
        )
    }
}
