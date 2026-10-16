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
    /// The active account's conversations, active and archived.
    let conversations: @MainActor () -> (active: [ChatItem], archived: [ChatItem])
    /// Opens an existing chat, bringing an archived one back into the chat list first.
    let open: @MainActor (DirectChatChoice) async -> Void
    /// Creates a new direct chat with the person, even when one already exists.
    let startNew: @MainActor (NewChatRecipient) async -> Void
}

extension DirectChatChooserSource {
    static func workspace(_ workspace: WorkspaceState) -> Self {
        Self(
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
                    guard await workspace.setChatArchived(choice.chat, archived: false) else { return }
                }
                workspace.selectChat(choice.chat)
            },
            startNew: { [weak workspace] recipient in
                await workspace?.startDirectChat(with: recipient, reusingExisting: false)
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
        let conversations = source.conversations()
        let choices = DirectChatChoices.existing(
            withPeer: recipient.accountIdHex,
            active: conversations.active,
            archived: conversations.archived
        )
        guard !choices.isEmpty else {
            presentation = nil
            await source.startNew(recipient)
            return
        }
        presentation = DirectChatChooserPresentation(recipient: recipient, choices: choices)
    }

    func open(_ choice: DirectChatChoice, from source: DirectChatChooserSource) async {
        presentation = nil
        await source.open(choice)
    }

    func startNew(from source: DirectChatChooserSource) async {
        guard let recipient = presentation?.recipient else { return }
        presentation = nil
        await source.startNew(recipient)
    }

    func cancel() {
        presentation = nil
    }
}
