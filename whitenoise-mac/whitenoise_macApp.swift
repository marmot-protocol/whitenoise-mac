//
//  whitenoise_macApp.swift
//  whitenoise-mac
//
//  Created by Jeff Gardner on 26/05/2026.
//

import AppKit
import Combine
import MarmotKit
import SwiftUI

/// App-lifetime lifecycle bridge for events that must still fire when the messenger window is
/// closed while the Settings window remains open: tearing down active conversation work (such as
/// voice recording) when the messenger window closes, and flushing pending composer drafts on
/// application termination.
@MainActor
final class AppLifecycleObserver {
    private var cancellables: Set<AnyCancellable> = []

    init(workspace: WorkspaceState, center: NotificationCenter = .default) {
        center.publisher(for: NSWindow.willCloseNotification)
            .sink { [weak workspace] notification in
                guard ConversationWindowIdentity.matches(notification.object) else { return }
                workspace?.leaveActiveConversation()
            }
            .store(in: &cancellables)

        center.publisher(for: NSApplication.willTerminateNotification)
            .sink { [weak workspace] _ in
                workspace?.flushComposerDraftPersistenceSynchronouslyForTermination()
            }
            .store(in: &cancellables)
    }
}

@main
struct whitenoise_macApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @State private var workspace: WorkspaceState
    @State private var session: SessionState
    @State private var settings: SettingsWindowCoordinator
    @State private var dockBadge = DockBadgeController()
    @State private var accountUpdate: Task<Void, Never>?
    @State private var linkRequestsObservation: Task<Void, Never>?
    @State private var unlinksObservation: Task<Void, Never>?
    /// Answers clicks on the app's banners. Installed over the workspace's own handler, which
    /// only knows the messenger; see `NotificationResponseRouter`.
    private let notificationResponses: NotificationResponseRouter
    private let lifecycleObserver: AppLifecycleObserver
    private let isUIFixture: Bool
    private let isUnitTestHost: Bool

    static let mainWindowID = "main"

    init() {
        let configuration = AppLaunchConfiguration.current
        let workspace = configuration.makeWorkspace()
        let session = SessionState()
        _workspace = State(initialValue: workspace)
        _session = State(initialValue: session)
        _settings = State(initialValue: SettingsWindowCoordinator(workspace: workspace))
        let notificationResponses = NotificationResponseRouter(workspace: workspace) { [weak session] in
            session?.accountScope?.onboarding
        }
        workspace.localNotificationCenter.setResponseHandler { [weak notificationResponses] userInfo in
            notificationResponses?.route(userInfo)
        }
        self.notificationResponses = notificationResponses
        self.lifecycleObserver = AppLifecycleObserver(workspace: workspace)
        isUIFixture = configuration.isUIFixture
        isUnitTestHost = configuration.isUnitTestHost
    }

    var body: some Scene {
        // The messenger keeps its single window and its existing selection, drafts and session.
        Window("White Noise", id: Self.mainWindowID) {
            ContentView(settings: settings)
                .environment(workspace)
                .environment(session)
                .task {
                    guard !isUnitTestHost else { return }
                    // Started before the bootstrap it runs alongside, not after: a cold start with
                    // no network is exactly when the offline notice has something to say, and
                    // bootstrap is the part that will be sitting there waiting on relays. A UI
                    // fixture skips it: its runtime is in memory, so it watches no network.
                    if !isUIFixture {
                        workspace.startConnectivityMonitoring()
                    }
                    await workspace.bootstrap()
                    let restoredAccountIdHex = workspace.activeAccount?.accountIdHex
                    await synchronizeAccountScope()
                    // A pending answer is asked for at launch too, as on iOS: a MarmotKit update
                    // that widens what diagnostics covers puts a yes back to pending, and that Mac
                    // would otherwise stop sharing unasked. Only now: the sheet draws the account
                    // scope's diagnostics model, which `synchronizeAccountScope()` installs.
                    await workspace.presentImprovementsPromptIfNeeded(forEnteredAccountIdHex: restoredAccountIdHex)
                }
                // Keyed on the messenger being on screen, not on `activeAccountId`: launch restores
                // the saved id before bootstrap loads the accounts and then keeps it, so a task on
                // the id would run only while nothing could be asked and never again. Waiting for
                // the messenger also keeps the one-time system prompt off the splash screen and
                // account setup, where a reflexive "Don't Allow" would be permanent.
                .task(id: workspace.showsMessengerChrome ? workspace.activeAccount?.id : nil) {
                    await requestNotificationPermissionIfUndetermined()
                }
                .task(id: workspace.selectedChat?.id) {
                    await synchronizeConversationProjection()
                }
                .onChange(of: scenePhase) { _, phase in
                    let activity: ProductAnalyticsActivityFfi?
                    switch phase {
                    case .active:
                        activity = .foreground
                    case .background:
                        activity = .background
                    case .inactive:
                        activity = nil
                    @unknown default:
                        activity = nil
                    }
                    guard let activity else { return }
                    Task { await session.updateProductAnalyticsActivity(activity) }
                }
        }
        .windowToolbarStyle(.unified)
        .windowResizability(.contentMinSize)
        // Account lifetime belongs to the app scene, including when Settings is the only open
        // window. Both windows use the same scope and observe the same account event streams.
        .onChange(of: workspace.phase) {
            settings.synchronize()
            notificationResponses.phaseDidChange()
        }
        .onChange(of: workspace.showsMessengerChrome, initial: true) { settings.synchronize() }
        .onChange(of: workspace.isOffline, initial: true) {
            session.updateConnectivity(available: !workspace.isOffline)
        }
        .onChange(of: workspace.developerMode) { settings.synchronize() }
        .onChange(of: workspace.signedInAccounts.map(\.id)) { settings.synchronize() }
        .onChange(of: applicationBadgeCount, initial: true) { _, count in
            dockBadge.apply(count: count)
        }
        .onChange(of: workspace.activeAccountId) { previousAccountId, _ in
            settings.synchronize()
            // Clear the old account's badge before the replacement scope can publish its total.
            dockBadge.activeAccountDidChange(
                from: previousAccountId,
                signedInAccountIds: Set(workspace.signedInAccounts.map(\.id))
            )
            accountUpdate?.cancel()
            accountUpdate = Task {
                guard !Task.isCancelled else { return }
                await synchronizeAccountScope()
            }
        }
        .onChange(of: runtimeIdentity, initial: true) {
            unlinksObservation?.cancel()
            guard let client = workspace.client else { return }
            unlinksObservation = Task { [weak workspace, weak session] in
                await session?.deviceUnlinks.observe(client) { [weak workspace] accountID in
                    guard let workspace else { return }
                    await AccountExit.leaveSignedOutAccount(accountIdHex: accountID, in: workspace)
                }
            }
        }
        .onChange(of: LinkRequestsObserveKey(runtime: runtimeIdentity, signedIn: workspace.signedInAccounts.map(\.id)))
        {
            linkRequestsObservation?.cancel()
            guard let client = workspace.client else { return }
            linkRequestsObservation = Task { [weak workspace, weak session] in
                await session?.linkRequests.observe(client, accounts: { workspace?.signedInAccounts ?? [] })
            }
        }
        .onChange(
            of: LinkRequestAlertKey(
                pending: session.linkRequests.pending,
                active: workspace.activeAccountId,
                showing: session.linkRequests.alert != nil
            )
        ) {
            session.linkRequests.presentIfNeeded(
                activeAccountIdHex: workspace.activeAccount?.accountIdHex, accounts: workspace.signedInAccounts)
        }
        .onChange(of: workspace.accounts.filter(\.unlinked).map(\.accountIdHex), initial: true) {
            session.deviceUnlinks.remind(about: workspace.accounts)
        }
        .commands {
            CommandGroup(replacing: .appSettings) {
                SettingsCommandButton(
                    isEnabled: workspace.showsMessengerChrome,
                    locale: workspace.preferredLocale,
                    coordinator: settings
                )
            }
            MessengerCommands(
                locale: workspace.preferredLocale, endingGroupIDs: session.accountScope?.endingGroupIds ?? [])
        }

        Settings {
            SettingsWindowView(coordinator: settings, workspace: workspace, session: session)
        }
    }

    private var runtimeIdentity: ObjectIdentifier? {
        workspace.client.map { ObjectIdentifier($0 as AnyObject) }
    }

    private var applicationBadgeCount: Int? {
        session.applicationBadgeCount(hasSignedInAccounts: !workspace.signedInAccounts.isEmpty)
    }

    /// Without notification permission macOS never draws the app-icon badge, so ask once the
    /// messenger is showing (see `NotificationPermissionPrompt`). Never from a UI fixture or a unit-test host:
    /// both run this shell, and a system prompt would sit over the window they drive.
    @MainActor
    private func requestNotificationPermissionIfUndetermined() async {
        guard !isUIFixture,
            !isUnitTestHost,
            workspace.showsMessengerChrome,
            await NotificationPermissionPrompt.requestIfUndetermined(using: workspace.localNotificationCenter) != nil
        else { return }
        dockBadge.permissionDidChange()
        await workspace.refreshNotificationAuthorizationStatus()
    }

    @MainActor
    private func synchronizeAccountScope() async {
        let activatingAccountID = workspace.activeAccountId
        await session.activate(
            account: workspace.activeAccount,
            runtime: workspace.client,
            connectivityAvailable: !workspace.isOffline,
            relayListsDidChange: { [weak workspace] in
                guard let workspace, let accountID = activatingAccountID else { return }
                workspace.peerProfileLookupRelaysByAccountId[accountID] = nil
            },
            // Manage Storage removed attachments MDK holds; the host's decrypted copies of them
            // would otherwise keep showing as downloaded. Open conversations re-read through MDK.
            attachmentsDidChange: { [weak workspace] in
                await workspace?.clearMediaCache()
            },
            // Settings → Delete Profile.
            removeAccount: DeleteProfileRemoval.remover(for: workspace, session: session),
            // End Group runs in its own model but still has to respect, and refresh, the legacy
            // group-details and chat-list state the workspace owns.
            groupDisbandHooks: GroupDisbandHooks(
                isOtherGroupCommitInFlight: { [weak workspace] in
                    workspace?.hasInFlightGroupCommit ?? false
                },
                groupDetailsDidChange: { [weak workspace] in
                    await workspace?.reloadSelectedGroupDetails()
                },
                chatListDidChange: { [weak workspace] in
                    await workspace?.reloadChats(forceFreshSnapshot: true)
                }
            ),
            // A bulk action from the chat-list selection ran against MDK directly; bring the
            // legacy chat state along, as each single-row action does after its own mutation.
            chatsDidChange: { [weak workspace] changes in
                guard let workspace, let accountID = activatingAccountID,
                    workspace.activeAccountId == accountID
                else { return }
                let removed = changes.removedGroupIds
                for groupIdHex in removed {
                    workspace.clearMediaReferenceResolutionCache(forAccountId: accountID, groupIdHex: groupIdHex)
                }
                if let open = workspace.groupDetailsSnapshot?.groupIdHex, removed.contains(open) {
                    workspace.closeGroupDetails()
                }
                // A left chat keeps its history, so its conversation may stay open; a deleted one
                // is gone, so it closes as a single-row delete closes it.
                if case .chat(let open) = workspace.selection, changes.deletedGroupIds.contains(open) {
                    workspace.leaveActiveConversation()
                    workspace.stopTimelineListener()
                    workspace.selection = nil
                    workspace.pruneMessageCache(keeping: nil)
                }
                await workspace.reloadChats(forceFreshSnapshot: true)
            },
            globalMessageSearchScopes: { [weak workspace] in
                guard let workspace, let accountID = activatingAccountID,
                    workspace.activeAccountId == accountID
                else { return [] }
                return workspace.activeChats.map { GlobalMessageSearchScope(groupId: $0.id, title: $0.title) }
            },
            globalMessageSearchNicknames: { [weak workspace] in
                guard let workspace, let accountID = activatingAccountID,
                    workspace.activeAccountId == accountID
                else { return .none }
                return workspace.activeContactNicknames
            }
        )
        guard let scope = session.accountScope else { return }
        if scenePhase == .active {
            await session.updateProductAnalyticsActivity(.foreground)
        }

        // The workspace still owns the legacy selection/composer state during the staged
        // migration, but it must not keep a second chat-list subscription alive. Hand that
        // compatibility state complete prepared snapshots from the account-scoped model.
        workspace.stopChatListListener()
        let account = scope.account
        let chatListModel = scope.chatListModel
        // MDK names no peer for a direct chat either side left; the sidebar names it after the
        // peer the workspace remembered, as the open chat's header already does.
        chatListModel.rememberedDirectPeer = { [weak workspace] groupIdHex in
            workspace?.rememberedDirectPeer(groupIdHex: groupIdHex, accountId: account.id)
        }
        chatListModel.cachedRoster = { [weak workspace] groupIdHex in
            workspace?.groupMemberDetailsCache[groupIdHex]
        }
        await chatListModel.setSnapshotObserver { [weak workspace, weak chatListModel] snapshot in
            guard let workspace, let chatListModel else { return }
            await workspace.applyPresentedChatListSnapshot(
                snapshot,
                account: account,
                avatarBytesByReference: chatListModel.avatarBytesByReference
            )
        }
        await synchronizeConversationProjection()
    }

    @MainActor
    private func synchronizeConversationProjection() async {
        guard let scope = session.accountScope,
            let chat = workspace.selectedChat,
            workspace.activeAccountId == scope.account.id
        else {
            session.accountScope?.releaseSelectedConversation()
            return
        }

        let model = scope.selectConversation(groupIdHex: chat.id)
        workspace.cancelTimelineLoad()
        workspace.stopTimelineListener()
        // Claim the chat's window for the projection, so legacy loads from any entry point
        // (sidebar selection, search, notifications) stand down instead of replacing it.
        workspace.timelineTaskGroupId = chat.id
        let account = scope.account
        let runtime = scope.runtime
        let avatarAssets = scope.avatarAssets
        let blockedUsers = scope.blockedUsers
        let installSnapshot: @MainActor (ConversationWindowSnapshotFfi) async -> Void = {
            [weak workspace, weak model, weak avatarAssets, weak blockedUsers] snapshot in
            guard let workspace, let model,
                workspace.activeAccountId == account.id,
                workspace.selectedChat?.id == model.groupIdHex
            else { return }
            // A legacy load that started before the claim above, or a listener it started, would
            // replace this window with the latest page and mark it read. Re-assert ownership.
            if workspace.timelineLoadTask != nil || workspace.timelineTask != nil {
                workspace.cancelTimelineLoad()
                workspace.stopTimelineListener()
            }
            workspace.timelineTaskGroupId = model.groupIdHex
            let identityAssets = snapshot.identities.compactMap(\.avatarAsset)
            await avatarAssets?.load(assets: identityAssets)
            let timelineRecords = BlockedConversationPresentation.timelineRecords(
                snapshot: snapshot,
                blockedAccountIDs: blockedUsers?.blockedAccountIDs ?? []
            )
            let page = TimelinePageFfi(
                messages: timelineRecords,
                hasMoreBefore: snapshot.hasMoreBefore,
                hasMoreAfter: snapshot.hasMoreAfter
            )
            let mentionNames = snapshot.mentionNames(
                activeAccount: account,
                nicknames: workspace.activeContactNicknames,
                npubForAccountIdHex: { runtime.npub(accountIdHex: $0) }
            )
            await workspace.applyTimelineWindow(
                page,
                groupIdHex: model.groupIdHex,
                account: account,
                client: runtime,
                owner: nil,
                preparedSenderProfiles: snapshot.senderProfiles(
                    activeAccount: account,
                    nicknames: workspace.activeContactNicknames,
                    avatarBytesByReference: avatarAssets?.bytesByReference ?? [:]
                ),
                preparedMentionNames: mentionNames,
                preparedReactions: snapshot.preparedReactions(activeAccountIdHex: account.accountIdHex),
                projectedClientTokens: Set(timelineRecords.compactMap(\.clientToken)),
                // The transcript marks read from the messages it reports on screen.
                marksLatestRowRead: false
            )
        }
        await model.setSnapshotObserver(installSnapshot)
        await blockedUsers.setChangeObserver { [weak model] _ in
            guard let snapshot = model?.snapshot else { return }
            await installSnapshot(snapshot)
        }
    }
}

private struct LinkRequestsObserveKey: Equatable {
    let runtime: ObjectIdentifier?
    let signedIn: [String]
}

private struct LinkRequestAlertKey: Equatable {
    let pending: [String: [String]]
    let active: String?
    let showing: Bool
}
