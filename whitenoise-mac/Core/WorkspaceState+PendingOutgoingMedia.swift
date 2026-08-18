//
//  WorkspaceState+PendingOutgoingMedia.swift
//  whitenoise-mac
//
//  The half of a media send that outlives the Send press: awaiting the Blossom uploads that
//  staging started, then publishing. Send itself never waits for either — it empties the composer
//  and parks the message here, where the transcript renders it as a loading bubble.
//

import Foundation
import MarmotKit

@MainActor
extension WorkspaceState {
    /// Parks a just-sent media message and starts the work that will publish it.
    ///
    /// `adoptedUploads` are the stage-time uploads already in flight for these attachments, handed
    /// over by the composer so the wait continues from where staging got to instead of restarting.
    /// Anything not covered there — an upload that failed, or one that never started — is uploaded
    /// here, concurrently with the rest.
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

    /// Re-runs a failed outgoing message from wherever it got to. Uploads are not adopted — the
    /// tasks that would have carried them are the ones that failed — so every attachment is
    /// uploaded again, which is also what recovers a message whose blobs never landed.
    func retryPendingOutgoingMediaMessage(_ id: PendingOutgoingMediaMessage.ID) {
        guard let draftKey = selectedComposerDraftKey,
            let index = pendingOutgoingMediaMessagesByConversation[draftKey]?.firstIndex(where: { $0.id == id }),
            let account = activeAccount,
            account.id == draftKey.accountId,
            let client
        else { return }
        pendingOutgoingMediaMessagesByConversation[draftKey]?[index].state = .uploading
        // The retry re-uploads from scratch, so last attempt's digests describe nothing that is on
        // its way out any more. Left behind, they would hide the bubble the retry just relit.
        pendingOutgoingMediaMessagesByConversation[draftKey]?[index].publishedPlaintextSHAs = []
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
        let messages = pendingOutgoingMediaMessagesByConversation[draftKey] ?? []
        for message in messages {
            pendingOutgoingMediaSendTasks.removeValue(forKey: message.id)?.cancel()
            for upload in pendingOutgoingMediaUploadTasks.removeValue(forKey: message.id) ?? [] {
                upload.cancel()
            }
        }
        releaseWarmPlaintexts(ofMessagesMatching: nil, in: messages)
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

        let uploads = message.attachments.map { attachment in
            adoptedUploads[attachment.id]
                ?? outgoingMediaUploadTask(
                    attachment,
                    accountRef: account.accountRef,
                    groupIdHex: draftKey.chatId,
                    client: client
                )
        }
        pendingOutgoingMediaUploadTasks[id] = uploads

        // Every upload is already running; awaiting them in composer order only fixes the order of
        // the references, never the order they are allowed to finish in.
        var references: [MediaAttachmentReferenceFfi] = []
        for upload in uploads {
            guard let reference = await upload.value else {
                // One failure sinks the message, so the siblings still in flight are transferring
                // bytes nobody will publish. A retry starts them over from scratch.
                for sibling in pendingOutgoingMediaUploadTasks.removeValue(forKey: id) ?? [] {
                    sibling.cancel()
                }
                setPendingOutgoingMediaMessageState(.failed, for: id, in: draftKey)
                return
            }
            references.append(reference)
        }
        pendingOutgoingMediaUploadTasks[id] = nil
        guard !Task.isCancelled, pendingOutgoingMediaMessage(id, in: draftKey) != nil else { return }

        // Stamped before the publish, not after it: the core commits an own send locally as part of
        // publishing, so the real row can reach the transcript through the subscription while we
        // are still awaiting the relay. These digests are what let it hide this bubble on arrival
        // instead of leaving the two stacked for the length of the round-trip.
        setPendingOutgoingMediaPublishedDigests(
            Set(references.map { $0.plaintextSha256.lowercased() }),
            for: id,
            in: draftKey
        )
        setPendingOutgoingMediaMessageState(.publishing, for: id, in: draftKey)

        // We are holding the plaintext that produced these references, so the sender's own bubble
        // has no reason to fetch its own image back from Blossom and decrypt it. Seed before
        // publishing: the real row can render the moment the send returns, and it must find a warm
        // cache when it does — in memory as well as on disk, so its first frame is the image rather
        // than a spinner over bytes this process is still holding.
        let heldPlaintextKeys = await cacheOutgoingMediaPlaintext(
            message.attachments,
            references: references,
            accountId: account.id,
            groupIdHex: draftKey.chatId
        )
        guard !Task.isCancelled, pendingOutgoingMediaMessage(id, in: draftKey) != nil else { return }
        setPendingOutgoingMediaWarmPlaintextKeys(heldPlaintextKeys, for: id, in: draftKey)

        do {
            _ = try await client.sendMediaAttachments(
                accountRef: account.accountRef,
                groupIdHex: draftKey.chatId,
                attachments: references,
                caption: message.caption.isEmpty ? nil : message.caption
            )
        } catch {
            // The blobs are on Blossom and the references stay valid, so a retry only has to
            // re-publish — but it re-uploads anyway rather than trusting a reference whose failure
            // mode we cannot see from here.
            lastError = error.localizedDescription
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
        removePendingOutgoingMediaMessage(id, in: draftKey)
    }

    /// A Blossom upload owned by an outgoing message rather than by the composer.
    ///
    /// Deliberately not `beginPendingMediaUpload`: the attachment has already left the composer, so
    /// there is no tile to report progress to and no entry in `pendingMediaUploadTasks` that anyone
    /// would ever reclaim.
    private func outgoingMediaUploadTask(
        _ attachment: PendingMediaAttachment,
        accountRef: String,
        groupIdHex: String,
        client: any MarmotRuntime
    ) -> Task<MediaAttachmentReferenceFfi?, Never> {
        Task { [weak self] () -> MediaAttachmentReferenceFfi? in
            do {
                let result = try await client.uploadMedia(
                    accountRef: accountRef,
                    groupIdHex: groupIdHex,
                    request: MediaUploadRequestFfi(
                        attachments: [attachment.uploadRequest],
                        caption: nil,
                        send: false,
                        blossomServer: nil
                    )
                )
                guard !Task.isCancelled else { return nil }
                guard let reference = result.attachments.first?.reference else {
                    self?.lastError = L10n.string("An attachment failed to upload")
                    return nil
                }
                return reference
            } catch is CancellationError {
                return nil
            } catch {
                guard !Task.isCancelled else { return nil }
                self?.lastError = error.localizedDescription
                return nil
            }
        }
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

    private func setPendingOutgoingMediaPublishedDigests(
        _ digests: Set<String>,
        for id: PendingOutgoingMediaMessage.ID,
        in draftKey: ComposerDraftKey
    ) {
        guard let index = pendingOutgoingMediaMessagesByConversation[draftKey]?.firstIndex(where: { $0.id == id })
        else { return }
        pendingOutgoingMediaMessagesByConversation[draftKey]?[index].publishedPlaintextSHAs = digests
    }

    private func setPendingOutgoingMediaWarmPlaintextKeys(
        _ keys: [MessageMediaDiskCacheKey],
        for id: PendingOutgoingMediaMessage.ID,
        in draftKey: ComposerDraftKey
    ) {
        guard let index = pendingOutgoingMediaMessagesByConversation[draftKey]?.firstIndex(where: { $0.id == id })
        else { return }
        // A retry re-uploads, so it seeds under fresh keys (a new nonce means a new ciphertext
        // digest). Let go of the attempt this one replaces, or its plaintexts would be held with
        // nothing left to claim them.
        let superseded = pendingOutgoingMediaMessagesByConversation[draftKey]?[index].warmPlaintextKeys ?? []
        for key in superseded where !keys.contains(key) {
            outgoingMediaWarmPlaintexts.remove(for: key)
        }
        pendingOutgoingMediaMessagesByConversation[draftKey]?[index].warmPlaintextKeys = keys
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
        releaseWarmPlaintexts(ofMessagesMatching: id, in: messages)
        messages.removeAll { $0.id == id }
        pendingOutgoingMediaMessagesByConversation[draftKey] = messages.isEmpty ? nil : messages
    }

    /// Lets go of the plaintexts a retired message was holding for its published row. By this point
    /// the row has either rendered from them or is about to read the same bytes back from the
    /// encrypted disk cache, which is where they durably live.
    private func releaseWarmPlaintexts(
        ofMessagesMatching id: PendingOutgoingMediaMessage.ID?,
        in messages: [PendingOutgoingMediaMessage]
    ) {
        for message in messages where id == nil || message.id == id {
            for key in message.warmPlaintextKeys {
                outgoingMediaWarmPlaintexts.remove(for: key)
            }
        }
    }
}
