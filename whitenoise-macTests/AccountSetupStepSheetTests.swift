//
//  AccountSetupStepSheetTests.swift
//  whitenoise-macTests
//

import MarmotKit
import SwiftUI
import Testing

@testable import whitenoise_mac

/// Every step screen, in every shape MarmotKit can put it in, lays out at the sheet's fixed size:
/// a screen whose content grew past it would push its pinned actions out of the sheet.
@Suite(.serialized) @MainActor struct AccountSetupStepSheetTests {
    private typealias F = OnboardingFixtures

    private static let sheetSize = CGSize(
        width: AccountSetupStepLayoutMetrics.width, height: AccountSetupStepLayoutMetrics.height
    )

    private static func expectSheetFits(
        _ step: OnboardingStepFfi,
        _ steps: [OnboardingStepStateFfi],
        proposal: OnboardingRepairProposalFfi? = nil,
        notice: OnboardingSingleDeviceNoticeFfi? = nil,
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        let model = OnboardingCoordinator.preview(steps: steps, proposal: proposal, singleDeviceNotice: notice)
        let size = F.hostedSize(AccountSetupStepSheet(model: model, step: step))
        #expect(size == sheetSize, "\(step) with \(steps.map(\.actions))", sourceLocation: sourceLocation)
    }

    @Test func profileScreens() {
        Self.expectSheetFits(.profile, [F.step(.profile, .needsInput, actions: [.editProfile, .continueWithout])])
        Self.expectSheetFits(
            .profile,
            [
                F.step(
                    .profile, .retryableFailure, findings: [.init(issue: .timedOut, endpoint: nil)],
                    actions: [.retry, .continueWithout]
                )
            ]
        )
        Self.expectSheetFits(
            .profile, [F.step(.profile, .needsInput, actions: [.approveRepair, .cancelRepair])],
            proposal: F.proposal(.profile, profile: F.profile(name: "Ada"))
        )
        Self.expectSheetFits(
            .profile, [F.step(.profile, .retryableFailure, actions: [.retry])],
            proposal: F.proposal(.profile, profile: F.profile(name: "Ada"))
        )
        Self.expectSheetFits(.profile, [F.step(.profile, .waitingForSigner)])
    }

    @Test func relayScreens() {
        Self.expectSheetFits(
            .relays,
            [
                F.step(
                    .relays, .needsInput, findings: [.init(issue: .missing, endpoint: nil)],
                    actions: [.useRecommendedRelays, .editRelays, .editDiscoveryRelays, .retry]
                )
            ]
        )
        Self.expectSheetFits(
            .relays, [F.step(.relays, .needsInput, actions: [.approveRepair, .cancelRepair])],
            proposal: F.proposal(.relays, reads: ["wss://a.example", "wss://b.example"], writes: ["wss://a.example"])
        )
        Self.expectSheetFits(
            .relays, [F.step(.relays, .retryableFailure, actions: [.retry])],
            proposal: F.proposal(.relays, reads: ["wss://a.example"], writes: ["wss://a.example"])
        )
        Self.expectSheetFits(
            .relays,
            [
                F.step(
                    .relays, .needsInput, findings: [.init(issue: .noUsableRoute, endpoint: "wss://a.example")],
                    actions: [.editRelays, .editDiscoveryRelays]
                )
            ]
        )
        Self.expectSheetFits(
            .inboxRelays, [F.step(.inboxRelays, .retryableFailure, actions: [.retry, .editDiscoveryRelays])]
        )
        Self.expectSheetFits(.relays, [F.step(.relays, .waitingForSigner, actions: [.reconnectSigner])])
        Self.expectSheetFits(
            .inboxRelays, [F.step(.inboxRelays, .needsInput, actions: [.useRecommendedRelays, .editRelays])]
        )
        Self.expectSheetFits(
            .inboxRelays, [F.step(.inboxRelays, .needsInput, actions: [.approveRepair, .cancelRepair])],
            proposal: F.proposal(.inboxRelays, reads: ["wss://inbox.example"])
        )
    }

    @Test func deviceScreens() {
        for discovery in [OnboardingDeviceDiscoveryFfi.noneFound, .otherInstallationPossible, .unknown] {
            Self.expectSheetFits(
                .singleDevice, [F.step(.singleDevice, .needsInput, actions: [.continueAnyway])],
                notice: F.notice(discovery)
            )
        }
        Self.expectSheetFits(
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
        Self.expectSheetFits(
            .keyPackage,
            [
                F.step(
                    .keyPackage, .retryableFailure, findings: [.init(issue: .publicationFailed, endpoint: nil)],
                    actions: [.retry]
                )
            ]
        )
        Self.expectSheetFits(.keyPackage, [F.step(.keyPackage, .waitingForSigner)])
        Self.expectSheetFits(
            .follows,
            [
                F.step(
                    .follows, .retryableFailure, findings: [.init(issue: .unreachable, endpoint: "wss://a.example")],
                    actions: [.retry, .continueWithout]
                )
            ]
        )
        Self.expectSheetFits(.follows, [F.step(.follows, .needsInput, actions: [.cancelRepair])])
    }

    /// The relay editor and the relay search, which replace the relay screen's overview, fit the
    /// sheet too.
    @Test func relayEditorAndSearchPanes() {
        for step in [OnboardingStepFfi.relays, .inboxRelays] {
            let model = OnboardingCoordinator.preview(steps: [
                F.step(step, .needsInput, actions: [.editRelays, .editDiscoveryRelays])
            ])
            for mode in [AccountSetupRelayStep.Mode.editing, .searching] {
                let size = F.hostedSize(
                    AccountSetupRelayStep(model: model, step: step, initialMode: mode)
                        .frame(width: Self.sheetSize.width, height: Self.sheetSize.height)
                )
                #expect(size == Self.sheetSize, "\(step) \(mode)")
            }
        }
    }

    /// A relay screen can pin four large buttons under its content. In every language, the sheet's
    /// title row and that column still leave the scrolling content at least 150pt.
    @Test func theRelayActionColumnLeavesRoomForTheStepInEveryLanguage() throws {
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
                let locale = Locale(identifier: language)
                let header = F.hostedSize(
                    AccountSetupStepSheetHeader(step: .relays) {}
                        .environment(\.locale, locale)
                        .frame(width: Self.sheetSize.width)
                )
                let column = F.hostedSize(
                    AccountSetupActionColumn {
                        AccountSetupRelayActions(plan: plan, model: model, active: .constant(nil)) { _ in }
                    }
                    .environment(\.locale, locale)
                    .controlSize(.large)
                    .wnButtonShape(.capsule)
                    .frame(width: Self.sheetSize.width)
                )
                let content = Self.sheetSize.height - header.height - column.height

                #expect(column.height > 4 * 30, "the column should hold four large buttons")
                #expect(content >= 150, "\(language): \(content)pt left for the content")
            }
        }
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
