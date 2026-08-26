//
//  WorkspaceState+Notifications.swift
//  whitenoise-mac
//
//  Notifications behavior extracted from WorkspaceState.swift (no behavior change).
//

import AVFoundation
import AppKit
import Combine
import Foundation
import MarmotKit
import Observation
import SwiftUI
import UserNotifications

@MainActor
extension WorkspaceState {
    func handleNotificationUpdate(_ update: NotificationUpdateFfi) async {
        guard !update.isFromSelf else { return }
        guard !deliveredNotificationKeys.contains(update.notificationKey) else { return }
        let activeNotificationAccountId =
            activeAccount?.accountIdHex == update.accountIdHex ? activeAccount?.id : nil
        // A same-account settings toggle/load that commits while the FFI read is
        // in flight owns the newer published snapshot; do not clobber it on resume.
        let notificationSettingsGenerationAtStart = notificationSettingsGeneration

        // The client-wide notification stream is the only live word the app gets about a background
        // account's incoming messages, so its avatar badge is refreshed from here. This sits above
        // the delivery gates below on purpose: the badge tracks unread messages, not whether the
        // user wants banners for them, so a muted account must still count up in the rail.
        await refreshAccountUnreadSummaryForBackgroundAccount(receiving: update)

        // Read the account's notification settings exactly once over the FFI
        // boundary, then reuse the snapshot for both responsibilities below:
        //   1. Keep the published `notificationSettings` snapshot in sync when
        //      the update targets the active account.
        //   2. Gate notification delivery on `localNotificationsEnabled`.
        // A failed read (`nil`) suppresses delivery and leaves the published
        // snapshot untouched, matching the prior early-return-on-error behavior.
        guard let settings = await fetchNotificationSettings(for: update) else { return }

        if let activeNotificationAccountId,
            ownsNotificationSettingsOperation(
                accountId: activeNotificationAccountId,
                generation: notificationSettingsGenerationAtStart
            )
        {
            notificationSettings = NotificationSettingsSnapshot(settings: settings)
        }

        guard settings.localNotificationsEnabled else { return }

        if activeAccount?.accountIdHex == update.accountIdHex,
            selectedChat?.id == update.groupIdHex,
            selectedConversationIsVisible()
        {
            return
        }

        // Archiving a chat is the user's word that it should stop interrupting them, so a filed-away
        // conversation gets no banner however busy it gets. Deliberately below the unread-badge
        // refresh above: that badge is not a banner preference, and the core already leaves archived
        // conversations out of the account totals it reports.
        if await notificationChatIsArchived(update) { return }

        if !notificationAuthorizationStatus.canPostNotifications {
            await refreshNotificationAuthorizationStatus()
        }
        guard notificationAuthorizationStatus.canPostNotifications else { return }

        do {
            let request = localNotificationRequest(for: update)
            try await localNotificationCenter.post(request)
            rememberDeliveredNotificationKey(update.notificationKey)
        } catch {
            setBackgroundStatus(error.localizedDescription)
        }
    }

    func handleNotificationResponse(_ userInfo: [String: String]) {
        guard let groupIdHex = userInfo["groupIdHex"] else { return }

        let account = notificationAccount(from: userInfo)
        let switchedAccounts: Bool
        if let account, !account.signedOut, activeAccountId != account.id {
            prepareForActiveAccountSwitch(to: account, preservingMessageCacheFor: groupIdHex)
            switchedAccounts = true
        } else if account == nil || account?.signedOut == true {
            guard activeAccountHasChat(groupIdHex: groupIdHex) else {
                setBackgroundStatus(
                    L10n.string("This notification is for an account or chat that is no longer available.")
                )
                NSApplication.shared.activate(ignoringOtherApps: true)
                return
            }
            switchedAccounts = false
        } else {
            switchedAccounts = false
        }

        if !switchedAccounts {
            leaveActiveConversation()
        }
        selection = .chat(groupIdHex)
        isChatListVisible = true
        if !switchedAccounts {
            closeNewChatComposer()
            pruneMessageCache(keeping: groupIdHex)
        }
        NSApplication.shared.activate(ignoringOtherApps: true)
        beginTimelineInitialLoadIfNeeded(groupIdHex: groupIdHex)

        Task {
            await reloadChats()
            await loadMessages(groupIdHex: groupIdHex)
        }
    }

    func activeAccountHasChat(groupIdHex: String) -> Bool {
        guard let activeAccountId else { return false }
        return chatItem(accountId: activeAccountId, chatId: groupIdHex) != nil
    }

    func startNotificationListener() {
        guard notificationTask == nil, client != nil else { return }
        notificationTask = Task { [weak self] in
            await self?.runNotificationListener()
        }
    }

    func stopNotificationListener() {
        notificationTask?.cancel()
        notificationTask = nil
    }

    func runNotificationListener() async {
        guard let client else { return }
        var reconnectAttempt = 0

        while !Task.isCancelled {
            do {
                let subscription = try await client.subscribeNotifications()
                while !Task.isCancelled {
                    guard let update = await subscription.next() else { break }
                    reconnectAttempt = 0
                    await handleNotificationUpdate(update)
                }
            } catch is CancellationError {
                return
            } catch {
                setBackgroundStatus(error.localizedDescription)
            }

            guard !Task.isCancelled else { break }
            do {
                try await waitBeforeListenerReconnect(attempt: reconnectAttempt)
            } catch is CancellationError {
                return
            } catch {
                setBackgroundStatus(error.localizedDescription)
            }
            reconnectAttempt += 1
        }

    }

    func rememberDeliveredNotificationKey(_ key: String) {
        guard deliveredNotificationKeys.insert(key).inserted else { return }
        deliveredNotificationKeyOrder.append(key)

        while deliveredNotificationKeyOrder.count > Self.deliveredNotificationKeyLimit {
            let expiredKey = deliveredNotificationKeyOrder.removeFirst()
            deliveredNotificationKeys.remove(expiredKey)
        }
    }

    /// Reads the notification settings for the account targeted by `update` over
    /// the off-main FFI boundary. Returns `nil` when there is no client or the
    /// read fails, so callers can suppress delivery without mutating UI state.
    ///
    /// This is intentionally side-effect free: refreshing the published
    /// `notificationSettings` snapshot for the active account is the caller's
    /// responsibility (see `handleNotificationUpdate(_:)`), which lets a single
    /// fetch serve both the active-account sync and the delivery gate.
    func fetchNotificationSettings(for update: NotificationUpdateFfi) async -> NotificationSettingsFfi? {
        guard let client else { return nil }
        let accountRef = update.accountRef
        return try? await FFIExecutor.run({
            try client.notificationSettings(accountRef: accountRef)
        })
    }

    /// Whether the conversation an incoming notification belongs to has been archived.
    ///
    /// The chat list is the app's only in-memory record of what is filed away, and it is maintained
    /// for the active account alone — while the notification listener is client-wide. An update for
    /// a background account therefore asks the core directly; otherwise archiving would only
    /// silence chats on whichever account happens to be open.
    ///
    /// An unreadable archive state answers `false`: a notification the user wanted is worth more
    /// than one they had already filed away.
    func notificationChatIsArchived(_ update: NotificationUpdateFfi) async -> Bool {
        if let activeAccount, activeAccount.accountIdHex == update.accountIdHex {
            if archivedChatItem(accountId: activeAccount.id, chatId: update.groupIdHex) != nil {
                return true
            }
            // `chatItem(accountId:chatId:)` spans both lists, so a hit once the archived lookup has
            // missed is a live row — no FFI read needed to know it is not archived.
            if chatItem(accountId: activeAccount.id, chatId: update.groupIdHex) != nil {
                return false
            }
        }

        guard let client else { return false }
        let details = try? await client.groupDetails(
            accountRef: update.accountRef,
            groupIdHex: update.groupIdHex
        )
        return details?.group.archived ?? false
    }

    func handleNotificationPermissionError(
        _ error: Error,
        shouldApply: @MainActor () -> Bool = { true }
    ) async {
        let status = await localNotificationCenter.authorizationStatus()
        guard shouldApply() else { return }

        notificationAuthorizationStatus = status
        if isNotificationsNotAllowedError(error) {
            if !notificationAuthorizationStatus.canPostNotifications {
                notificationAuthorizationStatus = .denied
            }
            lastError = Self.notificationPermissionGuidance
            return
        }

        lastError = error.localizedDescription
    }

    func isNotificationsNotAllowedError(_ error: Error) -> Bool {
        let nsError = error as NSError
        if nsError.domain == UNErrorDomain,
            nsError.code == UNError.Code.notificationsNotAllowed.rawValue
        {
            return true
        }

        let message = error.localizedDescription.lowercased()
        return message.contains("notification")
            && message.contains("not allowed")
    }

    func localNotificationRequest(for update: NotificationUpdateFfi) -> LocalNotificationRequest {
        let nickname = contactNicknames(forOwnerAccountIdHex: update.accountIdHex)
            .nickname(forContactAccountIdHex: update.sender.accountIdHex)
        let senderName =
            nickname
            ?? PeerDisplayText.sanitize(update.sender.displayName)
            ?? PeerDisplayText.sanitize(update.sender.accountIdHex)
            ?? L10n.string("Someone")
        let senderTemplateName = PeerDisplayText.templateFragment(senderName)
        let groupName = PeerDisplayText.sanitize(update.groupName)
        let previewText = PeerDisplayText.sanitize(update.previewText) ?? L10n.string("New message")
        let previewTemplateText = PeerDisplayText.templateFragment(previewText)

        // For an E2EE messenger, notification content is rendered as banners,
        // persisted in Notification Center, and shown on the lock screen — i.e.
        // it leaves the app's control. Honor the user's preview-privacy choice:
        // `.hidden` reveals nothing, `.senderOnly` keeps who-it's-from but never
        // the decrypted message text, `.full` is the legacy behavior. See #30.
        let previewMode = notificationPreviewMode
        let genericBody = L10n.string("New message")

        let title: String
        let body: String
        switch update.trigger {
        case .groupInvite:
            if previewMode == .hidden {
                title = L10n.string("White Noise")
                body = L10n.string("New group invite")
            } else {
                title = L10n.string("Group invite")
                body = groupName ?? senderName
            }
        case .newMessage:
            switch previewMode {
            case .full:
                if update.isDm {
                    title = senderName
                    body = previewText
                } else {
                    title = groupName ?? L10n.string("New message")
                    body = "\(senderTemplateName): \(previewTemplateText)"
                }
            case .senderOnly:
                if update.isDm {
                    title = senderName
                    body = genericBody
                } else {
                    title = groupName ?? L10n.string("New message")
                    body = senderName
                }
            case .hidden:
                title = L10n.string("White Noise")
                body = genericBody
            }
        // The core raises these three only when the local account is the subject, and
        // never with a `previewText`: the event *is* the whole content, so there is no
        // decrypted message text to withhold and `.senderOnly` reads the same as
        // `.full`. Copy matches the timeline's own system rows (`MarmotMapping`) so the
        // banner and the row behind it say the same thing.
        case .removedFromGroup:
            (title, body) = groupStateNotificationText(
                notice: L10n.string("You were removed from this group"),
                groupName: groupName,
                previewMode: previewMode
            )
        case .madeAdmin:
            (title, body) = groupStateNotificationText(
                notice: L10n.string("You were made an admin"),
                groupName: groupName,
                previewMode: previewMode
            )
        case .removedAsAdmin:
            (title, body) = groupStateNotificationText(
                notice: L10n.string("You are no longer an admin"),
                groupName: groupName,
                previewMode: previewMode
            )
        }

        return LocalNotificationRequest(
            identifier: update.notificationKey,
            title: title,
            body: body,
            threadIdentifier: update.groupIdHex,
            userInfo: localNotificationUserInfo(for: update)
        )
    }

    /// Title and body for a group-state notice. The notice itself is the body — it is the
    /// only content such an update carries — and the group it happened in is the title,
    /// except under `.hidden`, which withholds the group name the way it withholds a
    /// sender's name everywhere else. An unknown group (the core reports no name) degrades
    /// to the same generic title rather than inventing a placeholder.
    func groupStateNotificationText(
        notice: String,
        groupName: String?,
        previewMode: NotificationPreviewMode
    ) -> (title: String, body: String) {
        let namedTitle = previewMode == .hidden ? nil : groupName
        return (namedTitle ?? L10n.string("White Noise"), notice)
    }

    func localNotificationUserInfo(for update: NotificationUpdateFfi) -> [String: String] {
        var userInfo = [
            "accountRef": update.accountRef,
            "accountIdHex": update.accountIdHex,
            "groupIdHex": update.groupIdHex,
            "conversationKey": update.conversationKey,
            "notificationKey": update.notificationKey,
        ]
        if let messageIdHex = update.messageIdHex {
            userInfo["messageIdHex"] = messageIdHex
        }
        return userInfo
    }

    func notificationAccount(from userInfo: [String: String]) -> AccountItem? {
        if let accountIdHex = userInfo["accountIdHex"],
            let account = accounts.first(where: { $0.accountIdHex == accountIdHex })
        {
            return account
        }

        guard let accountRef = userInfo["accountRef"] else { return nil }
        return accounts.first { account in
            account.accountRef == accountRef || account.id == accountRef
        }
    }
}
