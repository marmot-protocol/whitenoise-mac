import AppKit
import SwiftUI

struct SettingsWindowView: View {
    let coordinator: SettingsWindowCoordinator
    let workspace: WorkspaceState
    let session: SessionState

    @Environment(\.openSettings) private var openSettings
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Group {
            if workspace.showsMessengerChrome,
                let scope = session.accountScope,
                scope.account.id == workspace.activeAccountId,
                scope.account.id == coordinator.accountID
            {
                NavigationSplitView {
                    SettingsListDrawerView(coordinator: coordinator)
                        .navigationSplitViewColumnWidth(min: 250, ideal: 270, max: 300)
                } detail: {
                    SettingsPanelView(
                        model: scope.settingsModel, deviceLinking: scope.deviceLinking, page: coordinator.page)
                }
                .deviceLinkSheet(
                    coordinator.hostsDeviceLinkSheet ? scope.deviceLinking : nil,
                    locale: workspace.preferredLocale,
                    suggestionAllowed: scope.onboarding.canEnterChats && scope.onboarding.hasShownIncompleteSetup
                )
                .id(scope.account.id)
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
        .onChange(of: workspace.showsMessengerChrome, initial: true) { coordinator.synchronize() }
        .onChange(of: workspace.activeAccountId) { coordinator.synchronize() }
        .onChange(of: workspace.developerMode) { coordinator.synchronize() }
        .onChange(of: workspace.signedInAccounts.map(\.id)) { coordinator.synchronize() }
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
        // forward when a Settings action produces a report or an unlink arrives.
        .onChange(of: session.wipeReportToShow) {
            if session.wipeReportToShow != nil { coordinator.focusMainWindow() }
        }
        .onChange(of: session.deviceUnlinks.notice) {
            if session.deviceUnlinks.notice != nil { coordinator.focusMainWindow() }
        }
        .onChange(of: session.linkRequests.alert) {
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
            if let window { coordinator.register(window, sheetIsPresented: sheetIsPresented) }
        }
    }
}

#Preview("Settings window") {
    let workspace = WorkspaceState.preview()
    let coordinator = SettingsWindowCoordinator(workspace: workspace)
    SettingsWindowView(coordinator: coordinator, workspace: workspace, session: SessionState())
}

#Preview("Settings window registration") {
    Color.clear.background {
        SettingsWindowRegistration(
            coordinator: SettingsWindowCoordinator(workspace: .preview()), sheetIsPresented: false)
    }
}
