import AppKit
import MarmotKit
import Testing

@testable import whitenoise_mac

@Suite(.serialized)
@MainActor
struct ShellCommandTests: WorkspaceTestSupport {
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

    @Test func settingsErrorsAndMainWindowChatInfoErrorsStayIsolated() {
        let workspace = WorkspaceState.preview()
        let coordinator = SettingsWindowCoordinator(workspace: workspace)
        coordinator.open(at: .notifications)

        // A main-window Chat Info error must never appear in Settings or be cleared by Settings
        // writes, clears, or navigation (even when the text happens to match).
        workspace.lastError = "Couldn't update group name"
        #expect(coordinator.lastError == nil)

        workspace.setSettingsError("Couldn't update group name")
        #expect(coordinator.lastError == "Couldn't update group name")
        #expect(workspace.lastError == "Couldn't update group name")

        workspace.setSettingsError("Notifications are turned off")
        #expect(coordinator.lastError == "Notifications are turned off")
        #expect(workspace.lastError == "Couldn't update group name")

        workspace.setSettingsError(nil)
        #expect(coordinator.lastError == nil)
        #expect(workspace.lastError == "Couldn't update group name")

        workspace.setSettingsError("Couldn't update group name")
        coordinator.navigate(to: .profile)
        #expect(coordinator.lastError == nil)
        #expect(workspace.lastError == "Couldn't update group name")
    }

    @Test func failedRawPrivateKeyExportReportsToSettingsWithoutTouchingMainWindowError() async throws {
        let account = AccountSummaryFfi(
            label: "Desktop Account",
            accountIdHex: String(repeating: "a", count: 64),
            localSigning: true,
            externalSigning: false,
            signedOut: false,
            running: true,
            unlinked: false
        )
        let runtime = FakeMarmotRuntime(accounts: [account])
        runtime.revealNsecError = FakeMarmotRuntimeError.unused
        let workspace = WorkspaceState(
            privateKeyExportDestinationPicker: { _, _ in
                FileManager.default.temporaryDirectory.appendingPathComponent("unused-key.txt")
            },
            clientFactory: { runtime }
        )
        let coordinator = SettingsWindowCoordinator(workspace: workspace)
        await workspace.bootstrap()
        workspace.lastError = "Main window error"

        let exported = await workspace.exportActiveAccountPrivateKey(.raw)

        #expect(!exported)
        #expect(coordinator.lastError != nil)
        #expect(workspace.lastError == "Main window error")
    }

    @Test func beginAddProfileStopsInProgressVoiceRecording() async throws {
        let account = AccountSummaryFfi(
            label: "Desktop Account",
            accountIdHex: String(repeating: "c", count: 64),
            localSigning: true,
            externalSigning: false,
            signedOut: false,
            running: true,
            unlinked: false
        )
        let runtime = FakeMarmotRuntime(accounts: [account])
        let workspace = WorkspaceState(clientFactory: { runtime })
        await workspace.bootstrap()
        let url = try armInProgressVoiceRecording(on: workspace)
        #expect(workspace.isRecordingVoiceMessage)

        let coordinator = SettingsWindowCoordinator(workspace: workspace)
        coordinator.open(at: .profile)
        coordinator.beginAddProfile()

        #expect(workspace.phase == .onboarding)
        #expect(!workspace.isRecordingVoiceMessage)
        #expect(workspace.voiceRecorder == nil)
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    @Test func remoteDeviceUnlinkChooserDoesNotOpenSettingsWhenPickingSurvivor() async throws {
        let first = AccountSummaryFfi(
            label: "First",
            accountIdHex: String(repeating: "1", count: 64),
            localSigning: true,
            externalSigning: false,
            signedOut: false,
            running: true,
            unlinked: false
        )
        let second = AccountSummaryFfi(
            label: "Second",
            accountIdHex: String(repeating: "2", count: 64),
            localSigning: true,
            externalSigning: false,
            signedOut: false,
            running: true,
            unlinked: false
        )
        let third = AccountSummaryFfi(
            label: "Third",
            accountIdHex: String(repeating: "3", count: 64),
            localSigning: true,
            externalSigning: false,
            signedOut: false,
            running: true,
            unlinked: false
        )
        let runtime = FakeMarmotRuntime(accounts: [first, second, third])
        let workspace = WorkspaceState(clientFactory: { runtime })
        await workspace.bootstrap()

        let coordinator = SettingsWindowCoordinator(workspace: workspace)
        var settingsOpens = 0
        coordinator.installPresentationActions(showSettings: { settingsOpens += 1 }, showMain: {})

        let unlinked = try #require(workspace.activeAccount)
        runtime.unlinkFromAnotherDevice(accountRef: unlinked.accountRef)
        await AccountExit.leaveSignedOutAccount(
            accountIdHex: unlinked.accountIdHex.lowercased(),
            in: workspace
        )
        #expect(workspace.activeAccountId == nil)
        #expect(settingsOpens == 0)

        let survivor = try #require(workspace.signedInAccounts.first)
        workspace.selectAccountFromSettings(survivor)
        #expect(workspace.activeAccountId == survivor.id)
        #expect(settingsOpens == 0)
    }

    @Test func removingActiveProfileWhileSwitchedToAnotherProfilePreservesNewActiveSession() async throws {
        let previousActiveAccount = UserDefaults.standard.object(forKey: WorkspaceState.activeAccountKey)
        defer { restoreDefault(previousActiveAccount, forKey: WorkspaceState.activeAccountKey) }
        UserDefaults.standard.set("First", forKey: WorkspaceState.activeAccountKey)

        let first = AccountSummaryFfi(
            label: "First",
            accountIdHex: String(repeating: "4", count: 64),
            localSigning: true,
            externalSigning: false,
            signedOut: false,
            running: true,
            unlinked: false
        )
        let second = AccountSummaryFfi(
            label: "Second",
            accountIdHex: String(repeating: "5", count: 64),
            localSigning: true,
            externalSigning: false,
            signedOut: false,
            running: true,
            unlinked: false
        )
        let runtime = FakeMarmotRuntime(accounts: [first, second])
        let gate = AsyncFfiGate()
        gate.isEnabled = true
        runtime.onRemoveAccountMidFlight = { _ in await gate.passIfArmed() }
        let workspace = WorkspaceState(clientFactory: { runtime })
        await workspace.bootstrap()

        let coordinator = SettingsWindowCoordinator(workspace: workspace)
        var settingsOpens = 0
        coordinator.installPresentationActions(showSettings: { settingsOpens += 1 }, showMain: {})

        let firstAccount = try #require(workspace.accounts.first { $0.id == "First" })
        let secondAccount = try #require(workspace.accounts.first { $0.id == "Second" })
        try #require(workspace.activeAccountId == firstAccount.id)

        let removal = Task { await workspace.removeAccount(firstAccount) }
        await gate.waitUntilReached()

        workspace.switchActiveAccount(secondAccount, finalSelection: .chat("second-chat"))
        #expect(workspace.activeAccountId == secondAccount.id)
        #expect(workspace.selection == .chat("second-chat"))
        let recordingURL = try armInProgressVoiceRecording(on: workspace)
        defer { workspace.cancelVoiceRecording() }
        #expect(workspace.isRecordingVoiceMessage)

        gate.release()
        _ = await removal.value

        #expect(workspace.activeAccountId == secondAccount.id)
        #expect(workspace.selection == .chat("second-chat"))
        #expect(workspace.isRecordingVoiceMessage)
        #expect(FileManager.default.fileExists(atPath: recordingURL.path))
        #expect(settingsOpens == 0)
    }

    @Test func coldLaunchRestoredSettingsWindowWaitsForBootstrapAndAdoptsReadyAccount() async throws {
        let account = AccountSummaryFfi(
            label: "Desktop Account",
            accountIdHex: String(repeating: "7", count: 64),
            localSigning: true,
            externalSigning: false,
            signedOut: false,
            running: true,
            unlinked: false
        )
        let runtime = FakeMarmotRuntime(accounts: [account])
        let workspace = WorkspaceState(clientFactory: { runtime })
        try #require(workspace.phase == .bootstrapping)

        let coordinator = SettingsWindowCoordinator(workspace: workspace)
        let window = ShellTestWindow()
        window.key = true
        coordinator.register(window, sheetIsPresented: false)

        #expect(!window.didClose)
        #expect(coordinator.accountID == nil)

        await workspace.bootstrap()
        coordinator.synchronize()

        let activeID = try #require(workspace.activeAccountId)
        #expect(!window.didClose)
        #expect(coordinator.accountID == activeID)
        #expect(coordinator.hostsDeviceLinkSheet)
    }

    @Test func coldLaunchRestoredSettingsWindowClosesWhenStartupResolvesToOnboarding() async throws {
        let runtime = FakeMarmotRuntime(accounts: [])
        let workspace = WorkspaceState(clientFactory: { runtime })
        try #require(workspace.phase == .bootstrapping)

        let coordinator = SettingsWindowCoordinator(workspace: workspace)
        var focusedMain = false
        coordinator.installPresentationActions(showSettings: {}, showMain: { focusedMain = true })
        let window = ShellTestWindow()
        coordinator.register(window, sheetIsPresented: false)
        #expect(!window.didClose)

        await workspace.bootstrap()
        coordinator.synchronize()

        #expect(workspace.phase == .onboarding)
        #expect(window.didClose)
        #expect(coordinator.accountID == nil)
        #expect(focusedMain)
    }

    @Test func settingsErrorsClearOnAccountSwitchAndDropLateErrorsFromPreviousAccount() async throws {
        let first = AccountSummaryFfi(
            label: "First",
            accountIdHex: String(repeating: "8", count: 64),
            localSigning: true,
            externalSigning: false,
            signedOut: false,
            running: true,
            unlinked: false
        )
        let second = AccountSummaryFfi(
            label: "Second",
            accountIdHex: String(repeating: "9", count: 64),
            localSigning: true,
            externalSigning: false,
            signedOut: false,
            running: true,
            unlinked: false
        )
        let runtime = FakeMarmotRuntime(accounts: [first, second])
        let workspace = WorkspaceState(clientFactory: { runtime })
        await workspace.bootstrap()

        let firstAccount = try #require(workspace.accounts.first { $0.id == "First" })
        let secondAccount = try #require(workspace.accounts.first { $0.id == "Second" })
        workspace.switchActiveAccount(firstAccount, finalSelection: nil)

        let coordinator = SettingsWindowCoordinator(workspace: workspace)
        coordinator.open(at: .notifications)
        workspace.setSettingsError("First profile notification error", accountId: firstAccount.id)
        #expect(coordinator.lastError == "First profile notification error")

        // Switching to profile B clears profile A's Settings error.
        workspace.switchActiveAccount(secondAccount, finalSelection: nil)
        coordinator.synchronize()
        #expect(coordinator.accountID == secondAccount.id)
        #expect(coordinator.lastError == nil)

        // A delayed failure owned by profile A must not surface under profile B.
        workspace.setSettingsError("Delayed first profile key export error", accountId: firstAccount.id)
        #expect(coordinator.lastError == nil)

        // An error owned by the current profile B still surfaces normally.
        workspace.setSettingsError("Second profile error", accountId: secondAccount.id)
        #expect(coordinator.lastError == "Second profile error")
    }

    @Test func remoteUnlinkRemovalFailureReportsToMainWindowError() async throws {
        let account = AccountSummaryFfi(
            label: "Unlinked",
            accountIdHex: String(repeating: "b", count: 64),
            localSigning: true,
            externalSigning: false,
            signedOut: false,
            running: true,
            unlinked: false
        )
        let runtime = FakeMarmotRuntime(accounts: [account])
        runtime.removeAccountError = FakeMarmotRuntimeError.unused
        let workspace = WorkspaceState(clientFactory: { runtime })
        await workspace.bootstrap()
        let coordinator = SettingsWindowCoordinator(workspace: workspace)

        let target = try #require(workspace.activeAccount)
        runtime.unlinkFromAnotherDevice(accountRef: target.accountRef)
        let removal = await AccountExit.removeUnlinkedAccount(
            accountIdHex: target.accountIdHex.lowercased(),
            in: workspace
        )

        #expect(removal.leftBehind?.id == target.id)
        #expect(workspace.lastError != nil)
        #expect(coordinator.lastError == nil)
    }

    @Test func notificationClickFocusesMainWindowAndCancelsAddProfileReturn() async throws {
        let workspace = WorkspaceState.preview()
        let coordinator = SettingsWindowCoordinator(workspace: workspace)
        var settingsOpens = 0
        var mainFocuses = 0
        coordinator.installPresentationActions(
            showSettings: { settingsOpens += 1 },
            showMain: { mainFocuses += 1 }
        )

        coordinator.open(at: .profile)
        #expect(settingsOpens == 1)

        // Start Add Profile from Settings, then click a notification targeting a chat.
        coordinator.beginAddProfile()
        #expect(workspace.phase == .onboarding)
        let focusCountBeforeNotification = mainFocuses

        let chat = try #require(workspace.activeChats.first)
        let account = try #require(workspace.activeAccount)
        let router = NotificationResponseRouter(workspace: workspace, onboarding: { nil })
        router.route(["accountIdHex": account.accountIdHex, "groupIdHex": chat.id])

        #expect(workspace.phase == .ready)
        #expect(mainFocuses > focusCountBeforeNotification)
        // Must NOT reopen Settings after navigating from a notification click.
        #expect(settingsOpens == 1)
    }

    @Test func remoteDeviceUnlinkDoesNotPopSettingsOverAlert() async throws {
        let first = AccountSummaryFfi(
            label: "First",
            accountIdHex: String(repeating: "1", count: 64),
            localSigning: true,
            externalSigning: false,
            signedOut: false,
            running: true,
            unlinked: false
        )
        let second = AccountSummaryFfi(
            label: "Second",
            accountIdHex: String(repeating: "2", count: 64),
            localSigning: true,
            externalSigning: false,
            signedOut: false,
            running: true,
            unlinked: false
        )
        let runtime = FakeMarmotRuntime(accounts: [first, second])
        let workspace = WorkspaceState(clientFactory: { runtime })
        await workspace.bootstrap()

        let coordinator = SettingsWindowCoordinator(workspace: workspace)
        var settingsOpens = 0
        coordinator.installPresentationActions(showSettings: { settingsOpens += 1 }, showMain: {})

        let unlinked = try #require(workspace.activeAccount)
        runtime.unlinkFromAnotherDevice(accountRef: unlinked.accountRef)
        await AccountExit.leaveSignedOutAccount(
            accountIdHex: unlinked.accountIdHex.lowercased(),
            in: workspace
        )

        #expect(settingsOpens == 0)
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
