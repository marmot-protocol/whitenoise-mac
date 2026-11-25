//
//  ContentView.swift
//  whitenoise-mac
//
//  Created by Jeff Gardner on 26/05/2026.
//

import AppKit
import SwiftUI

private struct TimestampReferenceDateKey: EnvironmentKey {
    static let defaultValue = Date()
}

extension EnvironmentValues {
    var timestampReferenceDate: Date {
        get { self[TimestampReferenceDateKey.self] }
        set { self[TimestampReferenceDateKey.self] = newValue }
    }
}

struct ContentView: View {
    @Environment(WorkspaceState.self) private var workspace
    @Environment(SessionState.self) private var session
    @Environment(\.openSettings) private var openSettings
    @Environment(\.openWindow) private var openWindow
    let settings: SettingsWindowCoordinator
    @State private var timestampReferenceDate = Date()

    var body: some View {
        @Bindable var workspace = workspace

        MessengerShellView(settings: settings)
            .background { MainWindowRegistration() }
            // Attached here, not on the conversation pane: a chat-list delete is most likely with
            // no chat selected, and the sidebar row menu cannot host its own dialog.
            .chatDestructiveActionsConfirmation()
            // Group changes made from the panes ask here. Sheets that make one host their own.
            .groupChangeAdvisoryAlert(session.accountScope?.groupChangeAdvisory)
            // A device-link request can arrive whatever the user is looking at, and wants an answer
            // while both screens show the code.
            .deviceLinkSheet(
                settings.hostsDeviceLinkSheet ? nil : currentAccountScope?.deviceLinking,
                locale: workspace.preferredLocale,
                suggestionAllowed: currentAccountScope.map {
                    $0.onboarding.canEnterChats && $0.onboarding.hasShownIncompleteSetup
                } == true
            )
            .deviceUnlinkAlert(
                session.deviceUnlinks,
                accountName: { account(forUnlinked: $0)?.displayName },
                onRemove: { notice in
                    Task {
                        await session.deviceUnlinks.finishLeaving(notice.accountIdHex)
                        let removal = await AccountExit.removeUnlinkedAccount(
                            accountIdHex: notice.accountIdHex, in: workspace)
                        // Didn't go: the notice comes back, so Delete Everything can be tried again.
                        // Otherwise it went, and the report says if anything was left undone.
                        if let account = removal.leftBehind {
                            session.deviceUnlinks.present(account)
                        } else {
                            session.reportWipe(removal.outcome)
                        }
                    }
                },
                onLater: { notice in
                    // The app left the account when the event arrived; this only retries that if it
                    // failed then.
                    if let account = account(forUnlinked: notice), !account.signedOut {
                        Task {
                            await AccountExit.leaveSignedOutAccount(accountIdHex: notice.accountIdHex, in: workspace)
                        }
                    }
                }
            )
            .accountWipeReportAlert(session)
            .profileLinkRequestAlert(session.linkRequests) { request in
                reviewLinkRequest(request)
            }
            // App-wide default: static text is selectable, so anything on screen — a startup
            // failure message, a relay URL, an npub, a profile field — can be selected and
            // copied without the view having to opt in. `.textSelection` propagates through the
            // environment, so this single application covers every descendant.
            //
            // The one deliberate exception is the chat transcript, which re-disables it and
            // re-enables per bubble on hover; see ConversationView (whitenoise-mac#205).
            .textSelection(.enabled)
            .frame(minWidth: 940, minHeight: 620)
            .preferredColorScheme(workspace.preferredColorScheme)
            .environment(\.locale, workspace.preferredLocale)
            .environment(\.timestampReferenceDate, timestampReferenceDate)
            // End Group runs in a per-group model, outside `hasInFlightGroupCommit`; surfaces that
            // start a group commit read this to hold off until it is done.
            .environment(\.endingGroupIds, session.accountScope?.endingGroupIds ?? [])
            // A bulk leave from the chat list publishes one commit per chat; the same surfaces wait
            // it out.
            .environment(\.isBulkLeavingChats, session.accountScope?.chatListSelection.isLeaving == true)
            .environment(
                \.openURL,
                OpenURLAction { url in
                    workspace.handleMessageLinkOpen(url)
                }
            )
            // No blanket `.tint` or `.foregroundStyle` on the window root (F01–F07 / #1034 / #1035):
            // native controls, selection, focus rings, links, and destructive roles keep system
            // semantics, while primary monochrome controls apply scoped `.tint(WNColor.fillPrimary)`
            // and switches apply dark-safe `.tint(WNColor.switchOnTint)`.
            .onOpenURL { url in
                workspace.handleDeepLinkURL(url)
            }
            .onAppear {
                settings.installPresentationActions(
                    showSettings: { openSettings() },
                    showMain: { openWindow(id: whitenoise_macApp.mainWindowID) }
                )
                applyAppearance(workspace.appearancePreference)
            }
            .onChange(of: session.accountScope?.deviceLinking.presentedSheet) {
                settings.updateDeviceLinkHost(
                    sheetIsPresented: session.accountScope?.deviceLinking.presentedSheet != nil)
            }
            .onChange(of: workspace.appearancePreference) { _, preference in
                applyAppearance(preference)
            }
            .onChange(of: workspace.languagePreference) { _, _ in
                workspace.refreshTimelineDisplayItems(
                    referenceDate: timestampReferenceDate,
                    locale: workspace.preferredLocale
                )
            }
            .onReceive(
                NotificationCenter.default.publisher(
                    for: NSLocale.currentLocaleDidChangeNotification
                )
            ) { _ in
                workspace.refreshSystemLanguageIfNeeded()
                workspace.refreshTimelineDisplayItems(
                    referenceDate: timestampReferenceDate,
                    locale: workspace.preferredLocale
                )
            }
            .onReceive(
                NotificationCenter.default.publisher(for: .NSCalendarDayChanged)
            ) { _ in
                refreshTimestampReferenceDate(now: Date())
            }
            .onReceive(
                NotificationCenter.default.publisher(
                    for: NSApplication.didBecomeActiveNotification
                )
            ) { _ in
                let foregroundStartedAt = DispatchTime.now().uptimeNanoseconds
                refreshTimestampReferenceDateIfNeeded()
                workspace.refreshSystemLanguageIfNeeded()
                // The app just regained focus. Flush any read-marking that was deferred
                // while it was in the background so the selected chat clears its unread
                // state now that the user may be looking at it again.
                Task {
                    await workspace.handleConversationVisibilityChange(visibleMessageIds: visibleConversationMessageIds)
                    workspace.recordForegroundLocalReady(since: foregroundStartedAt)
                    await workspace.refreshAccountProfiles()
                }
            }
            .onReceive(
                NotificationCenter.default.publisher(
                    for: NSApplication.willTerminateNotification
                )
            ) { _ in
                workspace.flushComposerDraftPersistenceSynchronouslyForTermination()
            }
            .onReceive(
                NotificationCenter.default.publisher(
                    for: NSWindow.didBecomeKeyNotification
                )
            ) { notification in
                settings.updateDeviceLinkHost(
                    sheetIsPresented: session.accountScope?.deviceLinking.presentedSheet != nil)
                guard ConversationWindowIdentity.matches(notification.object) else { return }
                Task {
                    await workspace.handleConversationVisibilityChange(visibleMessageIds: visibleConversationMessageIds)
                }
            }
            .sheet(isPresented: $workspace.isGlobalMessageSearchPresented) {
                GlobalMessageSearchView()
                    .environment(workspace)
                    .environment(\.locale, workspace.preferredLocale)
            }
            // Presented here rather than from the messenger shell for the same reason as the
            // search sheet: `\.locale` is injected at this root, and a sheet is a separate
            // presentation that does not inherit it, so both have to re-inject it themselves.
            .sheet(isPresented: $workspace.isImprovementsPromptPresented) {
                if let model = session.accountScope?.settingsModel.diagnostics {
                    HelpImproveWhiteNoiseSheet(model: model) {
                        workspace.dismissImprovementsPrompt()
                    }
                    .environment(\.locale, workspace.preferredLocale)
                }
            }
            .onReceive(
                NotificationCenter.default.publisher(
                    for: NSWindow.didDeminiaturizeNotification
                )
            ) { notification in
                guard ConversationWindowIdentity.matches(notification.object) else { return }
                Task {
                    await workspace.handleConversationVisibilityChange(visibleMessageIds: visibleConversationMessageIds)
                }
            }
    }

    private var currentAccountScope: AccountScope? {
        guard workspace.activeAccount?.signedOut == false,
            let scope = session.accountScope, scope.account.id == workspace.activeAccountId
        else { return nil }
        return scope
    }

    /// The open transcript's on-screen messages, so regaining focus marks only what the user can
    /// see. Nil without a projected conversation, which keeps the legacy path marking the latest.
    private var visibleConversationMessageIds: Set<String>? {
        session.accountScope?.selectedConversationModel?.readableMessageIds
    }

    /// Review on another profile's link request: switch to it. Its own `DeviceLinkingViewModel`
    /// reads the request and presents it, so comparing and linking run as that profile.
    private func reviewLinkRequest(_ request: ProfileLinkRequestsMonitor.Request) {
        guard
            let account = workspace.signedInAccounts.first(where: {
                $0.accountIdHex.lowercased() == request.accountIdHex
            })
        else { return }
        workspace.selectAccount(account)
    }

    private func account(forUnlinked notice: DeviceUnlinkMonitor.Notice) -> AccountItem? {
        workspace.accounts.first { $0.accountIdHex.lowercased() == notice.accountIdHex }
    }

    private func applyAppearance(_ preference: AppearancePreference) {
        NativeAppearanceController.apply(preference)
    }

    private func refreshTimestampReferenceDateIfNeeded(now: Date = Date()) {
        guard !Calendar.autoupdatingCurrent.isDate(timestampReferenceDate, inSameDayAs: now) else { return }
        refreshTimestampReferenceDate(now: now)
    }

    private func refreshTimestampReferenceDate(now: Date) {
        timestampReferenceDate = now
        workspace.refreshTimelineDisplayItems(referenceDate: now, locale: workspace.preferredLocale)
    }
}

#Preview {
    let workspace = WorkspaceState.preview()
    ContentView(settings: SettingsWindowCoordinator(workspace: workspace))
        .environment(workspace)
        .environment(SessionState())
}

private struct MainWindowRegistration: NSViewRepresentable {
    func makeNSView(context: Context) -> RegistrationView {
        RegistrationView()
    }

    func updateNSView(_ nsView: RegistrationView, context: Context) {}

    final class RegistrationView: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let window { ConversationWindowIdentity.window = window }
        }
    }
}

#Preview("Main window registration") {
    Color.clear.background { MainWindowRegistration() }
}
