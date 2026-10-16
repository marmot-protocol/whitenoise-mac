//
//  DirectChatChooserViewModel.swift
//  whitenoise-mac
//
//  Picking a person in New chat: continue a direct chat you already have with them, or start
//  another one. Without this the existing chat was the only possible outcome.
//

import Foundation
import Observation

/// Where the chooser reads conversations from and what its two outcomes do.
struct DirectChatChooserSource {
    /// The account the chooser is acting for right now.
    let activeAccountId: @MainActor () -> String?
    /// The active account's conversations, active and archived.
    let conversations: @MainActor () -> (active: [ChatItem], archived: [ChatItem])
    /// Opens an existing chat, bringing an archived one back into the chat list first.
    let open: @MainActor (DirectChatChoice) async -> Void
    /// Creates a new direct chat with the person, even when one already exists, under the given
    /// account only: the chat is not created if the active account has changed since.
    let startNew: @MainActor (NewChatRecipient, _ accountId: String?) async -> Void
}

extension DirectChatChooserSource {
    static func workspace(_ workspace: WorkspaceState) -> Self {
        Self(
            activeAccountId: { [weak workspace] in workspace?.activeAccountId },
            conversations: { [weak workspace] in
                guard let workspace, let accountId = workspace.activeAccountId else { return ([], []) }
                return (
                    workspace.chatsByAccount[accountId] ?? [],
                    workspace.archivedChatsByAccount[accountId] ?? []
                )
            },
            open: { [weak workspace] choice in
                guard let workspace else { return }
                // Opening an archived chat unarchives it, as the group composer does, or the user
                // lands in a chat the sidebar is not showing.
                if choice.isArchived {
                    // The unarchive suspends; a switch meanwhile must not select this account's
                    // chat id under the next one.
                    let accountId = workspace.activeAccountId
                    guard await workspace.setChatArchived(choice.chat, archived: false),
                        workspace.activeAccountId == accountId
                    else { return }
                }
                workspace.selectChat(choice.chat)
            },
            startNew: { [weak workspace] recipient, accountId in
                await workspace?.startDirectChat(
                    with: recipient,
                    reusingExisting: false,
                    expectedAccountId: accountId
                )
            }
        )
    }
}

@MainActor
@Observable
final class DirectChatChooserViewModel {
    /// Non-nil while the chooser sheet is up.
    var presentation: DirectChatChooserPresentation?

    /// Entry point for a person row: creates the first direct chat straight away, and asks only
    /// when there is already one to continue.
    func choose(_ recipient: NewChatRecipient, from source: DirectChatChooserSource) async {
        // The chooser acts for the account it was opened under. Start New runs in a task the
        // view launches later, and an account switch in between must not create the chat under
        // the account switched to.
        let accountId = source.activeAccountId()
        let conversations = source.conversations()
        let choices = DirectChatChoices.existing(
            withPeer: recipient.accountIdHex,
            active: conversations.active,
            archived: conversations.archived
        )
        guard !choices.isEmpty else {
            presentation = nil
            await source.startNew(recipient, accountId)
            return
        }
        presentation = DirectChatChooserPresentation(
            recipient: recipient,
            choices: choices,
            accountId: accountId
        )
    }

    func open(_ choice: DirectChatChoice, from source: DirectChatChooserSource) async {
        presentation = nil
        await source.open(choice)
    }

    func startNew(from source: DirectChatChooserSource) async {
        guard let presentation else { return }
        self.presentation = nil
        await source.startNew(presentation.recipient, presentation.accountId)
    }

    func cancel() {
        presentation = nil
    }
}
