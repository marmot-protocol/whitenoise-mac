import Foundation

/// The composer's Send for a draft that uses custom emoji.
///
/// Such a draft goes out as a kind-9 carrying each emoji's image (`sendTaggedMedia`), which has no
/// client token and no pending row, so unlike a plain text send the draft stays in the composer
/// until MDK accepts the message: a failure leaves it there for an explicit retry. On acceptance
/// it clears only what was sent, so anything typed meanwhile survives.
@MainActor
enum CustomEmojiComposerSend {
    enum Outcome: Equatable {
        /// The draft uses no custom emoji; the ordinary send handles it.
        case notCustom
        case sent
        /// Refused, failed or superseded: the notice, if any, says why and the draft stays.
        case kept
    }

    static func send(workspace: WorkspaceState, conversation: ConversationViewModel) async -> Outcome {
        guard workspace.editingMessageContext == nil, workspace.stagedVoiceMessage == nil,
            let draftKey = workspace.selectedComposerDraftKey, draftKey.chatId == conversation.groupIdHex
        else { return .notCustom }
        let text = workspace.canonicalizeMentions(
            in: workspace.draftText, selections: workspace.composerMentionSelections
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        let emoji = CustomEmojiSendCatalog.used(in: text, sendables: conversation.customEmojiSendables)
        guard !emoji.isEmpty else { return .notCustom }
        guard let client = workspace.client, let account = workspace.activeAccount,
            workspace.selectedChat?.canUseComposer == true, !workspace.isSending
        else { return .kept }
        guard workspace.pendingMediaAttachments.isEmpty else {
            conversation.customEmojiSender.report(.mixedWithAttachments)
            return .kept
        }

        let submittedDraft = workspace.draftTextByConversation[draftKey] ?? ""
        let replyTargetId = workspace.replyDraftContextByConversation[draftKey]?.targetMessageId
        workspace.isSending = true
        let accepted = await conversation.customEmojiSender.submit(
            text: text, replyTargetId: replyTargetId, emoji: emoji)
        workspace.isSending = false
        guard accepted else { return .kept }

        // Keyed by the captured draft key, never the live selection, so a chat switched to
        // mid-send keeps its own composer.
        guard (workspace.draftTextByConversation[draftKey] ?? "") == submittedDraft,
            workspace.replyDraftContextByConversation[draftKey]?.targetMessageId == replyTargetId,
            workspace.editingMessageContextByConversation[draftKey] == nil
        else { return .sent }
        workspace.draftTextByConversation[draftKey] = nil
        workspace.composerMentionSelectionsByConversation[draftKey] = nil
        workspace.replyDraftContextByConversation[draftKey] = nil
        await workspace.deletePersistedComposerDraft(for: draftKey, accountRef: account.accountRef, client: client)
        return .sent
    }
}
