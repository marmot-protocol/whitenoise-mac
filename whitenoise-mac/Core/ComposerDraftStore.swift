//
//  ComposerDraftStore.swift
//  whitenoise-mac
//
//  How a composer's draft is kept in MDK's encrypted draft store. An attachment's bytes cross the
//  FFI once: a small one inline on its first save, a large one as a file MDK copies into its media
//  store (`stageMessageDraftAttachmentFile`). Every later save names a held attachment by id, so
//  saving text never copies a body again, and the draft owns its files across relaunches.
//

import Foundation
import MarmotKit

/// What the composer holds for one conversation, as it is saved.
nonisolated struct ComposerDraftContents: Sendable {
    let content: String
    let replyToMessageIdHex: String?
    let attachments: [PendingMediaAttachment]

    /// Nothing in the composer: the stored draft is cleared, which also discards a file still
    /// copying into it.
    var isEmpty: Bool {
        content.isEmpty && replyToMessageIdHex == nil && attachments.isEmpty
    }
}

nonisolated enum ComposerDraftStore {
    /// A save that loses a revision race to a concurrent save or a finished file copy re-reads the
    /// draft and tries again; more than this many in a row is a real failure.
    static let maxSaveAttempts = 3

    /// The draft id an attachment is saved under; a restored one keeps the same `UUID`.
    static func draftAttachmentId(for attachment: PendingMediaAttachment) -> String {
        attachment.id.uuidString.lowercased()
    }

    /// The inputs that make the stored draft hold exactly the composer's attachments, in its order.
    ///
    /// - An attachment the draft already holds is `.retained`, so its body is not copied again.
    /// - A small one it does not hold yet goes `.inline`.
    /// - A large one it does not hold yet is left unnamed: its file is still copying in, and MDK
    ///   keeps whatever a save does not name, so the copy lands whatever this save does.
    /// - One the draft holds that the composer dropped is `.removed`, which also deletes its file.
    ///   A save keeps unnamed attachments since MarmotKit 0.19.0, so a removal must be explicit.
    static func saveInputs(
        for attachments: [PendingMediaAttachment],
        stored: [SelectedMessageDraftAttachmentFfi]
    ) -> [MessageDraftAttachmentInputFfi] {
        let storedIds = Set(stored.map(\.id))
        var inputs: [MessageDraftAttachmentInputFfi] = []
        var composerIds = Set<String>()
        for attachment in attachments {
            let id = draftAttachmentId(for: attachment)
            composerIds.insert(id)
            if storedIds.contains(id) {
                inputs.append(.retained(id: id))
            } else if OutgoingMediaDraftProcessor.isInline(attachment) {
                inputs.append(.inline(attachment: inlineAttachment(from: attachment)))
            }
        }
        for attachment in stored where !composerIds.contains(attachment.id) {
            inputs.append(.removed(id: attachment.id))
        }
        return inputs
    }

    /// Saves `contents` against the current revision, or clears the draft when it is empty.
    /// Blocking: run it on `FFIExecutor` (or at termination, where nothing else can run).
    static func save(
        _ contents: ComposerDraftContents,
        accountRef: String,
        groupIdHex: String,
        client: any MarmotRuntime
    ) throws {
        for attempt in 1...maxSaveAttempts {
            let selected = try client.selectedMessageDraft(accountRef: accountRef, groupIdHex: groupIdHex)
            do {
                if contents.isEmpty {
                    _ = try client.clearMessageDraftIfRevision(accountRef: accountRef, revision: selected.revision)
                } else {
                    _ = try client.saveMessageDraftInputsIfRevision(
                        accountRef: accountRef,
                        revision: selected.revision,
                        content: contents.content,
                        replyToMessageIdHex: contents.replyToMessageIdHex,
                        mediaAttachments: saveInputs(
                            for: contents.attachments,
                            stored: selected.draft?.mediaAttachments ?? []
                        )
                    )
                }
                return
            } catch MarmotKitError.MessageDraftRevisionConflict where attempt < maxSaveAttempts {
                continue
            }
        }
    }

    /// Copies a large attachment into the draft as a file. MDK reads it from a scratch copy of the
    /// composer's bytes, removed once the call returns. Throws `MessageDraftRevisionConflict` when
    /// the draft changed under the call: before the copy started (retry against a fresh revision)
    /// or by being cleared or sent while it copied (the copy is gone, and should stay so).
    ///
    /// MDK measures the copy against everything the draft holds, so first the stored attachments
    /// the composer no longer has are removed: a replaced recording or audio file must not count
    /// against its replacement. `composerAttachments` is read as the copy starts, not when the
    /// attachment was picked, so it never removes an attachment picked (and copied) since; nil
    /// (the composer is gone) removes nothing. That save keeps the stored text; the next debounced
    /// save brings it up to date.
    static func stageFile(
        _ attachment: PendingMediaAttachment,
        composerAttachments: @escaping @MainActor @Sendable () -> [PendingMediaAttachment]?,
        accountRef: String,
        groupIdHex: String,
        client: any MarmotRuntime
    ) async throws {
        let control = MediaFileTransferControlFfi()
        let id = draftAttachmentId(for: attachment)
        try await MediaFileUploadRunner.run([attachment], control: control) { requests in
            guard let source = requests.first else { throw MediaFileUploadFailure.sourceUnavailable }
            let keptIds = await composerAttachments().map { Set($0.map(draftAttachmentId(for:))) }
            let selected = try await FFIExecutor.run {
                let selected = try client.selectedMessageDraft(accountRef: accountRef, groupIdHex: groupIdHex)
                guard let draft = selected.draft, let keptIds else { return selected }
                let dropped = draft.mediaAttachments.filter { !keptIds.contains($0.id) }
                guard !dropped.isEmpty else { return selected }
                return try client.saveMessageDraftInputsIfRevision(
                    accountRef: accountRef,
                    revision: selected.revision,
                    content: draft.content,
                    replyToMessageIdHex: draft.replyToMessageIdHex,
                    mediaAttachments: dropped.map { .removed(id: $0.id) }
                )
            }
            _ = try await client.stageMessageDraftAttachmentFile(
                accountRef: accountRef,
                revision: selected.revision,
                request: MessageDraftAttachmentFileRequestFfi(
                    id: id,
                    sourcePath: source.sourcePath,
                    expectedSize: source.expectedSize,
                    fileName: attachment.fileName,
                    mediaType: attachment.mediaType,
                    dim: attachment.dim,
                    thumbhash: attachment.thumbhash,
                    durationSeconds: attachment.durationSeconds,
                    waveformSamples: attachment.waveformSamples.map(Double.init)
                ),
                control: control
            )
        }
    }

    /// The stored draft with every attachment's bytes. A file-backed attachment is read through a
    /// handoff copy that is cloned, mapped and unlinked (`PickedMediaFile`), then released, so its
    /// bytes are never resident; an inline one is read whole. One whose bytes are gone is left out.
    static func restore(
        accountRef: String,
        groupIdHex: String,
        client: any MarmotRuntime
    ) async throws -> (draft: SelectedMessageDraftContentFfi?, attachments: [MessageDraftAttachmentFfi]) {
        let (selected, inlineBodies) = try await FFIExecutor.run {
            let selected = try client.selectedMessageDraft(accountRef: accountRef, groupIdHex: groupIdHex)
            var bodies: [String: Data] = [:]
            for attachment in selected.draft?.mediaAttachments ?? [] where !attachment.fileBacked {
                guard
                    let plaintext = try client.messageDraftAttachmentIfRevision(
                        accountRef: accountRef,
                        revision: selected.revision,
                        attachmentId: attachment.id
                    )
                else { throw MarmotKitError.MessageDraftRevisionConflict }
                bodies[attachment.id] = plaintext
            }
            return (selected, bodies)
        }
        var attachments: [MessageDraftAttachmentFfi] = []
        for attachment in selected.draft?.mediaAttachments ?? [] {
            let plaintext: Data?
            if attachment.fileBacked {
                plaintext = try await fileBody(
                    of: attachment.id,
                    revision: selected.revision,
                    accountRef: accountRef,
                    client: client
                )
            } else {
                plaintext = inlineBodies[attachment.id]
            }
            guard let plaintext else { continue }
            attachments.append(
                MessageDraftAttachmentFfi(
                    id: attachment.id,
                    fileName: attachment.fileName,
                    mediaType: attachment.mediaType,
                    plaintext: plaintext,
                    dim: attachment.dim,
                    thumbhash: attachment.thumbhash,
                    durationSeconds: attachment.durationSeconds,
                    waveformSamples: attachment.waveformSamples
                ))
        }
        return (selected.draft, attachments)
    }

    private static func fileBody(
        of attachmentId: String,
        revision: MessageDraftRevisionFfi,
        accountRef: String,
        client: any MarmotRuntime
    ) async throws -> Data? {
        let control = MediaFileTransferControlFfi()
        // Shielded: cancelling the task awaiting a handoff can drop a lease it already took.
        let handoff = try await AttachmentHandoffOpening.shielded(
            cancel: { control.cancel() },
            {
                try await client.openMessageDraftAttachmentHandoff(
                    accountRef: accountRef,
                    revision: revision,
                    attachmentId: attachmentId,
                    control: control
                )
            }
        )
        guard let handoff else { return nil }
        let lease = AttachmentHandoffLease(handoff, releaser: RuntimeHandoffReleaser(runtime: client))
        defer { lease.release() }
        return try PickedMediaFile.mappedData(from: lease.url)
    }

    private static func inlineAttachment(from attachment: PendingMediaAttachment) -> MessageDraftAttachmentFfi {
        MessageDraftAttachmentFfi(
            id: draftAttachmentId(for: attachment),
            fileName: attachment.fileName,
            mediaType: attachment.mediaType,
            plaintext: attachment.data,
            dim: attachment.dim,
            thumbhash: attachment.thumbhash,
            durationSeconds: attachment.durationSeconds,
            waveformSamples: attachment.waveformSamples.map(Double.init)
        )
    }
}
