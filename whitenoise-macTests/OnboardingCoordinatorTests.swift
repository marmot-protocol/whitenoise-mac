//
//  OnboardingCoordinatorTests.swift
//  whitenoise-macTests
//

import MarmotKit
import Testing

@testable import whitenoise_mac

/// What each of `OnboardingCoordinator`'s commands asks MarmotKit for, and what it does with the
/// answer: install the returned checkpoint, or keep the error for the screen that pressed it.
@Suite(.serialized) @MainActor struct OnboardingCoordinatorTests {
    private typealias F = OnboardingFixtures

    /// Every command that returns a checkpoint installs it: the fake answers each one by moving
    /// the revision on by one.
    @Test func eachCommandInstallsTheCheckpointItReturns() async {
        let relays = F.step(
            .relays, .needsInput,
            actions: [.retry, .continueWithout, .editRelays, .useRecommendedRelays, .approveRepair, .cancelRepair]
        )
        let runtime = FakeMarmotRuntime(accounts: [])
        let model = await F.coordinator(F.snapshot(steps: [relays]), runtime: runtime)
        #expect(model.snapshot?.revision == 2)

        await model.retry(.relays)
        await model.skip(.relays)
        await model.proposeRelays(step: .relays, read: ["wss://a.example"], write: ["wss://a.example"])
        await model.proposeRecommendedRelays(step: .relays)
        await model.cancelRepair()
        await model.approveRepair()
        await model.acknowledgeSingleDevice()

        #expect(model.error == nil)
        #expect(model.snapshot?.revision == 9)
        #expect(model.isBusy == false)
    }

    @Test func searchingTheDefaultsLooksOnTheSeedRelaysAndPublishesNothing() async {
        let runtime = FakeMarmotRuntime(accounts: [])
        let model = await F.coordinator(
            F.snapshot(steps: [F.step(.inboxRelays, .retryableFailure, actions: [.editDiscoveryRelays])]),
            runtime: runtime
        )

        await model.searchDefaultRelays()
        await model.setDiscoveryRelays(["wss://other.example"])

        #expect(runtime.onboardingDiscoveryRelayUpdates == [MarmotClient.seedRelays, ["wss://other.example"]])
        #expect(runtime.uploadedProfileImageData == nil)
    }

    /// A command MarmotKit refuses leaves the last checkpoint on screen and says why.
    @Test func aRefusedCommandKeepsTheCheckpointAndReportsTheError() async {
        let runtime = FakeMarmotRuntime(accounts: [])
        let model = await F.coordinator(
            F.snapshot(steps: [F.step(.keyPackage, .retryableFailure, actions: [.retry])]), runtime: runtime
        )
        runtime.onboardingState = nil

        await model.retry(.keyPackage)

        #expect(model.snapshot?.revision == 2)
        #expect(model.error != nil)
        #expect(model.isBusy == false)
    }

    /// A pending check whose run throws, instead of returning a failed step, is not run again
    /// automatically: that would retry it at once, with no backoff, for as long as it throws.
    @Test func aPendingCheckThatThrowsIsNotRetriedInALoop() async {
        let runtime = FakeMarmotRuntime(accounts: [])
        let model = await F.coordinator(F.snapshot(steps: [F.step(.relays, .checking)]), runtime: runtime)
        runtime.onboardingState = F.snapshot(steps: [F.step(.relays, .pending)], revision: 5)
        runtime.runOnboardingError = FakeMarmotRuntimeError.unused
        let runsBefore = runtime.runOnboardingCallCount

        // The retry returns a pending step, so the coordinator runs it on its own, and that throws.
        await model.retry(.relays)
        if let automatic = model.automaticOperation { await automatic.value }
        // A second automatic run, had the failure scheduled one.
        if let automatic = model.automaticOperation { await automatic.value }

        #expect(runtime.runOnboardingCallCount == runsBefore + 1)
        #expect(model.error != nil)
        #expect(model.automaticOperation == nil)
        model.stop()
    }

    @Test func theCurrentStepIsTheFirstOneNotPassedOrSkipped() async {
        let model = await F.coordinator(
            F.snapshot(steps: [
                F.step(.profile, .passed), F.step(.follows, .skipped), F.step(.relays, .checking),
                F.step(.keyPackage, .pending),
            ])
        )

        #expect(model.currentStep?.step == .relays)
        #expect(model.isDurablyReady == false)
    }

    @Test func approvingWithoutACheckpointAsksNothing() async {
        let runtime = FakeMarmotRuntime(accounts: [])
        let model = OnboardingCoordinator(accountRef: "account", runtime: runtime)

        await model.approveRepair()
        await model.acknowledgeSingleDevice()

        #expect(model.snapshot == nil)
        #expect(model.error == nil)
    }

    @Test func cancellingEndsTheAttempt() async {
        let runtime = FakeMarmotRuntime(accounts: [])
        let model = await F.coordinator(
            F.snapshot(steps: [F.step(.relays, .retryableFailure, actions: [.retry])]), runtime: runtime
        )

        let cancelled = await model.cancel()

        #expect(cancelled)
        #expect(runtime.onboardingState == nil)
        model.stop()
    }

    @Test func recoveryThatMarmotKitRefusesIsReported() async {
        let runtime = FakeMarmotRuntime(accounts: [])
        let model = await F.coordinator(
            F.snapshot(steps: [F.step(.relays, .retryableFailure, actions: [.retry])]), runtime: runtime
        )

        await model.recover(acknowledgeLatestOnlyEvidence: true)

        #expect(model.error != nil)
    }

    @Test func recoveryRestartsTheCheckpoint() async {
        let runtime = FakeMarmotRuntime(accounts: [])
        var snapshot = F.snapshot(steps: [F.step(.relays, .retryableFailure, actions: [.retry])])
        snapshot.recoveryEpoch = "epoch"
        let model = await F.coordinator(snapshot, runtime: runtime)
        #expect(model.recoveryRequired)

        await model.recover(acknowledgeLatestOnlyEvidence: true)

        #expect(model.error == nil)
        model.stop()
    }

    @Test func aPreviewCoordinatorRunsNothing() async {
        let model = OnboardingCoordinator.preview(steps: [F.step(.relays, .retryableFailure, actions: [.retry])])

        await model.retry(.relays)
        let cancelled = await model.cancel()
        await model.recover(acknowledgeLatestOnlyEvidence: true)

        #expect(cancelled == false)
        #expect(model.snapshot?.revision == 1)
        #expect(model.error == nil)
    }
}
