//
//  WorkspaceState+Drafts.swift
//  whitenoise-mac
//
//  Durable, encrypted composer-draft persistence through MarmotKit.
//

import Foundation
import MarmotKit

private nonisolated struct ComposerDraftPersistenceSnapshot: Sendable {
    let content: String
    let replyToMessageIdHex: String?
    let mediaAttachments: [MessageDraftAttachmentFfi]

    var isEmpty: Bool {
        content.isEmpty && replyToMessageIdHex == nil && mediaAttachments.isEmpty
    }
}

@MainActor
extension WorkspaceState {
    private static let composerDraftSaveDebounceNanoseconds: UInt64 = 400_000_000

    /// Mark one conversation's effective composer draft dirty and coalesce rapid text changes
    /// into a single encrypted SQLCipher upsert. While editing an already-sent message, the
    /// effective draft is the unsent composer state preserved by `MessageEditContext`, not the
    /// temporary edit text occupying the field.
    func composerDraftDidChange(for key: ComposerDraftKey) {
        restoredComposerDraftKeys.insert(key)
        guard client != nil, accounts.contains(where: { $0.id == key.accountId }) else { return }

        composerDraftMutationGenerations[key, default: 0] &+= 1
        let generation = composerDraftMutationGenerations[key] ?? 0
        dirtyComposerDraftKeys.insert(key)
        composerDraftPersistenceTasks[key]?.cancel()
        composerDraftPersistenceTasks[key] = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: Self.composerDraftSaveDebounceNanoseconds)
            } catch {
                return
            }
            await self?.persistComposerDraft(for: key, generation: generation)
        }
    }

    /// Flush every dirty draft through the normal off-main FFI boundary. Account teardown uses
    /// the scoped form before non-destructive sign-out so the encrypted draft survives sign-in.
    func flushComposerDraftPersistence(forAccountId accountId: String? = nil) async {
        let keys = dirtyComposerDraftKeys
            .filter { accountId == nil || $0.accountId == accountId }
            .sorted {
                if $0.accountId != $1.accountId { return $0.accountId < $1.accountId }
                return $0.chatId < $1.chatId
            }
        for key in keys {
            composerDraftPersistenceTasks[key]?.cancel()
            guard let generation = composerDraftMutationGenerations[key] else { continue }
            await persistComposerDraft(for: key, generation: generation)
        }
    }

    /// `NSApplication.willTerminateNotification` cannot await an asynchronous task. Perform the
    /// final small local-database flush synchronously so edits inside the debounce window survive
    /// an ordinary app quit. Interactive saves continue to use `runOffMain`.
    func flushComposerDraftPersistenceSynchronouslyForTermination() {
        guard let client else { return }
        for task in composerDraftPersistenceTasks.values {
            task.cancel()
        }
        composerDraftPersistenceTasks.removeAll()

        let keys = dirtyComposerDraftKeys
        for key in keys {
            guard let account = accounts.first(where: { $0.id == key.accountId }) else { continue }
            let snapshot = composerDraftPersistenceSnapshot(for: key)
            do {
                if snapshot.isEmpty {
                    try client.deleteMessageDraft(accountRef: account.accountRef, groupIdHex: key.chatId)
                } else {
                    _ = try client.saveMessageDraft(
                        accountRef: account.accountRef,
                        groupIdHex: key.chatId,
                        content: snapshot.content,
                        replyToMessageIdHex: snapshot.replyToMessageIdHex,
                        mediaAttachments: snapshot.mediaAttachments
                    )
                }
                dirtyComposerDraftKeys.remove(key)
            } catch {
                // Termination is already committed and there is no reliable UI surface left.
                // Keep the key dirty in case termination is cancelled by the system.
            }
        }
    }

    /// Load a selected conversation's full draft once per session. The mutation-generation check
    /// makes live typing authoritative if it races the blocking FFI read or member-name hydration.
    func restoreComposerDraftIfNeeded(accountId: String, groupIdHex: String) async {
        let key = ComposerDraftKey(accountId: accountId, chatId: groupIdHex)
        guard !restoredComposerDraftKeys.contains(key),
            let client,
            let account = accounts.first(where: { $0.id == accountId })
        else { return }

        if !composerDraftPersistenceSnapshot(for: key).isEmpty {
            restoredComposerDraftKeys.insert(key)
            return
        }

        let startingGeneration = composerDraftMutationGenerations[key] ?? 0
        restoredComposerDraftKeys.insert(key)
        do {
            let storedDraft = try await runOffMain {
                try client.messageDraft(accountRef: account.accountRef, groupIdHex: groupIdHex)
            }

            let mentionNames: MarkdownMentionNames
            if storedDraft?.content.contains("@npub1") == true,
                let members = await cachedGroupMembers(
                    groupIdHex: groupIdHex,
                    account: account,
                    client: client
                )
            {
                mentionNames = Self.mentionNames(from: members)
            } else {
                mentionNames = [:]
            }

            guard composerDraftMutationGenerations[key] ?? 0 == startingGeneration,
                composerDraftPersistenceSnapshot(for: key).isEmpty
            else { return }
            guard let storedDraft else { return }

            if storedDraft.content.isEmpty,
                storedDraft.replyToMessageIdHex == nil,
                storedDraft.mediaAttachments.isEmpty
            {
                await deletePersistedComposerDraft(
                    for: key,
                    accountRef: account.accountRef,
                    client: client
                )
                return
            }

            let presentation = MentionDisplayResolver.composerDraftPresentation(
                in: storedDraft.content,
                mentionNames: mentionNames
            )
            draftTextByConversation[key] = presentation.text.isEmpty ? nil : presentation.text
            composerMentionSelectionsByConversation[key] =
                presentation.selections.isEmpty ? nil : presentation.selections
            if let targetMessageId = storedDraft.replyToMessageIdHex {
                replyDraftContextByConversation[key] = MessageReplyContext(
                    targetMessageId: targetMessageId,
                    senderName: L10n.string("Reply"),
                    body: DisplayText.short(targetMessageId, head: 12, tail: 8)
                )
            }
            let attachments = storedDraft.mediaAttachments
                .prefix(OutgoingMediaDraftProcessor.maxAttachmentCount)
                .map(Self.pendingMediaAttachment(from:))
            pendingMediaAttachmentsByConversation[key] = attachments.isEmpty ? nil : attachments
            pendingMediaUploadStatesByConversation[key] = nil
        } catch {
            restoredComposerDraftKeys.remove(key)
            setBackgroundStatus(
                String(format: L10n.string("A saved draft could not be restored: %@"), error.localizedDescription)
            )
        }
    }

    /// Replace the restored reply placeholder once its target is present in the materialized
    /// timeline. The stable target id remains usable even when the target is outside the window.
    func hydrateRestoredReplyContext(accountId: String, groupIdHex: String) {
        let key = ComposerDraftKey(accountId: accountId, chatId: groupIdHex)
        guard let context = replyDraftContextByConversation[key],
            let message = timelineMessage(groupIdHex: groupIdHex, messageId: context.targetMessageId)
        else { return }
        replyDraftContextByConversation[key] = MessageReplyContext(
            targetMessageId: context.targetMessageId,
            senderName: message.senderName,
            body: message.replyPreviewText
        )
    }

    /// A successful send must win over any debounced or already-queued save for the same key.
    /// The shared serial FFI queue orders an in-flight save before this awaited delete.
    func deletePersistedComposerDraft(
        for key: ComposerDraftKey,
        accountRef: String,
        client: any MarmotRuntime
    ) async {
        composerDraftPersistenceTasks[key]?.cancel()
        composerDraftPersistenceTasks[key] = nil
        composerDraftMutationGenerations[key, default: 0] &+= 1
        let generation = composerDraftMutationGenerations[key] ?? 0
        dirtyComposerDraftKeys.insert(key)
        restoredComposerDraftKeys.insert(key)
        do {
            try await runOffMain {
                try client.deleteMessageDraft(accountRef: accountRef, groupIdHex: key.chatId)
            }
            guard composerDraftMutationGenerations[key] == generation else { return }
            dirtyComposerDraftKeys.remove(key)
        } catch {
            guard composerDraftMutationGenerations[key] == generation else { return }
            setBackgroundStatus(
                String(format: L10n.string("A sent draft could not be removed: %@"), error.localizedDescription)
            )
        }
    }

    /// Forget coordinator state without mutating the encrypted store. Used when account/group
    /// teardown already owns the durable-data lifecycle (sign-out retention, account removal,
    /// group deletion cascade, or Delete All Local Data).
    func discardComposerDraftPersistenceState(for key: ComposerDraftKey) {
        composerDraftPersistenceTasks[key]?.cancel()
        composerDraftPersistenceTasks[key] = nil
        composerDraftMutationGenerations[key] = nil
        dirtyComposerDraftKeys.remove(key)
        restoredComposerDraftKeys.remove(key)
    }

    func discardComposerDraftPersistenceState(forAccountId accountId: String) {
        let keys = Set(composerDraftPersistenceTasks.keys)
            .union(composerDraftMutationGenerations.keys)
            .union(dirtyComposerDraftKeys)
            .union(restoredComposerDraftKeys)
            .filter { $0.accountId == accountId }
        for key in keys {
            discardComposerDraftPersistenceState(for: key)
        }
    }

    func discardAllComposerDraftPersistenceState() {
        for task in composerDraftPersistenceTasks.values {
            task.cancel()
        }
        composerDraftPersistenceTasks.removeAll()
        composerDraftMutationGenerations.removeAll()
        dirtyComposerDraftKeys.removeAll()
        restoredComposerDraftKeys.removeAll()
    }

    private func persistComposerDraft(for key: ComposerDraftKey, generation: UInt64) async {
        guard composerDraftMutationGenerations[key] == generation,
            dirtyComposerDraftKeys.contains(key),
            let client,
            let account = accounts.first(where: { $0.id == key.accountId })
        else { return }
        defer {
            if composerDraftMutationGenerations[key] == generation {
                composerDraftPersistenceTasks[key] = nil
            }
        }

        let snapshot = composerDraftPersistenceSnapshot(for: key)
        do {
            if snapshot.isEmpty {
                try await runOffMain {
                    try client.deleteMessageDraft(accountRef: account.accountRef, groupIdHex: key.chatId)
                }
            } else {
                _ = try await runOffMain {
                    try client.saveMessageDraft(
                        accountRef: account.accountRef,
                        groupIdHex: key.chatId,
                        content: snapshot.content,
                        replyToMessageIdHex: snapshot.replyToMessageIdHex,
                        mediaAttachments: snapshot.mediaAttachments
                    )
                }
            }
            guard composerDraftMutationGenerations[key] == generation else { return }
            dirtyComposerDraftKeys.remove(key)
        } catch {
            guard composerDraftMutationGenerations[key] == generation else { return }
            setBackgroundStatus(
                String(format: L10n.string("A draft could not be saved: %@"), error.localizedDescription)
            )
        }
    }

    private func composerDraftPersistenceSnapshot(
        for key: ComposerDraftKey
    ) -> ComposerDraftPersistenceSnapshot {
        let text: String
        let mentionSelections: [ComposerMentionSelection]
        let replyContext: MessageReplyContext?
        let mediaAttachments: [PendingMediaAttachment]
        if let edit = editingMessageContextByConversation[key] {
            text = edit.preservedDraft
            mentionSelections = edit.preservedMentionSelections
            replyContext = edit.preservedReplyContext
            mediaAttachments = edit.preservedMediaAttachments
        } else {
            text = draftTextByConversation[key] ?? ""
            mentionSelections = composerMentionSelectionsByConversation[key] ?? []
            replyContext = replyDraftContextByConversation[key]
            mediaAttachments = pendingMediaAttachmentsByConversation[key] ?? []
        }

        // Picker-selected mentions retain their exact npub identity across restart. Typed names
        // without a marker stay visible text and continue through the normal send-time inference.
        let canonicalContent = ComposerMentionCanonicalizer.canonicalize(
            text,
            selections: mentionSelections,
            candidates: []
        )
        return ComposerDraftPersistenceSnapshot(
            content: canonicalContent,
            replyToMessageIdHex: replyContext?.targetMessageId,
            mediaAttachments: mediaAttachments.map(Self.messageDraftAttachment(from:))
        )
    }

    private nonisolated static func messageDraftAttachment(
        from attachment: PendingMediaAttachment
    ) -> MessageDraftAttachmentFfi {
        MessageDraftAttachmentFfi(
            id: attachment.id.uuidString.lowercased(),
            fileName: attachment.fileName,
            mediaType: attachment.mediaType,
            plaintext: attachment.data,
            dim: attachment.dim,
            thumbhash: attachment.thumbhash,
            durationSeconds: attachment.durationSeconds,
            waveformSamples: attachment.waveformSamples.map(Double.init)
        )
    }

    private nonisolated static func pendingMediaAttachment(
        from attachment: MessageDraftAttachmentFfi
    ) -> PendingMediaAttachment {
        PendingMediaAttachment(
            id: UUID(uuidString: attachment.id) ?? UUID(),
            fileName: attachment.fileName,
            mediaType: attachment.mediaType,
            data: attachment.plaintext,
            dim: attachment.dim,
            thumbhash: attachment.thumbhash,
            durationSeconds: attachment.durationSeconds,
            waveformSamples: attachment.waveformSamples.map { CGFloat($0) }
        )
    }
}
