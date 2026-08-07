//
//  WorkspaceState+ChatRestoration.swift
//  whitenoise-mac
//
//  Optional restoration of the conversation each account last had selected. The memory is per
//  account, and so is every read of it: launching, switching identities on the rail, and coming
//  back to the chats from Settings all reopen the conversation belonging to the account that is
//  active at that moment, never one carried over from another identity.
//

import Foundation

/// What an account's memory says to do when the app — not the user — has to pick a conversation.
nonisolated enum RememberedChatOutcome {
    /// Reopen this remembered conversation.
    case reopen(ChatItem)
    /// Nothing to reopen, but the account still remembers a conversation that is only temporarily
    /// unrestorable (archived). The stand-in the caller falls back to must not be persisted over it.
    case fallBackPreservingMemory
    /// Nothing to reopen and nothing to protect: whatever the caller falls back to becomes the
    /// account's new memory, exactly as a user-made selection would.
    case fallBack

    var chat: ChatItem? {
        guard case .reopen(let chat) = self else { return nil }
        return chat
    }

    var preservesMemory: Bool {
        if case .fallBackPreservingMemory = self { return true }
        return false
    }
}

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
            !isPreservingRememberedChat,
            let activeAccount,
            case .chat(let groupIdHex) = selection
        else { return }

        chatRestorationStore.setTarget(
            groupIdHex: groupIdHex,
            forOwnerAccountIdHex: activeAccount.accountIdHex
        )
    }

    /// Whether `account` remembers a conversation at all — answerable before its chat list has been
    /// loaded, which is what lets an account switch decline to select some substitute row. Selecting
    /// one would write straight back through `selection`'s `didSet` and destroy the memory before it
    /// could ever be honored.
    func hasRememberedChat(forAccount account: AccountItem) -> Bool {
        rememberedChatId(forAccount: account) != nil
    }

    /// The conversation to reopen for `account`, or `nil` when the setting is off, the account
    /// remembers nothing, or its currently loaded chat list cannot resolve the memory. Works for a
    /// background account as well as the active one, so a switch can land on the right conversation
    /// immediately when that account's rows are already cached.
    func rememberedChat(forAccount account: AccountItem) -> ChatItem? {
        guard let groupIdHex = rememberedChatId(forAccount: account),
            let chat = chatItem(accountId: account.id, chatId: groupIdHex),
            !chat.isNoLongerMember,
            // Archiving hides the row, and every switch resets the sidebar to the active filter, so
            // reopening an archived conversation would show a transcript with no row beside it. The
            // memory survives archiving; it just stops being restored while the chat is filed away.
            archivedChatItem(accountId: account.id, chatId: groupIdHex) == nil
        else { return nil }

        return chat
    }

    /// What the active account's memory says to do, without touching that memory. Safe to ask
    /// against a chat list that may still be a stale cache — a rail tap taken before the account's
    /// fresh snapshot has landed.
    func rememberedChatOutcomeForActiveAccount() -> RememberedChatOutcome {
        guard let activeAccount,
            let groupIdHex = rememberedChatId(forAccount: activeAccount)
        else { return .fallBack }

        if let chat = rememberedChat(forAccount: activeAccount) {
            return .reopen(chat)
        }
        // Filed away rather than gone, so the memory keeps pointing at it and unarchiving returns
        // the user to it.
        if archivedChatItem(accountId: activeAccount.id, chatId: groupIdHex) != nil {
            return .fallBackPreservingMemory
        }
        return .fallBack
    }

    /// The same answer, plus the cleanup half: a memory the account can never act on again — it left
    /// the group, or the conversation is gone from its list entirely — is forgotten so the ordinary
    /// most-recent pick takes over for good.
    ///
    /// Only for callers whose `activeChats`/`archivedChats` are a *completed* snapshot, since
    /// forgetting a conversation the list has merely not loaded yet cannot be undone. That is a
    /// property of the caller, not of the lists being non-empty: an account whose snapshot really is
    /// empty must forget a dead memory, and a stale cache with rows in it must not act at all.
    /// `performChatListReload` applies both lists immediately before the one caller that qualifies.
    func resolveRememberedChatForActiveAccount() -> RememberedChatOutcome {
        let outcome = rememberedChatOutcomeForActiveAccount()
        guard case .fallBack = outcome,
            let activeAccount,
            rememberedChatId(forAccount: activeAccount) != nil
        else { return outcome }

        // A memory that survived neither branch above: the snapshot has no openable conversation
        // under that id, whether it omits it entirely or carries it with membership ended.
        chatRestorationStore.removeTarget(forOwnerAccountIdHex: activeAccount.accountIdHex)
        return outcome
    }

    /// Runs `body` with the restoration write suspended when `preserved` is set, so a conversation
    /// the app picked on the user's behalf cannot overwrite a memory that resolution deliberately
    /// left in place. Without this, falling back past an archived conversation would forget it on the
    /// very next selection and unarchiving would find nothing to return to.
    func withRememberedChatPreserved(_ preserved: Bool, _ body: () -> Void) {
        guard preserved else {
            body()
            return
        }
        isPreservingRememberedChat = true
        defer { isPreservingRememberedChat = false }
        body()
    }

    func removeChatRestorationTarget(forOwnerAccountIdHex accountIdHex: String) {
        chatRestorationStore.removeTarget(forOwnerAccountIdHex: accountIdHex)
    }

    func clearChatRestorationTargets() {
        chatRestorationStore.clearTargets()
    }

    private func rememberedChatId(forAccount account: AccountItem) -> String? {
        guard restoreLastSelectedChat, !account.signedOut else { return nil }
        return chatRestorationStore.targetGroupId(forOwnerAccountIdHex: account.accountIdHex)
    }
}
