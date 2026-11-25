//
//  EntryFlowsRenderTests.swift
//  whitenoise-macTests
//
//  Behavioral render and interaction tests for the native Mac entry flows refresh (#1106 & #1105):
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
        #expect(OnboardingSignUpView.canDismissWithEscape(workspace))

        workspace.signUpDraft.displayName = "Alice"
        #expect(!OnboardingSignUpView.canDismissWithEscape(workspace))
        workspace.signUpDraft.displayName = ""
        #expect(OnboardingSignUpView.canDismissWithEscape(workspace))

        workspace.signUpDraft.about = "Writer"
        #expect(!OnboardingSignUpView.canDismissWithEscape(workspace))
        workspace.signUpDraft.about = ""
        #expect(OnboardingSignUpView.canDismissWithEscape(workspace))

        workspace.signUpCreatedAccountRef = "account-1"
        #expect(!OnboardingSignUpView.canDismissWithEscape(workspace))
        workspace.signUpCreatedAccountRef = nil
        #expect(OnboardingSignUpView.canDismissWithEscape(workspace))

        workspace.authenticationActivity = .signUp
        #expect(!OnboardingSignUpView.canDismissWithEscape(workspace))
        workspace.authenticationActivity = nil
        #expect(OnboardingSignUpView.canDismissWithEscape(workspace))
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

    /// `NameGroupPanelView` keeps Escape and Return scoped to its own pane so an adjacent
    /// conversation search field is never hijacked by window-wide Cancel/Create shortcuts; inside
    /// the pane, header Back and Escape preserve the staged draft while explicit Cancel discards it.
    @Test func nameGroupPanelDoesNotHijackAdjacentEscapeAndPreservesDraftOnBack() async throws {
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

        var adjacentEscapeHandled = false
        let size = CGSize(width: 660, height: 520)
        let host = HostedViewWindow(
            HStack(spacing: 0) {
                NameGroupPanelView(draftImage: .constant(nil))
                    .environment(workspace)
                    .environment(\.hasWindowTopNoticeBand, true)
                    .frame(width: 340, height: size.height)

                AdjacentConversationPaneProbe {
                    adjacentEscapeHandled = true
                }
                .frame(width: 320, height: size.height)
            },
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

        // With an adjacent conversation search surface claiming Escape, `NameGroupPanelView` must
        // NOT register a window-wide `.cancelAction` or `.defaultAction` that hijacks Escape or
        // Return and discards the staged group draft.
        #expect(host.window.performKeyEquivalent(with: escapeEvent))
        #expect(await host.settle { adjacentEscapeHandled })
        #expect(workspace.isNewChatComposerVisible)
        #expect(workspace.composePane == .nameGroup)
        #expect(workspace.newChatName == "Field Notes")
        #expect(workspace.newChatRecipients == [member])

        let returnEvent = try #require(
            NSEvent.keyEvent(
                with: .keyDown,
                location: .zero,
                modifierFlags: [],
                timestamp: 0,
                windowNumber: host.window.windowNumber,
                context: nil,
                characters: "\r",
                charactersIgnoringModifiers: "\r",
                isARepeat: false,
                keyCode: 36
            )
        )
        #expect(!host.window.performKeyEquivalent(with: returnEvent))
        #expect(workspace.composePane == .nameGroup)

        // Header Back (leading control in `ComposePaneHeader` with 12pt horizontal padding and
        // zero titlebar clearance under `hasWindowTopNoticeBand == true`) returns to Choose
        // members while preserving the staged draft.
        host.click(at: CGPoint(x: 24, y: 16))
        #expect(await host.settle { workspace.composePane == .chooseMembers })
        #expect(workspace.isNewChatComposerVisible)
        #expect(workspace.newChatName == "Field Notes")
        #expect(workspace.newChatRecipients == [member])

        // Re-entering Name group and clicking Cancel (bottom-leading of the 340pt sidebar with
        // 12pt padding) closes the composer and discards the draft.
        workspace.composeShowNameGroup()
        _ = await host.settle(timeout: .milliseconds(100)) { false }
        host.click(at: CGPoint(x: 42, y: size.height - 24))
        #expect(await host.settle { !workspace.isNewChatComposerVisible })
        #expect(workspace.newChatName.isEmpty)
        #expect(workspace.newChatRecipients.isEmpty)
    }

    /// Pressing Escape inside `DirectChatChooserSheet` invokes `onCancel` without triggering
    /// `onOpen` or `onStartNew`.
    @Test func directChatChooserSheetEscapeInvokesOnlyCancel() async throws {
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
                )
            ]
        )

        var didOpen = false
        var didStartNew = false
        var didCancel = false
        let host = HostedViewWindow(
            DirectChatChooserSheet(
                presentation: presentation,
                onOpen: { _ in didOpen = true },
                onStartNew: { didStartNew = true },
                onCancel: { didCancel = true }
            ),
            size: CGSize(width: 420, height: 280)
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

        #expect(host.window.performKeyEquivalent(with: escapeEvent))
        #expect(await host.settle { didCancel })
        #expect(!didOpen)
        #expect(!didStartNew)
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

private struct AdjacentConversationPaneProbe: View {
    let onEscape: () -> Void
    @State private var query = "search"

    var body: some View {
        VStack {
            TextField("Search messages", text: $query)
                .textFieldStyle(.roundedBorder)
                .padding()
            Button("Close search", action: onEscape)
                .keyboardShortcut(.cancelAction)
            Spacer()
        }
    }
}
