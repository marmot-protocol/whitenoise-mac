//
//  whitenoise_macApp.swift
//  whitenoise-mac
//
//  Created by Jeff Gardner on 26/05/2026.
//

import MarmotKit
import SwiftUI

@main
struct whitenoise_macApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @State private var workspace: WorkspaceState
    @State private var session: SessionState
    private let shouldBootstrapWorkspace: Bool

    init() {
        let configuration = AppLaunchConfiguration.current
        _workspace = State(initialValue: configuration.makeWorkspace())
        _session = State(initialValue: SessionState())
        shouldBootstrapWorkspace = configuration.shouldBootstrapWorkspace
    }

    var body: some Scene {
        // A single `Window` scene (not `WindowGroup`) intentionally restricts the app to
        // exactly one window. The whole UI is driven by one shared `WorkspaceState`
        // (selection, search text, composer drafts, reply context, chat-list visibility,
        // sheet-presentation flags, etc.), so a second window would not be an independent
        // workspace — it would be a live mirror that fights the first over the same mutable
        // state. `Window` also removes the automatic File ▸ New Window (⌘N) command and
        // multi-window restoration that `WindowGroup` provides. See issue #46.
        Window("White Noise", id: "main") {
            ContentView()
                .environment(workspace)
                .environment(session)
                .task {
                    if shouldBootstrapWorkspace {
                        // Started before the bootstrap it runs alongside, not after: a cold start
                        // with no network is exactly when the offline notice has something to say,
                        // and bootstrap is the part that will be sitting there waiting on relays.
                        // Gated on the same flag as bootstrap so a UI fixture launch stays offline
                        // in the literal sense — it opens no sockets at all.
                        workspace.startConnectivityMonitoring()
                        await workspace.bootstrap()
                        await synchronizeAccountScope()
                    }
                }
                .task(id: workspace.activeAccountId) {
                    await synchronizeAccountScope()
                }
                .task(id: workspace.selectedChat?.id) {
                    await synchronizeConversationProjection()
                }
                .task(id: workspace.isOffline) {
                    session.updateConnectivity(available: !workspace.isOffline)
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
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentMinSize)
        .commands {
            CommandMenu("Navigate") {
                Button(L10n.string("Search All Messages…")) {
                    workspace.presentGlobalMessageSearch()
                }
                .keyboardShortcut("f", modifiers: [.command, .shift])
                .disabled(workspace.activeAccount == nil)
            }
        }
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
                workspace.selectedChat?.id == model.groupIdHex,
                model.isLatestPresentation(snapshot.revision)
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
                owner: .conversationSnapshot(isCurrent: { [weak model] in
                    model?.isLatestPresentation(snapshot.revision) ?? false
                }),
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
            await model?.representSnapshot()
        }
    }
}
