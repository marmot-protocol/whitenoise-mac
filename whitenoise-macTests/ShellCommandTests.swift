import AppKit
import Testing

@testable import whitenoise_mac

@MainActor
struct ShellCommandTests {
    @Test func onlyTheVisibleMainWindowCanCountAsReadingTheConversation() {
        let main = ShellTestWindow()
        let settings = ShellTestWindow()
        #expect(WorkspaceState.defaultConversationWindowVisibilityProvider(keyWindow: main, conversationWindow: main))
        #expect(
            !WorkspaceState.defaultConversationWindowVisibilityProvider(keyWindow: settings, conversationWindow: main))
        #expect(!WorkspaceState.defaultConversationWindowVisibilityProvider(keyWindow: nil, conversationWindow: main))

        main.minimized = true
        #expect(!WorkspaceState.defaultConversationWindowVisibilityProvider(keyWindow: main, conversationWindow: main))
        main.minimized = false
        main.testVisible = false
        #expect(!WorkspaceState.defaultConversationWindowVisibilityProvider(keyWindow: main, conversationWindow: main))
    }

    @Test func newChatRunsOnlyFromTheFocusedReadyMessenger() throws {
        let workspace = WorkspaceState.preview()
        let accountID = try #require(workspace.activeAccountId)
        let main = ShellTestWindow()
        let settings = ShellTestWindow()
        let modal = ShellTestWindow()
        let focus = CommandFocus(key: settings)
        let commands = MessengerCommandContext(workspace: workspace, accountID: accountID) {
            MessengerCommandContext.acceptsCommands(
                keyWindow: focus.key, messengerWindow: main, modalWindow: focus.modal)
        }

        commands.newChat()
        #expect(!workspace.isNewChatComposerVisible)

        focus.key = main
        focus.modal = modal
        commands.newChat()
        #expect(!workspace.isNewChatComposerVisible)

        focus.modal = nil
        main.testSheet = modal
        commands.newChat()
        #expect(!workspace.isNewChatComposerVisible)

        main.testSheet = nil
        workspace.showAccountOnboarding()
        commands.newChat()
        #expect(!workspace.isNewChatComposerVisible)

        workspace.leaveAccountOnboarding()
        workspace.isChatListVisible = false
        commands.newChat()
        #expect(workspace.isNewChatComposerVisible)
        #expect(workspace.isChatListVisible)
    }

    @Test func staleConversationAndAccountCommandsCannotTargetTheNewSelection() throws {
        let workspace = WorkspaceState.preview()
        let accountID = try #require(workspace.activeAccountId)
        let original = try #require(workspace.selectedChat)
        let commands = MessengerCommandContext(
            workspace: workspace, accountID: accountID, isMessengerWindowTarget: { true })
        #expect(commands.activeChat(matching: original.id)?.id == original.id)

        let other = try #require(workspace.activeChats.first(where: { $0.id != original.id }))
        workspace.selection = .chat(other.id)
        #expect(commands.activeChat(matching: original.id) == nil)
        #expect(commands.activeChat(matching: other.id)?.id == other.id)

        workspace.activeAccountId = try #require(workspace.signedInAccounts.first(where: { $0.id != accountID })).id
        commands.searchAllMessages()
        #expect(!workspace.isGlobalMessageSearchPresented)
        #expect(commands.activeChat(matching: other.id) == nil)
    }

    @Test func restoredSettingsWindowAdoptsActiveAccountAndKeyDeviceLinkHost() throws {
        let workspace = WorkspaceState.preview()
        let activeID = try #require(workspace.activeAccountId)
        let coordinator = SettingsWindowCoordinator(workspace: workspace)
        let window = ShellTestWindow()
        window.key = true

        coordinator.register(window, sheetIsPresented: false)

        #expect(coordinator.accountID == activeID)
        #expect(coordinator.page == .profile)
        #expect(coordinator.hostsDeviceLinkSheet)
        #expect(!window.didClose)
    }

    @Test func restoredSettingsWindowClosesImmediatelyDuringOnboarding() {
        let workspace = WorkspaceState.preview()
        workspace.showAccountOnboarding()
        let coordinator = SettingsWindowCoordinator(workspace: workspace)
        var focusedMain = false
        coordinator.installPresentationActions(showSettings: {}, showMain: { focusedMain = true })
        let window = ShellTestWindow()

        coordinator.register(window, sheetIsPresented: false)

        #expect(coordinator.accountID == nil)
        #expect(!coordinator.hostsDeviceLinkSheet)
        #expect(window.didClose)
        #expect(focusedMain)
    }

    private final class CommandFocus {
        var key: NSWindow
        var modal: NSWindow?

        init(key: NSWindow) {
            self.key = key
        }
    }
}

@MainActor
final class ShellTestWindow: NSWindow {
    var testVisible = true
    var minimized = false
    var key = false
    var didClose = false
    var testSheet: NSWindow?

    override var isVisible: Bool { testVisible }
    override var isMiniaturized: Bool { minimized }
    override var isKeyWindow: Bool { key }
    override var attachedSheet: NSWindow? { testSheet }

    override func close() {
        didClose = true
    }
}
