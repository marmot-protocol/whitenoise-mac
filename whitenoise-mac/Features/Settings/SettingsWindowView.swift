import AppKit
import SwiftUI

struct SettingsWindowView: View {
    let coordinator: SettingsWindowCoordinator
    let workspace: WorkspaceState
    let session: SessionState

    @Environment(\.openSettings) private var openSettings
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        ZStack {
            Color.clear
            if workspace.showsMessengerChrome,
                let scope = session.accountScope,
                let account = workspace.activeAccount,
                scope.account.id == account.id,
                scope.account.id == coordinator.accountID
            {
                NavigationSplitView {
                    SettingsSidebarView(
                        coordinator: coordinator,
                        account: account,
                        devicesAvailable: scope.deviceLinking.isAvailable,
                        isAccountMutationInProgress: workspace.isAccountMutationInProgress,
                        preferredLocale: workspace.preferredLocale
                    )
                    .navigationSplitViewColumnWidth(min: 250, ideal: 270, max: 300)
                } detail: {
                    SettingsPanelView(
                        model: scope.settingsModel, deviceLinking: scope.deviceLinking, page: coordinator.page
                    )
                    .safeAreaInset(edge: .top, spacing: 0) {
                        if workspace.isOffline { OfflineNoticeBand() }
                    }
                }
                .navigationTitle(coordinator.page.title(in: workspace.preferredLocale))
                .deviceLinkSheet(
                    coordinator.hostsDeviceLinkSheet ? scope.deviceLinking : nil,
                    profileName: account.displayName,
                    locale: workspace.preferredLocale,
                    suggestionAllowed: scope.onboarding.canEnterChats && scope.onboarding.hasShownIncompleteSetup
                )
                .id(scope.account.id)
                .task(id: scope.account.id) {
                    scope.productAnalytics.record(.screen(.settings))
                }
            }
        }
        .background {
            SettingsWindowRegistration(
                coordinator: coordinator,
                sheetIsPresented: session.accountScope?.deviceLinking.presentedSheet != nil
            )
        }
        .frame(minWidth: 760, minHeight: 620)
        .environment(workspace)
        .environment(session)
        .environment(\.locale, workspace.preferredLocale)
        .environment(coordinator)
        .environment(\.endingGroupIds, session.accountScope?.endingGroupIds ?? [])
        .environment(\.isBulkLeavingChats, session.accountScope?.chatListSelection.isLeaving == true)
        .environment(\.openURL, OpenURLAction { workspace.handleMessageLinkOpen($0) })
        .preferredColorScheme(workspace.preferredColorScheme)
        .textSelection(.enabled)
        .onAppear {
            coordinator.installPresentationActions(
                showSettings: { openSettings() },
                showMain: { openWindow(id: whitenoise_macApp.mainWindowID) }
            )
        }
        .onReceive(
            NotificationCenter.default.publisher(for: NSWindow.willCloseNotification), perform: coordinator.didClose
        )
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in
            coordinator.updateDeviceLinkHost(
                sheetIsPresented: session.accountScope?.deviceLinking.presentedSheet != nil)
        }
        .onChange(of: session.accountScope?.deviceLinking.presentedSheet) {
            coordinator.updateDeviceLinkHost(
                sheetIsPresented: session.accountScope?.deviceLinking.presentedSheet != nil)
        }
        // These account-wide notices have a single host in the main window. Bring their host
        // forward when a Settings action produces a report or an unlink/link request is pending.
        .onChange(of: session.wipeReportToShow, initial: true) {
            if session.wipeReportToShow != nil { coordinator.focusMainWindow() }
        }
        .onChange(of: session.deviceUnlinks.notice, initial: true) {
            if session.deviceUnlinks.notice != nil { coordinator.focusMainWindow() }
        }
        .onChange(of: session.linkRequests.alert, initial: true) {
            if session.linkRequests.alert != nil { coordinator.focusMainWindow() }
        }
    }
}

private struct SettingsWindowRegistration: NSViewRepresentable {
    let coordinator: SettingsWindowCoordinator
    let sheetIsPresented: Bool

    func makeNSView(context: Context) -> RegistrationView {
        RegistrationView(coordinator: coordinator, sheetIsPresented: sheetIsPresented)
    }

    func updateNSView(_ nsView: RegistrationView, context: Context) {
        nsView.sheetIsPresented = sheetIsPresented
    }

    final class RegistrationView: NSView {
        let coordinator: SettingsWindowCoordinator
        var sheetIsPresented: Bool

        init(coordinator: SettingsWindowCoordinator, sheetIsPresented: Bool) {
            self.coordinator = coordinator
            self.sheetIsPresented = sheetIsPresented
            super.init(frame: .zero)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            NotificationCenter.default.removeObserver(self, name: NSWindow.didBecomeKeyNotification, object: nil)
            guard let window else { return }
            coordinator.register(window, sheetIsPresented: sheetIsPresented)
            NotificationCenter.default.addObserver(
                self, selector: #selector(windowBecameKey), name: NSWindow.didBecomeKeyNotification, object: window)
        }

        @objc private func windowBecameKey() {
            if let window { coordinator.register(window, sheetIsPresented: sheetIsPresented) }
        }
    }
}

#if DEBUG
    #Preview("Settings window") {
        let workspace = WorkspaceState.preview()
        let coordinator = SettingsWindowCoordinator(workspace: workspace)
        let session = SessionState()
        SettingsWindowView(coordinator: coordinator, workspace: workspace, session: session)
            .task {
                await session.activate(
                    account: workspace.activeAccount,
                    runtime: FakeMarmotRuntime(
                        accounts: [], storageRootPath: URL.temporaryDirectory.appending(path: UUID().uuidString).path),
                    connectivityAvailable: false
                )
                coordinator.open(show: {})
            }
    }

#endif

#Preview("Settings window registration") {
    Color.clear.background {
        SettingsWindowRegistration(
            coordinator: SettingsWindowCoordinator(workspace: .preview()), sheetIsPresented: false)
    }
}
