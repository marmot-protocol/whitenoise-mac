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
    /// presentation rather than `NSSwitch`, even inside a grouped `Form` where macOS defaults
    /// toggles to switches.
    @Test func accountSetupRecoveryUsesCheckboxPresentationNotSwitch() {
        let defaultFormHost = NSHostingView(
            rootView: Form {
                Toggle("Default", isOn: .constant(true))
            }
            .formStyle(.grouped)
            .frame(width: 360, height: 80)
        )
        defaultFormHost.frame = CGRect(x: 0, y: 0, width: 360, height: 80)
        defaultFormHost.layoutSubtreeIfNeeded()
        #expect(!Self.descendants(of: defaultFormHost, as: NSSwitch.self).isEmpty)

        let card = AccountSetupRecoveryCard(acknowledgesRisk: .constant(false), isEnabled: true)
            .frame(width: 360)
        let cardSize = F.hostedSize(card)
        #expect(cardSize.height > 80, "recovery card did not render its content")

        let host = NSHostingView(
            rootView: Form {
                AccountSetupRecoveryCard(acknowledgesRisk: .constant(false), isEnabled: true)
            }
            .formStyle(.grouped)
            .frame(width: 400, height: 260)
        )
        host.frame = CGRect(x: 0, y: 0, width: 400, height: 260)
        host.layoutSubtreeIfNeeded()

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

    /// Escape clears an active search query first through `clearComposeSearch()`, then navigates
    /// back once empty — and ignores Escape entirely while chat creation is in flight so a pending
    /// creation error is never erased by an empty-query lookup.
    @Test func newChatEscapePreservesQueryAndErrorWhileCreatingAndClearsWhenIdle() {
        let workspace = WorkspaceState.preview()
        workspace.showNewChat()
        workspace.newChatQuery = "alice"
        workspace.isCreatingChat = true
        workspace.lastError = "Couldn't reach recipient"

        NewChatPanelView.handleEscape(in: workspace)
        #expect(workspace.newChatQuery == "alice")
        #expect(workspace.lastError == "Couldn't reach recipient")
        #expect(workspace.isNewChatComposerVisible)

        workspace.isCreatingChat = false
        NewChatPanelView.handleEscape(in: workspace)
        #expect(workspace.newChatQuery.isEmpty)
        #expect(workspace.isNewChatComposerVisible)

        NewChatPanelView.handleEscape(in: workspace)
        #expect(!workspace.isNewChatComposerVisible)
    }

    /// Header Back returns to Choose members while preserving staged group name and members,
    /// whereas Cancel / Escape closes the composer and discards the draft.
    @Test func nameGroupBackPreservesDraftWhileCancelDiscardsIt() {
        let workspace = WorkspaceState.preview()
        let member = NewChatRecipient(
            sourceQuery: "alice",
            memberRef: String(repeating: "a", count: 64),
            accountIdHex: String(repeating: "a", count: 64),
            npub: "npub1alice",
            displayName: "Alice",
            pictureURL: nil
        )
        workspace.showNewChat()
        workspace.composeShowChooseMembers()
        workspace.toggleComposeMember(member)
        workspace.composeShowNameGroup()
        workspace.newChatName = "Field Notes"

        workspace.composeGoBack()
        #expect(workspace.isNewChatComposerVisible)
        #expect(workspace.composePane == .chooseMembers)
        #expect(workspace.newChatName == "Field Notes")
        #expect(workspace.newChatRecipients == [member])

        workspace.composeShowNameGroup()
        workspace.closeNewChatComposer()
        #expect(!workspace.isNewChatComposerVisible)
        #expect(workspace.newChatName.isEmpty)
        #expect(workspace.newChatRecipients.isEmpty)
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
