//
//  EntryFlowsRenderTests.swift
//  whitenoise-macTests
//
//  Behavioral render tests for the native Mac entry flows refresh (#1106 & #1105):
//  account-setup checkboxes, compose flow panes, direct-chat chooser sheet, and group draft image picker.
//

import AppKit
import MarmotKit
import SwiftUI
import Testing

@testable import whitenoise_mac

@Suite(.serialized) @MainActor struct EntryFlowsRenderTests {
    private typealias F = OnboardingFixtures

    // MARK: - #1106 Account setup native checkboxes

    /// Recovery risk acknowledgment is a subordinate consent choice (C06) and must use checkbox
    /// presentation rather than `NSSwitch`. A switch-styled `WNToggle` serves as the positive
    /// control proving the view walk detects `NSSwitch` instances.
    @Test func accountSetupRecoveryUsesCheckboxPresentationNotSwitch() async throws {
        let switchControlHost = NSHostingView(
            rootView: WNToggle("Control", isOn: .constant(true), presentation: .switch)
                .frame(width: 240, height: 44)
        )
        switchControlHost.layoutSubtreeIfNeeded()
        #expect(!Self.descendants(of: switchControlHost, as: NSSwitch.self).isEmpty)

        var snapshot = F.snapshot(steps: [F.step(.relays, .needsInput)])
        snapshot.recoveryEpoch = "epoch-1"
        let model = await F.coordinator(snapshot)
        defer { model.stop() }

        let host = NSHostingView(rootView: AccountSetupView(model: model).frame(width: 940, height: 620))
        host.frame = CGRect(x: 0, y: 0, width: 940, height: 620)
        host.layoutSubtreeIfNeeded()

        #expect(host.fittingSize.width == 940)
        #expect(
            Self.descendants(of: host, as: NSSwitch.self).isEmpty,
            "recovery acknowledgment should be a checkbox, not an NSSwitch")
    }

    /// Relay Read/Write role toggles use checkbox presentation rather than switches, and add the
    /// role row when `showsRoles` is enabled.
    @Test func relayDraftEditorRolesUseCheckboxPresentationNotSwitches() {
        let draft = AccountSetupRelayDraft(entries: [.init(address: "wss://relay.example.com")])
        let host = NSHostingView(
            rootView: AccountSetupRelayDraftEditor(draft: .constant(draft), showsRoles: true)
                .frame(width: 360)
        )
        host.frame = CGRect(origin: .zero, size: host.fittingSize)
        host.layoutSubtreeIfNeeded()

        let withoutRoles = F.hostedSize(
            AccountSetupRelayDraftEditor(draft: .constant(draft), showsRoles: false).frame(width: 360)
        )

        #expect(host.fittingSize.height > withoutRoles.height)
        #expect(
            Self.descendants(of: host, as: NSSwitch.self).isEmpty,
            "relay Read/Write roles should be checkboxes, not NSSwitch controls")
    }

    // MARK: - #1105 New chat, group creation, and direct-chat chooser

    @Test func composeFlowPanelsRenderAtDrawerWidth() {
        let workspace = WorkspaceState.preview()
        let session = SessionState()

        let newChat = F.hostedSize(
            NewChatPanelView()
                .environment(workspace)
                .environment(session)
                .frame(width: 300, height: 520)
        )
        #expect(newChat == CGSize(width: 300, height: 520))

        let chooseMembers = F.hostedSize(
            ChooseMembersPanelView()
                .environment(workspace)
                .environment(session)
                .frame(width: 300, height: 520)
        )
        #expect(chooseMembers == CGSize(width: 300, height: 520))

        let nameGroup = F.hostedSize(
            NameGroupPanelView(draftImage: .constant(nil))
                .environment(workspace)
                .environment(session)
                .frame(width: 300, height: 520)
        )
        #expect(nameGroup == CGSize(width: 300, height: 520))
    }

    @Test func directChatChooserSheetRendersContentSizedWithChoices() {
        let peer = String(repeating: "b", count: 64)
        let presentation = DirectChatChooserPresentation(
            recipient: NewChatRecipient(
                sourceQuery: "",
                memberRef: peer,
                accountIdHex: peer,
                npub: "npub1preview",
                displayName: "Bob",
                pictureURL: nil
            ),
            choices: [
                DirectChatChoice(
                    chat: ChatItem(
                        id: "recent",
                        title: "Bob",
                        subtitle: "",
                        preview: "See you tomorrow",
                        updatedAt: .now,
                        avatarSeed: peer,
                        pictureURL: nil,
                        unreadCount: 0,
                        isDirect: true
                    ),
                    isArchived: false
                ),
                DirectChatChoice(
                    chat: ChatItem(
                        id: "older",
                        title: "Bob",
                        subtitle: "",
                        preview: "",
                        updatedAt: .now.addingTimeInterval(-86_400 * 30),
                        avatarSeed: peer,
                        pictureURL: nil,
                        unreadCount: 0,
                        isDirect: true
                    ),
                    isArchived: true
                ),
            ]
        )

        let size = F.hostedSize(
            DirectChatChooserSheet(
                presentation: presentation,
                onOpen: { _ in },
                onStartNew: {},
                onCancel: {}
            )
        )

        #expect(size.width >= 380)
        #expect(size.height > 120)
    }

    @Test func groupDraftImagePickerRendersUnnamedAndNamedStates() {
        for name in ["", "Hiking crew"] {
            let size = F.hostedSize(
                GroupDraftImagePicker(name: name, image: .constant(nil))
                    .frame(width: 300)
            )
            #expect(size.width == 300)
            #expect(size.height > GroupDraftImagePicker.avatarSize)
        }
    }

    // MARK: - Helpers

    private static func descendants<T: NSView>(of root: NSView, as type: T.Type) -> [T] {
        var result: [T] = []
        if let match = root as? T {
            result.append(match)
        }
        for subview in root.subviews {
            result.append(contentsOf: descendants(of: subview, as: type))
        }
        return result
    }
}
