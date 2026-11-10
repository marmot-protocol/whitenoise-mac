//
//  GroupDisbandRenderTests.swift
//  whitenoise-macTests
//
//  The surfaces that report a group being ended — the inspector's status section and End Group
//  row, the composer notice and the sidebar capsule — draw in every state. Rasterized rather than
//  inspected: the test host builds no accessibility tree.
//

import AppKit
import MarmotKit
import SwiftUI
import Testing

@testable import whitenoise_mac

/// `.serialized` and `@MainActor` because rasterizing switches `NSAppearance`, which off the main
/// thread takes the test host down.
@Suite(.serialized) @MainActor struct GroupDisbandRenderTests {
    @Test(arguments: [NSAppearance.Name.aqua, NSAppearance.Name.darkAqua])
    func eachStatusDrawsAndNoneDrawsNothing(appearance: NSAppearance.Name) throws {
        let none = try Self.drawnHeight(GroupDisbandStatusSection(status: .none, onDismiss: {}), in: appearance)
        let pending = try Self.drawnHeight(
            GroupDisbandStatusSection(status: .pending, onDismiss: {}), in: appearance)
        let failed = try Self.drawnHeight(
            GroupDisbandStatusSection(status: .failed(.noLongerMember), isDismissing: true, onDismiss: {}),
            in: appearance)
        let ended = try Self.drawnHeight(
            GroupDisbandStatusSection(status: .disbanded, onDismiss: {}), in: appearance)

        #expect(none == 0)
        #expect(pending > 0)
        // The failure carries a Dismiss button under its line.
        #expect(failed > 0)
        #expect(ended > 0)
    }

    @Test(arguments: [NSAppearance.Name.aqua, NSAppearance.Name.darkAqua])
    func theComposerNoticeAndSidebarBadgeDraw(appearance: NSAppearance.Name) throws {
        for lifecycle in [GroupLifecycle.ending, .ended] {
            let notice = try Self.drawnHeight(
                GroupLifecycleComposerNotice(lifecycle: lifecycle, message: lifecycle.composerNotice ?? "")
                    .frame(width: 480),
                in: appearance)
            let badge = try Self.drawnHeight(GroupLifecycleBadge(lifecycle: lifecycle), in: appearance)
            #expect(notice > 0)
            #expect(badge > 0)
        }
    }

    /// An admin held back by members on old clients still sees End Group, with the reason under it;
    /// one who can end the group sees the row without it.
    @Test func theLeaveSectionExplainsABlockedEndGroup() async throws {
        let blocked = try await Self.leaveSection(
            Self.managementState(canDisband: false, disbandingBlockers: ["a"]))
        let open = try await Self.leaveSection(Self.managementState(canDisband: true))

        #expect(blocked.snapshot.disband.showsEndGroup)
        #expect(blocked.snapshot.disband.blockerMessage != nil)
        #expect(open.snapshot.disband.canEndGroup)

        let blockedHeight = try Self.drawnHeight(blocked.view, in: .aqua)
        let openHeight = try Self.drawnHeight(open.view, in: .aqua)
        #expect(openHeight > 0)
        #expect(blockedHeight > openHeight)
    }

    @Test func anEndedGroupsLeaveSectionOffersTheLocalDelete() async throws {
        var state = Self.managementState(canDisband: false)
        state.lifecycleState = .disbanded
        let ended = try await Self.leaveSection(state)

        #expect(ended.snapshot.disband.lifecycle == .ended)
        #expect(ended.snapshot.destructiveAction == .deleteLocally)
        #expect(try Self.drawnHeight(ended.view, in: .darkAqua) > 0)
    }

    // MARK: - Helpers

    private struct LeaveSectionFixture<Content: View> {
        let snapshot: GroupDetailsSnapshot
        let view: Content
    }

    private static func leaveSection(
        _ managementState: GroupManagementStateFfi
    ) async throws -> LeaveSectionFixture<some View> {
        let account = desktopAccount()
        let runtime = FakeMarmotRuntime(accounts: [account])
        runtime.installGroupDetails(
            groupDetailsFixture(selfAccountIdHex: account.accountIdHex), managementState: managementState)
        let workspace = WorkspaceState(clientFactory: { runtime })
        await workspace.bootstrap()
        let chat = try #require(workspace.activeChats.first)
        await workspace.showGroupDetails(for: chat)
        let snapshot = try #require(workspace.groupDetailsSnapshot)
        let model = GroupDisbandViewModel(
            accountRef: account.accountIdHex, groupIdHex: snapshot.groupIdHex, runtime: runtime)
        let view = VStack(alignment: .leading) {
            GroupDetailsLeaveSection(chat: chat, snapshot: snapshot, disbandModel: model)
        }
        .frame(width: 420)
        .environment(workspace)
        .environment(SessionState())
        return LeaveSectionFixture(snapshot: snapshot, view: view)
    }

    private static func managementState(
        canDisband: Bool,
        disbandingBlockers: [String] = []
    ) -> GroupManagementStateFfi {
        GroupManagementStateFfi(
            myAccountIdHex: desktopAccount().accountIdHex,
            isSelfAdmin: true,
            isLastAdmin: true,
            canInvite: true,
            canLeave: false,
            requiresSelfDemoteBeforeLeave: true,
            leaveRequestPending: false,
            leaveRequestedAtMs: nil,
            leaveBlocked: false,
            canCancelLeave: false,
            lifecycleState: .stable,
            disbandingEnabled: canDisband,
            disbanding: false,
            canEnableDisbanding: false,
            canDisband: canDisband,
            disbandingBlockers: disbandingBlockers,
            disbandRequest: nil,
            memberActions: []
        )
    }

    /// The rows of the rasterized view that carry any ink; 0 for a view that draws nothing.
    private static func drawnHeight(_ view: some View, in appearance: NSAppearance.Name) throws -> Int {
        let scheme: ColorScheme = appearance == .darkAqua ? .dark : .light
        let renderer = ImageRenderer(content: view.environment(\.colorScheme, scheme))
        renderer.scale = 2

        var image: NSImage?
        NSAppearance(named: appearance)?.performAsCurrentDrawingAppearance {
            image = renderer.nsImage
        }
        guard let tiff = image?.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else { return 0 }
        return (0..<rep.pixelsHigh).filter { y in
            stride(from: 0, to: rep.pixelsWide, by: 2).contains { x in
                (rep.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.05
            }
        }.count
    }
}
