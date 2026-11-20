import Foundation
import MarmotKit
import Observation

/// Which device-linking sheet is up. The new device's own link has no id: there is at most one.
enum DeviceLinkSheet: Hashable, Identifiable {
    /// This device asked to be linked and is comparing the code.
    case newDevice
    /// This profile is signed in on a device from before this one: offer to link to it.
    case linkSuggestion
    /// This device is the one already set up: how to start a link from the new one, waiting for its
    /// request. The request's own sheet replaces it when it arrives.
    case addNewDevice
    /// Another device asked this one to link it.
    case prompt(id: String)

    var id: Self { self }
}

/// Device linking for the signed-in account: this device's own link, the prompts for sign-ins it
/// can link, the account's devices, unrecognized sign-ins and the compromise warning.
///
/// MDK owns every piece of it. This mirrors each read, re-reads it on the event MDK names for it
/// (none of which carries ids, so each is a whole re-read), and installs the snapshot each linking
/// call returns. The device group's own events never reach the host.
///
/// Linking works only when the runtime reports `deviceGroupsEnabled` (every MarmotKit open since
/// 0.18.0); `isAvailable` is false otherwise and the model reads nothing. Owned by `AccountScope`, so it
/// lives exactly as long as the account and an account switch discards it.
@MainActor
@Observable
final class DeviceLinkingViewModel {
    enum Action: Hashable {
        case startLink, confirmMatch, cancelLink, reset, checkSignIns, startFresh, dismissCompromise
        case link(promptId: String)
        case decline(promptId: String)
        case device(slotIdHex: String)
        case signIn(slotIdHex: String)
        case moveSibling(slotIdHex: String)
    }

    let isAvailable: Bool
    private(set) var snapshot = DeviceLinkSnapshotFfi(newDevice: nil, prompts: [], moves: [], deviceGroupStalled: false)
    private(set) var devices: [LinkedDeviceFfi] = []
    private(set) var signIns: [UnrecognizedSignInFfi] = []
    private(set) var compromiseItems: [CompromiseWarningItemFfi] = []
    private(set) var keyPackageRefreshOverdue = false
    private(set) var chatsClosedToLinkedDevices: UInt32 = 0
    private(set) var removedDeviceLeftoverChats: UInt32 = 0
    private(set) var startedFresh = false
    /// Each held chat's history from another of the account's devices, by group id.
    private(set) var historyImports: [String: ChatHistoryImportStateFfi] = [:]
    private(set) var inFlight: Set<Action> = []
    /// The last failed action's message, shown by the surface that made it. Cleared by the next action.
    private(set) var actionError: String?
    /// Which sheet the shell presents. Set by the user's actions and by a prompt that needs them.
    var presentedSheet: DeviceLinkSheet?

    @ObservationIgnored private let accountRef: String
    @ObservationIgnored private let accountIdHex: String
    @ObservationIgnored private let runtime: (any MarmotRuntime)?
    @ObservationIgnored private var eventsTask: Task<Void, Never>?
    @ObservationIgnored private var refreshers: [Part: CoalescingRead] = [:]
    /// Prompts the user closed or finished with. A prompt id is local to this runtime and MDK keeps
    /// a finished prompt listed, so this keeps one from opening its sheet again; it is never
    /// persisted, and a new request is a new prompt id.
    @ObservationIgnored private var settledPromptIds: Set<String> = []
    @ObservationIgnored private var linkSuggestionShown = false
    /// A name for this device the user gave while it had none, to write once the roster lists it:
    /// after the first link this device founds the device group, and only then has a slot to rename.
    @ObservationIgnored private var pendingThisDeviceLabel: String?
    /// The held name was typed by the user, so it replaces whatever name the roster entry arrives
    /// with. The name picked during linking yields to one given first.
    @ObservationIgnored private var pendingThisDeviceLabelReplaces = false
    @ObservationIgnored private var thisDeviceLabelTask: Task<Void, Never>?

    private enum Part: CaseIterable {
        case link, devices, signIns, compromise, keyPackage, historyImports
    }

    /// `isAvailable` overrides the runtime's answer, for previews only.
    init(accountRef: String, accountIdHex: String, runtime: (any MarmotRuntime)?, isAvailable: Bool? = nil) {
        self.accountRef = accountRef
        self.accountIdHex = accountIdHex.lowercased()
        self.runtime = runtime
        self.isAvailable = isAvailable ?? (runtime?.deviceGroupsEnabled == true)
    }

    // MARK: Derived

    /// The account's devices other than this one.
    var otherDevices: [LinkedDeviceFfi] { devices.filter { !$0.isThisDevice } }

    /// Prompts still worth listing: everything MDK lists that the user has not closed.
    var openPrompts: [DeviceLinkPromptFfi] {
        snapshot.prompts.filter { !settledPromptIds.contains($0.promptId) }
    }

    func prompt(id: String) -> DeviceLinkPromptFfi? {
        snapshot.prompts.first { $0.promptId == id }
    }

    var thisDevice: LinkedDeviceFfi? { devices.first(where: \.isThisDevice) }

    /// A device this one approved hasn't joined yet (`Linking`) while this device is in a device list.
    /// MDK warns that moving this device now can fail that link and skip its chat additions. Every
    /// prompt counts, closed ones included: closing the sheet doesn't finish the link.
    var approvedLinkStillJoining: Bool {
        thisDevice != nil
            && snapshot.prompts.contains { prompt in
                if case .linking = prompt.state { return true }
                return false
            }
    }

    /// This device has no name in the roster yet, or no roster at all (it has never been linked):
    /// the moment to ask for one, so the account's other devices never list it as unnamed.
    var thisDeviceNeedsName: Bool {
        isAvailable && (thisDevice?.label.isEmpty ?? true)
    }

    /// The name to show for imported history's source: the roster's current name for its slot,
    /// then the name MDK reported with the rows. Nil for a backup or a device with no name; the
    /// caller says "another device".
    func deviceName(for source: MessageImportSource) -> String? {
        guard case .device(let slotIdHex, let label) = source else { return nil }
        if let listed = device(slotIdHex: slotIdHex), !listed.label.isEmpty { return listed.label }
        return label.isEmpty ? nil : label
    }

    func historyImportState(groupIdHex: String) -> ChatHistoryImportStateFfi? {
        historyImports[groupIdHex.lowercased()]
    }

    func device(slotIdHex: String?) -> LinkedDeviceFfi? {
        guard let slotIdHex else { return nil }
        return devices.first { $0.slotIdHex == slotIdHex }
    }

    func isBusy(_ action: Action) -> Bool { inFlight.contains(action) }

    // MARK: Lifetime

    /// Subscribes before the first reads, so a change between the two still arrives.
    func start() {
        guard isAvailable, eventsTask == nil, let runtime else { return }
        let subscription = runtime.subscribeEvents()
        eventsTask = Task { [weak self] in
            await self?.refreshAll()
            await self?.observe(subscription, runtime: runtime)
        }
    }

    func stop() {
        eventsTask?.cancel()
        eventsTask = nil
        thisDeviceLabelTask?.cancel()
        thisDeviceLabelTask = nil
        for refresher in refreshers.values { refresher.cancel() }
        refreshers.removeAll()
        presentedSheet = nil
    }

    func refreshAll() async {
        await withTaskGroup(of: Void.self) { group in
            for part in Part.allCases {
                group.addTask { await self.refresh(part) }
            }
        }
    }

    // MARK: This device asks to be linked

    func startLink() async {
        guard isAvailable else { return }
        actionError = nil
        presentedSheet = .newDevice
        await perform(.startLink) { runtime, accountRef in
            do {
                return try await runtime.startDeviceLink(accountRef: accountRef)
            } catch MarmotKitError.Runtime(let details)
                where details == DeviceLinkPresentation.refusalPrefix + "key_package_not_published"
            {
                // The request names a published KeyPackage this device has not joined a group by:
                // publish one and ask again, rather than sending the user to Developer mode.
                _ = try await runtime.rotateKeyPackage(accountRef: accountRef)
                return try await runtime.startDeviceLink(accountRef: accountRef)
            }
        }
    }

    func confirmMatch() async {
        await perform(.confirmMatch) { runtime, accountRef in
            try await runtime.confirmDeviceLinkMatch(accountRef: accountRef)
        }
    }

    /// Cancel, and "They don't match": MDK leaves a mismatch for the user to report by cancelling.
    func cancelLink() async {
        await perform(.cancelLink) { runtime, accountRef in
            try await runtime.cancelDeviceLink(accountRef: accountRef)
        }
    }

    /// Only a new device can start a link, so the device already set up explains how and waits.
    func showAddNewDevice() {
        guard isAvailable else { return }
        presentedSheet = .addNewDevice
    }

    func showNewDeviceLink() {
        guard snapshot.newDevice != nil else { return }
        presentedSheet = .newDevice
    }

    // MARK: Another device asks this one

    /// `thisDeviceLabel` names this device too, when it had no name: written once the link has
    /// made this device's roster entry (see `nameThisDevice`).
    func link(
        promptId: String, label: String, addToAllChats: Bool, bringHistory: Bool, thisDeviceLabel: String? = nil
    ) async {
        let label = label.trimmingCharacters(in: .whitespacesAndNewlines)
        let linked = await perform(.link(promptId: promptId)) { runtime, accountRef in
            try await runtime.linkDevice(
                accountRef: accountRef, promptId: promptId, label: label, addToAllChats: addToAllChats,
                bringHistory: bringHistory)
        }
        if linked, let thisDeviceLabel, DeviceLinkPresentation.isValidLabel(thisDeviceLabel) {
            nameThisDevice(thisDeviceLabel)
        }
    }

    /// Names this device in the roster. It may have no entry yet (the link that founds the device
    /// group is still settling) or the group may be busy with an earlier change, so the name is
    /// held and written once the roster lists this device, retrying `device_group_busy` a while.
    /// A name someone else gives this device first stands.
    func nameThisDevice(_ label: String) {
        nameThisDevice(label, replacingName: false)
    }

    /// Name This Mac's Save: renames this device's roster entry, or holds the name until the roster
    /// lists this device and then writes it over whatever name the entry has (iOS's "New Device").
    func saveThisDeviceName(_ label: String) async {
        if let me = thisDevice {
            await rename(slotIdHex: me.slotIdHex, label: label)
        } else {
            nameThisDevice(label, replacingName: true)
        }
    }

    private func nameThisDevice(_ label: String, replacingName: Bool) {
        let label = label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isAvailable, DeviceLinkPresentation.isValidLabel(label) else { return }
        pendingThisDeviceLabel = label
        pendingThisDeviceLabelReplaces = replacingName
        writePendingThisDeviceLabel()
    }

    private func writePendingThisDeviceLabel() {
        guard thisDeviceLabelTask == nil, pendingThisDeviceLabel != nil, let runtime else { return }
        thisDeviceLabelTask = Task { [weak self] in
            for attempt in 0..<20 {
                guard let self, !Task.isCancelled, let label = self.pendingThisDeviceLabel else { break }
                if attempt > 0 { try? await Task.sleep(for: .seconds(3)) }
                await self.refresh(.devices)
                guard let me = self.thisDevice else { continue }
                // Named meanwhile, here or on another device: that name stands, unless the user
                // typed this one.
                guard me.label.isEmpty || me.label == label || self.pendingThisDeviceLabelReplaces else {
                    self.pendingThisDeviceLabel = nil
                    break
                }
                if me.label == label {
                    self.pendingThisDeviceLabel = nil
                    break
                }
                do {
                    try await runtime.renameLinkedDevice(
                        accountRef: self.accountRef, slotIdHex: me.slotIdHex, label: label)
                    self.pendingThisDeviceLabel = nil
                    await self.refresh(.devices)
                    break
                } catch MarmotKitError.Runtime(let details)
                    where details == DeviceLinkPresentation.refusalPrefix + "device_group_busy"
                {
                    continue
                } catch {
                    break
                }
            }
            self?.thisDeviceLabelTask = nil
        }
    }

    func decline(promptId: String) async {
        let declined = await perform(.decline(promptId: promptId)) { runtime, accountRef in
            try await runtime.declineDeviceLink(accountRef: accountRef, promptId: promptId)
        }
        if declined { closePrompt(promptId) }
    }

    func showPrompt(_ promptId: String) {
        presentedSheet = .prompt(id: promptId)
    }

    /// Closes a prompt's sheet without answering it. A prompt still linking carries on; one the user
    /// closes is not opened again on its own.
    func closePrompt(_ promptId: String) {
        settledPromptIds.insert(promptId)
        if presentedSheet == .prompt(id: promptId) { presentedSheet = nil }
        presentNextPromptIfNeeded()
    }

    func closeSheet() {
        switch presentedSheet {
        case .prompt(let id): closePrompt(id)
        case .newDevice, .linkSuggestion, .addNewDevice, nil: presentedSheet = nil
        }
    }

    // MARK: Suggesting a link after sign-in

    /// Sign-ins of this profile from before this device that the user has not answered yet.
    var earlierSignIns: [UnrecognizedSignInFfi] {
        signIns.filter { $0.beforeThisDevice && $0.state == .prompt }
    }

    /// The profile is already signed in elsewhere and this device is in no device list yet, the way
    /// a freshly signed-in device is. Like Signal or Element after a new login, offer to link.
    var suggestsLinking: Bool {
        isAvailable && otherDevices.isEmpty && !startedFresh && snapshot.newDevice == nil
            && !earlierSignIns.isEmpty
    }

    /// Opens the suggestion once per signed-in session, and only when nothing else is on screen. The
    /// shell calls this once setup has finished: before that this device has no published KeyPackage
    /// for a link request to name.
    func presentLinkSuggestionIfNeeded() {
        guard !linkSuggestionShown, presentedSheet == nil, suggestsLinking else { return }
        linkSuggestionShown = true
        presentedSheet = .linkSuggestion
    }

    // MARK: Devices

    @discardableResult
    func rename(slotIdHex: String, label: String) async -> Bool {
        let label = label.trimmingCharacters(in: .whitespacesAndNewlines)
        return await performDevice(slotIdHex) { runtime, accountRef in
            try await runtime.renameLinkedDevice(accountRef: accountRef, slotIdHex: slotIdHex, label: label)
        }
    }

    func update(
        slotIdHex: String, addToAllChats: Bool? = nil, bringHistory: Bool? = nil, keepWhileInactive: Bool? = nil
    ) async {
        await performDevice(slotIdHex) { runtime, accountRef in
            try await runtime.updateLinkedDeviceSettings(
                accountRef: accountRef, slotIdHex: slotIdHex, addToAllChats: addToAllChats,
                bringHistory: bringHistory, keepWhileInactive: keepWhileInactive)
        }
    }

    @discardableResult
    func remove(slotIdHex: String) async -> Bool {
        await performDevice(slotIdHex) { runtime, accountRef in
            try await runtime.removeLinkedDevice(accountRef: accountRef, slotIdHex: slotIdHex)
        }
    }

    /// Discards this device's stalled copy of the device group and publishes a fresh KeyPackage, the
    /// two steps MDK requires before a fresh link. The link itself is the user's next step.
    func resetForRepair() async {
        await perform(.reset) { runtime, accountRef in
            let snapshot = try await runtime.resetDeviceGroupForRepair(accountRef: accountRef)
            _ = try await runtime.rotateKeyPackage(accountRef: accountRef)
            return snapshot
        }
        // The reset may have gone through even if the KeyPackage didn't: read what it left.
        await refresh(.link)
        await refresh(.devices)
    }

    func dismissMoveSibling(moveId: String, slotIdHex: String) async {
        await perform(.moveSibling(slotIdHex: slotIdHex)) { runtime, accountRef in
            try await runtime.dismissDeviceGroupMoveSibling(
                accountRef: accountRef, moveId: moveId, slotIdHex: slotIdHex)
        }
    }

    // MARK: Sign-ins and the compromise warning

    func answer(slotIdHex: String, response: SignInResponseFfi) async {
        await run(.signIn(slotIdHex: slotIdHex)) { runtime, accountRef in
            try await runtime.answerSignIn(accountRef: accountRef, slotIdHex: slotIdHex, response: response)
        }
        await refresh(.signIns)
    }

    func checkSignIns() async {
        if let next = await run(
            .checkSignIns,
            { runtime, accountRef in
                try await runtime.checkSignIns(accountRef: accountRef)
            })
        {
            signIns = next
        }
    }

    func startFresh() async {
        await run(.startFresh) { runtime, accountRef in
            try await runtime.startFresh(accountRef: accountRef)
        }
        await refresh(.signIns)
        await refresh(.devices)
    }

    func dismissCompromiseWarning() async {
        await run(.dismissCompromise) { runtime, accountRef in
            try await runtime.dismissCompromiseWarning(accountRef: accountRef)
        }
        await refresh(.compromise)
    }

    // MARK: Plumbing

    /// Runs a linking call that answers with a snapshot and installs it. True when it succeeded.
    @discardableResult
    private func perform(
        _ action: Action,
        _ body: @MainActor (any MarmotRuntime, String) async throws -> DeviceLinkSnapshotFfi
    ) async -> Bool {
        guard let next = await run(action, body) else { return false }
        install(next)
        // The call's own `DeviceLinkChanged` can be read before this reply lands, and the reply may
        // be older than that read. Reading again after it leaves the newest snapshot showing.
        await refresh(.link)
        return true
    }

    @discardableResult
    private func performDevice(
        _ slotIdHex: String,
        _ body: @MainActor (any MarmotRuntime, String) async throws -> Void
    ) async -> Bool {
        let succeeded = await run(.device(slotIdHex: slotIdHex), body) != nil
        // The roster change lands through the device group; `LinkedDevicesChanged` follows, but a
        // re-read now shows `removal_pending` and the new label without waiting for it.
        await refresh(.devices)
        return succeeded
    }

    /// Runs one user action, at most one of each kind at a time. Nil when it did not succeed; its
    /// failure is `actionError`.
    @discardableResult
    private func run<Value>(
        _ action: Action,
        _ body: @MainActor (any MarmotRuntime, String) async throws -> Value
    ) async -> Value? {
        guard isAvailable, let runtime, !inFlight.contains(action) else { return nil }
        inFlight.insert(action)
        actionError = nil
        defer { inFlight.remove(action) }
        do {
            return try await body(runtime, accountRef)
        } catch is CancellationError {
            return nil
        } catch {
            actionError = DeviceLinkPresentation.errorMessage(for: error)
            return nil
        }
    }

    private func install(_ next: DeviceLinkSnapshotFfi) {
        snapshot = next
        if case .prompt(let id) = presentedSheet, prompt(id: id) == nil {
            presentedSheet = nil
        }
        presentNextPromptIfNeeded()
    }

    /// Opens the first prompt that needs the user, unless a sheet is already up. Like a
    /// verification request on Signal or Element: the answer is wanted now, wherever the user is.
    private func presentNextPromptIfNeeded() {
        // A request arriving while this device waits for one, or while it asks which device is new,
        // answers that question: it replaces those sheets.
        switch presentedSheet {
        case nil, .addNewDevice, .linkSuggestion: break
        case .newDevice, .prompt: return
        }
        if let next = snapshot.prompts.first(where: {
            !settledPromptIds.contains($0.promptId) && DeviceLinkPresentation.needsAttention($0.state)
        }) {
            presentedSheet = .prompt(id: next.promptId)
        }
    }

    private func refresh(_ part: Part) async {
        guard isAvailable else { return }
        let refresher: CoalescingRead
        if let existing = refreshers[part] {
            refresher = existing
        } else {
            refresher = CoalescingRead { [weak self] in await self?.readOnce(part) }
            refreshers[part] = refresher
        }
        await refresher.run()
    }

    private func readOnce(_ part: Part) async {
        guard let runtime else { return }
        do {
            switch part {
            case .link:
                let next = try await runtime.deviceLinkSnapshot(accountRef: accountRef)
                try Task.checkCancellation()
                install(next)
            case .devices:
                let next = try await runtime.linkedDevices(accountRef: accountRef)
                // Not evented: MDK asks hosts to read these when showing the device list.
                let closed = try await runtime.chatsClosedToLinkedDevices(accountRef: accountRef)
                let leftover = try await runtime.removedDeviceLeftoverChats(accountRef: accountRef)
                let fresh = try await runtime.startedFresh(accountRef: accountRef)
                try Task.checkCancellation()
                devices = next
                chatsClosedToLinkedDevices = closed
                removedDeviceLeftoverChats = leftover
                startedFresh = fresh
                // A name held for this device gets written once the roster lists it.
                if pendingThisDeviceLabel != nil { writePendingThisDeviceLabel() }
            case .signIns:
                let next = try await runtime.unrecognizedSignIns(accountRef: accountRef)
                try Task.checkCancellation()
                signIns = next
            case .compromise:
                let next = try await runtime.compromiseWarning(accountRef: accountRef)
                try Task.checkCancellation()
                compromiseItems = next
            case .keyPackage:
                let next = try await runtime.keyPackageRefreshOverdue(accountRef: accountRef)
                try Task.checkCancellation()
                keyPackageRefreshOverdue = next
            case .historyImports:
                let next = try await runtime.chatHistoryImports(accountRef: accountRef)
                try Task.checkCancellation()
                historyImports = Dictionary(
                    next.map { ($0.groupIdHex.lowercased(), $0.state) }, uniquingKeysWith: { _, latest in latest })
            }
        } catch {
            // Keep the last answer: an unreadable refresh is not evidence the state went away.
        }
    }

    private func observe(_ subscription: EventsSubscription, runtime: any MarmotRuntime) async {
        while !Task.isCancelled {
            let event: MarmotEventFfi?
            do {
                event = try await runtime.nextEvent(subscription: subscription)
            } catch {
                return
            }
            guard let event else { return }
            guard let part = part(for: event) else { continue }
            await refresh(part)
        }
    }

    private func part(for event: MarmotEventFfi) -> Part? {
        let part: Part
        let eventAccount: String
        switch event {
        case .deviceLinkChanged(let id, _): (part, eventAccount) = (.link, id)
        case .linkedDevicesChanged(let id, _): (part, eventAccount) = (.devices, id)
        case .chatHistoryImportsChanged(let id, _): (part, eventAccount) = (.historyImports, id)
        case .unrecognizedSignInsChanged(let id, _): (part, eventAccount) = (.signIns, id)
        case .compromiseWarningChanged(let id, _): (part, eventAccount) = (.compromise, id)
        case .keyPackageRefreshOverdueChanged(let id, _): (part, eventAccount) = (.keyPackage, id)
        default: return nil
        }
        return eventAccount.lowercased() == accountIdHex ? part : nil
    }

    static func preview(
        snapshot: DeviceLinkSnapshotFfi? = nil,
        devices: [LinkedDeviceFfi] = [],
        signIns: [UnrecognizedSignInFfi] = [],
        compromiseItems: [CompromiseWarningItemFfi] = []
    ) -> DeviceLinkingViewModel {
        let model = DeviceLinkingViewModel(
            accountRef: "preview", accountIdHex: "preview", runtime: nil, isAvailable: true)
        if let snapshot { model.snapshot = snapshot }
        model.devices = devices
        model.signIns = signIns
        model.compromiseItems = compromiseItems
        return model
    }
}

/// Serializes one read: a request made while a read is in flight runs once more after it, so the
/// last value installed is always from the newest read.
///
/// One task owns the loop and clears itself in the same main-actor step that finds nothing left to
/// read. Callers only wait on it: a caller that waited on a finished read and looped would never
/// suspend, and the main actor would spin before the read's own caller could clear it.
@MainActor
private final class CoalescingRead {
    private let read: @MainActor () async -> Void
    private var drain: Task<Void, Never>?
    private var requested = false

    init(read: @escaping @MainActor () async -> Void) {
        self.read = read
    }

    func run() async {
        requested = true
        if let drain {
            await drain.value
            return
        }
        let next = Task { [weak self] in
            while let self, self.requested {
                self.requested = false
                await self.read()
            }
            self?.drain = nil
        }
        drain = next
        await next.value
    }

    /// Stops the loop. The model drops a cancelled reader, so none is started on it again.
    func cancel() {
        requested = false
        drain?.cancel()
    }
}
