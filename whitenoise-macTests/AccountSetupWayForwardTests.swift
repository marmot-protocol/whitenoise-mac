//
//  AccountSetupWayForwardTests.swift
//  whitenoise-macTests
//

import Foundation
import MarmotKit
import Testing

@testable import whitenoise_mac

/// Relay findings that name the list, the relay host and a fix the step offers; and every blocking
/// setup state staying actionable — Cancel Sign-In on a screen with nothing else to press, Check
/// Again on the checklist when a run left the current step waiting or checking.
@Suite(.serialized) @MainActor struct AccountSetupWayForwardTests: WorkspaceTestSupport {
    private typealias F = OnboardingFixtures
    private typealias Findings = AccountSetupRelayFindings
    private typealias Line = AccountSetupRelayFindings.Line

    // MARK: - Relay findings

    /// A members-only relay answers but refuses, so the summary must not claim the relays were
    /// silent; each relay is named by its host, and the advice offers no change the step lacks.
    @Test func inboxFailureNamesTheListAndEachRelayByHost() {
        let findings = [
            relayFinding(.authenticationRequired, "wss://auth.example/"),
            relayFinding(.unreachable, "wss://dead.example"),
            relayFinding(.paymentRequired, "wss://paid.example:443/inbox"),
            relayFinding(.noUsableRoute, nil),
            relayFinding(.inspectionCompleted, "wss://ok.example", outcome: .success),
        ]
        let lines = Findings.lines(
            step: .inboxRelays, findings: findings, actions: [.retry, .editDiscoveryRelays, .cancelOnboarding]
        )
        #expect(
            lines == [
                Line(key: "Your message inbox has no relay White Noise can use."),
                Line(
                    key: "%@ requires sign-in that White Noise couldn’t complete.", host: "auth.example",
                    embedsHost: true),
                Line(key: "%@ couldn’t be reached.", host: "dead.example", embedsHost: true),
                Line(key: "%@ requires payment.", host: "paid.example", embedsHost: true),
                Line(
                    key:
                        "If this keeps happening, add a relay that works to your message inbox in another Nostr app, then sign in again."
                ),
            ]
        )
        #expect(
            lines[1].text(locale: Locale(identifier: "en"))
                == "auth.example requires sign-in that White Noise couldn’t complete.")

        let relayList = Findings.lines(step: .relays, findings: findings, actions: [.retry])
        #expect(relayList.first == Line(key: "Your relay list has no relay White Noise can use."))
        #expect(Set(relayList).isDisjoint(with: [lines[0], lines[4]]))
    }

    @Test(arguments: [OnboardingStepFfi.relays, .inboxRelays])
    func adviceSuggestsOnlyAChangeTheStepOffers(_ step: OnboardingStepFfi) {
        let findings = [relayFinding(.noUsableRoute, nil, context: .publishedDeclaration)]
        let advice = [[OnboardingActionFfi.useRecommendedRelays, .editRelays], [.editRelays], [.retry], []]
            .map { Findings.lines(step: step, findings: findings, actions: $0).last }
        #expect(Set(advice).count == 3)
        #expect(advice[2] == advice[3])
        #expect(
            advice[0]?.key
                == (step == .inboxRelays
                    ? "Add White Noise’s default relays to your message inbox to continue."
                    : "Add White Noise’s default relays to your relay list to continue.")
        )
    }

    @Test func searchedRelaysAreIntroducedSeparatelyFromTheList() {
        let slow = relayFinding(.timedOut, "wss://slow.example", context: .recordDiscovery)
        let expected = [
            Line(key: "Some relays couldn’t be searched for your relay list."),
            Line(key: "%@ didn’t answer in time.", host: "slow.example", embedsHost: true),
        ]
        #expect(Findings.lines(step: .relays, findings: [slow], actions: [.retry]) == expected)
        // MDK's own incomplete-search notice is not repeated, and search failures never suggest
        // list changes.
        let reported = relayFinding(.discoveryIncomplete, nil, context: .recordDiscovery)
        #expect(Findings.lines(step: .relays, findings: [reported, slow], actions: [.editRelays]) == expected)
    }

    @Test func addressRejectionsDifferFromRelayRefusals() {
        let declared = relayFinding(.invalidRelay, "wss://bad.example", context: .publishedDeclaration)
        let queried = relayFinding(.invalidRelay, "wss://bad.example")
        let lines = Findings.lines(step: .relays, findings: [declared, queried], actions: [])
        #expect(
            Array(lines.prefix(2)).map(\.key) == [
                "%@ isn’t a valid relay address.", "%@ refused White Noise’s request.",
            ]
        )
    }

    @Test func relayHostsAreBoundedUntrustedText() throws {
        #expect(Findings.host("wss://Relay.Example:4848/path?q=1") == "relay.example")
        let hostile = try #require(
            Findings.host("\u{202e}wss://spoof.example\n" + String(repeating: "a", count: 2_000)))
        #expect(!hostile.contains("\u{202e}"))
        #expect(!hostile.contains("\n"))
        #expect(hostile.count <= 120)
        #expect(Findings.host("\u{200b}") == nil)
        // An endpoint with nothing visible left falls back to the issue's own line.
        let unreadable = relayFinding(.unreachable, "\u{200b}")
        #expect(
            Findings.lines(step: .relays, findings: [unreadable], actions: [])
                .contains(Line(key: try #require(AccountSetupGuide.issueKey(.unreachable))))
        )
    }

    // MARK: - Cancel Sign-In

    /// A restored approved update can offer only `cancelOnboarding`: the screen says the sign-in
    /// can only be cancelled, offers Cancel Sign-In, and promises no publication it cannot make.
    @Test(arguments: [OnboardingStepFfi.relays, .inboxRelays])
    func anInterruptedRelayUpdateWithoutRetryOffersCancelSignIn(_ step: OnboardingStepFfi) {
        var stranded = F.snapshot(steps: [F.step(step, .needsInput, actions: [.cancelOnboarding])])
        stranded.proposal = F.proposal(step, reads: ["wss://a.example"], writes: ["wss://a.example"])
        let plan = AccountSetupRelayPlan(snapshot: stranded, step: step)

        #expect(plan.isInterrupted)
        #expect(plan.offersNoAction)
        #expect(plan.messageKeys == ["The addresses below are an update that didn’t finish publishing."])
        #expect(AccountSetupNoActionLines.offersCancelSignIn(step, in: stranded))
        #expect(AccountSetupNoActionLines.messageKeys(step, in: stranded) == [AccountSetupWayForward.cannotContinueKey])

        var retryable = F.snapshot(steps: [F.step(step, .needsInput, actions: [.retry, .cancelOnboarding])])
        retryable.proposal = stranded.proposal
        #expect(!AccountSetupNoActionLines.offersCancelSignIn(step, in: retryable))
        // Any action the screen draws, even a secondary one, is a way forward.
        let searchable = F.snapshot(steps: [F.step(step, .needsInput, actions: [.editDiscoveryRelays])])
        #expect(!AccountSetupNoActionLines.offersCancelSignIn(step, in: searchable))
    }

    /// Without a retry, the profile screen asks for none.
    @Test func aProfileStepWithoutRetryDoesNotAskForOne() {
        var interrupted = F.snapshot(steps: [F.step(.profile, .needsInput, actions: [.cancelOnboarding])])
        interrupted.proposal = F.proposal(.profile, profile: F.profile(name: "Ada"))
        #expect(AccountSetupProfilePlan(snapshot: interrupted).messageKeys.isEmpty)
        #expect(AccountSetupNoActionLines.offersCancelSignIn(.profile, in: interrupted))

        let lookup = F.snapshot(steps: [F.step(.profile, .retryableFailure, actions: [.cancelOnboarding])])
        #expect(AccountSetupProfilePlan(snapshot: lookup).messageKeys == ["We couldn’t get your profile details."])

        var retryable = interrupted
        retryable.steps = [F.step(.profile, .needsInput, actions: [.retry])]
        #expect(!AccountSetupProfilePlan(snapshot: retryable).messageKeys.isEmpty)
        #expect(!AccountSetupNoActionLines.offersCancelSignIn(.profile, in: retryable))
    }

    /// Setup never publishes follows, so `editFollows` alone is no way forward.
    @Test func followsWithoutADrawnActionOffersCancelSignIn() {
        let stranded = F.snapshot(steps: [F.step(.follows, .needsInput, actions: [.editFollows, .cancelOnboarding])])
        #expect(AccountSetupNoActionLines.offersCancelSignIn(.follows, in: stranded))
        for action in [OnboardingActionFfi.retry, .cancelRepair, .continueWithout] {
            let offered = F.snapshot(steps: [F.step(.follows, .needsInput, actions: [.editFollows, action])])
            #expect(!AccountSetupNoActionLines.offersCancelSignIn(.follows, in: offered))
        }
    }

    // MARK: - Check Again

    @Test func onlyAWaitingOrCheckingCurrentStepIsStalled() {
        #expect(AccountSetupWayForward.stalledStep(F.snapshot(steps: [F.step(.relays, .checking)]))?.step == .relays)
        #expect(
            AccountSetupWayForward.stalledStep(
                F.snapshot(steps: [F.step(.profile, .passed), F.step(.relays, .pending)])
            )?.step == .relays
        )
        // A step that needs a decision is reviewed instead.
        #expect(AccountSetupWayForward.stalledStep(F.snapshot(steps: [F.step(.relays, .needsInput)])) == nil)
        #expect(AccountSetupWayForward.stalledStep(F.snapshot(steps: [F.step(.relays, .passed)], ready: true)) == nil)
        var cancelling = F.snapshot(steps: [F.step(.relays, .checking)])
        cancelling.cancellationPending = true
        #expect(AccountSetupWayForward.stalledStep(cancelling) == nil)
        #expect(AccountSetupWayForward.stalledStep(nil) == nil)
    }

    /// A checkpoint restored with its current step still checking — the app quit mid-check —
    /// offers Check Again instead of a spinner nothing will stop, and Check Again runs it.
    @Test func aCheckLeftCheckingOffersCheckAgain() async {
        let runtime = FakeMarmotRuntime(accounts: [])
        runtime.onboardingState = F.snapshot(steps: [F.step(.profile, .passed), F.step(.relays, .checking)])
        let model = OnboardingCoordinator(accountRef: "account", runtime: runtime)
        model.start()
        await Self.waitUntil { model.isObserving }

        #expect(model.needsCheckAgain)
        let guide = AccountSetupGuide(
            snapshot: model.snapshot, recoveryRequired: false, isStalled: model.needsCheckAgain)
        #expect(guide.titleKey == AccountSetupWayForward.checkAgainTitleKey)
        #expect(guide.subtitleKey == AccountSetupWayForward.checkAgainSubtitleKey)
        #expect(guide.steps.map(guide.rowState) == [.passed, .pending])
        #expect(guide.reviewStep == nil)

        // While Check Again runs, it is not offered again.
        runtime.onboardingRunGate.isEnabled = true
        let command = Task { await model.run() }
        await runtime.onboardingRunGate.waitUntilReached()
        #expect(!model.needsCheckAgain)
        runtime.onboardingRunGate.release()
        await command.value
        #expect(runtime.runOnboardingCallCount == 1)
        model.stop()
    }

    /// A pending check is run on its own once; a run that changes nothing is not repeated in a
    /// loop, and the checklist offers Check Again.
    @Test func aRunThatChangesNothingIsNotRepeated() async {
        let runtime = FakeMarmotRuntime(accounts: [])
        runtime.onboardingState = F.snapshot(steps: [F.step(.relays, .pending)])
        let model = OnboardingCoordinator(accountRef: "account", runtime: runtime)
        model.start()
        await Self.waitUntil { model.needsCheckAgain }

        #expect(runtime.runOnboardingCallCount == 1)
        #expect(model.automaticOperation == nil)

        // Check Again runs it once more, and again stops there.
        await model.run()
        if let automatic = model.automaticOperation { await automatic.value }
        #expect(runtime.runOnboardingCallCount == 2)
        #expect(model.needsCheckAgain)
        model.stop()
    }

    /// A run is judged on what it changed, not on when it looked: a core that restamps a
    /// finished step's `checkedAt` on every run still made no progress, so the run is not
    /// repeated.
    @Test func aRunThatOnlyRestampsATimestampIsNotRepeated() async {
        let runtime = FakeMarmotRuntime(accounts: [])
        runtime.onboardingState = F.snapshot(steps: [F.step(.profile, .passed), F.step(.relays, .pending)])
        runtime.onboardingRunChange = { snapshot in
            snapshot.steps[0].checkedAt = (snapshot.steps[0].checkedAt ?? 0) + 1
        }
        let model = OnboardingCoordinator(accountRef: "account", runtime: runtime)
        model.start()
        await Self.waitUntil { model.needsCheckAgain }

        #expect(runtime.runOnboardingCallCount == 1)
        #expect(model.snapshot?.steps[0].checkedAt == 1)
        #expect(model.automaticOperation == nil)
        model.stop()
    }

    /// An error has its own Try Again, and a step that needs the user is reviewed: neither
    /// offers Check Again.
    @Test func anErrorOrADecisionIsNotAStall() async {
        let runtime = FakeMarmotRuntime(accounts: [])
        runtime.onboardingState = F.snapshot(steps: [F.step(.relays, .checking)])
        let model = OnboardingCoordinator(accountRef: "account", runtime: runtime)
        model.start()
        await Self.waitUntil { model.isObserving }
        #expect(model.needsCheckAgain)

        runtime.onboardingState = nil
        await model.run()
        #expect(model.error != nil)
        #expect(!model.needsCheckAgain)
        model.stop()

        let decision = FakeMarmotRuntime(accounts: [])
        decision.onboardingState = F.snapshot(steps: [F.step(.relays, .needsInput, actions: [.retry])])
        let reviewing = OnboardingCoordinator(accountRef: "account", runtime: decision)
        reviewing.start()
        await Self.waitUntil { reviewing.isObserving }
        #expect(!reviewing.needsCheckAgain)
        reviewing.stop()
    }

    // MARK: - Catalog

    /// Every key the relay findings can hand out, found by running `lines` over every finding a
    /// relay step can report rather than read from a second list that could fall behind it, and
    /// every language the app ships, read from the bundle so a new one is covered as it lands.
    @Test func everyNewKeyIsTranslated() throws {
        var keys = Set(relayFindingKeys())
        #expect(keys.contains("%@ isn’t safe to connect to."))
        #expect(keys.contains("Some relays couldn’t be searched for your message inbox."))
        #expect(
            keys.contains(
                "If this keeps happening, add a relay that works to your relay list in another Nostr app, then sign in again."
            )
        )
        keys.formUnion([
            AccountSetupWayForward.cannotContinueKey, AccountSetupWayForward.checkAgainTitleKey,
            AccountSetupWayForward.checkAgainSubtitleKey, AccountSetupWayForward.checkAgainActionKey,
            "Cancel Sign-In", "Cancel sign-in?", "Keep Signing In",
            "You’ll need to sign in again to continue. Changes that were already published are kept.",
            "The addresses below are an update that didn’t finish publishing.",
        ])
        let languages = Bundle.main.localizations.filter { $0 != "en" && $0 != "Base" }
        #expect(languages.contains("fi"))
        for language in languages {
            let bundle = try #require(
                Bundle.main.path(forResource: language, ofType: "lproj").flatMap(Bundle.init(path:))
            )
            for key in keys {
                #expect(bundle.localizedString(forKey: key, value: nil, table: nil) != key, "\(language): \(key)")
            }
        }
    }

    /// The key of every line `lines` writes for one finding of each issue, in each context, with
    /// and without a relay, under each set of fixes a relay step can offer.
    private func relayFindingKeys() -> [String] {
        let issues: [OnboardingIssueFfi] = [
            .missing, .malformed, .futureDated, .invalidRelay, .retiredRelay, .unsafeRelay, .unreachable,
            .timedOut, .authenticationRequired, .paymentRequired, .accessRestricted, .noUsableRoute,
            .publicationFailed, .signerUnavailable, .signerRejected, .recordChanged, .interrupted,
            .tooManyRelays, .multiDeviceUnsupported, .otherInstallationPossible, .discoveryIncomplete,
            .inspectionCompleted,
        ]
        let contexts: [OnboardingFindingContextFfi] = [
            .unknown, .recordDiscovery, .publishedDeclaration, .declaredRoute, .repairApproval, .repairPublication,
        ]
        let actionSets: [[OnboardingActionFfi]] = [[.useRecommendedRelays, .editRelays], [.editRelays], [.retry]]
        var keys: [String] = []
        for step in [OnboardingStepFfi.relays, .inboxRelays] {
            for issue in issues {
                for context in contexts {
                    for endpoint in [nil, "wss://relay.example"] {
                        let finding = relayFinding(issue, endpoint, context: context)
                        for actions in actionSets {
                            keys += Findings.lines(step: step, findings: [finding], actions: actions).map(\.key)
                        }
                    }
                }
            }
        }
        return keys
    }

    // MARK: - Fixtures

    private func relayFinding(
        _ issue: OnboardingIssueFfi,
        _ endpoint: String?,
        context: OnboardingFindingContextFfi = .declaredRoute,
        outcome: OnboardingCheckOutcomeFfi = .failure
    ) -> OnboardingFindingFfi {
        OnboardingFindingFfi(
            issue: issue, endpoint: endpoint, context: context, purpose: .directoryQuery,
            outcome: outcome, declaredCapability: .inbox, actions: [], observedRevision: 2
        )
    }
}
