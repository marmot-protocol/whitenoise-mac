//
//  AccountSetupStepScreenTests.swift
//  whitenoise-macTests
//

import MarmotKit
import SwiftUI
import Testing

@testable import whitenoise_mac

/// Every step screen, in every shape MarmotKit can put it in, lays out in the onboarding column
/// inside the smallest window, and the coordinator opens and closes the screens in place of the
/// checklist.
@Suite(.serialized) @MainActor struct AccountSetupStepScreenTests {
    private typealias F = OnboardingFixtures

    private static let windowSize = CGSize(width: 940, height: 620)

    /// The screen fills the window it is given — its column scrolls rather than growing the pane
    /// — and the step underneath it stays inside the onboarding column, as Sign Up's form does.
    private static func expectScreenFits(
        _ step: OnboardingStepFfi,
        _ steps: [OnboardingStepStateFfi],
        proposal: OnboardingRepairProposalFfi? = nil,
        notice: OnboardingSingleDeviceNoticeFfi? = nil,
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        let model = OnboardingCoordinator.preview(steps: steps, proposal: proposal, singleDeviceNotice: notice)
        let screen = F.hostedSize(
            AccountSetupStepScreen(model: model, step: step)
                .frame(width: windowSize.width, height: windowSize.height)
        )
        #expect(screen == windowSize, "\(step) with \(steps.map(\.actions))", sourceLocation: sourceLocation)
    }

    @Test func profileScreens() {
        Self.expectScreenFits(.profile, [F.step(.profile, .needsInput, actions: [.editProfile, .continueWithout])])
        Self.expectScreenFits(
            .profile,
            [
                F.step(
                    .profile, .retryableFailure, findings: [.init(issue: .timedOut, endpoint: nil)],
                    actions: [.retry, .continueWithout]
                )
            ]
        )
        Self.expectScreenFits(
            .profile, [F.step(.profile, .needsInput, actions: [.approveRepair, .cancelRepair])],
            proposal: F.proposal(.profile, profile: F.profile(name: "Ada"))
        )
        Self.expectScreenFits(
            .profile, [F.step(.profile, .retryableFailure, actions: [.retry])],
            proposal: F.proposal(.profile, profile: F.profile(name: "Ada"))
        )
        Self.expectScreenFits(.profile, [F.step(.profile, .waitingForSigner)])
    }

    @Test func relayScreens() {
        Self.expectScreenFits(
            .relays,
            [
                F.step(
                    .relays, .needsInput, findings: [.init(issue: .missing, endpoint: nil)],
                    actions: [.useRecommendedRelays, .editRelays, .editDiscoveryRelays, .retry]
                )
            ]
        )
        Self.expectScreenFits(
            .relays, [F.step(.relays, .needsInput, actions: [.approveRepair, .cancelRepair])],
            proposal: F.proposal(.relays, reads: ["wss://a.example", "wss://b.example"], writes: ["wss://a.example"])
        )
        Self.expectScreenFits(
            .relays, [F.step(.relays, .retryableFailure, actions: [.retry])],
            proposal: F.proposal(.relays, reads: ["wss://a.example"], writes: ["wss://a.example"])
        )
        Self.expectScreenFits(
            .relays,
            [
                F.step(
                    .relays, .needsInput, findings: [.init(issue: .noUsableRoute, endpoint: "wss://a.example")],
                    actions: [.editRelays, .editDiscoveryRelays]
                )
            ]
        )
        Self.expectScreenFits(
            .inboxRelays, [F.step(.inboxRelays, .retryableFailure, actions: [.retry, .editDiscoveryRelays])]
        )
        Self.expectScreenFits(.relays, [F.step(.relays, .waitingForSigner, actions: [.reconnectSigner])])
        Self.expectScreenFits(
            .inboxRelays, [F.step(.inboxRelays, .needsInput, actions: [.useRecommendedRelays, .editRelays])]
        )
        Self.expectScreenFits(
            .inboxRelays, [F.step(.inboxRelays, .needsInput, actions: [.approveRepair, .cancelRepair])],
            proposal: F.proposal(.inboxRelays, reads: ["wss://inbox.example"])
        )
    }

    @Test func deviceScreens() {
        for discovery in [OnboardingDeviceDiscoveryFfi.noneFound, .otherInstallationPossible, .unknown] {
            Self.expectScreenFits(
                .singleDevice, [F.step(.singleDevice, .needsInput, actions: [.continueAnyway])],
                notice: F.notice(discovery)
            )
        }
        Self.expectScreenFits(
            .singleDevice,
            [
                F.step(
                    .singleDevice, .retryableFailure, findings: [.init(issue: .discoveryIncomplete, endpoint: nil)],
                    actions: [.retry]
                )
            ],
            notice: F.notice(.unknown)
        )
    }

    @Test func secureMessagingAndFollowsScreens() {
        Self.expectScreenFits(
            .keyPackage,
            [
                F.step(
                    .keyPackage, .retryableFailure, findings: [.init(issue: .publicationFailed, endpoint: nil)],
                    actions: [.retry]
                )
            ]
        )
        Self.expectScreenFits(.keyPackage, [F.step(.keyPackage, .waitingForSigner)])
        Self.expectScreenFits(
            .follows,
            [
                F.step(
                    .follows, .retryableFailure, findings: [.init(issue: .unreachable, endpoint: "wss://a.example")],
                    actions: [.retry, .continueWithout]
                )
            ]
        )
        Self.expectScreenFits(.follows, [F.step(.follows, .needsInput, actions: [.cancelRepair])])
    }

    /// The relay editor and the relay search, which replace the relay screen's overview, fill the
    /// window too.
    @Test func relayEditorAndSearchPanes() {
        for step in [OnboardingStepFfi.relays, .inboxRelays] {
            let model = OnboardingCoordinator.preview(steps: [
                F.step(step, .needsInput, actions: [.editRelays, .editDiscoveryRelays])
            ])
            for mode in [AccountSetupRelayStep.Mode.editing, .searching] {
                let size = F.hostedSize(
                    AccountSetupRelayStep(model: model, step: step, initialMode: mode)
                        .frame(width: Self.windowSize.width, height: Self.windowSize.height)
                )
                #expect(size == Self.windowSize, "\(step) \(mode)")
            }
        }
    }

    /// A relay screen can stack four large buttons under its content. In every language they stay
    /// one button wide each — inside the onboarding column, not wrapped into a second row.
    @Test func theRelayActionColumnStaysInTheOnboardingColumnInEveryLanguage() throws {
        let searchDefaults = F.snapshot(steps: [
            F.step(.relays, .needsInput, actions: [.retry, .editRelays, .editDiscoveryRelays])
        ])
        var proposed = F.snapshot(steps: [
            F.step(.relays, .needsInput, actions: [.approveRepair, .cancelRepair, .editDiscoveryRelays])
        ])
        proposed.proposal = F.proposal(.relays, reads: ["wss://a.example"], writes: ["wss://a.example"])
        let languages = Bundle.main.localizations.filter { $0 != "Base" }

        for snapshot in [searchDefaults, proposed] {
            let plan = AccountSetupRelayPlan(snapshot: snapshot, step: .relays)
            #expect(plan.secondaryActions.count + 1 == 4, "\(plan.secondaryActions)")
            let model = OnboardingCoordinator.preview(steps: snapshot.steps, proposal: snapshot.proposal)
            for language in languages {
                let column = F.hostedSize(
                    AccountSetupActionColumn {
                        AccountSetupRelayActions(plan: plan, model: model, active: .constant(nil)) { _ in }
                    }
                    .environment(\.locale, Locale(identifier: language))
                    .controlSize(.large)
                    .wnButtonShape(.capsule)
                    .frame(width: OnboardingLayout.contentWidth)
                )
                #expect(column.width == OnboardingLayout.contentWidth, "\(language)")
                #expect(column.height < 4 * 60, "\(language): \(column.height)pt for four buttons")
            }
        }
    }

    /// The editable profile screen is Sign Up's pane plus Not Now, and like Sign Up it fits the
    /// smallest window without scrolling, header row included, in every language.
    @Test func theEditableProfileScreenFitsTheSmallestWindowWithoutScrolling() throws {
        let model = OnboardingCoordinator.preview(steps: [
            F.step(.profile, .needsInput, actions: [.editProfile, .continueWithout])
        ])
        let languages = Bundle.main.localizations.filter { $0 != "Base" }
        for language in languages {
            let column = AccountSetupStepColumn {
                AccountSetupProfileAvatar(
                    titleKey: "Add your profile", avatar: nil, displayName: "", choosePhoto: {}, removePhoto: {}
                )
            } content: {
                AccountSetupProfileForm(displayName: .constant(""), about: .constant(""))
            } actions: {
                AccountSetupStepButton(titleKey: "Save", model: model, active: .constant(nil)) {}
                AccountSetupStepButton(titleKey: "Not Now", tier: .secondary, model: model, active: .constant(nil)) {}
            }
            .controlSize(.large)
            .wnButtonShape(.capsule)
            .environment(\.locale, Locale(identifier: language))
            .environment(WorkspaceState.preview())
            let column_ = try #require(ImageRenderer(content: column).nsImage?.size.height)
            let header = F.hostedSize(OnboardingHeaderRow(exit: .backToSetup {}).frame(width: Self.windowSize.width))
            let height = column_ + header.height + 2 * AccountSetupStepLayoutMetrics.edgePadding

            #expect(height <= Self.windowSize.height, "\(language): \(height)pt")
        }
    }

    /// The progress in the header row counts the step being reviewed among the checkpoint's steps.
    @Test func theProgressNamesTheStepAmongTheCheckpointsSteps() {
        let guide = AccountSetupGuide(
            snapshot: F.snapshot(steps: [
                F.step(.profile, .passed), F.step(.relays, .needsInput), F.step(.keyPackage, .pending),
            ]),
            recoveryRequired: false
        )
        let progress = F.hostedSize(AccountSetupStepProgress(guide: guide, step: .relays))
        let missing = F.hostedSize(AccountSetupStepProgress(guide: guide, step: .singleDevice))

        #expect(progress.width > 0)
        #expect(missing == .zero)
        #expect(
            AccountSetupStepProgress.segmentColor(isCurrent: false, state: F.step(.profile, .passed))
                != AccountSetupStepProgress.segmentColor(isCurrent: false, state: F.step(.keyPackage, .pending))
        )
    }

    // MARK: - Opening and closing a step's screen

    @Test func reviewingAStepOpensItsScreenAndBackReturnsToTheChecklist() async {
        let model = await F.coordinator(
            F.snapshot(steps: [F.step(.profile, .needsInput, actions: [.editProfile, .continueWithout])])
        )
        #expect(model.reviewingStep == nil)

        model.review(.profile)
        #expect(model.reviewingStep == .profile)

        model.endReview()
        #expect(model.reviewingStep == nil)
    }

    /// Only an unfinished step listed in the checkpoint has a screen to open.
    @Test func aFinishedOrUnlistedStepHasNoScreenToOpen() async {
        let model = await F.coordinator(
            F.snapshot(steps: [F.step(.profile, .passed), F.step(.relays, .needsInput, actions: [.retry])])
        )

        model.review(.profile)
        #expect(model.reviewingStep == nil)
        model.review(.singleDevice)
        #expect(model.reviewingStep == nil)
        model.review(.relays)
        #expect(model.reviewingStep == .relays)
    }

    /// Once the step passes or is skipped, the checklist comes back on its own — the screen has
    /// nothing left to offer.
    @Test func finishingTheStepReturnsToTheChecklist() async {
        let runtime = FakeMarmotRuntime(accounts: [])
        let model = await F.coordinator(
            F.snapshot(steps: [
                F.step(.profile, .needsInput, actions: [.editProfile, .continueWithout]),
                F.step(.relays, .needsInput, actions: [.retry]),
            ]),
            runtime: runtime
        )
        model.review(.profile)

        runtime.onboardingState = F.snapshot(
            steps: [F.step(.profile, .skipped), F.step(.relays, .needsInput, actions: [.retry])], revision: 10
        )
        await model.skip(.profile)

        #expect(model.reviewingStep == nil)
    }

    /// A step still waiting on the user keeps its screen up across a new checkpoint, as when an
    /// action failed and the screen has to show why.
    @Test func anUnfinishedStepKeepsItsScreenAcrossANewCheckpoint() async {
        let runtime = FakeMarmotRuntime(accounts: [])
        let model = await F.coordinator(
            F.snapshot(steps: [F.step(.keyPackage, .retryableFailure, actions: [.retry])]), runtime: runtime
        )
        model.review(.keyPackage)

        await model.retry(.keyPackage)

        #expect(model.snapshot?.revision == 3)
        #expect(model.reviewingStep == .keyPackage)
    }

    /// A cancellation closes the screen: the pane behind it shows the sign-in closing.
    @Test func aCancellationReturnsToTheChecklist() async {
        let runtime = FakeMarmotRuntime(accounts: [])
        let model = await F.coordinator(
            F.snapshot(steps: [F.step(.relays, .needsInput, actions: [.retry])]), runtime: runtime
        )
        model.review(.relays)

        var cancelling = F.snapshot(steps: [F.step(.relays, .needsInput, actions: [.retry])], revision: 10)
        cancelling.cancellationPending = true
        runtime.onboardingState = cancelling
        await model.retry(.relays)

        #expect(model.reviewingStep == nil)
        model.review(.relays)
        #expect(model.reviewingStep == nil)
    }

    /// Recovering restarts the session on the checklist, even when the step whose screen was open
    /// is still unfinished in the checkpoint that comes back.
    @Test func recoveringReturnsToTheChecklist() async {
        let runtime = FakeMarmotRuntime(accounts: [])
        let model = await F.coordinator(
            F.snapshot(steps: [F.step(.relays, .needsInput, actions: [.retry])]), runtime: runtime
        )
        model.review(.relays)
        #expect(model.reviewingStep == .relays)

        var unreadable = F.snapshot(steps: [F.step(.relays, .needsInput, actions: [.retry])])
        unreadable.recoveryEpoch = "epoch"
        runtime.onboardingState = unreadable
        await model.recover(acknowledgeLatestOnlyEvidence: true)

        #expect(model.error == nil)
        #expect(model.reviewingStep == nil)
        model.stop()
    }

    /// Every finding MarmotKit can report has its own line of copy.
    @Test func everyFindingHasItsOwnLine() {
        let issues: [OnboardingIssueFfi] = [
            .missing, .malformed, .futureDated, .invalidRelay, .retiredRelay, .unsafeRelay, .unreachable,
            .timedOut, .authenticationRequired, .paymentRequired, .accessRestricted, .noUsableRoute,
            .publicationFailed, .signerUnavailable, .signerRejected, .recordChanged, .interrupted,
            .tooManyRelays, .multiDeviceUnsupported, .otherInstallationPossible, .discoveryIncomplete,
        ]
        let lines = issues.map(AccountSetupGuide.issueKey)

        #expect(Set(lines).count == issues.count)
    }

    @Test func theRelayEditorDrawsOneRowPerAddress() {
        let draft = AccountSetupRelayDraft(entries: [
            .init(address: "wss://a.example"), .init(address: "wss://b.example", reads: true, writes: false),
        ])
        let one = F.hostedSize(
            AccountSetupRelayDraftEditor(draft: .constant(AccountSetupRelayDraft(entries: [.init()])), showsRoles: true)
                .frame(width: 400)
        )
        let two = F.hostedSize(
            AccountSetupRelayDraftEditor(draft: .constant(draft), showsRoles: true).frame(width: 400))
        let inbox = F.hostedSize(
            AccountSetupRelayDraftEditor(draft: .constant(draft), showsRoles: false).frame(width: 400)
        )

        #expect(two.height > one.height)
        // The inbox has no Read and Write uses to draw under each address.
        #expect(inbox.height < two.height)
    }

    // MARK: - The pane

    /// The pane in the states the fit test does not draw: still checking, closing, and stopped
    /// on an error with Try Again.
    @Test func thePaneDrawsItsWaitingStates() async {
        let checking = await F.coordinator(F.snapshot(steps: [F.step(.relays, .checking)]))
        var cancelling = F.snapshot(steps: [F.step(.relays, .checking)])
        cancelling.cancellationPending = true
        let closing = await F.coordinator(cancelling)
        let runtime = FakeMarmotRuntime(accounts: [])
        let failed = await F.coordinator(F.snapshot(steps: [F.step(.relays, .checking)]), runtime: runtime)
        runtime.onboardingState = nil
        await failed.retry(.relays)
        #expect(failed.error != nil)

        for model in [checking, closing, failed] {
            let size = F.hostedSize(AccountSetupView(model: model).frame(width: 940))
            #expect(size.width == 940)
        }
    }

    /// The onboarding surface shows the setup pane for a checkpoint, and the landing pane without.
    @Test func theOnboardingSurfaceRoutesOnTheCheckpoint() async {
        let model = await F.coordinator(F.snapshot(steps: [F.step(.relays, .checking)]))

        let withSetup = F.hostedSize(OnboardingView(model: model).frame(width: 940))
        let withoutSetup = F.hostedSize(OnboardingView(model: nil).frame(width: 940))

        #expect(withSetup.width == 940)
        #expect(withoutSetup.width == 940)
    }
}
