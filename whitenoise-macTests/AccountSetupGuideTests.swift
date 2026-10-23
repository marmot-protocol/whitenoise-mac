//
//  AccountSetupGuideTests.swift
//  whitenoise-macTests
//

import AppKit
import MarmotKit
import SwiftUI
import Testing

@testable import whitenoise_mac

/// The guided account setup after Sign In: the vertical checklist and which step it offers for
/// review, what each step's own screen offers, that a walked-through setup ends on Open Chats
/// instead of jumping to the chat list, and that its tallest states still fit the smallest window.
@Suite(.serialized) @MainActor struct AccountSetupGuideTests {
    private typealias F = OnboardingFixtures

    // MARK: - Checklist

    @Test func whileChecksRunNoStepIsOfferedForReview() {
        let guide = AccountSetupGuide(
            snapshot: F.snapshot(steps: [
                F.step(.profile, .passed),
                F.step(.follows, .skipped),
                F.step(.relays, .checking),
                F.step(.inboxRelays, .pending),
            ]),
            recoveryRequired: false
        )

        #expect(guide.phase == .working(F.step(.relays, .checking)))
        #expect(guide.reviewStep == nil)
        #expect(guide.steps.map { AccountSetupGuide.checkState($0) } == [.passed, .skipped, .checking, .pending])
        #expect(guide.titleKey == "Getting ready to chat")
    }

    @Test func onlyTheFirstUnfinishedStepCanBeReviewed() {
        let relays = F.step(.relays, .retryableFailure, actions: [.retry, .useRecommendedRelays])
        let device = F.step(.singleDevice, .needsInput, actions: [.continueAnyway])
        let guide = AccountSetupGuide(
            snapshot: F.snapshot(steps: [F.step(.profile, .passed), relays, device]),
            recoveryRequired: false
        )

        #expect(guide.phase == .attention(relays))
        #expect(guide.reviewStep == .relays)
        #expect(guide.titleKey == "A little more to do")
    }

    /// The three "needs attention" splits iOS draws: an acknowledgment, an optional review, or a
    /// fix that cannot be skipped.
    @Test func attentionStatesSplitByWhatTheUserIsAskedFor() {
        let device = F.step(.singleDevice, .needsInput, actions: [.continueAnyway])
        let profile = F.step(.profile, .needsInput, actions: [.continueWithout, .editProfile])
        let relays = F.step(.relays, .needsInput, actions: [.continueAnyway, .continueWithout, .retry])

        #expect(AccountSetupGuide.checkState(device) == .acknowledgment)
        #expect(AccountSetupGuide.checkState(profile) == .optionalReview)
        #expect(AccountSetupGuide.checkState(relays) == .requiredFix)
        #expect(AccountSetupGuide.CheckState.requiredFix.subtitleKey == "Fix to continue")
        #expect(AccountSetupGuide.CheckState.optionalReview.subtitleKey == "Review or skip")
        #expect(AccountSetupGuide.CheckState.acknowledgment.subtitleKey == "Review to continue")
    }

    @Test func recoveryOutranksCancellationWhichOutranksReady() {
        let ready = F.snapshot(steps: [F.step(.profile, .passed)], ready: true)
        var cancelling = ready
        cancelling.cancellationPending = true

        #expect(AccountSetupGuide(snapshot: ready, recoveryRequired: false).phase == .ready)
        #expect(AccountSetupGuide(snapshot: cancelling, recoveryRequired: false).phase == .cancelling)
        #expect(AccountSetupGuide(snapshot: cancelling, recoveryRequired: true).phase == .recovery)
        // Recovery is not "a little more to do": nothing can be done but recover.
        #expect(
            AccountSetupGuide(snapshot: cancelling, recoveryRequired: true).titleKey == "Sign-in setup needs recovery"
        )
    }

    // MARK: - Profile step

    @Test func anEditableProfileOffersTheFormSaveAndNotNow() {
        let plan = AccountSetupProfilePlan(
            snapshot: F.snapshot(steps: [
                F.step(.profile, .needsInput, actions: [.editProfile, .continueWithout])
            ])
        )

        #expect(plan.canEdit)
        #expect(plan.canSkip)
        #expect(plan.primaryAction == .save)
        #expect(plan.titleKey == "Add your profile")
    }

    @Test func aFailedProfileLookupOffersTryAgainAndExplainsTheFailure() {
        let plan = AccountSetupProfilePlan(
            snapshot: F.snapshot(steps: [
                F.step(
                    .profile, .retryableFailure, findings: [.preview(issue: .timedOut, endpoint: nil)],
                    actions: [.retry, .continueWithout]
                )
            ])
        )

        #expect(plan.canEdit == false)
        #expect(plan.primaryAction == .retry)
        #expect(plan.titleKey == "Couldn’t load your profile")
        #expect(
            plan.messageKeys == [
                "The service we checked took too long to respond.",
                "Try again, or continue signing in without changing your profile.",
            ]
        )
    }

    @Test func anInterruptedProfilePublicationCanOnlyBeFinished() {
        var snapshot = F.snapshot(steps: [
            F.step(.profile, .retryableFailure, actions: [.retry, .continueWithout])
        ])
        snapshot.proposal = F.proposal(.profile, profile: F.profile(name: "Ada"))
        let plan = AccountSetupProfilePlan(snapshot: snapshot)

        #expect(plan.isInterrupted)
        #expect(plan.canEdit == false)
        #expect(plan.canSkip == false)
        #expect(plan.primaryAction == .retry)
    }

    @Test func theNameFieldWritesBothNostrNamesAndKeepsUnshownFields() {
        var existing = F.profile(name: "old")
        existing.nip05 = "ada@example.com"
        existing.picture = "https://example.com/old.jpg"

        let profile = AccountSetupProfilePlan.metadata(
            displayName: "  Ada  ", about: "Hi", pictureURL: "https://example.com/new.jpg", existing: existing
        )

        #expect(profile?.name == "Ada")
        #expect(profile?.displayName == "Ada")
        #expect(profile?.about == "Hi")
        #expect(profile?.picture == "https://example.com/new.jpg")
        #expect(profile?.nip05 == "ada@example.com")
        #expect(AccountSetupProfilePlan.metadata(displayName: " ", about: "", pictureURL: nil, existing: nil) == nil)
    }

    @Test func savingTheProfileUploadsThePhotoThenProposesAndApproves() async throws {
        let runtime = FakeMarmotRuntime(accounts: [])
        var snapshot = F.snapshot(steps: [F.step(.profile, .needsInput, actions: [.editProfile, .approveRepair])])
        // The fake's run and propose each only bump the revision, so the proposal propose returns
        // has to be there already, at the revision it will return: 1, then 2 after run, then 3.
        var reviewed = F.profile(name: "Ada")
        reviewed.nip05 = "ada@example.com"
        reviewed.lud16 = "ada@ln.example.com"
        snapshot.proposal = F.proposal(.profile, revision: 3, profile: reviewed)
        runtime.onboardingState = snapshot
        let model = OnboardingCoordinator(accountRef: "account", runtime: runtime)
        await model.run()
        let photo = SignUpProfileImage(
            attachment: try await AvatarImageCropper.attachment(fromCroppedImageData: Self.jpeg())
        )

        await model.saveProfile(displayName: "Ada", about: "", avatar: photo)

        #expect(runtime.uploadedProfileImageData == photo.data)
        // What was published: the uploaded photo, the typed name, and the fields the form does
        // not show carried over from the proposal it was filled from.
        let published = runtime.proposedOnboardingProfiles.last
        #expect(runtime.proposedOnboardingProfiles.count == 1)
        #expect(published?.picture == runtime.uploadedProfileImageURL)
        #expect(published?.displayName == "Ada")
        #expect(published?.name == "Ada")
        #expect(published?.nip05 == "ada@example.com")
        #expect(published?.lud16 == "ada@ln.example.com")
        #expect(model.error == nil)
        // Approved: one revision past the proposal.
        #expect(model.snapshot?.revision == 4)
    }

    @Test func publishingRefusesAProposalTheSnapshotDoesNotOffer() async {
        let runtime = FakeMarmotRuntime(accounts: [])
        runtime.onboardingState = F.snapshot(steps: [
            F.step(.relays, .needsInput, actions: [.useRecommendedRelays])
        ])
        let model = OnboardingCoordinator(accountRef: "account", runtime: runtime)
        await model.run()

        await model.useRecommendedRelays(step: .relays)

        #expect(model.error == AccountSetupFailure.settingsChanged.errorDescription)
    }

    // MARK: - Relay steps

    @Test func missingRelaysLeadWithTheDefaultsAndListThem() {
        let plan = AccountSetupRelayPlan(
            snapshot: F.snapshot(steps: [
                F.step(
                    .relays, .needsInput,
                    actions: [.retry, .editRelays, .editDiscoveryRelays, .useRecommendedRelays]
                )
            ]),
            step: .relays
        )

        #expect(plan.primaryAction == .useDefaults)
        #expect(plan.secondaryActions == [.edit, .discovery])
        #expect(plan.statusTitleKey == "Set up your relays")
        let list = plan.addressList(defaultRelays: ["wss://a.example"], searchRelays: [])
        #expect(list?.headerKey == "Default relays")
        #expect(list?.entries.first?.roleKey == "Read and write")
    }

    @Test func aProposalIsReviewedThenSavedOrDiscarded() {
        var snapshot = F.snapshot(steps: [F.step(.relays, .needsInput, actions: [.approveRepair, .cancelRepair])])
        snapshot.proposal = F.proposal(
            .relays, reads: ["wss://a.example", "wss://b.example"], writes: ["wss://a.example"])
        let plan = AccountSetupRelayPlan(snapshot: snapshot, step: .relays)

        #expect(plan.primaryAction == .approve)
        #expect(plan.secondaryActions == [.edit, .discard])
        #expect(plan.titleKey(.approve, isPrimary: true) == "Save Relay Changes")
        let entries = plan.addressList(defaultRelays: [], searchRelays: [])?.entries
        #expect(entries?.map(\.roleKey) == ["Read and write", "Read only"])
    }

    @Test func withoutDefaultsTheInboxSearchesTheDefaultRelaysFirst() {
        let plan = AccountSetupRelayPlan(
            snapshot: F.snapshot(steps: [
                F.step(.inboxRelays, .retryableFailure, actions: [.retry, .editDiscoveryRelays])
            ]),
            step: .inboxRelays
        )

        #expect(plan.primaryAction == .searchDefaults)
        #expect(plan.secondaryActions == [.retry, .discovery])
        #expect(plan.titleKey(.discovery, isPrimary: false) == "Look on Another Relay")
    }

    @Test func anInterruptedRelayPublicationOnlyRetries() {
        var snapshot = F.snapshot(steps: [F.step(.relays, .retryableFailure, actions: [.retry, .editRelays])])
        snapshot.proposal = F.proposal(.relays, reads: ["wss://a.example"], writes: ["wss://a.example"])
        let plan = AccountSetupRelayPlan(snapshot: snapshot, step: .relays)

        #expect(plan.isInterrupted)
        #expect(plan.primaryAction == .retry)
        #expect(plan.secondaryActions.isEmpty)
    }

    /// After an npub sign-in a relay step can wait on a signer the Mac cannot reconnect: there is
    /// nothing to press, so the screen says so instead of showing a lone Close.
    @Test func aStepOfferingOnlyUnsupportedActionsSaysItCannotBeFinishedHere() {
        let signer = F.snapshot(steps: [F.step(.relays, .waitingForSigner, actions: [.reconnectSigner])])
        let plan = AccountSetupRelayPlan(snapshot: signer, step: .relays)

        #expect(plan.primaryAction == nil)
        #expect(plan.secondaryActions.isEmpty)
        #expect(plan.offersNoAction)
        #expect(
            AccountSetupNoActionLines.messageKeys(.relays, in: signer) == [
                AccountSetupNoActionLines.signerKey, AccountSetupNoActionLines.unsupportedKey,
            ]
        )
        let unsupported = AccountSetupNoActionLines.unsupportedKey
        let secureMessaging = F.snapshot(steps: [F.step(.keyPackage, .retryableFailure)])
        #expect(AccountSetupNoActionLines.messageKeys(.keyPackage, in: secureMessaging) == [unsupported])
        let follows = F.snapshot(steps: [F.step(.follows, .needsInput, actions: [.editFollows])])
        #expect(AccountSetupNoActionLines.messageKeys(.follows, in: follows) == [unsupported])
        let device = F.snapshot(steps: [F.step(.singleDevice, .needsInput)])
        #expect(AccountSetupNoActionLines.messageKeys(.singleDevice, in: device) == [unsupported])
        let profile = F.snapshot(steps: [F.step(.profile, .needsInput, actions: [.editFollows])])
        #expect(AccountSetupNoActionLines.messageKeys(.profile, in: profile) == [unsupported])
    }

    /// A screen with something to press, or a step being checked again, says nothing extra.
    @Test func aStepWithAnActionOrBeingCheckedHasNoFallbackLine() {
        let defaults = F.snapshot(steps: [F.step(.relays, .needsInput, actions: [.useRecommendedRelays])])
        let checking = F.snapshot(steps: [F.step(.keyPackage, .checking)])
        let profile = F.snapshot(steps: [F.step(.profile, .needsInput, actions: [.editProfile])])
        let device = F.snapshot(steps: [F.step(.singleDevice, .needsInput, actions: [.continueAnyway])])

        #expect(AccountSetupNoActionLines.messageKeys(.relays, in: defaults).isEmpty)
        #expect(AccountSetupNoActionLines.messageKeys(.keyPackage, in: checking).isEmpty)
        #expect(AccountSetupNoActionLines.messageKeys(.profile, in: profile).isEmpty)
        #expect(AccountSetupNoActionLines.messageKeys(.singleDevice, in: device).isEmpty)
        #expect(AccountSetupNoActionLines.messageKeys(.relays, in: nil).isEmpty)
    }

    @Test func theRelayDraftNeedsValidAddressesAndAWriteRelay() {
        typealias Entry = AccountSetupRelayDraft.Entry
        #expect(AccountSetupRelayDraft(entries: [Entry()]).selection(for: .relays).problem == .empty)
        #expect(
            AccountSetupRelayDraft(entries: [Entry(address: "https://a.example")]).selection(for: .relays).problem
                == .invalidAddress
        )
        #expect(
            AccountSetupRelayDraft(entries: [Entry(address: "wss://a.example", reads: true, writes: false)])
                .selection(for: .relays).problem == .noWriteRelay
        )
        let inbox = AccountSetupRelayDraft(entries: [
            Entry(address: "wss://a.example", reads: false, writes: false),
            Entry(address: " wss://a.example "),
        ])
        #expect(inbox.selection(for: .inboxRelays).lists?.reads == ["wss://a.example"])
        #expect(inbox.selection(for: .inboxRelays).lists?.writes == [])

        let relays = AccountSetupRelayDraft(entries: [
            Entry(address: "wss://a.example", reads: true, writes: false),
            Entry(address: "wss://b.example"),
        ])
        #expect(relays.selection(for: .relays).lists?.reads == ["wss://a.example", "wss://b.example"])
        #expect(relays.selection(for: .relays).lists?.writes == ["wss://b.example"])
    }

    // MARK: - Follows

    @Test func theFollowsStepIsSkippedOrItsProposalWithdrawnAutomatically() {
        let skippable = F.snapshot(steps: [
            F.step(.profile, .passed), F.step(.follows, .needsInput, actions: [.continueWithout]),
        ])
        var proposed = F.snapshot(steps: [F.step(.follows, .needsInput, actions: [.cancelRepair])])
        proposed.proposal = F.proposal(.follows)
        let otherStep = F.snapshot(steps: [F.step(.profile, .needsInput, actions: [.continueWithout])])

        #expect(OnboardingCoordinator.automaticFollowsAction(skippable) == .skip)
        #expect(OnboardingCoordinator.automaticFollowsAction(proposed) == .cancelRepair)
        #expect(OnboardingCoordinator.automaticFollowsAction(otherStep) == nil)
    }

    // MARK: - Catalog

    /// Every key the guide and the step plans hand the views is in the catalog, so no step shows
    /// English in a translated build.
    @Test func everySetupKeyIsInTheCatalog() throws {
        let steps: [OnboardingStepFfi] = [.profile, .follows, .relays, .inboxRelays, .singleDevice, .keyPackage]
        var keys = steps.flatMap { [AccountSetupGuide.titleKey($0), AccountSetupGuide.descriptionKey($0)] }
        let states: [AccountSetupGuide.CheckState] = [
            .pending, .checking, .passed, .skipped, .optionalReview, .requiredFix, .acknowledgment,
        ]
        keys += states.map(\.subtitleKey)
        let discoveries: [OnboardingDeviceDiscoveryFfi] = [.noneFound, .otherInstallationPossible, .unknown]
        keys += discoveries.flatMap { [AccountSetupGuide.deviceNoticeKey($0), AccountSetupGuide.deviceActionKey($0)] }
        let phases: [(OnboardingSnapshotFfi?, Bool)] = [
            (F.snapshot(steps: [F.step(.profile, .checking)]), false),
            (F.snapshot(steps: [F.step(.profile, .needsInput)]), false),
            (F.snapshot(steps: [], ready: true), false),
            (nil, true),
        ]
        for (snapshot, recovery) in phases {
            let guide = AccountSetupGuide(snapshot: snapshot, recoveryRequired: recovery)
            keys += [guide.titleKey, guide.subtitleKey]
        }

        let profileActions: [[OnboardingActionFfi]] = [[.editProfile], [.retry, .continueWithout], [.retry]]
        for actions in profileActions {
            let plan = AccountSetupProfilePlan(
                snapshot: F.snapshot(steps: [F.step(.profile, .needsInput, actions: actions)]))
            keys += [plan.titleKey] + plan.messageKeys
        }
        let relayActions: [[OnboardingActionFfi]] = [
            [.useRecommendedRelays, .editRelays, .editDiscoveryRelays, .retry],
            [.editRelays, .editDiscoveryRelays], [.retry, .editDiscoveryRelays], [.retry],
        ]
        let allRelayActions: [AccountSetupRelayPlan.Action] = [
            .approve, .useDefaults, .retry, .discard, .edit, .discovery, .searchDefaults,
        ]
        for step in [OnboardingStepFfi.relays, .inboxRelays] {
            for actions in relayActions {
                let plan = AccountSetupRelayPlan(
                    snapshot: F.snapshot(steps: [F.step(step, .needsInput, actions: actions)]), step: step
                )
                keys += [plan.statusTitleKey] + plan.messageKeys
                keys += allRelayActions.flatMap {
                    [plan.titleKey($0, isPrimary: true), plan.titleKey($0, isPrimary: false)]
                }
            }
            var snapshot = F.snapshot(steps: [
                F.step(step, .needsInput, actions: [.approveRepair, .cancelRepair])
            ])
            snapshot.proposal = F.proposal(step, reads: ["wss://a.example"], writes: [])
            let plan = AccountSetupRelayPlan(snapshot: snapshot, step: step)
            keys += [plan.statusTitleKey] + plan.messageKeys
            keys += [plan.addressList(defaultRelays: [], searchRelays: [])?.headerKey].compactMap { $0 }
        }
        keys += ["Read and write", "Write only", "Read only", "Default relays", "Relays to search"]
        let problems: [AccountSetupRelayDraft.Problem] = [
            .empty, .invalidAddress, .missingUse, .noWriteRelay, .tooMany,
        ]
        keys += problems.map(\.messageKey)
        keys += [AccountSetupFailure.settingsChanged.errorDescription].compactMap { $0 }
        keys += [AccountSetupNoActionLines.unsupportedKey, AccountSetupNoActionLines.signerKey]

        let german = try #require(Bundle.main.path(forResource: "de", ofType: "lproj").flatMap(Bundle.init(path:)))
        for key in Set(keys) {
            #expect(german.localizedString(forKey: key, value: nil, table: nil) != key, "untranslated: \(key)")
        }
    }

    // MARK: - Open Chats

    @Test func aWalkedThroughSetupWaitsForOpenChats() async {
        let runtime = FakeMarmotRuntime(accounts: [])
        runtime.onboardingState = F.snapshot(steps: [F.step(.relays, .checking)])
        let model = OnboardingCoordinator(accountRef: "account", runtime: runtime)

        await model.run()
        #expect(model.canEnterChats == false)

        runtime.onboardingState = F.snapshot(steps: [F.step(.relays, .passed)], ready: true, revision: 5)
        await model.run()

        #expect(model.isDurablyReady)
        #expect(model.canEnterChats == false)

        model.openChats()
        #expect(model.canEnterChats)
    }

    @Test func anAlreadyReadyCheckpointGoesStraightIn() async {
        let runtime = FakeMarmotRuntime(accounts: [])
        runtime.onboardingState = F.snapshot(steps: [F.step(.relays, .passed)], ready: true)
        let model = OnboardingCoordinator(accountRef: "account", runtime: runtime)

        await model.run()

        #expect(model.canEnterChats)
    }

    @Test func openChatsDoesNothingBeforeTheCheckpointIsReady() async {
        let runtime = FakeMarmotRuntime(accounts: [])
        runtime.onboardingState = F.snapshot(steps: [F.step(.relays, .checking)])
        let model = OnboardingCoordinator(accountRef: "account", runtime: runtime)

        await model.run()
        model.openChats()

        #expect(model.hasConfirmedOpenChats == false)
        #expect(model.canEnterChats == false)
    }

    /// Settings → Add Account reopens onboarding while the current account's scope, and its
    /// ready checkpoint, are still active. That checkpoint must not stand in for Welcome.
    @Test func anAlreadyReadyCheckpointDoesNotReplaceWelcome() async {
        let model = await F.coordinator(F.snapshot(steps: [F.step(.relays, .passed)], ready: true))

        #expect(model.canEnterChats)
        #expect(OnboardingView.showsAccountSetup(model) == false)
        #expect(OnboardingView.showsAccountSetup(nil) == false)
    }

    /// A walked-through setup keeps its pane through Open Chats and the shell's move to the chats,
    /// then gives it up, so a later Add Account lands on Welcome.
    @Test func aWalkedThroughSetupLeavesThePaneOnceTheChatsAreEntered() async {
        let runtime = FakeMarmotRuntime(accounts: [])
        let model = await F.coordinator(F.snapshot(steps: [F.step(.relays, .checking)]), runtime: runtime)
        #expect(OnboardingView.showsAccountSetup(model))

        runtime.onboardingState = F.snapshot(steps: [F.step(.relays, .passed)], ready: true, revision: 5)
        await model.run()
        model.didEnterChats()
        #expect(model.hasEnteredChats == false, "the shell cannot enter before Open Chats")
        #expect(OnboardingView.showsAccountSetup(model))

        model.openChats()
        #expect(OnboardingView.showsAccountSetup(model), "Opening your chats… stays up until the shell leaves")

        model.didEnterChats()
        #expect(OnboardingView.showsAccountSetup(model) == false)
    }

    // MARK: - Cancel

    /// A cancellation MarmotKit is still finishing cannot be asked for again: the pane hides its
    /// ✕ then, and the coordinator refuses the press that slips through.
    @Test func aFinishingCancellationRefusesAnotherCancel() async {
        var snapshot = F.snapshot(steps: [F.step(.relays, .checking)])
        snapshot.cancellationPending = true
        let runtime = FakeMarmotRuntime(accounts: [])
        let model = await F.coordinator(snapshot, runtime: runtime)

        let first = await model.cancel()
        let second = await model.cancel()

        #expect(first == false)
        #expect(second == false)
        #expect(model.canStartSessionCommand == false)
        #expect(runtime.cancelOnboardingCallCount == 0)
    }

    /// Cancelling while a check runs would restart the observation and re-enable every button
    /// while MarmotKit is still working, so it is refused until the check returns.
    @Test func cancelIsRefusedWhileACheckIsInFlight() async {
        let runtime = FakeMarmotRuntime(accounts: [])
        runtime.onboardingState = F.snapshot(steps: [F.step(.relays, .checking)])
        runtime.onboardingRunGate.isEnabled = true
        let model = OnboardingCoordinator(accountRef: "account", runtime: runtime)
        let running = Task { await model.run() }
        await runtime.onboardingRunGate.waitUntilReached()

        let cancelledMidCheck = await model.cancel()

        #expect(cancelledMidCheck == false)
        #expect(model.isBusy)
        #expect(runtime.cancelOnboardingCallCount == 0)

        runtime.onboardingRunGate.release()
        await running.value
        let cancelledAfter = await model.cancel()

        #expect(cancelledAfter)
        #expect(runtime.cancelOnboardingCallCount == 1)
        model.stop()
    }

    // MARK: - Fit

    /// The pane's tallest states — the six-row checklist with a step to review, the recovery
    /// explanation, and the finished checklist — drawn at their floor still fit the smallest
    /// window, in every language the app ships: German and Russian run longest.
    @Test func theTallestSetupStatesFitTheSmallestWindowInEveryLanguage() async throws {
        let attention = F.snapshot(steps: [
            F.step(.profile, .passed),
            F.step(.follows, .skipped),
            F.step(
                .relays, .retryableFailure,
                findings: [
                    .preview(issue: .unreachable, endpoint: "wss://relay.example.com"),
                    .preview(issue: .timedOut, endpoint: "wss://another-relay.example.com"),
                ],
                actions: [.retry, .useRecommendedRelays, .editDiscoveryRelays, .continueWithout]
            ),
            F.step(.inboxRelays, .pending),
            F.step(.singleDevice, .pending),
            F.step(.keyPackage, .pending),
        ])
        let ready = F.snapshot(
            steps: [OnboardingStepFfi.profile, .follows, .relays, .inboxRelays, .singleDevice, .keyPackage]
                .map { F.step($0, .passed) },
            ready: true
        )
        var recovery = attention
        recovery.recoveryEpoch = "epoch"

        let languages = Bundle.main.localizations.filter { $0 != "Base" }
        #expect(languages.count >= 10)
        for (name, snapshot) in [("attention", attention), ("ready", ready), ("recovery", recovery)] {
            let model = await F.coordinator(snapshot)
            for language in languages {
                let pane = AccountSetupView(model: model)
                    .environment(WorkspaceState.preview())
                    .environment(\.locale, Locale(identifier: language))
                    .frame(width: Self.minimumWindowWidth)
                let height = try #require(ImageRenderer(content: pane).nsImage?.size.height)
                #expect(height <= Self.minimumWindowHeight, "the \(name) state needs \(height)pt in \(language)")
            }
        }
    }

    // MARK: - Fixtures

    private static let minimumWindowWidth: CGFloat = 940
    private static let minimumWindowHeight: CGFloat = 620

    /// A small JPEG, encoded the way the crop editor encodes its output.
    private static func jpeg() throws -> Data {
        let image = NSImage(size: NSSize(width: 8, height: 8), flipped: false) { rect in
            NSColor.systemTeal.setFill()
            rect.fill()
            return true
        }
        let tiff = try #require(image.tiffRepresentation)
        let bitmap = try #require(NSBitmapImageRep(data: tiff))
        return try #require(bitmap.representation(using: .jpeg, properties: [:]))
    }

}

extension Result where Success == (reads: [String], writes: [String]), Failure == AccountSetupRelayDraft.Problem {
    fileprivate var problem: AccountSetupRelayDraft.Problem? {
        if case .failure(let problem) = self { return problem }
        return nil
    }

    fileprivate var lists: (reads: [String], writes: [String])? {
        if case .success(let lists) = self { return lists }
        return nil
    }
}
