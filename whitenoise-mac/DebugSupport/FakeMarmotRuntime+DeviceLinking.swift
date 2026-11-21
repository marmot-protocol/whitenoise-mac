// coverage:ignore-file
//
//  FakeMarmotRuntime+DeviceLinking.swift
//
//  Device linking on the fake runtime. State lives in `FakeDeviceLinkingState` so tests can seed
//  a snapshot, a device list or sign-ins, and read back the calls made. The transitions are the
//  ones MDK's README documents for each call, without any of the cryptography behind them.
//

#if DEBUG
    import Foundation
    import MarmotKit

    nonisolated final class FakeDeviceLinkingState: @unchecked Sendable {
        var snapshot = DeviceLinkSnapshotFfi(newDevice: nil, prompts: [], moves: [], deviceGroupStalled: false)
        var devices: [LinkedDeviceFfi] = []
        var signIns: [UnrecognizedSignInFfi] = []
        var compromiseItems: [CompromiseWarningItemFfi] = []
        var keyPackageRefreshOverdue = false
        var chatsClosedToLinkedDevices: UInt32 = 0
        var removedDeviceLeftoverChats: UInt32 = 0
        var startedFresh = false
        var historyImports: [ChatHistoryImportFfi] = []
        /// Thrown by every call when set, the way MDK refuses each one without device groups.
        var error: Error?
        /// Thrown by the next mutating call only, then cleared.
        var nextActionError: Error?
        /// Thrown by `rotateKeyPackage` alone, after the reset before it went through.
        var keyPackageRotationError: Error?
        /// Parks a snapshot read after it has taken its snapshot, so its answer lands late.
        let snapshotReadGate = AsyncFfiGate()
        /// Parks a roster read after it has taken the roster, so its answer lands late.
        let devicesReadGate = AsyncFfiGate()
        /// Parks `renameLinkedDevice` before it takes effect.
        let renameGate = AsyncFfiGate()
        /// Parks `linkDevice`'s reply after the link went through, so the reply lands late.
        let linkReplyGate = AsyncFfiGate()

        private(set) var snapshotReadCount = 0
        private(set) var deviceReadCount = 0
        private(set) var linkCalls: [(promptId: String, label: String, addToAllChats: Bool, bringHistory: Bool)] = []
        private(set) var declinedPromptIds: [String] = []
        private(set) var renames: [(slotIdHex: String, label: String)] = []
        private(set) var settingsUpdates:
            [(slotIdHex: String, addToAllChats: Bool?, bringHistory: Bool?, keepWhileInactive: Bool?)] = []
        private(set) var removedSlots: [String] = []
        private(set) var answers: [(slotIdHex: String, response: SignInResponseFfi)] = []
        private(set) var checkSignInsCount = 0
        private(set) var resetCount = 0
        private(set) var dismissedMoveSiblings: [(moveId: String, slotIdHex: String)] = []
        private(set) var compromiseDismissCount = 0
        private(set) var keyPackageRotationCount = 0

        fileprivate func read() throws {
            if let error { throw error }
        }

        fileprivate func act() throws {
            if let error { throw error }
            if let nextActionError {
                self.nextActionError = nil
                throw nextActionError
            }
        }

        fileprivate func countSnapshotRead() { snapshotReadCount += 1 }
        fileprivate func countDeviceRead() { deviceReadCount += 1 }
        fileprivate func recordLink(_ call: (String, String, Bool, Bool)) { linkCalls.append(call) }
        fileprivate func recordDecline(_ promptId: String) { declinedPromptIds.append(promptId) }
        fileprivate func recordRename(_ call: (String, String)) { renames.append(call) }
        fileprivate func recordSettings(_ call: (String, Bool?, Bool?, Bool?)) { settingsUpdates.append(call) }
        fileprivate func recordRemoval(_ slot: String) { removedSlots.append(slot) }
        fileprivate func recordAnswer(_ call: (String, SignInResponseFfi)) { answers.append(call) }
        fileprivate func recordCheck() { checkSignInsCount += 1 }
        fileprivate func recordReset() { resetCount += 1 }
        fileprivate func recordMoveDismissal(_ call: (String, String)) { dismissedMoveSiblings.append(call) }
        fileprivate func recordCompromiseDismissal() { compromiseDismissCount += 1 }
        fileprivate func recordKeyPackageRotation() { keyPackageRotationCount += 1 }

        fileprivate func updatePrompt(_ promptId: String, to state: DeviceLinkPromptStateFfi) {
            guard let index = snapshot.prompts.firstIndex(where: { $0.promptId == promptId }) else { return }
            snapshot.prompts[index].state = state
        }

        fileprivate func updateDevice(_ slotIdHex: String, _ change: (inout LinkedDeviceFfi) -> Void) {
            guard let index = devices.firstIndex(where: { $0.slotIdHex == slotIdHex }) else { return }
            change(&devices[index])
        }
    }

    extension FakeMarmotRuntime {
        func deviceLinkSnapshot(accountRef: String) async throws -> DeviceLinkSnapshotFfi {
            deviceLinking.countSnapshotRead()
            try deviceLinking.read()
            let snapshot = deviceLinking.snapshot
            await deviceLinking.snapshotReadGate.passIfArmed()
            return snapshot
        }

        func startDeviceLink(accountRef: String) async throws -> DeviceLinkSnapshotFfi {
            try deviceLinking.act()
            deviceLinking.snapshot.newDevice = .waitingForAnswer
            return deviceLinking.snapshot
        }

        func confirmDeviceLinkMatch(accountRef: String) async throws -> DeviceLinkSnapshotFfi {
            try deviceLinking.act()
            deviceLinking.snapshot.newDevice = .waitingForOtherDevice
            return deviceLinking.snapshot
        }

        func cancelDeviceLink(accountRef: String) async throws -> DeviceLinkSnapshotFfi {
            try deviceLinking.act()
            deviceLinking.snapshot.newDevice = .ended(reason: .cancelled)
            return deviceLinking.snapshot
        }

        func linkDevice(
            accountRef: String, promptId: String, label: String, addToAllChats: Bool, bringHistory: Bool
        ) async throws -> DeviceLinkSnapshotFfi {
            try deviceLinking.act()
            deviceLinking.recordLink((promptId, label, addToAllChats, bringHistory))
            deviceLinking.updatePrompt(promptId, to: .linking)
            let reply = deviceLinking.snapshot
            await deviceLinking.linkReplyGate.passIfArmed()
            return reply
        }

        func declineDeviceLink(accountRef: String, promptId: String) async throws -> DeviceLinkSnapshotFfi {
            try deviceLinking.act()
            deviceLinking.recordDecline(promptId)
            deviceLinking.snapshot.prompts.removeAll { $0.promptId == promptId }
            return deviceLinking.snapshot
        }

        func dismissDeviceGroupMoveSibling(accountRef: String, moveId: String, slotIdHex: String) async throws
            -> DeviceLinkSnapshotFfi
        {
            try deviceLinking.act()
            deviceLinking.recordMoveDismissal((moveId, slotIdHex))
            if let index = deviceLinking.snapshot.moves.firstIndex(where: { $0.moveId == moveId }) {
                deviceLinking.snapshot.moves[index].oldSiblings.removeAll { $0.slotIdHex == slotIdHex }
            }
            return deviceLinking.snapshot
        }

        func resetDeviceGroupForRepair(accountRef: String) async throws -> DeviceLinkSnapshotFfi {
            try deviceLinking.act()
            deviceLinking.recordReset()
            deviceLinking.snapshot.deviceGroupStalled = false
            deviceLinking.devices = []
            return deviceLinking.snapshot
        }

        func linkedDevices(accountRef: String) async throws -> [LinkedDeviceFfi] {
            deviceLinking.countDeviceRead()
            try deviceLinking.read()
            let devices = deviceLinking.devices
            await deviceLinking.devicesReadGate.passIfArmed()
            return devices
        }

        func renameLinkedDevice(accountRef: String, slotIdHex: String, label: String) async throws {
            await deviceLinking.renameGate.passIfArmed()
            try deviceLinking.act()
            deviceLinking.recordRename((slotIdHex, label))
            deviceLinking.updateDevice(slotIdHex) { $0.label = label }
        }

        func updateLinkedDeviceSettings(
            accountRef: String, slotIdHex: String, addToAllChats: Bool?, bringHistory: Bool?,
            keepWhileInactive: Bool?
        ) async throws {
            try deviceLinking.act()
            deviceLinking.recordSettings((slotIdHex, addToAllChats, bringHistory, keepWhileInactive))
            deviceLinking.updateDevice(slotIdHex) { device in
                if let addToAllChats { device.addToAllChats = addToAllChats }
                if let bringHistory { device.bringHistory = bringHistory }
                if let keepWhileInactive { device.keepWhileInactive = keepWhileInactive }
            }
        }

        func removeLinkedDevice(accountRef: String, slotIdHex: String) async throws {
            try deviceLinking.act()
            deviceLinking.recordRemoval(slotIdHex)
            deviceLinking.updateDevice(slotIdHex) { $0.removalPending = true }
        }

        func chatsClosedToLinkedDevices(accountRef: String) async throws -> UInt32 {
            try deviceLinking.read()
            return deviceLinking.chatsClosedToLinkedDevices
        }

        func removedDeviceLeftoverChats(accountRef: String) async throws -> UInt32 {
            try deviceLinking.read()
            return deviceLinking.removedDeviceLeftoverChats
        }

        func keyPackageRefreshOverdue(accountRef: String) async throws -> Bool {
            try deviceLinking.read()
            return deviceLinking.keyPackageRefreshOverdue
        }

        func unrecognizedSignIns(accountRef: String) async throws -> [UnrecognizedSignInFfi] {
            try deviceLinking.read()
            return deviceLinking.signIns
        }

        func checkSignIns(accountRef: String) async throws -> [UnrecognizedSignInFfi] {
            try deviceLinking.act()
            deviceLinking.recordCheck()
            return deviceLinking.signIns
        }

        func answerSignIn(accountRef: String, slotIdHex: String, response: SignInResponseFfi) async throws {
            try deviceLinking.act()
            deviceLinking.recordAnswer((slotIdHex, response))
            switch response {
            case .reject, .dismiss:
                deviceLinking.signIns.removeAll { $0.slotIdHex == slotIdHex }
            case .notNow:
                if let index = deviceLinking.signIns.firstIndex(where: { $0.slotIdHex == slotIdHex }) {
                    deviceLinking.signIns[index].state = .notNow
                }
            }
        }

        func startFresh(accountRef: String) async throws {
            try deviceLinking.act()
            deviceLinking.startedFresh = true
            for index in deviceLinking.signIns.indices where deviceLinking.signIns[index].beforeThisDevice {
                deviceLinking.signIns[index].state = .notNow
            }
        }

        func startedFresh(accountRef: String) async throws -> Bool {
            try deviceLinking.read()
            return deviceLinking.startedFresh
        }

        func compromiseWarning(accountRef: String) async throws -> [CompromiseWarningItemFfi] {
            try deviceLinking.read()
            return deviceLinking.compromiseItems
        }

        func dismissCompromiseWarning(accountRef: String) async throws {
            try deviceLinking.act()
            deviceLinking.recordCompromiseDismissal()
            deviceLinking.compromiseItems = []
        }

        func chatHistoryImports(accountRef: String) async throws -> [ChatHistoryImportFfi] {
            try deviceLinking.read()
            return deviceLinking.historyImports
        }

        func rotateKeyPackage(accountRef: String) async throws -> UInt64 {
            try deviceLinking.act()
            if let error = deviceLinking.keyPackageRotationError { throw error }
            deviceLinking.recordKeyPackageRotation()
            return 1
        }
    }
#endif
