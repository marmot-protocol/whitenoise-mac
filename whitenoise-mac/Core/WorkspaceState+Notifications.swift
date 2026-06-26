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

        // Read the account's notification settings exactly once over the FFI
        // boundary, then reuse the snapshot for both responsibilities below:
        //   1. Keep the published `notificationSettings` snapshot in sync when
        //      the update targets the active account.
        //   2. Gate notification delivery on `localNotificationsEnabled`.
        // A failed read (`nil`) suppresses delivery and leaves the published
        // snapshot untouched, matching the prior early-return-on-error behavior.
        guard let settings = await fetchNotificationSettings(for: update) else { return }

        if activeAccount?.accountIdHex == update.accountIdHex {
            notificationSettings = NotificationSettingsSnapshot(settings: settings)
        }

        guard settings.localNotificationsEnabled else { return }

        if selectedChat?.id == update.groupIdHex, selectedConversationIsVisible() {
            return
        }

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

        let switchedAccounts: Bool
        if let account = notificationAccount(from: userInfo), activeAccountId != account.id {
            prepareForActiveAccountSwitch(to: account, preservingMessageCacheFor: groupIdHex)
            switchedAccounts = true
        } else {
            switchedAccounts = false
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
        return try? await runOffMain({
            try client.notificationSettings(accountRef: accountRef)
        })
    }

    func handleNotificationPermissionError(_ error: Error) async {
        if isNotificationsNotAllowedError(error) {
            await refreshNotificationAuthorizationStatus()
            if !notificationAuthorizationStatus.canPostNotifications {
                notificationAuthorizationStatus = .denied
            }
            lastError = Self.notificationPermissionGuidance
            return
        }

        lastError = error.localizedDescription
        await refreshNotificationAuthorizationStatus()
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
        let senderName =
            firstNonBlank([
                update.sender.displayName,
                update.sender.accountIdHex,
            ]) ?? L10n.string("Someone")
        let previewText = firstNonBlank([update.previewText]) ?? L10n.string("New message")

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
                body = firstNonBlank([update.groupName, senderName]) ?? L10n.string("New group invite")
            }
        case .newMessage:
            switch previewMode {
            case .full:
                if update.isDm {
                    title = senderName
                    body = previewText
                } else {
                    title = firstNonBlank([update.groupName]) ?? L10n.string("New message")
                    body = "\(senderName): \(previewText)"
                }
            case .senderOnly:
                if update.isDm {
                    title = senderName
                    body = genericBody
                } else {
                    title = firstNonBlank([update.groupName]) ?? L10n.string("New message")
                    body = senderName
                }
            case .hidden:
                title = L10n.string("White Noise")
                body = genericBody
            }
        }

        return LocalNotificationRequest(
            identifier: update.notificationKey,
            title: title,
            body: body,
            threadIdentifier: update.groupIdHex,
            userInfo: localNotificationUserInfo(for: update)
        )
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
