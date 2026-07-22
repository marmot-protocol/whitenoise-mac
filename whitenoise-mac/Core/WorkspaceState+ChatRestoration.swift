//
//  WorkspaceState+ChatRestoration.swift
//  whitenoise-mac
//
//  Optional, account-scoped restoration of the chat selected at app termination.
//

import Foundation

@MainActor
extension WorkspaceState {
    func setRestoreLastSelectedChat(_ enabled: Bool) {
        guard restoreLastSelectedChat != enabled else { return }

        restoreLastSelectedChat = enabled
        chatRestorationStore.setEnabled(enabled)
        if enabled {
            persistSelectedChatForRestorationIfEnabled()
        } else {
            chatRestorationStore.clearTargets()
        }
    }

    func persistSelectedChatForRestorationIfEnabled() {
        guard restoreLastSelectedChat,
            let activeAccount,
            case .chat(let groupIdHex) = selection
        else { return }

        chatRestorationStore.setTarget(
            groupIdHex: groupIdHex,
            forOwnerAccountIdHex: activeAccount.accountIdHex
        )
    }

    /// Resolves the saved chat exactly once, after the launch account's first chat snapshot is
    /// available. A later sign-in or manual account switch in the same process is not a launch
    /// restoration and must retain the ordinary most-recent-chat behavior.
    func consumeStartupRestoredChat() -> ChatItem? {
        guard shouldResolveStartupChatSelection else { return nil }
        shouldResolveStartupChatSelection = false

        guard restoreLastSelectedChat,
            let activeAccount,
            !activeAccount.signedOut,
            let groupIdHex = chatRestorationStore.targetGroupId(
                forOwnerAccountIdHex: activeAccount.accountIdHex
            )
        else { return nil }

        guard let chat = activeChats.first(where: { $0.id == groupIdHex }),
            !chat.isNoLongerMember
        else {
            chatRestorationStore.removeTarget(
                forOwnerAccountIdHex: activeAccount.accountIdHex
            )
            return nil
        }

        return chat
    }

    func discardStartupChatRestoration() {
        shouldResolveStartupChatSelection = false
    }

    func removeChatRestorationTarget(forOwnerAccountIdHex accountIdHex: String) {
        chatRestorationStore.removeTarget(forOwnerAccountIdHex: accountIdHex)
    }

    func clearChatRestorationTargets() {
        chatRestorationStore.clearTargets()
        shouldResolveStartupChatSelection = false
    }
}
