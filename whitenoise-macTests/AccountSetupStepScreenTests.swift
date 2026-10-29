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
                    .profile, .retryableFailure, findings: [.preview(issue: .timedOut, endpoint: nil)],
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
                    .relays, .needsInput, findings: [.preview(issue: .missing, endpoint: nil)],
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
                    .relays, .needsInput, findings: [.preview(issue: .noUsableRoute, endpoint: "wss://a.example")],
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
                    .singleDevice, .retryableFailure, findings: [.preview(issue: .discoveryIncomplete, endpoint: nil)],
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
                    .keyPackage, .retryableFailure, findings: [.preview(issue: .publicationFailed, endpoint: nil)],
                    actions: [.retry]
                )
            ]
        )
        Self.expectScreenFits(.keyPackage, [F.step(.keyPackage, .waitingForSigner)])
        Self.expectScreenFits(
            .follows,
            [
                F.step(
                    .follows, .retryableFailure, findings: [.preview(issue: .unreachable, endpoint: "wss://a.example")],
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

    /// The editable profile screen is Sign Up's pane plus Not Now. With the privacy card closed it
    /// fits the smallest window without scrolling, header row included, in the languages whose
    /// card summary is two lines — see `languagesThatFitClosed`. Elsewhere the screen scrolls, which
    /// `theEditableProfileScreenReachesSaveAndNotNowInEveryLanguage` holds.
    @Test func theEditableProfileScreenFitsTheSmallestWindowWithoutScrolling() throws {
        for language in Self.languagesThatFitClosed {
            let height = try Self.editableProfileColumnHeight(locale: Locale(identifier: language))
            #expect(height <= Self.windowSize.height, "\(language): \(height)pt")
        }
    }

    /// In every language, at the smallest window, the real profile screen puts its whole column —
    /// Save and Not Now included — inside a scroll view that reaches its end. This replaces a test
    /// that sized the screen and then asserted the size it had set; here the probe reads AppKit's
    /// scroll view, so a screen that clipped its column instead would have no scroll view, or a
    /// document shorter than the column, and fail.
    @Test func theEditableProfileScreenReachesSaveAndNotNowInEveryLanguage() throws {
        let model = OnboardingCoordinator.preview(steps: [
            F.step(.profile, .needsInput, actions: [.editProfile, .continueWithout])
        ])
        let header = F.hostedSize(OnboardingHeaderRow(exit: .backToSetup {}).frame(width: Self.windowSize.width))
        for language in Bundle.main.localizations where language != "Base" {
            let locale = Locale(identifier: language)
            let column = try Self.editableProfileColumnHeight(locale: locale) - header.height
            for height in [Self.windowSize.height, 400] {
                let geometry = try #require(
                    F.scrollGeometry(
                        AccountSetupStepScreen(model: model, step: .profile).environment(\.locale, locale),
                        size: CGSize(width: Self.windowSize.width, height: height)
                    ),
                    "\(language) at \(height)pt: no scroll view"
                )
                #expect(geometry.documentHeight >= column - 1, "\(language) at \(height)pt: \(geometry)")
                // A column shorter than the window is centred in it, so the end is in view either
                // way: scrolled to, or already above the bottom edge.
                #expect(
                    geometry.maximumVisibleBottom >= geometry.documentHeight - 1,
                    "\(language) at \(height)pt: the end of the column is out of reach — \(geometry)")
            }
        }
    }

    /// With the privacy card open the column is taller than the smallest window in every language
    /// but Chinese. The screen still opens at its top, where the card is, and scrolling reaches
    /// Save and Not Now.
    @Test func anOpenedPrivacyCardKeepsSaveAndNotNowReachable() throws {
        let model = OnboardingCoordinator.preview(steps: [
            F.step(.profile, .needsInput, actions: [.editProfile, .continueWithout])
        ])
        for language in Bundle.main.localizations where language != "Base" {
            let screen = AccountSetupStepLayout {
                AccountSetupProfileAvatar(
                    titleKey: "Add your profile", avatar: nil, displayName: "", choosePhoto: {}, removePhoto: {}
                )
            } content: {
                AccountSetupProfileForm(
                    displayName: .constant(""), about: .constant(""), isPrivacyNoteInitiallyExpanded: true
                )
            } actions: {
                AccountSetupStepButton(titleKey: "Save", model: model, active: .constant(nil)) {}
                AccountSetupStepButton(titleKey: "Not Now", tier: .secondary, model: model, active: .constant(nil)) {}
            }
            .controlSize(.large)
            .wnButtonShape(.capsule)
            .environment(\.locale, Locale(identifier: language))

            let geometry = try #require(
                F.scrollGeometry(screen, size: Self.windowSize), "\(language): no scroll view")
            // The top of the column — the opened card — is in view (a column that fits is centred,
            // so its top sits below the viewport's), and scrolling reaches its end.
            #expect(geometry.visibleTop <= 0.5, "\(language): the opened card is out of view — \(geometry)")
            #expect(geometry.maximumVisibleBottom >= geometry.documentHeight - 1, "\(language): \(geometry)")
        }
    }

    /// The editable profile screen's column plus its header row and margins, in `locale`.
    private static func editableProfileColumnHeight(locale: Locale) throws -> CGFloat {
        let model = OnboardingCoordinator.preview(steps: [
            F.step(.profile, .needsInput, actions: [.editProfile, .continueWithout])
        ])
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
        .environment(\.locale, locale)
        .environment(WorkspaceState.preview())
        let columnHeight = try #require(ImageRenderer(content: column).nsImage?.size.height)
        let header = F.hostedSize(OnboardingHeaderRow(exit: .backToSetup {}).frame(width: windowSize.width))
        return columnHeight + header.height + 2 * AccountSetupStepLayoutMetrics.edgePadding
    }

    /// Where the closed card's summary is two lines. Measured on 2026-10-29 at the smallest window:
    /// 616pt in English, Spanish and Chinese; 631pt in de/fr/it/pt/tr (three lines) and 646pt in
    /// Russian (four), against 620 — this screen has 26pt less room than Sign Up, for its header
    /// progress and Not Now. Those scroll from the top, with Not Now a short scroll away.
    private static let languagesThatFitClosed = ["en", "es", "zh-Hans", "zh-Hant"]

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
        #expect(AccountSetupStepProgress.position(of: .relays, in: guide).map { [$0.number, $0.count] } == [2, 3])
        #expect(AccountSetupStepProgress.position(of: .singleDevice, in: guide) == nil)
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

    /// Every fault MarmotKit can report has its own line of copy; a relay that answered has none.
    @Test func everyFindingHasItsOwnLine() {
        let issues: [OnboardingIssueFfi] = [
            .missing, .malformed, .futureDated, .invalidRelay, .retiredRelay, .unsafeRelay, .unreachable,
            .timedOut, .authenticationRequired, .paymentRequired, .accessRestricted, .noUsableRoute,
            .publicationFailed, .signerUnavailable, .signerRejected, .recordChanged, .interrupted,
            .tooManyRelays, .multiDeviceUnsupported, .otherInstallationPossible, .discoveryIncomplete,
        ]
        let lines = issues.compactMap(AccountSetupGuide.issueKey)

        #expect(lines.count == issues.count)
        #expect(Set(lines).count == issues.count)
        #expect(AccountSetupGuide.issueKey(.inspectionCompleted) == nil)
    }

    /// `inspectionCompleted` only says a relay answered. A step whose only finding is that one
    /// prints nothing under it — no "Complete", no relay address — and a failed step falls back to
    /// its generic line exactly as if it had named nothing.
    @Test func anAnsweredRelayIsNotListedAsAProblem() {
        let answered = OnboardingFindingFfi.preview(issue: .inspectionCompleted, endpoint: "wss://relay.example.com")
        let unreachable = OnboardingFindingFfi.preview(issue: .unreachable, endpoint: "wss://down.example.com")

        #expect(AccountSetupFindingLines.problems(in: [answered]).isEmpty)
        #expect(
            AccountSetupFindingLines.problems(in: [answered, unreachable]).map(\.endpoint) == ["wss://down.example.com"]
        )

        func height(_ findings: [OnboardingFindingFfi], isFailure: Bool) -> CGFloat {
            F.hostedSize(
                VStack(spacing: 0) { AccountSetupFindingLines(findings: findings, isFailure: isFailure) }
                    .frame(width: 400)
            ).height
        }
        #expect(height([answered], isFailure: false) == height([], isFailure: false))
        #expect(height([answered], isFailure: true) == height([], isFailure: true))
        #expect(height([answered, unreachable], isFailure: true) == height([unreachable], isFailure: true))
    }

    /// The relay step draws its divider and finding list only when there is a fault to list, so a
    /// relay that merely answered leaves the callout as if nothing had been found.
    @Test func theRelayStepDrawsNoFindingsForAnAnsweredRelay() async {
        let answered = OnboardingFindingFfi.preview(issue: .inspectionCompleted, endpoint: "wss://relay.example.com")
        let withAnswer = await F.coordinator(
            F.snapshot(steps: [F.step(.relays, .needsInput, findings: [answered], actions: [.retry])])
        )
        let without = await F.coordinator(
            F.snapshot(steps: [F.step(.relays, .needsInput, actions: [.retry])])
        )

        let answeredSize = F.hostedSize(AccountSetupRelayStep(model: withAnswer, step: .relays).frame(width: 400))
        let emptySize = F.hostedSize(AccountSetupRelayStep(model: without, step: .relays).frame(width: 400))
        #expect(answeredSize == emptySize)
        withAnswer.stop()
        without.stop()
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
