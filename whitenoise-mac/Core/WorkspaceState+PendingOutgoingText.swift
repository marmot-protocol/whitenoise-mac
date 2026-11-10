//
//  WorkspaceState+PendingOutgoingText.swift
//  whitenoise-mac
//
//  The half of a text send that outlives the Send press: waiting its turn behind the sends already
//  going out of this conversation, then publishing. Send itself never waits for either — it empties
//  the composer and parks the message here, where the transcript renders it until the core has a row
//  of its own to show.
//

import Foundation
import MarmotKit

@MainActor
extension WorkspaceState {
    /// Parks a just-sent text message and queues the publish that will deliver it.
    ///
    /// Chained per conversation so back-to-back sends publish in the order Send was pressed. That
    /// chain is why the parking exists at all: waiting on a predecessor is waiting on a whole relay
    /// round-trip, and a message waiting out someone else's timeout has not reached the core, so the
    /// core has nothing to project for it. This row is what stands in for it until it does.
    func beginPendingOutgoingTextSend(
        _ message: PendingOutgoingTextMessage,
        for draftKey: ComposerDraftKey,
        account: AccountItem,
        client: any MarmotRuntime
    ) {
        pendingOutgoingTextMessagesByConversation[draftKey, default: []].append(message)

        let predecessor = outgoingTextSendTasks[draftKey]
        outgoingTextSendTasks[draftKey] = Task { [weak self] in
            // A failed predecessor still releases this one: its task finishes either way, it just
            // leaves a failed bubble behind it.
            await predecessor?.value
            guard !Task.isCancelled else { return }
            await self?.completePendingOutgoingTextSend(
                message.id,
                for: draftKey,
                account: account,
                client: client
            )
        }
    }

    /// Re-publishes a failed text message from the row it failed in.
    ///
    /// Deliberately not re-queued behind the conversation's chain: the messages in that chain are
    /// the ones the user has sent *since*, and holding a retry behind them would reorder the
    /// transcript around the one row the user is trying to rescue.
    func retryPendingOutgoingTextMessage(_ id: PendingOutgoingTextMessage.ID) {
        guard let draftKey = selectedComposerDraftKey,
            let message = pendingOutgoingTextMessage(id, in: draftKey),
            message.state == .failed,
            let account = activeAccount,
            account.id == draftKey.accountId,
            let client
        else { return }
        // Off `.failed` synchronously, so the guard above is what makes this single-flight: the
        // publishing task only reaches its own transition a main-actor hop later, and until then a
        // second Retry press reads the same failed row and starts another round-trip. The media
        // retry relights its bubble the same way.
        setPendingOutgoingTextMessageState(.publishing, for: id, in: draftKey)
        pendingOutgoingTextSendTasks[id]?.cancel()
        pendingOutgoingTextSendTasks[id] = Task { [weak self] in
            // Checked before publishing, as in `beginPendingOutgoingTextSend`: the cancellation
            // above is otherwise inert, since nothing downstream of it consults the flag until
            // after the send has already gone out.
            guard !Task.isCancelled else { return }
            await self?.completePendingOutgoingTextSend(
                id,
                for: draftKey,
                account: account,
                client: client
            )
        }
    }

    /// Drops a failed text message. Only offered once it has failed: a message still on its way out
    /// has no cancellation story in the core, so the affordance would be a lie.
    func discardPendingOutgoingTextMessage(_ id: PendingOutgoingTextMessage.ID) {
        guard let draftKey = selectedComposerDraftKey else { return }
        removePendingOutgoingTextMessage(id, in: draftKey)
    }

    func cancelAllPendingOutgoingTextSends() {
        for key in Array(pendingOutgoingTextMessagesByConversation.keys) {
            cancelPendingOutgoingTextSends(for: key)
        }
        pendingOutgoingTextMessagesByConversation.removeAll()
    }

    func cancelPendingOutgoingTextSends(for draftKey: ComposerDraftKey) {
        for message in pendingOutgoingTextMessagesByConversation[draftKey] ?? [] {
            pendingOutgoingTextSendTasks.removeValue(forKey: message.id)?.cancel()
        }
        pendingOutgoingTextMessagesByConversation[draftKey] = nil
    }

    func cancelPendingOutgoingTextSends(forAccountId accountId: String) {
        let keys = pendingOutgoingTextMessagesByConversation.keys.filter { $0.accountId == accountId }
        for draftKey in keys {
            cancelPendingOutgoingTextSends(for: draftKey)
        }
    }

    private func completePendingOutgoingTextSend(
        _ id: PendingOutgoingTextMessage.ID,
        for draftKey: ComposerDraftKey,
        account: AccountItem,
        client: any MarmotRuntime
    ) async {
        guard let message = pendingOutgoingTextMessage(id, in: draftKey) else { return }

        setPendingOutgoingTextMessageState(.publishing, for: id, in: draftKey)

        do {
            if let replyContext = message.replyContext {
                _ = try await client.replyToMessageWithClientToken(
                    accountRef: account.accountRef,
                    groupIdHex: draftKey.chatId,
                    targetMessageId: replyContext.targetMessageId,
                    text: message.text,
                    clientToken: message.clientToken
                )
            } else {
                _ = try await client.sendTextWithClientToken(
                    accountRef: account.accountRef,
                    groupIdHex: draftKey.chatId,
                    text: message.text,
                    clientToken: message.clientToken
                )
            }
        } catch {
            // An interrupted host await can race durable local admission. Resolve that ambiguity
            // with the same token instead of creating another semantic send on retry.
            if let status = try? client.localSendStatus(
                accountRef: account.accountRef,
                groupIdHex: draftKey.chatId,
                clientToken: message.clientToken
            ) {
                switch status {
                case .queued, .engineOwned, .completed:
                    return
                case .rejected:
                    break
                }
            }
            lastError = UserFacingError.message(for: error)
            setPendingOutgoingTextMessageState(.failed, for: id, in: draftKey)
            return
        }
        // Durable local admission is success, but not the reconciliation signal. Keep the pending
        // row until a complete conversation snapshot carries this exact client token.
    }

    private func pendingOutgoingTextMessage(
        _ id: PendingOutgoingTextMessage.ID,
        in draftKey: ComposerDraftKey
    ) -> PendingOutgoingTextMessage? {
        pendingOutgoingTextMessagesByConversation[draftKey]?.first { $0.id == id }
    }

    private func setPendingOutgoingTextMessageState(
        _ state: PendingOutgoingTextMessageState,
        for id: PendingOutgoingTextMessage.ID,
        in draftKey: ComposerDraftKey
    ) {
        guard let index = pendingOutgoingTextMessagesByConversation[draftKey]?.firstIndex(where: { $0.id == id })
        else { return }
        pendingOutgoingTextMessagesByConversation[draftKey]?[index].state = state
    }

    private func removePendingOutgoingTextMessage(
        _ id: PendingOutgoingTextMessage.ID,
        in draftKey: ComposerDraftKey
    ) {
        pendingOutgoingTextSendTasks.removeValue(forKey: id)
        var messages = pendingOutgoingTextMessagesByConversation[draftKey] ?? []
        messages.removeAll { $0.id == id }
        pendingOutgoingTextMessagesByConversation[draftKey] = messages.isEmpty ? nil : messages
    }
}
