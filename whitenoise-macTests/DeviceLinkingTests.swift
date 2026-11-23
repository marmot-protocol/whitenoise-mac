import Foundation
import MarmotKit
import Observation
import Testing

@testable import whitenoise_mac

/// Device linking over MDK's device groups: the account's model mirrors MDK's reads,
/// re-reads them on the events MDK names, presents a request that wants an answer, and routes the
/// user's answers back. Linking is inert unless the runtime opened with device groups.
@MainActor
struct DeviceLinkingTests: WorkspaceTestSupport {
    private static let account = AccountItem.samples[0]
    private static let code = [DeviceLinkEmojiFfi(emoji: "🐶", description: "dog")]

    private func makeRuntime(enabled: Bool = true) -> FakeMarmotRuntime {
        let runtime = FakeMarmotRuntime(accounts: [])
        runtime.deviceGroupsEnabled = enabled
        return runtime
    }

    private func makeModel(_ runtime: FakeMarmotRuntime) -> DeviceLinkingViewModel {
        DeviceLinkingViewModel(
            accountRef: Self.account.accountRef,
            accountIdHex: Self.account.accountIdHex,
            runtime: runtime
        )
    }

    private static func prompt(_ id: String, _ state: DeviceLinkPromptStateFfi) -> DeviceLinkPromptFfi {
        DeviceLinkPromptFfi(promptId: id, slotIdHex: nil, requestedAt: 1_700_000_000, state: state)
    }

    private static func snapshot(prompts: [DeviceLinkPromptFfi] = []) -> DeviceLinkSnapshotFfi {
        DeviceLinkSnapshotFfi(newDevice: nil, prompts: prompts, moves: [], deviceGroupStalled: false)
    }

    static func makeDevice(_ slot: Character, thisDevice: Bool = false) -> LinkedDeviceFfi {
        device(slot, thisDevice: thisDevice)
    }

    private static func device(_ slot: Character, thisDevice: Bool = false) -> LinkedDeviceFfi {
        LinkedDeviceFfi(
            slotIdHex: String(repeating: slot, count: 64), isThisDevice: thisDevice, label: "", client: "",
            platform: "", linkedAt: 0, linkedBySlotIdHex: nil, status: .active, addToAllChats: true,
            bringHistory: true, keepWhileInactive: false, lastActiveAt: nil, inactive: false, removalPending: false)
    }

    // MARK: Availability

    @Test func withoutDeviceGroupsTheModelReadsAndSendsNothing() async {
        let runtime = makeRuntime(enabled: false)
        let model = makeModel(runtime)

        model.start()
        await model.startLink()
        await model.refreshAll()

        #expect(!model.isAvailable)
        #expect(runtime.deviceLinking.snapshotReadCount == 0)
        #expect(runtime.deviceLinking.deviceReadCount == 0)
        #expect(runtime.eventHub.subscriberCount == 0)
        #expect(runtime.deviceLinking.snapshot.newDevice == nil)
    }

    // MARK: Reads and events

    @Test func startingReadsEveryPart() async {
        let runtime = makeRuntime()
        runtime.deviceLinking.devices = [Self.device("a", thisDevice: true), Self.device("b")]
        runtime.deviceLinking.keyPackageRefreshOverdue = true
        runtime.deviceLinking.chatsClosedToLinkedDevices = 3
        let model = makeModel(runtime)

        model.start()
        defer { model.stop() }
        await Self.waitUntil { model.devices.count == 2 && model.keyPackageRefreshOverdue }

        #expect(model.otherDevices.map(\.slotIdHex) == [String(repeating: "b", count: 64)])
        #expect(model.chatsClosedToLinkedDevices == 3)
        #expect(runtime.deviceLinking.snapshotReadCount == 1)
    }

    @Test func aLinkChangeForThisAccountReReadsTheSnapshotOnly() async {
        let runtime = makeRuntime()
        let model = makeModel(runtime)
        model.start()
        defer { model.stop() }
        await Self.waitUntil {
            runtime.deviceLinking.snapshotReadCount == 1 && runtime.deviceLinking.deviceReadCount == 1
        }

        runtime.deviceLinking.snapshot.newDevice = .joining
        runtime.eventHub.emit(.deviceLinkChanged(accountIdHex: AccountItem.samples[1].accountIdHex, accountLabel: "x"))
        runtime.eventHub.emit(
            .deviceLinkChanged(accountIdHex: Self.account.accountIdHex.uppercased(), accountLabel: "jeff"))
        await Self.waitUntil { model.snapshot.newDevice == .joining }

        #expect(runtime.deviceLinking.snapshotReadCount == 2)
        #expect(runtime.deviceLinking.deviceReadCount == 1)
    }

    /// Removing a device re-reads the roster while its `LinkedDevicesChanged` asks for the same
    /// read. Overlapping requests for one read used to spin the main actor at 100% CPU: a waiter
    /// looped on a read that had finished but that only the read's own caller could clear.
    @Test func overlappingReadsOfOnePartAllFinish() async {
        let runtime = makeRuntime()
        let slot = String(repeating: "b", count: 64)
        runtime.deviceLinking.devices = [Self.device("a", thisDevice: true), Self.device("b")]
        let model = makeModel(runtime)
        model.start()
        defer { model.stop() }
        await Self.waitUntil { model.devices.count == 2 }

        await withTaskGroup(of: Void.self) { group in
            group.addTask { await model.remove(slotIdHex: slot) }
            for _ in 0..<8 {
                group.addTask {
                    runtime.eventHub.emit(
                        .linkedDevicesChanged(accountIdHex: Self.account.accountIdHex, accountLabel: "jeff"))
                    await model.refreshAll()
                }
            }
        }

        #expect(runtime.deviceLinking.removedSlots == [slot])
        #expect(model.device(slotIdHex: slot)?.removalPending == true)
    }

    @Test func linkedDevicesChangedReReadsTheDeviceList() async {
        let runtime = makeRuntime()
        let model = makeModel(runtime)
        model.start()
        defer { model.stop() }
        await Self.waitUntil { runtime.deviceLinking.deviceReadCount == 1 }

        runtime.deviceLinking.devices = [Self.device("a", thisDevice: true)]
        runtime.eventHub.emit(.linkedDevicesChanged(accountIdHex: Self.account.accountIdHex, accountLabel: "jeff"))
        await Self.waitUntil { model.devices.count == 1 }

        #expect(model.devices.count == 1)
    }

    /// MDK warns that moving this device can fail a link it approved that is still joining, so the
    /// Devices page says to finish it first, once this device is in a device list. Closing a prompt's
    /// sheet doesn't finish its link, so any prompt still `Linking` counts.
    @Test func aLinkThisDeviceApprovedThatIsStillJoiningIsMentionedBeforeAMove() async {
        let runtime = makeRuntime()
        runtime.deviceLinking.snapshot = Self.snapshot(prompts: [
            Self.prompt("p1", .linked), Self.prompt("p2", .linking),
        ])
        let model = makeModel(runtime)

        await model.refreshAll()
        #expect(!model.approvedLinkStillJoining)

        runtime.deviceLinking.devices = [Self.device("a", thisDevice: true), Self.device("b")]
        await model.refreshAll()
        #expect(model.approvedLinkStillJoining)

        runtime.deviceLinking.snapshot = Self.snapshot(prompts: [Self.prompt("p2", .linked)])
        await model.refreshAll()
        #expect(!model.approvedLinkStillJoining)
    }

    @Test func aFailedReadKeepsWhatWasShown() async {
        let runtime = makeRuntime()
        runtime.deviceLinking.devices = [Self.device("a", thisDevice: true)]
        let model = makeModel(runtime)
        await model.refreshAll()
        runtime.deviceLinking.error = FakeMarmotRuntimeError.unused

        await model.refreshAll()

        #expect(model.devices.count == 1)
    }

    // MARK: Prompts on a device already signed in

    @Test func aPromptThatNeedsAnAnswerOpensItsSheet() async {
        let runtime = makeRuntime()
        runtime.deviceLinking.snapshot = Self.snapshot(prompts: [Self.prompt("p1", .comparing(code: Self.code))])
        let model = makeModel(runtime)

        await model.refreshAll()

        #expect(model.presentedSheet == .prompt(id: "p1"))
    }

    @Test func finishedPromptsDoNotOpenASheet() async {
        let runtime = makeRuntime()
        runtime.deviceLinking.snapshot = Self.snapshot(prompts: [
            Self.prompt("p1", .ended(reason: .timedOut)), Self.prompt("p2", .linking),
        ])
        let model = makeModel(runtime)

        await model.refreshAll()

        #expect(model.presentedSheet == nil)
        #expect(model.openPrompts.count == 2)
    }

    @Test func aClosedPromptStaysClosedAndTheNextOneOpens() async {
        let runtime = makeRuntime()
        runtime.deviceLinking.snapshot = Self.snapshot(prompts: [
            Self.prompt("p1", .competingRequests), Self.prompt("p2", .preparing),
        ])
        let model = makeModel(runtime)
        await model.refreshAll()
        #expect(model.presentedSheet == .prompt(id: "p1"))

        model.closeSheet()
        await model.refreshAll()

        #expect(model.presentedSheet == .prompt(id: "p2"))
        #expect(model.openPrompts.map(\.promptId) == ["p2"])
    }

    /// Done on a linked prompt has to take its "linked · Review" row off the Devices page at once.
    /// MDK keeps the finished prompt listed, so nothing else would redraw the page to drop it.
    @Test func closingAFinishedPromptRedrawsTheDevicesPage() async {
        let runtime = makeRuntime()
        runtime.deviceLinking.snapshot = Self.snapshot(prompts: [Self.prompt("p1", .linked)])
        let model = makeModel(runtime)
        await model.refreshAll()
        #expect(model.openPrompts.map(\.promptId) == ["p1"])

        let redrawn = ObservationInvalidationFlag()
        withObservationTracking {
            _ = model.openPrompts
        } onChange: {
            redrawn.markInvalidated()
        }
        model.closePrompt("p1")

        #expect(redrawn.value)
        #expect(model.openPrompts.isEmpty)
    }

    @Test func devicesNameWhiteNoiseByItsProductName() {
        #expect(DeviceLinkPresentation.clientName("whitenoise") == "White Noise")
        #expect(DeviceLinkPresentation.clientName("other-client") == "other-client")
        #expect(DeviceLinkPresentation.appDescription(platform: "iOS", client: "whitenoise") == "iOS · White Noise")
        #expect(DeviceLinkPresentation.appDescription(platform: "", client: "") == nil)
    }

    @Test func linkingSendsTheTrimmedLabelAndBothChoices() async {
        let runtime = makeRuntime()
        runtime.deviceLinking.snapshot = Self.snapshot(prompts: [Self.prompt("p1", .comparing(code: Self.code))])
        let model = makeModel(runtime)
        await model.refreshAll()

        await model.link(promptId: "p1", label: "  iPhone \n", addToAllChats: true, bringHistory: false)

        let call = runtime.deviceLinking.linkCalls.first
        #expect(call?.promptId == "p1")
        #expect(call?.label == "iPhone")
        #expect(call?.addToAllChats == true)
        #expect(call?.bringHistory == false)
        #expect(model.prompt(id: "p1")?.state == .linking)
    }

    @Test func notNowDeclinesAndClosesTheSheet() async {
        let runtime = makeRuntime()
        runtime.deviceLinking.snapshot = Self.snapshot(prompts: [Self.prompt("p1", .comparing(code: Self.code))])
        let model = makeModel(runtime)
        await model.refreshAll()

        await model.decline(promptId: "p1")

        #expect(runtime.deviceLinking.declinedPromptIds == ["p1"])
        #expect(model.presentedSheet == nil)
    }

    @Test func aRefusalIsShownInItsOwnWords() async {
        let runtime = makeRuntime()
        runtime.deviceLinking.snapshot = Self.snapshot(prompts: [Self.prompt("p1", .comparing(code: Self.code))])
        runtime.deviceLinking.nextActionError = MarmotKitError.Runtime(
            details: "device group refused: too_many_devices")
        let model = makeModel(runtime)
        await model.refreshAll()

        await model.link(promptId: "p1", label: "iPhone", addToAllChats: true, bringHistory: true)

        #expect(model.actionError == DeviceLinkPresentation.refusalMessage("too_many_devices"))
        #expect(!model.isBusy(.link(promptId: "p1")))
    }

    // MARK: This device asks to be linked

    @Test func startingALinkOpensTheNewDeviceSheetAndWaitsForAnAnswer() async {
        let runtime = makeRuntime()
        let model = makeModel(runtime)

        await model.startLink()

        #expect(model.presentedSheet == .newDevice)
        #expect(model.snapshot.newDevice == .waitingForAnswer)
    }

    /// The request names a published KeyPackage; without one, publish it and ask again rather than
    /// failing the user's first try.
    @Test func startingWithoutAPublishedKeyPackagePublishesOneAndRetries() async {
        let runtime = makeRuntime()
        runtime.deviceLinking.nextActionError = MarmotKitError.Runtime(
            details: "device group refused: key_package_not_published")
        let model = makeModel(runtime)

        await model.startLink()

        #expect(runtime.deviceLinking.keyPackageRotationCount == 1)
        #expect(model.snapshot.newDevice == .waitingForAnswer)
        #expect(model.actionError == nil)
    }

    @Test func confirmingAndCancellingFollowTheCore() async {
        let runtime = makeRuntime()
        let model = makeModel(runtime)
        await model.startLink()

        await model.confirmMatch()
        #expect(model.snapshot.newDevice == .waitingForOtherDevice)

        await model.cancelLink()
        #expect(model.snapshot.newDevice == .ended(reason: .cancelled))
    }

    // MARK: Suggesting a link after sign-in

    private static func earlierSignIn(_ state: UnrecognizedSignInStateFfi = .prompt) -> UnrecognizedSignInFfi {
        UnrecognizedSignInFfi(
            slotIdHex: String(repeating: "e", count: 64), client: "whitenoise", appearedAt: 0, lastSeenAt: 0,
            beforeThisDevice: true, signedIn: true, state: state, linkedBySlotIdHex: nil, previouslyLinkedHere: false)
    }

    /// A fresh sign-in on a profile already used elsewhere is offered a link, once.
    @Test func aSignInFromBeforeThisDeviceSuggestsLinkingOnce() async {
        let runtime = makeRuntime()
        runtime.deviceLinking.signIns = [Self.earlierSignIn()]
        let model = makeModel(runtime)
        await model.refreshAll()

        model.presentLinkSuggestionIfNeeded()
        #expect(model.presentedSheet == .linkSuggestion)

        model.closeSheet()
        model.presentLinkSuggestionIfNeeded()
        #expect(model.presentedSheet == nil)
    }

    @Test func noSuggestionOnceLinkedStartedFreshOrAnswered() async {
        let linked = makeRuntime()
        linked.deviceLinking.signIns = [Self.earlierSignIn()]
        linked.deviceLinking.devices = [Self.device("a", thisDevice: true), Self.device("b")]
        let fresh = makeRuntime()
        fresh.deviceLinking.signIns = [Self.earlierSignIn()]
        fresh.deviceLinking.startedFresh = true
        let answered = makeRuntime()
        answered.deviceLinking.signIns = [Self.earlierSignIn(.notNow)]

        for runtime in [linked, fresh, answered] {
            let model = makeModel(runtime)
            await model.refreshAll()
            #expect(!model.suggestsLinking)
        }
    }

    @Test func linkingFromTheSuggestionStartsThisDevicesLink() async {
        let runtime = makeRuntime()
        runtime.deviceLinking.signIns = [Self.earlierSignIn()]
        let model = makeModel(runtime)
        await model.refreshAll()
        model.presentLinkSuggestionIfNeeded()

        await model.startLink()

        #expect(model.presentedSheet == .newDevice)
        #expect(model.snapshot.newDevice == .waitingForAnswer)
        #expect(!model.suggestsLinking)
    }

    /// Only the new device can start a link. The device already set up waits, and the request it was
    /// waiting for replaces that sheet, as it replaces the which-device-is-new question.
    @Test func anArrivingRequestReplacesTheWaitingAndSuggestionSheets() async {
        let runtime = makeRuntime()
        runtime.deviceLinking.signIns = [Self.earlierSignIn()]
        let model = makeModel(runtime)
        await model.refreshAll()

        model.presentLinkSuggestionIfNeeded()
        model.showAddNewDevice()
        #expect(model.presentedSheet == .addNewDevice)

        runtime.deviceLinking.snapshot = Self.snapshot(prompts: [Self.prompt("p1", .preparing)])
        await model.refreshAll()

        #expect(model.presentedSheet == .prompt(id: "p1"))
    }

    @Test func thisDevicesOwnLinkIsNotReplacedByARequest() async {
        let runtime = makeRuntime()
        let model = makeModel(runtime)
        await model.startLink()

        runtime.deviceLinking.snapshot = Self.snapshot(prompts: [Self.prompt("p1", .preparing)])
        runtime.deviceLinking.snapshot.newDevice = .waitingForAnswer
        await model.refreshAll()

        #expect(model.presentedSheet == .newDevice)
    }

    // MARK: Devices and repair

    @Test func removingADeviceReReadsTheList() async {
        let runtime = makeRuntime()
        runtime.deviceLinking.devices = [Self.device("a", thisDevice: true), Self.device("b")]
        let model = makeModel(runtime)
        await model.refreshAll()
        let slot = String(repeating: "b", count: 64)

        let removed = await model.remove(slotIdHex: slot)

        #expect(removed)
        #expect(runtime.deviceLinking.removedSlots == [slot])
        #expect(model.device(slotIdHex: slot)?.removalPending == true)
    }

    @Test func settingsPatchOnlyTheChangedToggle() async {
        let runtime = makeRuntime()
        runtime.deviceLinking.devices = [Self.device("b")]
        let model = makeModel(runtime)
        let slot = String(repeating: "b", count: 64)

        await model.update(slotIdHex: slot, keepWhileInactive: true)

        let update = runtime.deviceLinking.settingsUpdates.first
        #expect(update?.addToAllChats == nil)
        #expect(update?.bringHistory == nil)
        #expect(update?.keepWhileInactive == true)
        #expect(model.device(slotIdHex: slot)?.keepWhileInactive == true)
    }

    /// MDK's repair is two steps before a fresh link: discard the stalled copy, publish a KeyPackage.
    @Test func resetForRepairAlsoPublishesAKeyPackage() async {
        let runtime = makeRuntime()
        runtime.deviceLinking.snapshot.deviceGroupStalled = true
        let model = makeModel(runtime)
        await model.refreshAll()

        await model.resetForRepair()

        #expect(runtime.deviceLinking.resetCount == 1)
        #expect(runtime.deviceLinking.keyPackageRotationCount == 1)
        #expect(!model.snapshot.deviceGroupStalled)
    }

    /// The reset can go through and the KeyPackage fail: the repair state still leaves the screen.
    @Test func aResetWhoseKeyPackageFailsStillShowsTheReset() async {
        let runtime = makeRuntime()
        runtime.deviceLinking.snapshot.deviceGroupStalled = true
        runtime.deviceLinking.keyPackageRotationError = FakeMarmotRuntimeError.unused
        let model = makeModel(runtime)
        await model.refreshAll()

        await model.resetForRepair()

        #expect(runtime.deviceLinking.resetCount == 1)
        #expect(model.actionError != nil)
        #expect(!model.snapshot.deviceGroupStalled)
    }

    @Test func answeringASignInReReadsTheList() async {
        let runtime = makeRuntime()
        let slot = String(repeating: "c", count: 64)
        runtime.deviceLinking.signIns = [
            UnrecognizedSignInFfi(
                slotIdHex: slot, client: "", appearedAt: 0, lastSeenAt: 0, beforeThisDevice: false, signedIn: true,
                state: .prompt, linkedBySlotIdHex: nil, previouslyLinkedHere: false)
        ]
        let model = makeModel(runtime)
        await model.refreshAll()

        await model.answer(slotIdHex: slot, response: .reject)

        #expect(runtime.deviceLinking.answers.map(\.response) == [.reject])
        #expect(model.signIns.isEmpty)
    }

    // MARK: Presentation

    @Test func labelsAreNonBlankAndAtMost64Bytes() {
        #expect(!DeviceLinkPresentation.isValidLabel("   "))
        #expect(DeviceLinkPresentation.isValidLabel(String(repeating: "a", count: 64)))
        #expect(!DeviceLinkPresentation.isValidLabel(String(repeating: "a", count: 65)))
        // 22 three-byte characters are 66 bytes: the limit is bytes, not characters.
        #expect(!DeviceLinkPresentation.isValidLabel(String(repeating: "€", count: 22)))
    }

    @Test func refusalsOutsideTheDeviceGroupFallBackToTheGeneralCopy() {
        let other = MarmotKitError.Runtime(details: "something else")
        #expect(DeviceLinkPresentation.errorMessage(for: other) == UserFacingError.message(for: other))
        let unknown = MarmotKitError.Runtime(details: "device group refused: brand_new_reason")
        #expect(
            DeviceLinkPresentation.errorMessage(for: unknown)
                == DeviceLinkPresentation.refusalMessage("brand_new_reason"))
    }

    @Test func anInactiveDeviceOffersKeepOnlyWhenNothingKeepsIt() {
        var device = Self.device("b")
        device.status = .inactive
        #expect(DeviceLinkPresentation.offersKeepOrRemove(device))
        device.keepWhileInactive = true
        #expect(!DeviceLinkPresentation.offersKeepOrRemove(device))
    }
}

/// A chat lets members' linked devices join only once an admin turns account-devices on, and the
/// switch is a group change: MDK's advisory refusals ask first, and a refusal names why.
@MainActor
struct GroupAccountDevicesTests {
    private static func setUp(
        _ activation: AccountDevicesActivationFfi, prompter: GroupChangeAdvisoryPrompter? = nil
    ) -> (FakeMarmotRuntime, GroupAccountDevicesViewModel, String) {
        let account = desktopAccount()
        let runtime = FakeMarmotRuntime(accounts: [account])
        runtime.deviceGroupsEnabled = true
        let details = groupDetailsFixture(selfAccountIdHex: account.accountIdHex)
        runtime.installGroupDetails(details)
        let groupIdHex = details.group.groupIdHex
        runtime.accountDevicesActivations[groupIdHex] = activation
        let model = GroupAccountDevicesViewModel(
            accountRef: account.accountIdHex, groupIdHex: groupIdHex, runtime: runtime, advisory: prompter)
        return (runtime, model, groupIdHex)
    }

    @Test func withoutDeviceGroupsNothingIsReadOrSent() async {
        let runtime = FakeMarmotRuntime(accounts: [])
        let model = GroupAccountDevicesViewModel(
            accountRef: "a", groupIdHex: "g", runtime: runtime, advisory: nil)

        await model.load()
        let enabled = await model.enable()

        #expect(model.activation == nil)
        #expect(!enabled)
        #expect(runtime.enabledAccountDevicesGroupIds.isEmpty)
    }

    @Test func enablingAnEligibleChatTurnsItOnAndReReads() async {
        let (runtime, model, groupIdHex) = Self.setUp(.eligible)
        await model.load()
        #expect(model.activation == .eligible)

        let enabled = await model.enable()

        #expect(enabled)
        #expect(runtime.enabledAccountDevicesGroupIds == [groupIdHex])
        #expect(model.activation == .alreadyEnabled)
        #expect(model.error == nil)
    }

    /// Turned on is turned on: a re-read that fails afterwards doesn't offer Turn On again.
    @Test func aChatTurnedOnStaysOnWhenTheReReadFails() async {
        let (runtime, model, _) = Self.setUp(.eligible)
        await model.load()
        runtime.accountDevicesActivationError = FakeMarmotRuntimeError.unused

        let enabled = await model.enable()

        #expect(enabled)
        #expect(model.activation == .alreadyEnabled)
    }

    /// MDK checks again when the commit is built; its reason replaces the stale answer on screen.
    @Test func aRefusalShowsMDKsReason() async {
        let (runtime, model, groupIdHex) = Self.setUp(.eligible)
        await model.load()
        runtime.accountDevicesActivations[groupIdHex] = .membersNeedUpdate

        let enabled = await model.enable()

        #expect(!enabled)
        #expect(model.activation == .membersNeedUpdate)
        #expect(model.error == nil)
    }

    @Test func anAdvisoryRefusalAsksAndRetriesOnConsent() async throws {
        let prompter = GroupChangeAdvisoryPrompter()
        let (runtime, model, groupIdHex) = Self.setUp(.eligible, prompter: prompter)
        runtime.groupChangeAdvisoryRefusals[groupIdHex] = .GroupCatchingUp(groupIdHex: groupIdHex)

        let enabling = Task { await model.enable() }
        var prompt: GroupChangeAdvisoryPrompter.Prompt?
        for _ in 0..<10_000 where prompt == nil {
            prompt = prompter.prompt
            await Task.yield()
        }
        let shown = try #require(prompt)
        prompter.resolve(id: shown.id, approved: true)

        #expect(await enabling.value)
        #expect(runtime.groupChangeAdvisoryAcknowledgements == ["catchingUp:\(groupIdHex)"])
        #expect(runtime.enabledAccountDevicesGroupIds == [groupIdHex])
    }

    @Test func choosingWaitIsNotAnError() async throws {
        let prompter = GroupChangeAdvisoryPrompter()
        let (runtime, model, groupIdHex) = Self.setUp(.eligible, prompter: prompter)
        runtime.groupChangeAdvisoryRefusals[groupIdHex] = .GroupCommitUndelivered(groupIdHex: groupIdHex)

        let enabling = Task { await model.enable() }
        var prompt: GroupChangeAdvisoryPrompter.Prompt?
        for _ in 0..<10_000 where prompt == nil {
            prompt = prompter.prompt
            await Task.yield()
        }
        prompter.resolve(id: try #require(prompt).id, approved: false)

        #expect(await enabling.value == false)
        #expect(model.error == nil)
        #expect(runtime.enabledAccountDevicesGroupIds.isEmpty)
    }
}

/// "This Mac was unlinked": MDK fires `DeviceUnlinked` once per account, after signing it out here.
@MainActor
struct DeviceUnlinkMonitorTests: WorkspaceTestSupport {
    @Test func anUnlinkEventRaisesOneNoticePerAccountInTurn() async {
        let runtime = FakeMarmotRuntime(accounts: [])
        runtime.deviceGroupsEnabled = true
        let monitor = DeviceUnlinkMonitor()
        let observing = Task { await monitor.observe(runtime) }
        defer { observing.cancel() }
        await Self.waitUntil { runtime.eventHub.subscriberCount == 1 }

        runtime.eventHub.emit(.deviceUnlinked(accountIdHex: "AA", accountLabel: "jeff"))
        runtime.eventHub.emit(.deviceUnlinked(accountIdHex: "aa", accountLabel: "jeff"))
        runtime.eventHub.emit(.deviceUnlinked(accountIdHex: "bb", accountLabel: "lab"))
        await Self.waitUntil { monitor.notice != nil }
        // Give the queued events time to land.
        await Self.waitUntil(timeout: .milliseconds(200)) { false }

        #expect(monitor.notice?.accountIdHex == "aa")
        monitor.dismiss()
        #expect(monitor.notice?.accountIdHex == "bb")
        monitor.dismiss()
        #expect(monitor.notice == nil)
    }

    /// The shell signs the account out as the event arrives, before the notice is answered.
    @Test func theEventHandsTheAccountToTheShellAsItArrives() async {
        let runtime = FakeMarmotRuntime(accounts: [])
        runtime.deviceGroupsEnabled = true
        let monitor = DeviceUnlinkMonitor()
        var unlinked: [String] = []
        let observing = Task { await monitor.observe(runtime) { unlinked.append($0) } }
        defer { observing.cancel() }
        await Self.waitUntil { runtime.eventHub.subscriberCount == 1 }

        runtime.eventHub.emit(.deviceUnlinked(accountIdHex: "AA", accountLabel: "jeff"))
        await Self.waitUntil { !unlinked.isEmpty }

        #expect(unlinked == ["aa"])
        #expect(monitor.notice?.accountIdHex == "aa")
    }

    /// MDK has already signed an unlinked account out, so leaving it does only the app's half: the
    /// last signed-in profile's chats stop showing, without asking MDK to sign out again.
    @Test func leavingAnAccountMDKAlreadySignedOutTearsItDownWithoutSigningOutAgain() async throws {
        let account = desktopAccount()
        let runtime = FakeMarmotRuntime(accounts: [account])
        runtime.installGroup(messageGroup())
        let state = WorkspaceState(clientFactory: { runtime })
        await state.bootstrap()
        let active = try #require(state.activeAccount)
        state.selectChat(try #require(state.activeChats.first { $0.id == "group" }))

        runtime.unlinkFromAnotherDevice(accountRef: account.label)
        await state.signOutAccount(active)

        #expect(runtime.signOutCallCount == 0)
        #expect(state.activeAccountId == nil)
        #expect(state.phase == .onboarding)
        #expect(state.activeChats.isEmpty)
        #expect(state.accounts.first?.unlinked == true)
    }

    /// Another account change can hold the account-change gate through the event and the Delete
    /// press. The app still leaves the unlinked profile at once, and the delete runs when the other
    /// change ends instead of being dropped.
    @Test func anUnlinkDuringAnotherAccountChangeIsLeftAndDeletedAfterIt() async throws {
        let desktop = desktopAccount()
        let backup = AccountSummaryFfi(
            label: "Backup Account",
            accountIdHex: "1111111111111111111111111111111111111111111111111111111111111111",
            localSigning: true, externalSigning: false, signedOut: false, running: true, unlinked: false)
        let runtime = FakeMarmotRuntime(accounts: [desktop, backup])
        runtime.installGroup(messageGroup())
        UserDefaults.standard.set(desktop.label, forKey: WorkspaceState.activeAccountKey)
        let state = WorkspaceState(clientFactory: { runtime })
        await state.bootstrap()
        #expect(state.activeAccountId == desktop.label)
        let backupItem = try #require(state.accounts.first { $0.id == backup.label })

        let otherChange = AsyncFfiGate()
        otherChange.isEnabled = true
        runtime.onSignOutAccountMidFlight = { _ in await otherChange.passIfArmed() }
        let signingOutBackup = Task { await state.signOutAccount(backupItem) }
        await otherChange.waitUntilReached()
        #expect(state.isAccountMutationInProgress)

        runtime.unlinkFromAnotherDevice(accountRef: desktop.label)
        // The leave takes the profile off screen at once, then checks again once the other change ends.
        let leaving = Task {
            await AccountExit.leaveSignedOutAccount(accountIdHex: desktop.accountIdHex.lowercased(), in: state)
        }
        await Self.waitUntil { state.activeAccountId == nil }
        #expect(state.activeChats.isEmpty)

        let deleting = Task {
            await AccountExit.removeUnlinkedAccount(accountIdHex: desktop.accountIdHex.lowercased(), in: state)
        }
        await Self.waitUntil(timeout: .milliseconds(200)) { false }
        #expect(runtime.removedAccountRefs.isEmpty)

        otherChange.release()
        await signingOutBackup.value
        await leaving.value
        _ = await deleting.value

        #expect(runtime.removedAccountRefs == [desktop.label])
        #expect(!state.accounts.contains { $0.id == desktop.label })
    }

    /// The other order: a sign-out of another profile read the account list before MDK signed the
    /// unlinked one out, and installs that list after the app left it. The unlinked profile must not
    /// come back as signed in, or become the profile on screen.
    @Test func anOlderAccountListInstalledAfterTheUnlinkDoesNotBringItBack() async throws {
        let desktop = desktopAccount()
        let backup = AccountSummaryFfi(
            label: "Backup Account",
            accountIdHex: "1111111111111111111111111111111111111111111111111111111111111111",
            localSigning: true, externalSigning: false, signedOut: false, running: true, unlinked: false)
        let runtime = FakeMarmotRuntime(accounts: [desktop, backup])
        UserDefaults.standard.set(desktop.label, forKey: WorkspaceState.activeAccountKey)
        let state = WorkspaceState(clientFactory: { runtime })
        await state.bootstrap()
        let backupItem = try #require(state.accounts.first { $0.id == backup.label })

        // Hold the account-list read that follows MDK's sign-out of the backup profile, after it has
        // taken MDK's list (desktop still signed in).
        runtime.onSignOutAccountMidFlight = { _ in runtime.userProfileGateEnabled = true }
        let signingOutBackup = Task { await state.signOutAccount(backupItem) }
        await Self.waitUntil { runtime.didReachUserProfileGate }

        runtime.unlinkFromAnotherDevice(accountRef: desktop.label)
        // The leave's own read waits behind the held one, so the held one can't land after it.
        let leaving = Task {
            await AccountExit.leaveSignedOutAccount(accountIdHex: desktop.accountIdHex.lowercased(), in: state)
        }
        await Self.waitUntil(timeout: .milliseconds(100)) { false }

        runtime.releaseUserProfileGate()
        await signingOutBackup.value
        await leaving.value

        #expect(state.activeAccountId == nil)
        #expect(state.accounts.first { $0.id == desktop.label }?.signedOut == true)
        #expect(state.phase == .onboarding)
    }

    /// The profile refresh that runs when the app comes back to the front takes no account-change
    /// gate. One that read the list before the unlink still can't put the profile back.
    @Test func aProfileRefreshThatReadBeforeTheUnlinkDoesNotBringItBack() async throws {
        let desktop = desktopAccount()
        let backup = AccountSummaryFfi(
            label: "Backup Account",
            accountIdHex: "1111111111111111111111111111111111111111111111111111111111111111",
            localSigning: true, externalSigning: false, signedOut: false, running: true, unlinked: false)
        let runtime = FakeMarmotRuntime(accounts: [desktop, backup])
        UserDefaults.standard.set(desktop.label, forKey: WorkspaceState.activeAccountKey)
        let state = WorkspaceState(clientFactory: { runtime })
        await state.bootstrap()
        #expect(state.activeAccountId == desktop.label)

        runtime.userProfileGateEnabled = true
        let refreshing = Task { await state.refreshAccountProfiles() }
        await Self.waitUntil { runtime.didReachUserProfileGate }

        runtime.unlinkFromAnotherDevice(accountRef: desktop.label)
        let leaving = Task {
            await AccountExit.leaveSignedOutAccount(accountIdHex: desktop.accountIdHex.lowercased(), in: state)
        }
        await Self.waitUntil(timeout: .milliseconds(100)) { false }
        runtime.releaseUserProfileGate()
        await refreshing.value
        await leaving.value

        #expect(state.activeAccountId == backup.label)
        #expect(state.accounts.first { $0.id == desktop.label }?.signedOut == true)
    }

    /// With two profiles left the unlink opens the profile chooser, and the refresh that runs when
    /// the app comes back to the front leaves it open rather than picking one.
    @Test func theChooserAfterAnUnlinkSurvivesAFocusRefresh() async throws {
        let desktop = desktopAccount()
        let others = ["1111", "2222"].map { prefix in
            AccountSummaryFfi(
                label: "Account \(prefix)", accountIdHex: String(repeating: prefix, count: 16),
                localSigning: true, externalSigning: false, signedOut: false, running: true, unlinked: false)
        }
        let runtime = FakeMarmotRuntime(accounts: [desktop] + others)
        UserDefaults.standard.set(desktop.label, forKey: WorkspaceState.activeAccountKey)
        let state = WorkspaceState(clientFactory: { runtime })
        await state.bootstrap()
        #expect(state.activeAccountId == desktop.label)

        runtime.unlinkFromAnotherDevice(accountRef: desktop.label)
        await AccountExit.leaveSignedOutAccount(accountIdHex: desktop.accountIdHex.lowercased(), in: state)
        #expect(state.activeAccountId == nil)

        await state.refreshAccountProfiles()

        #expect(state.activeAccountId == nil)
        #expect(state.signedInAccounts.count == 2)
    }

    /// MDK has signed the account out when the event arrives, so the app leaves it even when the
    /// account list can't be read then; the event won't come again.
    @Test func anUnlinkLeavesTheProfileEvenWhenTheListCantBeRead() async throws {
        let desktop = desktopAccount()
        let backup = AccountSummaryFfi(
            label: "Backup Account",
            accountIdHex: "1111111111111111111111111111111111111111111111111111111111111111",
            localSigning: true, externalSigning: false, signedOut: false, running: true, unlinked: false)
        let runtime = FakeMarmotRuntime(accounts: [desktop, backup])
        runtime.installGroup(messageGroup())
        UserDefaults.standard.set(desktop.label, forKey: WorkspaceState.activeAccountKey)
        let state = WorkspaceState(clientFactory: { runtime })
        await state.bootstrap()
        #expect(state.activeAccountId == desktop.label)

        runtime.unlinkFromAnotherDevice(accountRef: desktop.label)
        runtime.listAccountsError = MarmotKitError.Runtime(details: "storage busy")
        await AccountExit.leaveSignedOutAccount(accountIdHex: desktop.accountIdHex.lowercased(), in: state)

        #expect(state.activeAccountId == backup.label)
        #expect(state.accounts.first { $0.id == desktop.label }?.signedOut == true)
        #expect(state.chatsByAccount[desktop.label]?.isEmpty ?? true)
        #expect(state.lastError == nil)
    }

    /// The unlinked profile goes off screen before the app awaits anything: its chats are gone while
    /// the account list is still being read.
    @Test func anUnlinkedProfileIsOffScreenBeforeTheListIsRead() async throws {
        let desktop = desktopAccount()
        let backup = AccountSummaryFfi(
            label: "Backup Account",
            accountIdHex: "1111111111111111111111111111111111111111111111111111111111111111",
            localSigning: true, externalSigning: false, signedOut: false, running: true, unlinked: false)
        let runtime = FakeMarmotRuntime(accounts: [desktop, backup])
        runtime.installGroup(messageGroup())
        UserDefaults.standard.set(desktop.label, forKey: WorkspaceState.activeAccountKey)
        let state = WorkspaceState(clientFactory: { runtime })
        await state.bootstrap()
        #expect(!state.activeChats.isEmpty)

        runtime.unlinkFromAnotherDevice(accountRef: desktop.label)
        runtime.userProfileGateEnabled = true
        let leaving = Task {
            await AccountExit.leaveSignedOutAccount(accountIdHex: desktop.accountIdHex.lowercased(), in: state)
        }
        await Self.waitUntil { runtime.didReachUserProfileGate }

        #expect(state.activeAccountId == nil)
        #expect(state.activeChats.isEmpty)
        #expect(state.chatsByAccount[desktop.label]?.isEmpty ?? true)

        runtime.releaseUserProfileGate()
        await leaving.value
        #expect(state.activeAccountId == backup.label)
    }

    private func twoProfiles() async -> (FakeMarmotRuntime, WorkspaceState) {
        let runtime = FakeMarmotRuntime(accounts: [desktopAccount(), Self.backupSummary])
        runtime.installGroup(messageGroup())
        UserDefaults.standard.set(desktopAccount().label, forKey: WorkspaceState.activeAccountKey)
        let state = WorkspaceState(clientFactory: { runtime })
        await state.bootstrap()
        return (runtime, state)
    }

    private static let backupSummary = AccountSummaryFfi(
        label: "Backup Account",
        accountIdHex: "1111111111111111111111111111111111111111111111111111111111111111",
        localSigning: true, externalSigning: false, signedOut: false, running: true, unlinked: false)

    /// One slow teardown doesn't hold up the next unlink: each account's runs on its own.
    @Test func aSlowTeardownDoesNotHoldUpTheNextUnlink() async {
        let runtime = FakeMarmotRuntime(accounts: [])
        runtime.deviceGroupsEnabled = true
        let monitor = DeviceUnlinkMonitor()
        let firstTeardown = AsyncFfiGate()
        firstTeardown.isEnabled = true
        var started: [String] = []
        let observing = Task {
            await monitor.observe(runtime) { id in
                started.append(id)
                if id == "aa" { await firstTeardown.passIfArmed() }
            }
        }
        defer { observing.cancel() }
        await Self.waitUntil { runtime.eventHub.subscriberCount == 1 }

        runtime.eventHub.emit(.deviceUnlinked(accountIdHex: "aa", accountLabel: "jeff"))
        await firstTeardown.waitUntilReached()
        runtime.eventHub.emit(.deviceUnlinked(accountIdHex: "bb", accountLabel: "lab"))
        await Self.waitUntil(timeout: .seconds(2)) { started.contains("bb") }

        #expect(started == ["aa", "bb"])
        firstTeardown.release()
    }

    /// Delete Everything on an unlinked profile goes through MDK's full wipe, as MDK asks, and hands
    /// its report to the shell, even when the account list couldn't be read as the unlink arrived.
    @Test func deletingAnUnlinkedProfileWipesItThroughMDK() async throws {
        let (runtime, state) = await twoProfiles()
        var partial = runtime.wipeOutcome
        partial.keyPackageFailures = [RelayFailureFfi(eventIdHex: "kp", reason: "relay refused")]
        runtime.wipeOutcome = partial
        runtime.unlinkFromAnotherDevice(accountRef: desktopAccount().label)
        runtime.listAccountsError = MarmotKitError.Runtime(details: "busy")
        await AccountExit.leaveSignedOutAccount(accountIdHex: desktopAccount().accountIdHex.lowercased(), in: state)
        runtime.listAccountsError = nil

        let removal = await AccountExit.removeUnlinkedAccount(
            accountIdHex: desktopAccount().accountIdHex.lowercased(), in: state)

        #expect(runtime.wipedAccountRefs == [desktopAccount().label])
        #expect(removal.outcome?.keyPackageFailures.count == 1)
        #expect(removal.leftBehind == nil)
        #expect(!state.accounts.contains { $0.id == desktopAccount().label })
    }

    /// A delete that fails leaves the profile here and says so, so the notice can offer it again.
    @Test func aFailedDeleteOfAnUnlinkedProfileIsReportedAsFailed() async throws {
        let (runtime, state) = await twoProfiles()
        runtime.unlinkFromAnotherDevice(accountRef: desktopAccount().label)
        await AccountExit.leaveSignedOutAccount(accountIdHex: desktopAccount().accountIdHex.lowercased(), in: state)
        runtime.removeAccountError = MarmotKitError.Runtime(details: "storage busy")

        let removal = await AccountExit.removeUnlinkedAccount(
            accountIdHex: desktopAccount().accountIdHex.lowercased(), in: state)

        #expect(removal.leftBehind?.id == desktopAccount().label)
        #expect(state.accounts.contains { $0.id == desktopAccount().label })
        #expect(state.lastError != nil)
    }

    /// A wipe that returns has removed the profile (MDK's contract: the account ref is then
    /// invalid), even when its cleanup didn't finish and the list can't be read. The profile goes,
    /// and the report says what was left undone; there is nothing to retry.
    @Test func anIncompleteWipeStillRemovesTheUnlinkedProfile() async throws {
        let (runtime, state) = await twoProfiles()
        var incomplete = runtime.wipeOutcome
        incomplete.localCleanup = LocalCleanupReportFfi(completed: false, reason: "locked")
        runtime.wipeOutcome = incomplete
        runtime.unlinkFromAnotherDevice(accountRef: desktopAccount().label)
        await AccountExit.leaveSignedOutAccount(accountIdHex: desktopAccount().accountIdHex.lowercased(), in: state)
        runtime.onRemoveAccountMidFlight = { _ in runtime.listAccountsError = MarmotKitError.Runtime(details: "busy") }

        let removal = await AccountExit.removeUnlinkedAccount(
            accountIdHex: desktopAccount().accountIdHex.lowercased(), in: state)

        #expect(removal.outcome?.localCleanup.completed == false)
        #expect(removal.leftBehind == nil)
        #expect(!state.accounts.contains { $0.id == desktopAccount().label })
    }

    /// The same for the profile on screen: an incomplete wipe with an unreadable list still leaves
    /// it at once, rather than restoring a session for an account MDK no longer holds.
    @Test func anIncompleteWipeOfTheActiveProfileStillLeavesIt() async throws {
        let (runtime, state) = await twoProfiles()
        let desktop = try #require(state.activeAccount)
        var incomplete = runtime.wipeOutcome
        incomplete.localCleanup = LocalCleanupReportFfi(completed: false, reason: "disk")
        runtime.wipeOutcome = incomplete
        runtime.onRemoveAccountMidFlight = { _ in runtime.listAccountsError = MarmotKitError.Runtime(details: "disk") }

        let outcome = await state.removeAccount(desktop)

        #expect(outcome?.localCleanup.completed == false)
        #expect(!state.accounts.contains { $0.id == desktop.id })
        #expect(state.activeAccountId == Self.backupSummary.label)
    }

    /// A profile still listed here that MDK no longer holds (it answers `UnknownAccount`) is gone:
    /// deleting it finishes leaving it instead of restoring it.
    @Test func deletingAProfileMDKNoLongerHoldsFinishesLeavingIt() async throws {
        let (runtime, state) = await twoProfiles()
        let desktop = try #require(state.activeAccount)
        try await runtime.removeAccount(accountRef: desktop.accountRef)  // gone in MDK, still listed here

        _ = await state.removeAccount(desktop)

        #expect(!state.accounts.contains { $0.id == desktop.id })
        #expect(state.activeAccountId == Self.backupSummary.label)
    }

    /// The same when the read after still lists it (it lagged MDK): MDK said it holds no such
    /// account, so the profile goes rather than being offered for deletion again.
    @Test func aProfileMDKNoLongerHoldsGoesEvenWhenTheListStillHasIt() async throws {
        let (runtime, state) = await twoProfiles()
        let desktop = try #require(state.activeAccount)
        runtime.listedAccountsOverride = try runtime.listAccounts()
        try await runtime.removeAccount(accountRef: desktop.accountRef)  // gone in MDK, still listed

        _ = await state.removeAccount(desktop)

        #expect(!state.accounts.contains { $0.id == desktop.id })
        #expect(state.activeAccountId == Self.backupSummary.label)
    }

    /// A focus read that sees a profile merely signed out (a Sign Out still finishing) doesn't treat
    /// it as unlinked: no false unlink notice, no Delete Everything wipe.
    @Test func aFocusRefreshLeavesAPlainSignOutAlone() async throws {
        let (runtime, state) = await twoProfiles()
        _ = try await runtime.signOut(accountRef: desktopAccount().label, deleteKeyPackages: false)

        await state.refreshAccountProfiles()

        // The unlink path isn't taken: the Sign Out that signed it out moves the app on itself.
        #expect(state.activeAccountId == desktopAccount().label)
        #expect(state.accounts.first { $0.id == desktopAccount().label }?.unlinked == false)
    }

    /// An unlink that lands while the refresh waits on a relay is caught by its final read.
    @Test func aMissedUnlinkDuringTheRelayRefreshIsLeftByItsFinalRead() async throws {
        let (runtime, state) = await twoProfiles()
        let relayWait = AsyncFfiGate()
        relayWait.isEnabled = true
        runtime.onRefreshProfile = { _ in await relayWait.passIfArmed() }
        let refreshing = Task { await state.refreshAccountProfiles() }
        await relayWait.waitUntilReached()
        runtime.unlinkFromAnotherDevice(accountRef: desktopAccount().label)  // nothing observes the event
        relayWait.release()
        await refreshing.value

        #expect(state.activeAccountId == Self.backupSummary.label)
        #expect(state.chatsByAccount[desktopAccount().label]?.isEmpty ?? true)
    }

    /// A refresh still waiting on a relay doesn't hold up the next focus's check for a missed unlink.
    @Test func aMissedUnlinkIsLeftWhileAnEarlierRefreshWaitsOnARelay() async throws {
        let (runtime, state) = await twoProfiles()
        runtime.profileRefreshDelaysByAccountId[Self.backupSummary.accountIdHex] = 30_000_000_000
        let earlier = Task { await state.refreshAccountProfiles() }
        await Self.waitUntil { state.isRefreshingAccountProfiles }
        runtime.unlinkFromAnotherDevice(accountRef: desktopAccount().label)  // nothing observes the event

        await state.refreshAccountProfiles()

        #expect(state.activeAccountId == Self.backupSummary.label)
        earlier.cancel()
        await earlier.value
    }

    /// Once MDK has wiped the profile on screen, an account list that can't be read must not bring
    /// its session back: the app moves on as if the list had been read, and the delete went through,
    /// so there is no error to show.
    @Test func aWipeWhoseListCantBeReadStillLeavesTheProfile() async throws {
        let (runtime, state) = await twoProfiles()
        let desktop = try #require(state.activeAccount)
        runtime.onRemoveAccountMidFlight = { _ in runtime.listAccountsError = MarmotKitError.Runtime(details: "busy") }

        _ = await state.removeAccount(desktop)

        #expect(runtime.wipedAccountRefs == [desktop.accountRef])
        #expect(!state.accounts.contains { $0.id == desktop.id })
        #expect(state.activeAccountId == Self.backupSummary.label)
        #expect(state.lastError == nil)
    }

    /// A read after the wipe that still lists the profile (it lagged MDK) doesn't bring it back:
    /// MDK's wipe returned, so the profile is gone.
    @Test func aWipeWhoseListStillHasTheProfileStillLeavesIt() async throws {
        let (runtime, state) = await twoProfiles()
        let desktop = try #require(state.activeAccount)
        let listedBefore = try runtime.listAccounts()
        runtime.onRemoveAccountMidFlight = { _ in runtime.listedAccountsOverride = listedBefore }

        _ = await state.removeAccount(desktop)

        #expect(runtime.wipedAccountRefs == [desktop.accountRef])
        #expect(!state.accounts.contains { $0.id == desktop.id })
        #expect(state.activeAccountId == Self.backupSummary.label)
    }

    /// Two profiles unlinked at once: Delete Everything on the first brings the second's notice
    /// straight up. SwiftUI shows one alert at a time, so the first's wipe report waits for that
    /// notice to be answered instead of racing it.
    @Test func aWipeReportWaitsForTheNextUnlinkNotice() async throws {
        let (runtime, state) = await twoProfiles()
        var incomplete = runtime.wipeOutcome
        incomplete.localCleanup = LocalCleanupReportFfi(completed: false, reason: "locked")
        runtime.wipeOutcome = incomplete
        let session = SessionState()
        for summary in [desktopAccount(), Self.backupSummary] {
            let id = summary.accountIdHex.lowercased()
            runtime.unlinkFromAnotherDevice(accountRef: summary.label)
            session.deviceUnlinks.receive(DeviceUnlinkMonitor.Notice(accountIdHex: id, accountLabel: summary.label))
            await AccountExit.leaveSignedOutAccount(accountIdHex: id, in: state)
        }

        session.deviceUnlinks.dismiss()  // Delete Everything on the first
        let removal = await AccountExit.removeUnlinkedAccount(
            accountIdHex: desktopAccount().accountIdHex.lowercased(), in: state)
        session.reportWipe(removal.outcome)

        #expect(session.wipeReport != nil)
        #expect(session.deviceUnlinks.notice?.accountIdHex == Self.backupSummary.accountIdHex.lowercased())
        #expect(session.wipeReportToShow == nil)
        session.deviceUnlinks.dismiss()  // Later on the second
        #expect(session.wipeReportToShow == session.wipeReport)
    }

    /// Three profiles unlinked at once, the first two deleted in turn while the third's notice is
    /// up: both wipe reports are kept and shown one after the other once that notice is answered.
    @Test func wipeReportsQueueBehindAnUnlinkNotice() {
        let session = SessionState()
        for id in ["aa", "bb", "cc"] {
            session.deviceUnlinks.receive(DeviceUnlinkMonitor.Notice(accountIdHex: id, accountLabel: id))
        }
        let clean = WipeOutcomeFfi(
            groupsLeft: 0, groupLeaveFailures: [], keyPackagesDeleted: 0, keyPackageFailures: [],
            localCleanup: LocalCleanupReportFfi(completed: true, reason: nil), groupsLeftToSiblings: 0,
            siblingsNotReached: false)
        var first = clean
        first.siblingsNotReached = true
        var second = clean
        second.localCleanup = LocalCleanupReportFfi(completed: false, reason: "locked")

        session.deviceUnlinks.dismiss()  // Delete Everything on aa
        session.reportWipe(first)
        session.deviceUnlinks.dismiss()  // Delete Everything on bb
        session.reportWipe(second)

        #expect(session.wipeReportToShow == nil)  // cc's notice is up
        session.deviceUnlinks.dismiss()
        let shownFirst = session.wipeReportToShow
        session.dismissWipeReport()
        let shownSecond = session.wipeReportToShow
        session.dismissWipeReport()

        #expect(shownFirst?.lines == AccountWipeReport(outcome: first)?.lines)
        #expect(shownSecond?.lines == AccountWipeReport(outcome: second)?.lines)
        #expect(session.wipeReportToShow == nil)
    }

    /// The same for Sign Out: once MDK has signed the profile out, a failed read doesn't restore it.
    /// The sign-out went through, so there is no error to show.
    @Test func aSignOutWhoseListCantBeReadStillLeavesTheProfile() async throws {
        let (runtime, state) = await twoProfiles()
        let desktop = try #require(state.activeAccount)
        runtime.onSignOutAccountMidFlight = { _ in runtime.listAccountsError = MarmotKitError.Runtime(details: "busy") }

        await state.signOutAccount(desktop)

        #expect(state.accounts.first { $0.id == desktop.id }?.signedOut == true)
        #expect(state.activeAccountId == Self.backupSummary.label)
        #expect(state.lastError == nil)
    }

    /// An unlink whose event the app missed shows up at the next focus refresh as the profile on
    /// screen signed out, and the app leaves it then, before waiting on any relay.
    @Test func aFocusRefreshLeavesAnUnlinkTheEventMissed() async throws {
        let (runtime, state) = await twoProfiles()
        #expect(state.activeAccountId == desktopAccount().label)
        runtime.unlinkFromAnotherDevice(accountRef: desktopAccount().label)  // nothing observes the event
        runtime.profileRefreshDelaysByAccountId[desktopAccount().accountIdHex] = 30_000_000_000

        let refreshing = Task { await state.refreshAccountProfiles() }
        await Self.waitUntil(timeout: .seconds(5)) { state.activeAccountId == Self.backupSummary.label }
        #expect(state.activeAccountId == Self.backupSummary.label)  // while the relay read still waits
        refreshing.cancel()
        await refreshing.value

        #expect(state.activeAccountId == Self.backupSummary.label)
        #expect(state.accounts.first { $0.id == desktopAccount().label }?.signedOut == true)
        #expect(state.chatsByAccount[desktopAccount().label]?.isEmpty ?? true)
    }

    /// A profile left with Later stays here signed out, and signed-out profiles show nowhere else, so
    /// the notice comes back once a launch. Signing in to it raises it again even after Later.
    @Test func anUnlinkedProfileStillHereIsRaisedOnceALaunchAndOnSignIn() {
        let monitor = DeviceUnlinkMonitor()
        let unlinked = AccountItem(
            id: "jeff", accountRef: "jeff", displayName: "Jeff", accountIdHex: "AA", signedOut: true, unlinked: true)
        let signedOut = AccountItem(
            id: "lab", accountRef: "lab", displayName: "Lab", accountIdHex: "bb", signedOut: true)

        monitor.remind(about: [unlinked, signedOut])
        #expect(monitor.notice?.accountIdHex == "aa")
        monitor.dismiss()
        #expect(monitor.notice == nil)

        monitor.remind(about: [unlinked, signedOut])
        #expect(monitor.notice == nil)

        monitor.present(unlinked)
        #expect(monitor.notice?.accountIdHex == "aa")
    }

    /// The live event counts as this launch's notice, so the reminder doesn't repeat it.
    @Test func theLiveEventCountsAsThisLaunchsReminder() {
        let monitor = DeviceUnlinkMonitor()
        monitor.receive(.init(accountIdHex: "aa", accountLabel: "jeff"))
        monitor.dismiss()

        monitor.remind(about: [
            AccountItem(
                id: "jeff", accountRef: "jeff", displayName: "Jeff", accountIdHex: "aa", signedOut: true,
                unlinked: true)
        ])

        #expect(monitor.notice == nil)
    }

    /// Signing in with the key of a profile another device unlinked hands that profile back, so the
    /// sign-in pane can offer to delete it, rather than ending in an error with no way forward.
    @Test func signingInToAnUnlinkedProfileHandsItBack() async throws {
        var summary = desktopAccount()
        summary.signedOut = true
        summary.unlinked = true
        let runtime = FakeMarmotRuntime(accounts: [summary])
        runtime.beginOnboardingError = MarmotKitError.AccountUnlinked(accountRef: summary.label)
        let state = WorkspaceState(clientFactory: { runtime })

        await state.bootstrap()
        state.showLogin()
        state.loginIdentity = "nsec1desktop"
        let unlinked = await state.login()

        #expect(unlinked?.accountRef == summary.label)
        #expect(unlinked?.unlinked == true)
        #expect(
            state.lastError == UserFacingError.message(for: MarmotKitError.AccountUnlinked(accountRef: summary.label)))
    }

    @Test func withoutDeviceGroupsItDoesNotSubscribe() async {
        let runtime = FakeMarmotRuntime(accounts: [])
        let monitor = DeviceUnlinkMonitor()

        await monitor.observe(runtime)

        #expect(runtime.eventHub.subscriberCount == 0)
    }
}

struct DeviceUnlinkPresentationTests {
    @Test func theAlertNamesTheProfileWhenItHasOne() {
        #expect(DeviceUnlinkPresentation.message(accountName: "Jeff").contains("Jeff"))
        let unnamed = DeviceUnlinkPresentation.message(accountName: nil)
        #expect(DeviceUnlinkPresentation.message(accountName: "  ") == unnamed)
        #expect(!unnamed.contains("%@"))
    }
}

/// Chat history copied from another of the account's devices: where it ends in the transcript, what
/// the marker calls its source, and the "bringing earlier messages" progress.
@MainActor
struct ImportedHistoryTests {
    private static func item(_ id: String, _ source: MessageImportSource?) -> TimelineMessageDisplayItem {
        TimelineMessageDisplayItem(
            message: MessageItem(
                id: id, importSource: source, senderName: "Jeff", body: id, sentAt: Date(), isOutgoing: false),
            dayLabel: nil)
    }

    private static let context = TranscriptRowContext(
        canVoteInPolls: true, showsDebugMetadata: false, isSelectionMode: false, localeIdentifier: "en",
        referenceDay: 0)

    @Test func theBoundaryMarksTheFirstLiveRowAfterImportedOnes() {
        let phone = MessageImportSource.device(slotIdHex: "a", label: "iPhone")
        let rows = TranscriptRow.rows(
            displayItems: [
                Self.item("old-1", phone), Self.item("old-2", phone), Self.item("live", nil),
                Self.item("later", nil),
            ],
            paging: .empty,
            pendingOutgoingRows: [],
            unreadDividerMessageId: nil,
            context: Self.context
        )
        let marked = rows.compactMap { row -> (String, MessageImportSource?)? in
            guard case .message(let item, _, _, _, let importedAbove) = row else { return nil }
            return (item.message.id, importedAbove)
        }
        #expect(marked.map(\.0) == ["old-1", "old-2", "live", "later"])
        #expect(marked.map(\.1) == [nil, nil, phone, nil])
    }

    @Test func anImportedRowNamesItsSource() {
        #expect(
            MessageItem.importSource(
                provenance: .backup(
                    source: BackupHistorySourceFfi(
                        recoveryPublicKeyHex: "", backupIdHex: "", headSha256Hex: "", writtenAt: 0)), importedFrom: nil)
                == .backup)
        #expect(
            MessageItem.importSource(
                provenance: .device(deviceSlotIdHex: "s"),
                importedFrom: HistoryImportSourceFfi(deviceSlotIdHex: "s", deviceLabel: "iPhone"))
                == .device(slotIdHex: "s", label: "iPhone"))
        #expect(MessageItem.importSource(provenance: nil, importedFrom: nil) == nil)
    }

    /// The marker follows renames: the roster's current name wins over the one the rows carried.
    @Test func theDeviceNameFollowsTheRoster() async {
        let runtime = FakeMarmotRuntime(accounts: [])
        runtime.deviceGroupsEnabled = true
        let slot = String(repeating: "b", count: 64)
        var phone = DeviceLinkingTests.makeDevice("b")
        phone.label = "Jeff's iPhone"
        runtime.deviceLinking.devices = [phone]
        let model = DeviceLinkingViewModel(accountRef: "a", accountIdHex: "a", runtime: runtime)
        await model.refreshAll()

        #expect(model.deviceName(for: .device(slotIdHex: slot, label: "iPhone")) == "Jeff's iPhone")
        #expect(model.deviceName(for: .device(slotIdHex: "gone", label: "Old")) == "Old")
        #expect(model.deviceName(for: .device(slotIdHex: "gone", label: "")) == nil)
        #expect(model.deviceName(for: .backup) == nil)
        #expect(
            ImportedHistoryDivider.text(source: .backup, deviceName: nil)
                != ImportedHistoryDivider.text(
                    source: .device(slotIdHex: slot, label: ""), deviceName: nil))
    }

    @Test func historyImportsAreReadPerChatAndOnTheirEvent() async {
        let runtime = FakeMarmotRuntime(accounts: [])
        runtime.deviceGroupsEnabled = true
        let account = AccountItem.samples[0]
        let model = DeviceLinkingViewModel(
            accountRef: account.accountRef, accountIdHex: account.accountIdHex, runtime: runtime)
        model.start()
        defer { model.stop() }
        await DeviceLinkingTests.waitUntil { runtime.eventHub.subscriberCount == 1 }

        runtime.deviceLinking.historyImports = [
            ChatHistoryImportFfi(groupIdHex: "ABC", state: .receiving(retrying: true))
        ]
        runtime.eventHub.emit(.chatHistoryImportsChanged(accountIdHex: account.accountIdHex, accountLabel: "jeff"))
        await DeviceLinkingTests.waitUntil { model.historyImportState(groupIdHex: "abc") != nil }

        #expect(model.historyImportState(groupIdHex: "abc") == .receiving(retrying: true))
    }
}

/// A linking call's reply can be older than the snapshot an event read already showed.
@MainActor
struct DeviceLinkActionReplyTests {
    @Test func aLateReplyDoesNotPutBackAnOlderSnapshot() async {
        let runtime = FakeMarmotRuntime(accounts: [])
        runtime.deviceGroupsEnabled = true
        runtime.deviceLinking.snapshot.prompts = [
            DeviceLinkPromptFfi(promptId: "p1", slotIdHex: nil, requestedAt: 0, state: .comparing(code: []))
        ]
        let model = DeviceLinkingViewModel(accountRef: "a", accountIdHex: "a", runtime: runtime)
        await model.refreshAll()
        #expect(model.prompt(id: "p1") != nil)

        runtime.deviceLinking.linkReplyGate.isEnabled = true
        let linking = Task {
            await model.link(promptId: "p1", label: "Phone", addToAllChats: true, bringHistory: false)
        }
        await runtime.deviceLinking.linkReplyGate.waitUntilReached()
        // The link's event is read first and shows the prompt gone; the read after the reply fails.
        runtime.deviceLinking.snapshot.prompts = []
        await model.refreshAll()
        #expect(model.prompt(id: "p1") == nil)
        runtime.deviceLinking.error = MarmotKitError.Runtime(details: "relay unreachable")
        runtime.deviceLinking.linkReplyGate.release()
        await linking.value

        #expect(model.prompt(id: "p1") == nil)
    }
}

/// Naming this device, so no device is ever listed unnamed.
@MainActor
struct ThisDeviceNameTests {
    @Test func aNameGivenWhileUnnamedIsWrittenOnceTheRosterListsThisDevice() async {
        let runtime = FakeMarmotRuntime(accounts: [])
        runtime.deviceGroupsEnabled = true
        runtime.deviceLinking.devices = [DeviceLinkingTests.makeDevice("a", thisDevice: true)]
        let model = DeviceLinkingViewModel(accountRef: "a", accountIdHex: "a", runtime: runtime)
        #expect(model.thisDeviceNeedsName)

        model.nameThisDevice("  Studio Mac ")
        await DeviceLinkingTests.waitUntil { model.thisDevice?.label == "Studio Mac" }

        #expect(runtime.deviceLinking.renames.map(\.label) == ["Studio Mac"])
        #expect(!model.thisDeviceNeedsName)
    }

    /// iOS names a device it approves "New Device"; saving a name over it renames it outright.
    @Test func savingANameOverAnExistingOneRenamesIt() async {
        let runtime = FakeMarmotRuntime(accounts: [])
        runtime.deviceGroupsEnabled = true
        var me = DeviceLinkingTests.makeDevice("a", thisDevice: true)
        me.label = "New Device"
        runtime.deviceLinking.devices = [me]
        let model = DeviceLinkingViewModel(accountRef: "a", accountIdHex: "a", runtime: runtime)
        await model.refreshAll()

        model.saveThisDeviceName(" Studio Mac ")
        await DeviceLinkingTests.waitUntil { model.thisDevice?.label == "Studio Mac" }

        #expect(runtime.deviceLinking.renames.map(\.label) == ["Studio Mac"])
    }

    /// Saved before the roster is read, the typed name still replaces "New Device" once it arrives.
    @Test func aNameSavedBeforeTheRosterArrivesStillReplacesNewDevice() async {
        let runtime = FakeMarmotRuntime(accounts: [])
        runtime.deviceGroupsEnabled = true
        var me = DeviceLinkingTests.makeDevice("a", thisDevice: true)
        me.label = "New Device"
        runtime.deviceLinking.devices = [me]
        let model = DeviceLinkingViewModel(accountRef: "a", accountIdHex: "a", runtime: runtime)
        #expect(model.thisDevice == nil)

        model.saveThisDeviceName("Studio Mac")
        await DeviceLinkingTests.waitUntil { model.thisDevice?.label == "Studio Mac" }

        #expect(runtime.deviceLinking.renames.map(\.label) == ["Studio Mac"])
    }

    /// Two saves while the roster loads: the second name is the one written.
    @Test func aSecondSaveWhileTheRosterLoadsWins() async {
        let runtime = FakeMarmotRuntime(accounts: [])
        runtime.deviceGroupsEnabled = true
        var me = DeviceLinkingTests.makeDevice("a", thisDevice: true)
        me.label = "New Device"
        runtime.deviceLinking.devices = [me]
        let model = DeviceLinkingViewModel(accountRef: "a", accountIdHex: "a", runtime: runtime)
        runtime.deviceLinking.devicesReadGate.isEnabled = true

        model.saveThisDeviceName("Mac")
        await runtime.deviceLinking.devicesReadGate.waitUntilReached()
        model.saveThisDeviceName("Studio Mac")
        runtime.deviceLinking.devicesReadGate.release()
        await DeviceLinkingTests.waitUntil { model.thisDevice?.label == "Studio Mac" }

        #expect(runtime.deviceLinking.renames.map(\.label) == ["Studio Mac"])
    }

    /// A typed name that fails says so, and the next one that saves clears it.
    @Test func aSavedNameClearsTheErrorAnEarlierOneLeft() async {
        let runtime = FakeMarmotRuntime(accounts: [])
        runtime.deviceGroupsEnabled = true
        runtime.deviceLinking.devices = [DeviceLinkingTests.makeDevice("a", thisDevice: true)]
        let model = DeviceLinkingViewModel(accountRef: "a", accountIdHex: "a", runtime: runtime)
        await model.refreshAll()

        runtime.deviceLinking.nextActionError = MarmotKitError.Runtime(details: "storage closed")
        model.saveThisDeviceName("Mac")
        await DeviceLinkingTests.waitUntil { model.actionError != nil }
        model.saveThisDeviceName("Studio Mac")
        await DeviceLinkingTests.waitUntil { model.thisDevice?.label == "Studio Mac" }

        #expect(model.actionError == nil)
    }

    /// A rename of this Mac from Settings joins the same writer, so a name still being written from
    /// Name This Mac can't land after it. Meanwhile this Mac's other settings stay disabled.
    @Test func aSettingsRenameReplacesAWaitingName() async {
        let runtime = FakeMarmotRuntime(accounts: [])
        runtime.deviceGroupsEnabled = true
        var me = DeviceLinkingTests.makeDevice("a", thisDevice: true)
        me.label = "New Device"
        runtime.deviceLinking.devices = [me]
        let model = DeviceLinkingViewModel(accountRef: "a", accountIdHex: "a", runtime: runtime)
        await model.refreshAll()

        runtime.deviceLinking.renameGate.isEnabled = true
        model.saveThisDeviceName("Studio Mac")
        await runtime.deviceLinking.renameGate.waitUntilReached()
        #expect(model.isBusy(.device(slotIdHex: me.slotIdHex)))
        #expect(await model.rename(slotIdHex: me.slotIdHex, label: "Office Mac"))
        runtime.deviceLinking.renameGate.release()
        await DeviceLinkingTests.waitUntil { runtime.deviceLinking.renames.count == 2 }
        await DeviceLinkingTests.waitUntil { !model.isBusy(.device(slotIdHex: me.slotIdHex)) }

        #expect(runtime.deviceLinking.renames.map(\.label) == ["Studio Mac", "Office Mac"])
        #expect(model.thisDevice?.label == "Office Mac")
        #expect(model.actionError == nil)
    }

    /// A group that stays busy past the retries lets the name go and says so, so Save and this
    /// Mac's settings come back.
    @Test func aNameStillBusyAfterTheRetriesIsDroppedWithAnError() async {
        let runtime = FakeMarmotRuntime(accounts: [])
        runtime.deviceGroupsEnabled = true
        var me = DeviceLinkingTests.makeDevice("a", thisDevice: true)
        me.label = "New Device"
        runtime.deviceLinking.devices = [me]
        let model = DeviceLinkingViewModel(
            accountRef: "a", accountIdHex: "a", runtime: runtime, nameRetries: 3, nameRetryDelay: .milliseconds(10))
        await model.refreshAll()
        runtime.deviceLinking.renameError = MarmotKitError.Runtime(
            details: DeviceLinkPresentation.refusalPrefix + "device_group_busy")

        model.saveThisDeviceName("Studio Mac")
        await DeviceLinkingTests.waitUntil { model.actionError != nil }

        #expect(!model.isBusy(.device(slotIdHex: me.slotIdHex)))
        #expect(model.thisDevice?.label == "New Device")
    }

    /// Settings can clear this Mac's name, as MDK allows, through the same writer.
    @Test func settingsCanClearThisMacsName() async {
        let runtime = FakeMarmotRuntime(accounts: [])
        runtime.deviceGroupsEnabled = true
        var me = DeviceLinkingTests.makeDevice("a", thisDevice: true)
        me.label = "Mac"
        runtime.deviceLinking.devices = [me]
        let model = DeviceLinkingViewModel(accountRef: "a", accountIdHex: "a", runtime: runtime)
        await model.refreshAll()

        #expect(await model.rename(slotIdHex: me.slotIdHex, label: "  "))
        await DeviceLinkingTests.waitUntil { model.thisDevice?.label == "" }

        #expect(runtime.deviceLinking.renames.map(\.label) == [""])
    }

    @Test func aNameSomeoneElseGaveFirstStands() async {
        let runtime = FakeMarmotRuntime(accounts: [])
        runtime.deviceGroupsEnabled = true
        var me = DeviceLinkingTests.makeDevice("a", thisDevice: true)
        me.label = "Named Elsewhere"
        runtime.deviceLinking.devices = [me]
        let model = DeviceLinkingViewModel(accountRef: "a", accountIdHex: "a", runtime: runtime)

        model.nameThisDevice("Mac")
        await DeviceLinkingTests.waitUntil { model.thisDevice != nil }
        await DeviceLinkingTests.waitUntil(timeout: .milliseconds(200)) { false }

        #expect(runtime.deviceLinking.renames.isEmpty)
    }
}

/// A link request for a profile that isn't active is raised from the shell, never left invisible
/// until the user happens to switch to that profile.
@MainActor
struct ProfileLinkRequestsMonitorTests: WorkspaceTestSupport {
    private static let active = AccountItem.samples[0]
    private static let other = AccountItem.samples[1]

    private func makeRuntime() -> FakeMarmotRuntime {
        let runtime = FakeMarmotRuntime(accounts: [])
        runtime.deviceGroupsEnabled = true
        runtime.deviceLinking.snapshot = DeviceLinkSnapshotFfi(
            newDevice: nil,
            prompts: [DeviceLinkPromptFfi(promptId: "p1", slotIdHex: nil, requestedAt: 0, state: .preparing)],
            moves: [], deviceGroupStalled: false)
        return runtime
    }

    @Test func anotherProfilesRequestRaisesTheAlertButTheActiveOnesDoesNot() async {
        let runtime = makeRuntime()
        let monitor = ProfileLinkRequestsMonitor()
        let accounts = [Self.active, Self.other]
        let observing = Task { await monitor.observe(runtime, accounts: { accounts }) }
        defer { observing.cancel() }
        await Self.waitUntil { monitor.pending.count == 2 }

        monitor.presentIfNeeded(activeAccountIdHex: Self.active.accountIdHex, accounts: accounts)

        #expect(monitor.alert?.accountIdHex == Self.other.accountIdHex.lowercased())
        #expect(
            monitor.requests(excluding: Self.active.accountIdHex, accounts: accounts).map(\.accountIdHex)
                == [Self.other.accountIdHex.lowercased()])
        #expect(monitor.takeAlert()?.profileName == Self.other.displayName)
    }

    @Test func notNowIsNotRaisedAgainButStaysListed() async {
        let runtime = makeRuntime()
        let monitor = ProfileLinkRequestsMonitor()
        let accounts = [Self.active, Self.other]
        let observing = Task { await monitor.observe(runtime, accounts: { accounts }) }
        defer { observing.cancel() }
        await Self.waitUntil { monitor.pending.count == 2 }
        monitor.presentIfNeeded(activeAccountIdHex: Self.active.accountIdHex, accounts: accounts)

        monitor.putOffAlert()
        monitor.presentIfNeeded(activeAccountIdHex: Self.active.accountIdHex, accounts: accounts)

        #expect(monitor.alert == nil)
        #expect(monitor.requests(excluding: Self.active.accountIdHex, accounts: accounts).count == 1)
    }

    @Test func anAnsweredRequestLeavesOnItsProfilesEvent() async {
        let runtime = makeRuntime()
        let monitor = ProfileLinkRequestsMonitor()
        let accounts = [Self.other]
        let observing = Task { await monitor.observe(runtime, accounts: { accounts }) }
        defer { observing.cancel() }
        await Self.waitUntil { !monitor.pending.isEmpty }

        runtime.deviceLinking.snapshot.prompts = []
        runtime.eventHub.emit(.deviceLinkChanged(accountIdHex: Self.other.accountIdHex.uppercased(), accountLabel: "x"))
        await Self.waitUntil { monitor.pending.isEmpty }

        #expect(monitor.pending.isEmpty)
    }

    /// A profile signed in while the app runs may have had its only `DeviceLinkChanged` before it
    /// was listed; the shell restarts the monitor when the signed-in set changes, which reads it.
    /// A profile signed out meanwhile loses its request and its alert.
    @Test func eachStartReadsEveryProfileAndDropsSignedOutOnes() async {
        let runtime = makeRuntime()
        let monitor = ProfileLinkRequestsMonitor()
        var accounts = [Self.other]
        var observing = Task { await monitor.observe(runtime, accounts: { accounts }) }
        await Self.waitUntil { !monitor.pending.isEmpty }
        monitor.presentIfNeeded(activeAccountIdHex: Self.active.accountIdHex, accounts: accounts)
        #expect(monitor.alert != nil)
        observing.cancel()

        let third = AccountItem.samples[2]
        accounts = [third]
        observing = Task { await monitor.observe(runtime, accounts: { accounts }) }
        defer { observing.cancel() }
        await Self.waitUntil { monitor.pending[third.accountIdHex.lowercased()] != nil }

        #expect(Array(monitor.pending.keys) == [third.accountIdHex.lowercased()])
        #expect(monitor.alert == nil)
    }

    /// A replaced observer's read that finishes late writes nothing over its successor's.
    @Test func aReplacedObserversLateReadIsDropped() async {
        let runtime = makeRuntime()
        let monitor = ProfileLinkRequestsMonitor()
        var accounts = [Self.other]
        runtime.deviceLinking.snapshotReadGate.isEnabled = true
        let old = Task { await monitor.observe(runtime, accounts: { accounts }) }
        await runtime.deviceLinking.snapshotReadGate.waitUntilReached()
        old.cancel()

        runtime.deviceLinking.snapshot.prompts = []
        accounts = [AccountItem.samples[2]]
        let reads = runtime.deviceLinking.snapshotReadCount
        let observing = Task { await monitor.observe(runtime, accounts: { accounts }) }
        defer { observing.cancel() }
        await Self.waitUntil { runtime.deviceLinking.snapshotReadCount > reads }
        runtime.deviceLinking.snapshotReadGate.release()
        await old.value

        #expect(monitor.pending.isEmpty)
    }

    /// Not Now on one profile's alert leaves the next profile's request to be raised.
    @Test func afterNotNowTheNextProfilesRequestIsRaised() async {
        let runtime = makeRuntime()
        let monitor = ProfileLinkRequestsMonitor()
        let third = AccountItem.samples[2]
        let accounts = [Self.active, Self.other, third]
        let observing = Task { await monitor.observe(runtime, accounts: { accounts }) }
        defer { observing.cancel() }
        await Self.waitUntil { monitor.pending.count == 3 }
        monitor.presentIfNeeded(activeAccountIdHex: Self.active.accountIdHex, accounts: accounts)
        let first = monitor.alert?.accountIdHex

        runtime.deviceLinking.snapshot.prompts = [
            DeviceLinkPromptFfi(promptId: "p2", slotIdHex: nil, requestedAt: 0, state: .preparing)
        ]
        runtime.eventHub.emit(.deviceLinkChanged(accountIdHex: third.accountIdHex, accountLabel: "x"))
        await Self.waitUntil { monitor.pending[third.accountIdHex.lowercased()] == ["p2"] }
        monitor.putOffAlert()
        monitor.presentIfNeeded(activeAccountIdHex: Self.active.accountIdHex, accounts: accounts)

        #expect(first == Self.other.accountIdHex.lowercased())
        #expect(monitor.alert?.accountIdHex == third.accountIdHex.lowercased())
    }

    @Test func withoutDeviceGroupsItReadsNothing() async {
        let runtime = FakeMarmotRuntime(accounts: [])
        let monitor = ProfileLinkRequestsMonitor()

        await monitor.observe(runtime, accounts: { [Self.other] })

        #expect(runtime.deviceLinking.snapshotReadCount == 0)
    }
}
