//
//  SettingsDevicesStorageRelaysViewTests.swift
//  whitenoise-macTests
//
//  Behavioral render and interaction tests for Wave 2C-2 (#1109, #1110, #1111):
//  Linked Devices & linking sheets, Data Usage / Manage Storage native tables,
//  and Relays, Developer Tools, Key Packages, Quarantined Groups, and AI Agents.
//

import AppKit
import MarmotKit
import SwiftUI
import Testing

@testable import whitenoise_mac

@Suite(.serialized) @MainActor
struct SettingsDevicesStorageRelaysViewTests {
    // MARK: - #1109 Linked Devices & linking sheets

    @Test func devicesSettingsViewLoadsActiveAccountDevicesAndShowsProfileName() async {
        let runtime = FakeMarmotRuntime(accounts: [])
        runtime.deviceGroupsEnabled = true
        runtime.deviceLinking.devices = [
            LinkedDeviceFfi(
                slotIdHex: String(repeating: "a", count: 64), isThisDevice: true, label: "Studio Mac",
                client: "whitenoise", platform: "macOS", linkedAt: 1_760_000_000, linkedBySlotIdHex: nil,
                status: .active, addToAllChats: true, bringHistory: true, keepWhileInactive: false,
                lastActiveAt: nil, inactive: false, removalPending: false),
            LinkedDeviceFfi(
                slotIdHex: String(repeating: "b", count: 64), isThisDevice: false, label: "iPhone",
                client: "whitenoise", platform: "iOS", linkedAt: 1_760_100_000,
                linkedBySlotIdHex: String(repeating: "a", count: 64), status: .active, addToAllChats: true,
                bringHistory: true, keepWhileInactive: false, lastActiveAt: nil, inactive: false,
                removalPending: false),
        ]
        let model = DeviceLinkingViewModel(
            accountRef: "account-1", accountIdHex: String(repeating: "1", count: 64), runtime: runtime)
        let workspace = WorkspaceState.preview()

        let host = HostedViewWindow(
            DevicesSettingsView(model: model)
                .environment(workspace)
                .frame(width: 760, height: 720),
            size: CGSize(width: 760, height: 720)
        )
        defer { host.close() }

        #expect(await host.settle { model.devices.count == 2 })
        if let drawing = host.snapshot(), let activeName = workspace.activeAccount?.displayName {
            #expect(DrawnText.contains(activeName, in: drawing))
            #expect(DrawnText.contains("Studio Mac", in: drawing))
        }
    }

    @Test func deviceLinkPromptSheetUsesCheckboxTogglesAndRendersEmojiCode() {
        let code = [
            ("🐶", "dog"), ("🔑", "key"), ("🌵", "cactus"), ("🚲", "bicycle"),
            ("🎸", "guitar"), ("🍋", "lemon"), ("⚓️", "anchor"),
        ].map { DeviceLinkEmojiFfi(emoji: $0.0, description: $0.1) }

        let model = DeviceLinkingViewModel.preview(
            snapshot: DeviceLinkSnapshotFfi(
                newDevice: nil,
                prompts: [
                    DeviceLinkPromptFfi(
                        promptId: "p1", slotIdHex: nil, requestedAt: 1_700_000_000,
                        state: .comparing(code: code))
                ],
                moves: [],
                deviceGroupStalled: false
            )
        )

        let host = NSHostingView(
            rootView: DeviceLinkPromptSheet(model: model, promptId: "p1")
                .environment(WorkspaceState.preview())
        )
        host.frame = CGRect(x: 0, y: 0, width: 460, height: 600)
        host.layoutSubtreeIfNeeded()

        #expect(host.fittingSize.height > 200)
        #expect(
            Self.descendants(of: host, as: NSSwitch.self).isEmpty,
            "Device link prompt options should use checkbox toggles rather than NSSwitch")
    }

    @Test func linkedDeviceSheetRendersDetailsAndMissingDeviceFallback() {
        let slotA = String(repeating: "a", count: 64)
        let device = LinkedDeviceFfi(
            slotIdHex: slotA, isThisDevice: false, label: "iPhone", client: "whitenoise", platform: "iOS",
            linkedAt: 1_760_100_000, linkedBySlotIdHex: nil, status: .active, addToAllChats: true,
            bringHistory: false, keepWhileInactive: false, lastActiveAt: nil, inactive: false,
            removalPending: false)
        let model = DeviceLinkingViewModel.preview(devices: [device])

        let populated = Self.hostedSize(
            LinkedDeviceSheet(model: model, slotIdHex: slotA).environment(WorkspaceState.preview()))
        #expect(populated.height > 300)

        let missing = Self.hostedSize(
            LinkedDeviceSheet(model: model, slotIdHex: "nonexistent").environment(WorkspaceState.preview()))
        #expect(missing.height > 40)
    }

    // MARK: - #1110 Storage & Manage Storage

    @Test func storageSettingsViewShowsPolicyLoadErrorInsteadOfSpinningForever() async {
        let model = StorageSettingsViewModel.preview(
            policy: nil, error: .unavailable("Couldn't load storage usage"))
        let workspace = WorkspaceState.preview()

        let host = HostedViewWindow(
            StorageSettingsView(model: model)
                .environment(workspace)
                .frame(width: 760, height: 720),
            size: CGSize(width: 760, height: 720)
        )
        defer { host.close() }

        _ = await host.steadyDrawing(timeout: .seconds(2))
        #expect(model.policy == nil)
        if let drawing = host.snapshot() {
            #expect(DrawnText.contains("Try Again", in: drawing))
        }

        let runtime = FakeMarmotRuntime(accounts: [])
        let liveModel = StorageSettingsViewModel(
            accountRef: "account-1", runtime: runtime, attachmentPolicyController: nil)
        let liveHost = HostedViewWindow(
            StorageSettingsView(model: liveModel)
                .environment(workspace)
                .frame(width: 760, height: 720),
            size: CGSize(width: 760, height: 720)
        )
        defer { liveHost.close() }
        #expect(await liveHost.settle { liveModel.policy != nil && !liveModel.isLoading })
    }

    @Test func manageStorageAttachmentSubpagesRenderNativeTableAndInvokeAttachmentsDidChange() async {
        let runtime = FakeMarmotRuntime(accounts: [])
        let mebibyte: UInt64 = 1_048_576
        runtime.attachmentStorageUsageResult = AttachmentStorageUsageFfi(
            mediaBytes: 24 * mebibyte, legacyBytes: 0, attachmentCount: 1,
            databaseBytes: 4 * mebibyte, databaseFreeBytes: 0,
            migration: .notNeeded, migrationBytes: 0, cacheBytes: 1 * mebibyte)
        runtime.chatStorageUsage = [
            ChatAttachmentUsageFfi(groupIdHex: "a1", bytes: 24 * mebibyte, attachmentCount: 1)
        ]
        runtime.retainedAttachmentSummaries = [
            RetainedAttachmentSummaryFfi(
                groupIdHex: "a1",
                target: AttachmentLocalTargetFfi(messageIdHex: "m1", sourceMessageIdHex: "m1", attachmentIndex: 0),
                byteCount: 24 * mebibyte, mediaType: "application/pdf", fileName: "Itinerary.pdf",
                receivedAt: 1_760_000_000)
        ]

        var didChangeCount = 0
        let model = ManageStorageViewModel(
            accountRef: "account-1",
            activeAccountIdHex: String(repeating: "f", count: 64),
            runtime: runtime,
            attachmentsDidChange: { didChangeCount += 1 }
        )
        await model.load()

        let host = HostedViewWindow(
            ManageStorageLargestAttachmentsView(model: model, nicknames: .none) {}
                .environment(WorkspaceState.preview())
                .frame(width: 760, height: 520),
            size: CGSize(width: 760, height: 520)
        )
        defer { host.close() }

        #expect(await host.settle { !model.attachmentPages(.account).hasMore })
        #expect(model.attachmentPages(.account).items.count == 1)
        if let contentView = host.window.contentView {
            #expect(
                !Self.descendants(of: contentView, as: NSTableView.self).isEmpty,
                "Largest attachments view should render a native SwiftUI Table backed by NSTableView")
        }

        await model.removeAllAttachments(inChat: "a1")
        #expect(didChangeCount == 1)
    }

    // MARK: - #1111 Relays, Developer Tools, Key Packages, Quarantined Groups, AI Agents

    @Test func relayViewsAndAddRelaySheetRenderAndLoad() async {
        let runtime = FakeMarmotRuntime(accounts: [])
        let model = RelaySettingsViewModel(accountRef: "account-1", runtime: runtime)

        let host = HostedViewWindow(
            RelaySettingsView(model: model)
                .environment(WorkspaceState.preview())
                .frame(width: 760, height: 640),
            size: CGSize(width: 760, height: 640)
        )
        defer { host.close() }

        #expect(await host.settle { !model.isLoading && !model.endpoints.isEmpty })

        if let first = model.endpoints.first {
            let detailSize = Self.hostedSize(
                RelayDetailSettingsView(model: model, relay: first) {}
                    .environment(WorkspaceState.preview())
                    .frame(width: 760, height: 640)
            )
            #expect(detailSize.height > 200)
        }

        let sheetSize = Self.hostedSize(AddRelaySheet(model: model))
        #expect(sheetSize.width >= 440)
        #expect(sheetSize.height >= 360)
    }

    @Test func developerModeKeyPackagesQuarantinedGroupsAndAIAgentsRenderCleanly() async {
        let runtime = FakeMarmotRuntime(accounts: [])
        runtime.quarantinedGroupRecords = [
            AppQuarantinedGroupFfi(groupIdHex: String(repeating: "a", count: 64), reason: .openMlsLoadFailed),
            AppQuarantinedGroupFfi(groupIdHex: String(repeating: "b", count: 64), reason: .rewindRestoreFailed),
        ]

        let workspace = WorkspaceState.preview()
        let devSize = Self.hostedSize(
            DeveloperModeSettingsView(model: .preview())
                .environment(workspace)
                .frame(width: 760, height: 640)
        )
        #expect(devSize.height > 200)

        let kpModel = KeyPackageSettingsViewModel(accountRef: "account-1", runtime: runtime)
        let kpHost = HostedViewWindow(
            KeyPackageSettingsView(model: kpModel)
                .environment(workspace)
                .frame(width: 760, height: 640),
            size: CGSize(width: 760, height: 640)
        )
        defer { kpHost.close() }
        #expect(await kpHost.settle { !kpModel.isLoading })

        let quarantinedModel = QuarantinedGroupsViewModel(accountRef: "account-1", runtime: runtime)
        let quarantinedHost = HostedViewWindow(
            QuarantinedGroupsSettingsView(model: quarantinedModel)
                .environment(workspace)
                .frame(width: 760, height: 640),
            size: CGSize(width: 760, height: 640)
        )
        defer { quarantinedHost.close() }
        #expect(await quarantinedHost.settle { quarantinedModel.groups.count == 2 })
        #expect(QuarantinedGroupReason.canRetry(.openMlsLoadFailed))
        #expect(!QuarantinedGroupReason.canRetry(.rewindRestoreFailed))

        let agentsWithAccount = Self.hostedSize(
            AIAgentsSettingsView(model: .preview())
                .environment(workspace)
                .frame(width: 760, height: 640)
        )
        #expect(agentsWithAccount.height > 200)

        let agentsWithoutAccount = Self.hostedSize(
            AIAgentsSettingsView(model: .preview(publicNpub: nil))
                .environment(workspace)
                .frame(width: 760, height: 640)
        )
        #expect(agentsWithoutAccount.height > 200)
    }

    // MARK: - Helpers

    private static func hostedSize(_ view: some View) -> CGSize {
        let host = NSHostingView(rootView: view)
        host.layoutSubtreeIfNeeded()
        return host.fittingSize
    }

    private static func descendants<T: NSView>(of view: NSView, as type: T.Type) -> [T] {
        var found: [T] = []
        if let match = view as? T { found.append(match) }
        for subview in view.subviews {
            found.append(contentsOf: descendants(of: subview, as: type))
        }
        return found
    }
}
