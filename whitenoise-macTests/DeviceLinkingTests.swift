import Foundation
import MarmotKit
import Testing

@testable import whitenoise_mac

/// Device linking over MDK's experimental device groups: the account's model mirrors MDK's reads,
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
        #expect(runtime.eventHub.subscriberCount == 0)
        #expect(runtime.deviceLinking.snapshot.newDevice == nil)
    }

    @Test func productionNeverOpensWithExperimentalDeviceGroups() {
        #expect(!DeviceGroupsMode.shouldTryExperimental(flavor: .production))
        #expect(DeviceGroupsMode.shouldTryExperimental(flavor: .development))
        #expect(DeviceGroupsMode.shouldTryExperimental(flavor: .staging))
    }

    /// Only the capability refusal falls back to the ordinary constructor; any other failure of the
    /// experimental open is the open failing, and retrying it ordinarily would hide that.
    @Test func onlyTheCapabilityRefusalFallsBack() {
        #expect(
            DeviceGroupsMode.isCapabilityMissing(MarmotKitError.Runtime(details: DeviceGroupsMode.unavailableDetails)))
        #expect(
            !DeviceGroupsMode.isCapabilityMissing(
                MarmotKitError.Runtime(details: "experimental_device_groups_required")))
        #expect(!DeviceGroupsMode.isCapabilityMissing(FakeMarmotRuntimeError.unused))
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
