//
//  EntryFlowsRenderTests.swift
//  whitenoise-macTests
//
//  Behavioral render tests for the native Mac entry flows refresh (#1106 & #1105):
//  account-setup checkboxes, sign-up Escape guard, compose flow panes, and direct-chat chooser sheet.
//

import AppKit
import MarmotKit
import SwiftUI
import Testing

@testable import whitenoise_mac

@Suite(.serialized) @MainActor struct EntryFlowsRenderTests {
    private typealias F = OnboardingFixtures

    // MARK: - #1106 Account setup & sign-up

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

    /// Escape on the sign-up pane is allowed only when the draft is untouched and no identity has
    /// been minted yet; typing into any field or having a pending publish retry leaves cancellation
    /// to the explicit Back button.
    @Test func signUpEscapeGuardRequiresUntouchedDraftAndNoCreatedIdentity() {
        let workspace = WorkspaceState.preview()
        workspace.showSignUp()
        #expect(workspace.canDismissSignUpWithEscape)

        workspace.signUpDraft.displayName = "Alice"
        #expect(!workspace.canDismissSignUpWithEscape)
        workspace.signUpDraft.displayName = ""
        #expect(workspace.canDismissSignUpWithEscape)

        workspace.signUpDraft.about = "Writer"
        #expect(!workspace.canDismissSignUpWithEscape)
        workspace.signUpDraft.about = ""
        #expect(workspace.canDismissSignUpWithEscape)

        workspace.signUpCreatedAccountRef = "account-1"
        #expect(!workspace.canDismissSignUpWithEscape)
        workspace.signUpCreatedAccountRef = nil
        #expect(workspace.canDismissSignUpWithEscape)

        workspace.authenticationActivity = .signUp
        #expect(!workspace.canDismissSignUpWithEscape)
        workspace.authenticationActivity = nil
        #expect(workspace.canDismissSignUpWithEscape)
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

    /// Mounting `NameGroupPanelView` wires its Cancel button to Escape (`.cancelAction`), disables
    /// it while creation is in flight, and keeps header Back returning to Choose members with the
    /// staged draft intact.
    @Test func nameGroupPanelEscapeCancelsWhenIdleAndHeaderBackPreservesDraft() async throws {
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

        let size = CGSize(width: 340, height: 520)
        let host = HostedViewWindow(
            NameGroupPanelView(draftImage: .constant(nil))
                .environment(workspace)
                .environment(\.hasWindowTopNoticeBand, true)
                .frame(width: size.width, height: size.height),
            size: size
        )
        defer { host.close() }

        let escapeEvent = try #require(
            NSEvent.keyEvent(
                with: .keyDown,
                location: .zero,
                modifierFlags: [],
                timestamp: 0,
                windowNumber: host.window.windowNumber,
                context: nil,
                characters: "\u{1b}",
                charactersIgnoringModifiers: "\u{1b}",
                isARepeat: false,
                keyCode: 53
            )
        )

        // While creation is in flight, Cancel is disabled so Escape cannot discard the draft.
        workspace.isCreatingChat = true
        _ = await host.settle(timeout: .milliseconds(100)) { false }
        _ = host.window.performKeyEquivalent(with: escapeEvent)
        #expect(workspace.isNewChatComposerVisible)
        #expect(workspace.composePane == .nameGroup)
        #expect(workspace.newChatName == "Field Notes")
        #expect(workspace.newChatRecipients == [member])

        // Header Back returns to Choose members without discarding the draft.
        workspace.isCreatingChat = false
        _ = await host.settle(timeout: .milliseconds(100)) { false }
        host.click(at: CGPoint(x: 24, y: 16))
        #expect(await host.settle { workspace.composePane == .chooseMembers })
        #expect(workspace.isNewChatComposerVisible)
        #expect(workspace.newChatName == "Field Notes")
        #expect(workspace.newChatRecipients == [member])

        // Re-entering Name group and pressing Escape invokes Cancel and discards the draft.
        workspace.composeShowNameGroup()
        _ = await host.settle(timeout: .milliseconds(100)) { false }
        #expect(host.window.performKeyEquivalent(with: escapeEvent))
        #expect(await host.settle { !workspace.isNewChatComposerVisible })
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
