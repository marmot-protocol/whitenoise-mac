//
//  WorkspaceState+PendingOutgoingMedia.swift
//  whitenoise-mac
//
//  The half of a media send that outlives the Send press. MarmotKit owns the atomic retained-media
//  upload and durable local admission; the app parks one tokenized placeholder here until the
//  authoritative conversation projection returns the row carrying that exact token.
//

import Foundation
import MarmotKit

@MainActor
extension WorkspaceState {
    /// Parks a just-sent media message and starts the work that will publish it.
    ///
    /// `adoptedUploads` are stage-time previews that must be cancelled once Send transfers
    /// ownership to MarmotKit's atomic upload-and-admit operation. They cannot be reused as the
    /// authoritative send because doing so would split retained-file ownership from admission.
    func beginPendingOutgoingMediaSend(
        _ message: PendingOutgoingMediaMessage,
        adoptedUploads: [PendingMediaAttachment.ID: Task<MediaAttachmentReferenceFfi?, Never>],
        for draftKey: ComposerDraftKey,
        account: AccountItem,
        client: any MarmotRuntime
    ) {
        // Captured before the append so it is the message ahead of this one, not this one.
        let predecessor = pendingOutgoingMediaMessagesByConversation[draftKey]?
            .last
            .flatMap { pendingOutgoingMediaSendTasks[$0.id] }
        pendingOutgoingMediaMessagesByConversation[draftKey, default: []].append(message)

        pendingOutgoingMediaSendTasks[message.id] = Task { [weak self] in
            // Publish in the order Send was pressed. A failed predecessor still releases this one:
            // its task finishes either way, it just leaves a failed bubble behind it.
            await predecessor?.value
            guard !Task.isCancelled else { return }
            await self?.completePendingOutgoingMediaSend(
                message.id,
                adoptedUploads: adoptedUploads,
                for: draftKey,
                account: account,
                client: client
            )
        }
    }

    /// Re-runs a failed outgoing message with the same durable client token. MarmotKit decides
    /// whether this is a retry of retained bytes or an already-admitted message.
    func retryPendingOutgoingMediaMessage(_ id: PendingOutgoingMediaMessage.ID) {
        guard let draftKey = selectedComposerDraftKey,
            let index = pendingOutgoingMediaMessagesByConversation[draftKey]?.firstIndex(where: { $0.id == id }),
            let account = activeAccount,
            account.id == draftKey.accountId,
            let client
        else { return }
        pendingOutgoingMediaMessagesByConversation[draftKey]?[index].state = .uploading
        pendingOutgoingMediaSendTasks[id]?.cancel()
        pendingOutgoingMediaSendTasks[id] = Task { [weak self] in
            await self?.completePendingOutgoingMediaSend(
                id,
                adoptedUploads: [:],
                for: draftKey,
                account: account,
                client: client
            )
        }
    }

    /// Drops a failed outgoing message. Only offered once it has failed: a message still on its way
    /// out has no cancellation story in the core, so the affordance would be a lie.
    func discardPendingOutgoingMediaMessage(_ id: PendingOutgoingMediaMessage.ID) {
        guard let draftKey = selectedComposerDraftKey else { return }
        removePendingOutgoingMediaMessage(id, in: draftKey)
    }

    func cancelAllPendingOutgoingMediaSends() {
        for key in Array(pendingOutgoingMediaMessagesByConversation.keys) {
            cancelPendingOutgoingMediaSends(for: key)
        }
        pendingOutgoingMediaMessagesByConversation.removeAll()
    }

    func cancelPendingOutgoingMediaSends(for draftKey: ComposerDraftKey) {
        for message in pendingOutgoingMediaMessagesByConversation[draftKey] ?? [] {
            pendingOutgoingMediaSendTasks.removeValue(forKey: message.id)?.cancel()
            for upload in pendingOutgoingMediaUploadTasks.removeValue(forKey: message.id) ?? [] {
                upload.cancel()
            }
        }
        pendingOutgoingMediaMessagesByConversation[draftKey] = nil
    }

    func cancelPendingOutgoingMediaSends(forAccountId accountId: String) {
        let keys = pendingOutgoingMediaMessagesByConversation.keys.filter { $0.accountId == accountId }
        for draftKey in keys {
            cancelPendingOutgoingMediaSends(for: draftKey)
        }
    }

    private func completePendingOutgoingMediaSend(
        _ id: PendingOutgoingMediaMessage.ID,
        adoptedUploads: [PendingMediaAttachment.ID: Task<MediaAttachmentReferenceFfi?, Never>],
        for draftKey: ComposerDraftKey,
        account: AccountItem,
        client: any MarmotRuntime
    ) async {
        guard let message = pendingOutgoingMediaMessage(id, in: draftKey) else { return }

        // Stage-time uploads exist only to make the composer responsive. Once the user presses
        // Send, one MarmotKit call must own both retained bytes and durable admission. Letting the
        // preview uploads finish would create two independent retained-file lifetimes.
        for upload in adoptedUploads.values {
            upload.cancel()
        }
        pendingOutgoingMediaUploadTasks[id] = nil
        setPendingOutgoingMediaMessageState(.uploading, for: id, in: draftKey)

        do {
            let submission = try await client.uploadMediaWithClientToken(
                accountRef: account.accountRef,
                groupIdHex: draftKey.chatId,
                request: MediaUploadRequestFfi(
                    attachments: message.attachments.map(\.uploadRequest),
                    caption: message.caption.isEmpty ? nil : message.caption,
                    send: true,
                    blossomServer: nil
                ),
                clientToken: message.clientToken
            )
            guard submission.acceptance != nil else {
                throw MarmotKitError.InvalidMediaReference(
                    details: "Media upload completed without durable message admission"
                )
            }
            let references = submission.upload.attachments.compactMap(\.reference)
            guard references.count == message.attachments.count else {
                throw MarmotKitError.InvalidMediaReference(
                    details: "One or more media attachments were not retained for sending"
                )
            }

            // The retained references are now authoritative. Keep the old plaintext cache warm
            // during the ownership migration, but never perform another host-side upload/send.
            await cacheOutgoingMediaPlaintext(
                message.attachments,
                references: references,
                accountId: account.id,
                groupIdHex: draftKey.chatId
            )
            setPendingOutgoingMediaMessageState(.publishing, for: id, in: draftKey)
        } catch {
            // An interrupted host await can race durable local admission. Resolve that ambiguity
            // with the same token rather than creating another semantic media send on retry.
            if let status = try? client.localSendStatus(
                accountRef: account.accountRef,
                groupIdHex: draftKey.chatId,
                clientToken: message.clientToken
            ) {
                switch status {
                case .queued, .engineOwned, .completed:
                    await refreshSelectedTimelineAfterSend(
                        groupIdHex: draftKey.chatId,
                        account: account,
                        client: client
                    )
                    return
                case .rejected:
                    break
                }
            }
            lastError = UserFacingError.message(for: error)
            setPendingOutgoingMediaMessageState(.failed, for: id, in: draftKey)
            return
        }

        clearMediaReferenceResolutionCache(forAccountId: account.id, groupIdHex: draftKey.chatId)
        // Re-window first, then drop the placeholder. Either order is safe on the delta path — the
        // core commits an own send locally as part of publishing, so a subscription delta may
        // already have put the real row on screen, where the digest match hides this bubble anyway.
        // What the old order cost was the *other* path: dropping the placeholder before the window
        // came back left a frame with neither row in it, so the transcript flashed where the
        // message had been. Retiring it afterwards makes the swap seamless in both directions.
        await refreshSelectedTimelineAfterSend(
            groupIdHex: draftKey.chatId,
            account: account,
            client: client
        )
        // Durable local admission is success, but only a projected row carrying this exact token
        // can retire the pending bubble. The conversation snapshot bridge performs that match.
    }

    private func pendingOutgoingMediaMessage(
        _ id: PendingOutgoingMediaMessage.ID,
        in draftKey: ComposerDraftKey
    ) -> PendingOutgoingMediaMessage? {
        pendingOutgoingMediaMessagesByConversation[draftKey]?.first { $0.id == id }
    }

    private func setPendingOutgoingMediaMessageState(
        _ state: PendingOutgoingMediaMessageState,
        for id: PendingOutgoingMediaMessage.ID,
        in draftKey: ComposerDraftKey
    ) {
        guard let index = pendingOutgoingMediaMessagesByConversation[draftKey]?.firstIndex(where: { $0.id == id })
        else { return }
        pendingOutgoingMediaMessagesByConversation[draftKey]?[index].state = state
    }

    private func removePendingOutgoingMediaMessage(
        _ id: PendingOutgoingMediaMessage.ID,
        in draftKey: ComposerDraftKey
    ) {
        pendingOutgoingMediaSendTasks.removeValue(forKey: id)
        for upload in pendingOutgoingMediaUploadTasks.removeValue(forKey: id) ?? [] {
            upload.cancel()
        }
        var messages = pendingOutgoingMediaMessagesByConversation[draftKey] ?? []
        messages.removeAll { $0.id == id }
        pendingOutgoingMediaMessagesByConversation[draftKey] = messages.isEmpty ? nil : messages
    }
}
