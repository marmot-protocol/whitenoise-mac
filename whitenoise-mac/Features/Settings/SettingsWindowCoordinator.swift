import AppKit
import Combine
import Observation

/// Routes Settings for the current workspace. An account's form and sheet state lives in
/// the Settings scene and is discarded when its account changes.
@MainActor
@Observable
final class SettingsWindowCoordinator {
    private(set) var page: SettingsPage = .profile
    private(set) var accountID: String?
    private(set) var pendingPage: SettingsPage?
    private(set) var hostsDeviceLinkSheet = false
    /// Settings-owned error text so Settings and main-window Chat Info never clobber or display
    /// each other's failures.
    private(set) var lastError: String?

    var parentPage: SettingsPage { page == .overview ? .profile : page.drawerPage }

    private var interruptedPage: SettingsPage?
    private var addProfileReturn: AddProfileReturn?
    @ObservationIgnored private weak var workspace: WorkspaceState?
    @ObservationIgnored private weak var window: NSWindow?
    @ObservationIgnored private var handoffs: AnyCancellable?
    @ObservationIgnored private var showWindow: (() -> Void)?
    @ObservationIgnored private var showMainWindow: (() -> Void)?

    private struct AddProfileReturn {
        let accountID: String
        let page: SettingsPage
    }

    init(workspace: WorkspaceState) {
        self.workspace = workspace
        handoffs = NotificationCenter.default.publisher(for: .workspaceAccountPresentation)
            .sink { [weak self, weak workspace] notification in
                guard let self, let workspace, notification.object as? WorkspaceState === workspace,
                    let event = notification.userInfo?[WorkspaceAccountPresentation.eventKey]
                        as? WorkspaceAccountPresentation
                else { return }

                switch event {
                case .settingsHandoff:
                    self.routeAccountMutation()
                case .cancelledAddProfile:
                    self.returnFromAddProfile()
                case .focusMainWindow:
                    self.addProfileReturn = nil
                    self.focusMainWindow()
                case .settingsError(let message):
                    self.lastError = message
                case .clearSettingsErrorIfEquals(let expected):
                    if self.lastError == expected {
                        self.lastError = nil
                    }
                }
            }
    }

    func installPresentationActions(showSettings: @escaping () -> Void, showMain: @escaping () -> Void) {
        showWindow = showSettings
        showMainWindow = showMain
    }

    func register(_ window: NSWindow, sheetIsPresented: Bool = false) {
        self.window = window
        adoptVisibleWindow()
        updateDeviceLinkHost(sheetIsPresented: sheetIsPresented)
    }

    func didClose(_ notification: Notification) {
        guard let closed = notification.object as? NSWindow, closed === window else { return }
        window = nil
        accountID = nil
        hostsDeviceLinkSheet = false
    }

    func updateDeviceLinkHost(sheetIsPresented: Bool) {
        // A sheet already on screen stays on its originating window.
        guard !sheetIsPresented else { return }
        hostsDeviceLinkSheet = accountID != nil && window?.isKeyWindow == true
    }

    func focusMainWindow() {
        showMainWindow?()
    }

    func open(at destination: SettingsPage? = nil, show: (() -> Void)? = nil) {
        guard let workspace, workspace.showsMessengerChrome, let account = workspace.activeAccount else { return }
        if let destination {
            navigate(to: destination)
        } else if accountID == nil {
            navigate(to: .profile)
        }
        accountID = account.id
        interruptedPage = nil
        (show ?? showWindow)?()
    }

    func navigate(to destination: SettingsPage) {
        guard let workspace, workspace.showsMessengerChrome else { return }
        page = availablePage(destination, developerModeEnabled: workspace.developerMode)
        lastError = nil
    }

    func beginAddProfile() {
        guard let workspace, workspace.showsMessengerChrome, let accountID,
            accountID == workspace.activeAccountId
        else { return }
        addProfileReturn = AddProfileReturn(accountID: accountID, page: page)
        close()
        workspace.showAccountOnboarding()
        focusMainWindow()
    }

    /// Called when the account, readiness, or available destinations change. A disappearing
    /// account removes its forms immediately, even if the account mutation is still finishing.
    func synchronize() {
        guard let workspace else { return }
        if let origin = addProfileReturn,
            !workspace.signedInAccounts.contains(where: { $0.id == origin.accountID })
                || workspace.phase == .ready
        {
            addProfileReturn = nil
        }
        if workspace.signedInAccounts.isEmpty {
            pendingPage = nil
            interruptedPage = nil
        }
        guard workspace.showsMessengerChrome, let activeID = workspace.activeAccount?.id else {
            if accountID != nil || window != nil {
                if accountID != nil, !workspace.signedInAccounts.isEmpty { interruptedPage = page }
                close()
                focusMainWindow()
            }
            return
        }
        // Switching via the chooser delivers its route synchronously. Reaching a ready account
        // through another path (for example, adding a profile from the chooser) consumes the chooser.
        pendingPage = nil
        interruptedPage = nil
        if let accountID, accountID != activeID {
            page = page.pageAfterActiveAccountChange
            self.accountID = activeID
        }
        page = availablePage(page, developerModeEnabled: workspace.developerMode)
    }

    /// Reconciles a Settings window opened directly by AppKit (e.g. macOS window restoration)
    /// without going through `open(at:show:)`.
    private func adoptVisibleWindow() {
        guard let workspace else { return }
        guard workspace.showsMessengerChrome, let activeID = workspace.activeAccount?.id else {
            close()
            focusMainWindow()
            return
        }
        guard accountID == nil else { return }
        page = availablePage(pendingPage ?? page, developerModeEnabled: workspace.developerMode)
        pendingPage = nil
        interruptedPage = nil
        accountID = activeID
    }

    private func close() {
        accountID = nil
        hostsDeviceLinkSheet = false
        lastError = nil
        window?.close()
    }

    private func routeAccountMutation() {
        guard let workspace else { return }
        let destination =
            pendingPage ?? (accountID == nil ? interruptedPage : page)?.pageAfterActiveAccountChange
        interruptedPage = nil

        if workspace.showsMessengerChrome {
            pendingPage = nil
            // Only resume Settings when a Settings window or pending chooser handoff originated the
            // mutation. Choosing a survivor after a remote unlink has no pending Settings route and
            // must not open Settings over the main window.
            guard let destination else { return }
            // Preserve errors from the account operation. Page changes initiated in the Settings
            // window clear the old form's error, while a handoff may carry one for the survivor.
            page = availablePage(destination, developerModeEnabled: workspace.developerMode)
            accountID = workspace.activeAccount?.id
            showWindow?()
        } else if workspace.phase == .ready, !workspace.signedInAccounts.isEmpty {
            pendingPage = destination ?? .overview
            close()
            focusMainWindow()
        } else {
            pendingPage = nil
        }
    }

    private func returnFromAddProfile() {
        defer { addProfileReturn = nil }
        guard let workspace, let origin = addProfileReturn,
            workspace.activeAccountId == origin.accountID,
            workspace.signedInAccounts.contains(where: { $0.id == origin.accountID })
        else { return }
        open(at: origin.page)
    }

    private func availablePage(_ destination: SettingsPage, developerModeEnabled: Bool) -> SettingsPage {
        if !developerModeEnabled, destination == .keyPackages || destination == .quarantinedGroups {
            return .developerMode
        }
        return destination
    }
}
