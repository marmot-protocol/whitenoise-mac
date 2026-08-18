//
//  WorkspaceState+Media.swift
//  whitenoise-mac
//
//  Media behavior extracted from WorkspaceState.swift (no behavior change).
//

import AVFoundation
import AppKit
import Combine
import Foundation
import MarmotKit
import Observation
import SwiftUI
import UserNotifications

private nonisolated struct MediaReferenceIndexTaskFailure: Error {
    let underlying: Error
}

private nonisolated struct MediaAttachmentDownloadTaskFailure: Error {
    let underlying: Error
}

/// One slot of a concurrently prepared batch. `index` is the position the user chose the file in,
/// which the group's completion order does not preserve; a nil `attachment` with a nil
/// `errorDescription` is a cancelled slot, which is silent by design.
private nonisolated struct PreparedMediaAttachmentOutcome: Sendable {
    let index: Int
    let attachment: PendingMediaAttachment?
    let errorDescription: String?
}

@MainActor
extension WorkspaceState {
    func clearAllComposerDrafts() {
        discardAllComposerDraftPersistenceState()
        cancelAllPendingMediaUploads()
        cancelAllPendingOutgoingMediaSends()
        cancelAllOutgoingTextSends()
        draftTextByConversation.removeAll()
        composerMentionSelectionsByConversation.removeAll()
        replyDraftContextByConversation.removeAll()
        editingMessageContextByConversation.removeAll()
        pendingMediaAttachmentsByConversation.removeAll()
        pendingMediaUploadStatesByConversation.removeAll()
    }

    func refreshMediaCacheFootprint() async {
        guard !isClearingMediaCache else { return }

        mediaCacheFootprintRefreshGeneration &+= 1
        let generation = mediaCacheFootprintRefreshGeneration
        isLoadingMediaCacheFootprint = true
        defer {
            if mediaCacheFootprintRefreshGeneration == generation {
                isLoadingMediaCacheFootprint = false
            }
        }

        let footprint = await mediaDiskCache.footprint()
        guard !Task.isCancelled,
            mediaCacheFootprintRefreshGeneration == generation,
            !isClearingMediaCache
        else { return }
        mediaCacheFootprint = footprint
    }

    /// Clears only regenerable attachment caches. Protocol databases, accounts, drafts, and app
    /// preferences remain untouched; full-data deletion continues to own key removal and the
    /// broader new-install reset.
    func clearMediaCache() async {
        guard !isClearingMediaCache else { return }

        mediaCacheFootprintRefreshGeneration &+= 1
        isLoadingMediaCacheFootprint = false
        isClearingMediaCache = true
        mediaCacheReclaimedByteCount = nil
        suppressAllMediaDiskStores()
        defer {
            resumeAllMediaDiskStores()
            isClearingMediaCache = false
        }

        // Cancel old downloads/stores before the purge and replace every visible attachment's
        // state. The disk cache's own generation gate independently rejects a stale direct store.
        resetMediaDownloadStateStores()
        clearSharedMediaThumbnailCache()
        RemoteImageLoader.shared.clearLocalCache()
        mediaCacheGeneration &+= 1

        let before = await mediaDiskCache.footprint()
        await mediaDiskCache.purgeAll()
        let after = await mediaDiskCache.footprint()

        mediaCacheFootprint = after
        mediaCacheReclaimedByteCount =
            before.byteCount > after.byteCount
            ? before.byteCount - after.byteCount
            : 0
    }

    func clearComposerDrafts(for chatIds: [String], accountId: String) {
        for chatId in chatIds {
            let key = ComposerDraftKey(accountId: accountId, chatId: chatId)
            discardComposerDraftPersistenceState(for: key)
            cancelPendingMediaUploads(for: key)
            cancelPendingOutgoingMediaSends(for: key)
            cancelOutgoingTextSends(for: key)
            draftTextByConversation[key] = nil
            composerMentionSelectionsByConversation[key] = nil
            replyDraftContextByConversation[key] = nil
            editingMessageContextByConversation[key] = nil
            pendingMediaAttachmentsByConversation[key] = nil
            pendingMediaUploadStatesByConversation[key] = nil
        }
    }

    func clearComposerDrafts(forAccountId accountId: String) {
        discardComposerDraftPersistenceState(forAccountId: accountId)
        cancelPendingMediaUploads(forAccountId: accountId)
        cancelPendingOutgoingMediaSends(forAccountId: accountId)
        cancelOutgoingTextSends(forAccountId: accountId)
        for key in draftTextByConversation.keys.filter({ $0.accountId == accountId }) {
            draftTextByConversation[key] = nil
        }
        for key in composerMentionSelectionsByConversation.keys.filter({ $0.accountId == accountId }) {
            composerMentionSelectionsByConversation[key] = nil
        }
        for key in replyDraftContextByConversation.keys.filter({ $0.accountId == accountId }) {
            replyDraftContextByConversation[key] = nil
        }
        for key in editingMessageContextByConversation.keys.filter({ $0.accountId == accountId }) {
            editingMessageContextByConversation[key] = nil
        }
        for key in pendingMediaAttachmentsByConversation.keys.filter({ $0.accountId == accountId }) {
            pendingMediaAttachmentsByConversation[key] = nil
        }
        for key in pendingMediaUploadStatesByConversation.keys.filter({ $0.accountId == accountId }) {
            pendingMediaUploadStatesByConversation[key] = nil
        }
    }

    func mediaDiskStoreGuard(forAccountId accountId: String) -> MediaDiskStoreGuard {
        MediaDiskStoreGuard(
            globalGeneration: mediaDiskStoreGlobalGeneration,
            accountGeneration: mediaDiskStoreAccountGenerations[accountId, default: 0]
        )
    }

    func isMediaDiskStoreAllowed(
        forAccountId accountId: String,
        storeGuard: MediaDiskStoreGuard
    ) -> Bool {
        storeGuard.globalGeneration == mediaDiskStoreGlobalGeneration
            && storeGuard.accountGeneration == mediaDiskStoreAccountGenerations[accountId, default: 0]
            && !isMediaDiskStoreGloballySuppressed
            && !mediaDiskStoreSuppressedAccountIds.contains(accountId)
            && activeAccountId == accountId
            && accounts.contains(where: { $0.id == accountId })
    }

    func isMediaDisplayAllowed(forAccountId accountId: String, groupIdHex: String) -> Bool {
        guard activeAccountId == accountId,
            accounts.contains(where: { $0.id == accountId })
        else { return false }

        if case .chat(let selectedGroupId) = selection {
            return selectedGroupId == groupIdHex
        }
        return true
    }

    func suppressMediaDiskStores(forAccountId accountId: String) {
        mediaDiskStoreAccountGenerations[accountId, default: 0] &+= 1
        mediaDiskStoreSuppressedAccountIds.insert(accountId)
        cancelMediaDiskStoreTasks(forAccountId: accountId)
    }

    func resumeMediaDiskStores(forAccountId accountId: String) {
        mediaDiskStoreSuppressedAccountIds.remove(accountId)
        mediaDiskStoreAccountGenerations[accountId, default: 0] &+= 1
    }

    func suppressAllMediaDiskStores() {
        mediaDiskStoreGlobalGeneration &+= 1
        isMediaDiskStoreGloballySuppressed = true
        cancelAllMediaDiskStoreTasks()
    }

    func resumeAllMediaDiskStores() {
        isMediaDiskStoreGloballySuppressed = false
        mediaDiskStoreGlobalGeneration &+= 1
    }

    func cancelMediaDiskStoreTasks(forAccountId accountId: String) {
        let cacheIDs = mediaDiskStoreTasks.compactMap { cacheID, tracked in
            tracked.accountId == accountId ? cacheID : nil
        }
        for cacheID in cacheIDs {
            mediaDiskStoreTasks[cacheID]?.task.cancel()
            mediaDiskStoreTasks[cacheID] = nil
        }
    }

    func cancelAllMediaDiskStoreTasks() {
        for tracked in mediaDiskStoreTasks.values {
            tracked.task.cancel()
        }
        mediaDiskStoreTasks.removeAll()
    }

    func scheduleMediaDiskCacheStore(
        _ download: MessageMediaDownload,
        for cacheKey: MessageMediaDiskCacheKey,
        accountId: String,
        storeGuard: MediaDiskStoreGuard
    ) {
        guard isMediaDiskStoreAllowed(forAccountId: accountId, storeGuard: storeGuard) else { return }

        let cacheID = cacheKey.cacheID
        mediaDiskStoreTasks[cacheID]?.task.cancel()
        nextMediaDiskStoreTaskToken &+= 1
        let token = nextMediaDiskStoreTaskToken
        let mediaDiskCache = mediaDiskCache
        let task = Task { [weak self, mediaDiskCache, download, cacheKey, accountId, storeGuard, cacheID, token] in
            guard !Task.isCancelled,
                self?.isMediaDiskStoreAllowed(forAccountId: accountId, storeGuard: storeGuard) == true
            else {
                self?.finishMediaDiskCacheStore(cacheID: cacheID, token: token)
                return
            }

            await mediaDiskCache.store(download, for: cacheKey)
            self?.finishMediaDiskCacheStore(cacheID: cacheID, token: token)
        }
        mediaDiskStoreTasks[cacheID] = MediaDiskStoreTask(
            accountId: accountId,
            token: token,
            task: task
        )
    }

    func finishMediaDiskCacheStore(cacheID: String, token: UInt64) {
        guard mediaDiskStoreTasks[cacheID]?.token == token else { return }
        mediaDiskStoreTasks[cacheID] = nil
    }

    func mediaDownloadState(for message: MessageItem, attachment: MessageMediaAttachment) -> MediaDownloadState {
        mediaDownloadStateStore(for: message, attachment: attachment).state
    }

    func mediaDownloadStateStore(
        for message: MessageItem,
        attachment: MessageMediaAttachment
    ) -> MediaDownloadStateStore {
        let key = mediaDownloadKey(message: message, attachment: attachment)
        if let store = mediaDownloads[key] {
            return store
        }
        let store = mediaDownloadStateStore(forKey: key)
        primeOwnSendMediaDownload(store, message: message, attachment: attachment)
        return store
    }

    /// Starts a just-sent attachment's download state at `.loaded`, from the plaintext the send is
    /// still holding.
    ///
    /// The send seeds the disk cache before it publishes, so the row that replaces the pending
    /// bubble does find its bytes — but that read is asynchronous, so the row rendered a spinner
    /// first and the sender watched their own image blink from loaded back to loading as the
    /// placeholder gave way. Handing the plaintext over synchronously makes the row's *first* frame
    /// the image, which is what makes the swap invisible.
    ///
    /// Gated on `isMediaDisplayAllowed` exactly like every other published download state: media
    /// must not appear for an account or a conversation the user is no longer looking at.
    private func primeOwnSendMediaDownload(
        _ store: MediaDownloadStateStore,
        message: MessageItem,
        attachment: MessageMediaAttachment
    ) {
        guard case .idle = store.state,
            let accountId = activeAccountId,
            !message.groupIdHex.isEmpty,
            !outgoingMediaWarmPlaintexts.isEmpty,
            isMediaDisplayAllowed(forAccountId: accountId, groupIdHex: message.groupIdHex),
            let download = outgoingMediaWarmPlaintexts.download(
                for: MessageMediaDiskCacheKey(
                    accountId: accountId,
                    groupIdHex: message.groupIdHex,
                    reference: attachment.reference
                )
            )
        else { return }
        store.update(.loaded(download))
    }

    func loadMediaAttachment(_ attachment: MessageMediaAttachment, for message: MessageItem) async {
        let key = mediaDownloadKey(message: message, attachment: attachment)
        // The priming variant, so a tap or an automatic download that reaches a just-sent
        // attachment before its row was ever rendered still resolves from the plaintext in hand.
        let stateStore = mediaDownloadStateStore(for: message, attachment: attachment)
        if case .loaded = stateStore.state {
            return
        }
        if case .loading = stateStore.state {
            return
        }

        guard let client, let activeAccount, !message.groupIdHex.isEmpty else {
            stateStore.update(.failed(L10n.string("Attachment unavailable")))
            return
        }

        let accountId = activeAccount.id
        let accountRef = activeAccount.accountRef
        let groupIdHex = message.groupIdHex
        let storeGuard = mediaDiskStoreGuard(forAccountId: accountId)
        stateStore.update(.loading)
        let cacheKey = MessageMediaDiskCacheKey(
            accountId: accountId,
            groupIdHex: groupIdHex,
            reference: attachment.reference
        )

        if let cachedDownload = await mediaDiskCache.cachedDownload(for: cacheKey) {
            guard
                canPublishMediaDownloadState(
                    forKey: key,
                    stateStore: stateStore,
                    accountId: accountId,
                    groupIdHex: groupIdHex
                )
            else {
                stateStore.update(.idle)
                return
            }
            stateStore.update(.loaded(cachedDownload))
            return
        }

        if case .loaded = stateStore.state {
            return
        }
        guard
            canPublishMediaDownloadState(
                forKey: key,
                stateStore: stateStore,
                accountId: accountId,
                groupIdHex: groupIdHex
            )
        else {
            stateStore.update(.idle)
            return
        }

        do {
            // Resolve first: the synchronous `listMedia` FFI may stall and must not consume one
            // of the scarce slots reserved for attachment downloads. Reference resolution bounds
            // its wait so cancellation or timeout can unwind while the detached FFI work continues.
            let reference = try await resolvedMediaReference(
                attachment.reference,
                accountId: accountId,
                accountRef: accountRef,
                groupIdHex: groupIdHex,
                client: client
            )
            guard
                canPublishMediaDownloadState(
                    forKey: key,
                    stateStore: stateStore,
                    accountId: accountId,
                    groupIdHex: groupIdHex
                )
            else {
                stateStore.update(.idle)
                return
            }

            if case .loaded = stateStore.state {
                return
            }
            guard
                canPublishMediaDownloadState(
                    forKey: key,
                    stateStore: stateStore,
                    accountId: accountId,
                    groupIdHex: groupIdHex
                )
            else {
                stateStore.update(.idle)
                return
            }

            let download = try await sharedMessageMediaDownload(
                cacheID: cacheKey.cacheID,
                cacheKey: cacheKey,
                mediaDownloadKey: key,
                accountId: accountId,
                accountRef: accountRef,
                groupIdHex: groupIdHex,
                reference: reference,
                client: client,
                storeGuard: storeGuard
            )
            guard
                canPublishMediaDownloadState(
                    forKey: key,
                    stateStore: stateStore,
                    accountId: accountId,
                    groupIdHex: groupIdHex
                )
            else {
                stateStore.update(.idle)
                return
            }
            stateStore.update(.loaded(download))
        } catch is CancellationError {
            guard isMediaDisplayAllowed(forAccountId: accountId, groupIdHex: groupIdHex) else {
                stateStore.update(.idle)
                return
            }
            if case .loading = stateStore.state {
                stateStore.update(.idle)
            }
        } catch {
            guard
                canPublishMediaDownloadState(
                    forKey: key,
                    stateStore: stateStore,
                    accountId: accountId,
                    groupIdHex: groupIdHex
                )
            else {
                stateStore.update(.idle)
                return
            }
            stateStore.update(.failed(error.localizedDescription))
        }
    }

    /// Lazily allocates per-attachment stores from SwiftUI body lookup without observing the
    /// backing dictionary; `mediaDownloads` is `@ObservationIgnored`, and pruning bounds it to
    /// attachments that still belong to the active timeline window.
    func mediaDownloadStateStore(forKey key: String) -> MediaDownloadStateStore {
        if let store = mediaDownloads[key] {
            return store
        }
        let store = MediaDownloadStateStore()
        mediaDownloads[key] = store
        return store
    }

    private func canPublishMediaDownloadState(
        forKey key: String,
        stateStore: MediaDownloadStateStore,
        accountId: String,
        groupIdHex: String
    ) -> Bool {
        isMediaDisplayAllowed(forAccountId: accountId, groupIdHex: groupIdHex)
            && mediaDownloads[key] === stateStore
    }

    func addMediaAttachments(from urls: [URL]) async {
        guard let draftKey = selectedComposerDraftKey else { return }
        guard canBeginMediaAttachmentSelection() else { return }
        let fileURLs = urls.filter(\.isFileURL)
        guard !fileURLs.isEmpty else { return }

        let selected = Array(fileURLs.prefix(remainingMediaAttachmentSlots))
        if selected.count < fileURLs.count {
            presentMaxMediaAttachmentWarning()
        }

        let prepared = await Self.preparedMediaAttachments(for: selected) { url in
            try await Self.preparedMediaAttachment(fromFileURL: url)
        }
        stagePreparedMediaAttachments(prepared, for: draftKey)
    }

    func addPastedMediaAttachments(from pasteboard: NSPasteboard = .general) async {
        let pasteboardAttachments = OutgoingMediaPasteboardReader.attachments(from: pasteboard)
        await addPastedMediaAttachments(pasteboardAttachments)
    }

    func addPastedMediaAttachments(_ pasteboardAttachments: [OutgoingMediaPasteboardAttachment]) async {
        guard let draftKey = selectedComposerDraftKey else { return }
        guard canBeginMediaAttachmentSelection() else { return }
        guard !pasteboardAttachments.isEmpty else { return }

        let selected = Array(pasteboardAttachments.prefix(remainingMediaAttachmentSlots))
        if selected.count < pasteboardAttachments.count {
            presentMaxMediaAttachmentWarning()
        }

        let prepared = await Self.preparedMediaAttachments(for: selected) { item in
            switch item.payload {
            case .fileURL(let url):
                return try await Self.preparedMediaAttachment(fromFileURL: url)
            case .imageData(let data, let typeIdentifier):
                return try await OutgoingMediaDraftProcessor.preparedAttachment(
                    fromPastedImageData: data,
                    typeIdentifier: typeIdentifier
                )
            }
        }
        stagePreparedMediaAttachments(prepared, for: draftKey)
    }

    /// Prepares a whole selection at once, returning the outcomes in the order the user chose them.
    ///
    /// Preparation is the expensive half of staging — read, decode, downsample, re-encode — and an
    /// attachment's upload cannot start until its own preparation is done. Preparing one file at a
    /// time therefore also staggered the uploads: the last image of a ten-file drop did not begin
    /// uploading until the other nine had been re-encoded. A failed item is reported rather than
    /// aborting the batch, so one unsupported file no longer costs the user the rest of the drop.
    private nonisolated static func preparedMediaAttachments<Item: Sendable>(
        for items: [Item],
        prepare: @Sendable @escaping (Item) async throws -> PendingMediaAttachment
    ) async -> [PreparedMediaAttachmentOutcome] {
        await withTaskGroup(of: PreparedMediaAttachmentOutcome.self) { group in
            for (index, item) in items.enumerated() {
                group.addTask {
                    do {
                        return PreparedMediaAttachmentOutcome(
                            index: index,
                            attachment: try await prepare(item),
                            errorDescription: nil
                        )
                    } catch is CancellationError {
                        return PreparedMediaAttachmentOutcome(index: index, attachment: nil, errorDescription: nil)
                    } catch {
                        return PreparedMediaAttachmentOutcome(
                            index: index,
                            attachment: nil,
                            errorDescription: error.localizedDescription
                        )
                    }
                }
            }
            var outcomes: [PreparedMediaAttachmentOutcome] = []
            for await outcome in group {
                outcomes.append(outcome)
            }
            return outcomes.sorted { $0.index < $1.index }
        }
    }

    private nonisolated static func preparedMediaAttachment(fromFileURL url: URL) async throws -> PendingMediaAttachment
    {
        let isSecurityScoped = url.startAccessingSecurityScopedResource()
        defer {
            if isSecurityScoped {
                url.stopAccessingSecurityScopedResource()
            }
        }
        return try await OutgoingMediaDraftProcessor.preparedAttachment(fromFileURL: url)
    }

    /// Stages a prepared batch in selection order, surfacing at most one failure. Preparation ran
    /// while the user could still switch chats, so every append re-checks the selection and the
    /// first refusal ends the batch (#245).
    private func stagePreparedMediaAttachments(
        _ outcomes: [PreparedMediaAttachmentOutcome],
        for draftKey: ComposerDraftKey
    ) {
        // Preparation ran while the composer was live, and a recording can only start from an
        // empty one — which this batch was, right up until it landed. Yield to the recording the
        // same way `finishVoiceRecording` yields to a meanwhile-staged file, or the batch would
        // append itself alongside a voice message that is meant to go out on its own.
        guard stagedVoiceMessage == nil else {
            presentVoiceMessageIsSentAloneWarning()
            return
        }
        var failure: String?
        for outcome in outcomes {
            guard let attachment = outcome.attachment else {
                failure = outcome.errorDescription ?? failure
                continue
            }
            guard appendPendingMediaAttachmentIfSelectionUnchanged(attachment, for: draftKey) else { return }
        }
        if let failure {
            lastError = failure
        }
    }

    func removePendingMediaAttachment(_ id: PendingMediaAttachment.ID) {
        guard let selectedComposerDraftKey else { return }
        cancelPendingMediaUpload(id)
        var attachments = pendingMediaAttachmentsByConversation[selectedComposerDraftKey] ?? []
        attachments.removeAll { $0.id == id }
        pendingMediaAttachmentsByConversation[selectedComposerDraftKey] = attachments.isEmpty ? nil : attachments
        var uploadStates = pendingMediaUploadStatesByConversation[selectedComposerDraftKey] ?? [:]
        uploadStates[id] = nil
        pendingMediaUploadStatesByConversation[selectedComposerDraftKey] = uploadStates.isEmpty ? nil : uploadStates
        composerDraftDidChange(for: selectedComposerDraftKey)
    }

    /// Upload a staged attachment to Blossom without publishing it, so pressing Send later only
    /// has to hand the resulting reference to `sendMediaAttachments`. The core exposes exactly
    /// this split: `uploadMedia(send: false)` is the first half of what `send: true` does.
    ///
    /// The returned task resolves to the Blossom reference (or `nil` if the upload failed or was
    /// cancelled), so a Send pressed while this is still running can await the upload already in
    /// flight instead of starting a duplicate one.
    @discardableResult
    func beginPendingMediaUpload(
        _ attachment: PendingMediaAttachment,
        for draftKey: ComposerDraftKey
    ) -> Task<MediaAttachmentReferenceFfi?, Never> {
        guard let client, let activeAccount else { return Task { nil } }
        setPendingMediaUploadState(.uploading, for: attachment.id, in: draftKey)
        pendingMediaUploadTasks[attachment.id]?.cancel()
        // The finished task stays in the map until the attachment is removed or sent: clearing it
        // here would race a retry that has already installed its replacement under the same id.
        let task = Task { [weak self] () -> MediaAttachmentReferenceFfi? in
            do {
                let result = try await client.uploadMedia(
                    accountRef: activeAccount.accountRef,
                    groupIdHex: draftKey.chatId,
                    request: MediaUploadRequestFfi(
                        attachments: [attachment.uploadRequest],
                        caption: nil,
                        send: false,
                        blossomServer: nil
                    )
                )
                guard !Task.isCancelled else { return nil }
                // A result that carries no reference is a failed upload, not a cancelled one: leaving
                // it `.uploading` would pin the tile on a spinner with no retry, and an outgoing
                // message awaiting this reference would wait for a value that never arrives.
                guard let reference = result.attachments.first?.reference else {
                    self?.setPendingMediaUploadState(.failed, for: attachment.id, in: draftKey)
                    return nil
                }
                self?.setPendingMediaUploadState(.uploaded(reference), for: attachment.id, in: draftKey)
                return reference
            } catch is CancellationError {
                return nil
            } catch {
                guard !Task.isCancelled else { return nil }
                self?.setPendingMediaUploadState(.failed, for: attachment.id, in: draftKey)
                self?.lastError = error.localizedDescription
                return nil
            }
        }
        pendingMediaUploadTasks[attachment.id] = task
        return task
    }

    func retryPendingMediaUpload(_ id: PendingMediaAttachment.ID) {
        guard let draftKey = selectedComposerDraftKey,
            let attachment = pendingMediaAttachmentsByConversation[draftKey]?.first(where: { $0.id == id })
        else { return }
        beginPendingMediaUpload(attachment, for: draftKey)
    }

    /// The upload task already running for `id`, handed over to whoever will await it and dropped
    /// from the composer's map *without* being cancelled.
    ///
    /// This is what lets Send be non-blocking: the composer clear that follows would otherwise
    /// cancel the very upload the outgoing message is about to wait on.
    func detachPendingMediaUpload(_ id: PendingMediaAttachment.ID) -> Task<MediaAttachmentReferenceFfi?, Never>? {
        pendingMediaUploadTasks.removeValue(forKey: id)
    }

    func cancelPendingMediaUpload(_ id: PendingMediaAttachment.ID) {
        pendingMediaUploadTasks.removeValue(forKey: id)?.cancel()
    }

    /// Bulk counterparts to `cancelPendingMediaUpload` for the paths that drop whole drafts. The task
    /// map is keyed by attachment, not by draft, so a scoped cancel has to walk the staged
    /// attachments — which means cancelling *before* the draft entries are dropped, or the ids are
    /// already gone. Without this a logout or a chat deletion leaves the uploads running against a
    /// composer that no longer exists and never reclaims their entries.
    func cancelAllPendingMediaUploads() {
        for task in pendingMediaUploadTasks.values {
            task.cancel()
        }
        pendingMediaUploadTasks.removeAll()
    }

    func cancelPendingMediaUploads(for draftKey: ComposerDraftKey) {
        for attachment in pendingMediaAttachmentsByConversation[draftKey] ?? [] {
            cancelPendingMediaUpload(attachment.id)
        }
    }

    func cancelPendingMediaUploads(forAccountId accountId: String) {
        for draftKey in pendingMediaAttachmentsByConversation.keys where draftKey.accountId == accountId {
            cancelPendingMediaUploads(for: draftKey)
        }
    }

    /// Writes an upload outcome only while its attachment is still staged in the conversation it
    /// was staged in. An upload that resolves after the user removed the tile — or after they
    /// switched chats — must not resurrect it or leak into another conversation
    /// (the same discipline as `appendPendingMediaAttachmentIfSelectionUnchanged`, #245).
    private func setPendingMediaUploadState(
        _ state: PendingMediaUploadState,
        for id: PendingMediaAttachment.ID,
        in draftKey: ComposerDraftKey
    ) {
        guard pendingMediaAttachmentsByConversation[draftKey]?.contains(where: { $0.id == id }) == true else { return }
        pendingMediaUploadStatesByConversation[draftKey, default: [:]][id] = state
    }

    func toggleVoiceRecording() async {
        if isRecordingVoiceMessage {
            await finishVoiceRecording()
        } else {
            await startVoiceRecording()
        }
    }

    func startVoiceRecording() async {
        guard !isRecordingVoiceMessage, !isPreparingVoiceRecording else { return }
        guard let draftKey = selectedComposerDraftKey else { return }
        guard canRecordVoiceMessage else {
            presentVoiceMessageIsSentAloneWarning()
            return
        }
        guard canBeginMediaAttachmentSelection() else { return }

        isPreparingVoiceRecording = true
        defer { isPreparingVoiceRecording = false }

        let preparationGeneration = voiceRecordingPreparationGeneration

        let hasPermission = await requestMicrophoneAccess()
        guard hasPermission else {
            if voiceRecordingPreparationGeneration == preparationGeneration,
                canResumeVoiceRecording(for: draftKey)
            {
                lastError = L10n.string("Microphone access is needed to record voice messages.")
            }
            return
        }
        guard voiceRecordingPreparationGeneration == preparationGeneration else { return }
        guard canResumeVoiceRecording(for: draftKey) else { return }

        do {
            let directory = try MediaPlaybackTempStore.voiceRecordingsDirectoryURL()
            let url = try MediaPlaybackTempStore.prepareVoiceRecordingFile(in: directory)
            voiceRecordingURL = url
            let settings: [String: Any] = [
                AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
                AVSampleRateKey: 44_100,
                AVNumberOfChannelsKey: 1,
                AVEncoderAudioQualityKey: AVAudioQuality.medium.rawValue,
            ]
            let recorder = try AVAudioRecorder(url: url, settings: settings)
            recorder.isMeteringEnabled = true
            guard recorder.record() else {
                throw VoiceRecordingFailure.startFailed
            }

            voiceRecorder = recorder
            voiceRecordingSamples = []
            voiceRecordingHistory = []
            voiceRecordingDurationSeconds = 0
            isRecordingVoiceMessage = true
            startVoiceRecordingMetering()
        } catch {
            resetVoiceRecording(deleteFile: true)
            lastError = L10n.string("Voice recording could not start.")
        }
    }

    func finishVoiceRecording() async {
        guard isRecordingVoiceMessage, let recorder = voiceRecorder, let url = voiceRecordingURL else {
            resetVoiceRecording(deleteFile: true)
            return
        }
        let draftKey = selectedComposerDraftKey
        let duration = max(voiceRecordingDurationSeconds, recorder.currentTime)
        // The whole take, not the few seconds still on screen: the window is a sliding view for the
        // live strip, so a 30-second recording used to be sent with a waveform of its tail. Tests
        // that arm a recording without the meter only fill the window, hence the fallback.
        let samples = voiceRecordingHistory.isEmpty ? voiceRecordingSamples : voiceRecordingHistory
        let fileName = url.lastPathComponent
        recorder.stop()
        resetVoiceRecording(deleteFile: false)

        guard let draftKey else {
            try? FileManager.default.removeItem(at: url)
            return
        }

        do {
            let attachment = try await OutgoingMediaDraftProcessor.preparedVoiceAttachment(
                from: VoiceRecordingResult(
                    url: url,
                    fileName: fileName,
                    durationSeconds: duration,
                    waveformSamples: samples
                )
            )
            // The ordinary composer is back on screen for the whole of this await —
            // `resetVoiceRecording` above cleared `isRecordingVoiceMessage` — so the user can type,
            // paste, or attach while the recording is still being decoded. A recording is a message
            // of its own, so it yields to whatever arrived instead of wiping it: appending here
            // would delete those attachments (and cancel their uploads) and hide the typed text
            // behind the voice bar. `preparedVoiceAttachment` already removes the recording temp
            // file in a defer, so nothing leaks when the prepared attachment is discarded here or
            // by the stale-selection guard.
            guard selectedComposerDraftKey == draftKey else { return }
            guard canRecordVoiceMessage else {
                presentVoiceMessageIsSentAloneWarning()
                return
            }
            appendPendingMediaAttachmentIfSelectionUnchanged(attachment, for: draftKey)
        } catch is CancellationError {
            return
        } catch {
            lastError = error.localizedDescription
        }
    }

    func cancelVoiceRecording() {
        voiceRecordingPreparationGeneration &+= 1
        resetVoiceRecording(deleteFile: true)
    }

    /// Throws the finished recording away — the trash can next to the voice-draft bar. The staged
    /// blob may already be uploading, so this goes through `removePendingMediaAttachment`, which
    /// cancels that upload rather than letting it land on a draft the user just discarded.
    func discardStagedVoiceMessage() {
        guard let staged = stagedVoiceMessage else { return }
        removePendingMediaAttachment(staged.id)
    }

    func canBeginMediaAttachmentSelection() -> Bool {
        // Hidden composers must also refuse new attachments/recordings: drops,
        // importers, paste, and recording shortcuts can still fire while the visible
        // composer is replaced, and collected media would otherwise accumulate
        // invisibly (the pending-media strip is hidden) and never be sent.
        guard let draftKey = selectedComposerDraftKey else { return false }
        guard composerSupportsMediaAttachmentSelection(for: draftKey) else { return false }
        // A staged recording owns the composer on its own, so every staging path — importer,
        // drop, paste, a second recording — is refused until it is sent or discarded.
        guard stagedVoiceMessage == nil else {
            presentVoiceMessageIsSentAloneWarning()
            return false
        }
        guard remainingMediaAttachmentSlots > 0 else {
            presentMaxMediaAttachmentWarning()
            return false
        }
        return true
    }

    /// Revalidates the composer draft captured before the mic-permission await. Unlike
    /// `canBeginMediaAttachmentSelection()`, this never surfaces max-attachment warnings for a
    /// stale captured context (#441).
    private func canResumeVoiceRecording(for draftKey: ComposerDraftKey) -> Bool {
        guard composerSupportsMediaAttachmentSelection(for: draftKey) else { return false }
        // The user can type or attach while the permission prompt is up; a recording that
        // resumed into that composer would no longer be a message of its own.
        guard canRecordVoiceMessage else { return false }
        return remainingMediaAttachmentSlots > 0
    }

    private func composerSupportsMediaAttachmentSelection(for draftKey: ComposerDraftKey) -> Bool {
        guard selectedComposerDraftKey == draftKey else { return false }
        guard client != nil, selectedChat?.canUseComposer == true else { return false }
        guard editingMessageContext == nil else { return false }
        return true
    }

    /// Appends a freshly prepared attachment only if the live composer selection still matches
    /// the draft captured before the async media-preparation step. If the user switched
    /// chats/accounts during preparation the attachment is discarded rather than filed under the
    /// stale conversation, preventing private-content misdirection (whitenoise-mac#245). Returns
    /// whether the selection still matched and the append was attempted.
    @discardableResult
    func appendPendingMediaAttachmentIfSelectionUnchanged(
        _ attachment: PendingMediaAttachment,
        for draftKey: ComposerDraftKey
    ) -> Bool {
        guard selectedComposerDraftKey == draftKey else { return false }
        appendPendingMediaAttachment(attachment, for: draftKey)
        return true
    }

    func appendPendingMediaAttachment(_ attachment: PendingMediaAttachment, for draftKey: ComposerDraftKey) {
        var attachments = pendingMediaAttachmentsByConversation[draftKey] ?? []
        if attachment.isVoiceMessage {
            // A recording is a whole message rather than an attachment, so it lands alone: the
            // composer refuses to stage anything alongside it, and anything already there is
            // dropped here — with its upload cancelled, since it has nowhere left to land.
            for superseded in attachments {
                cancelPendingMediaUpload(superseded.id)
                pendingMediaUploadStatesByConversation[draftKey]?[superseded.id] = nil
            }
            attachments.removeAll()
        } else if attachment.kind == .audio {
            // A new audio file replaces the old one, so the superseded upload has nowhere to land.
            for superseded in attachments where superseded.kind == .audio {
                cancelPendingMediaUpload(superseded.id)
                pendingMediaUploadStatesByConversation[draftKey]?[superseded.id] = nil
            }
            attachments.removeAll { $0.kind == .audio }
        }
        guard attachments.count < OutgoingMediaDraftProcessor.maxAttachmentCount else {
            presentMaxMediaAttachmentWarning()
            return
        }
        attachments.append(attachment)
        pendingMediaAttachmentsByConversation[draftKey] = attachments
        // Media uploads cannot carry a reply target yet, so reply and pending media are
        // mutually exclusive — staging media drops any active reply banner.
        replyDraftContextByConversation[draftKey] = nil
        if attachment.kind == .audio {
            draftTextByConversation[draftKey] = nil
            composerMentionSelectionsByConversation[draftKey] = nil
        }
        // Upload straight away so Send only has to publish the reference. Every staging path
        // (importer, drag-drop, paste, voice) funnels through here; restored drafts are the one
        // bypass and kick their own uploads in `restoreComposerDraftIfNeeded`.
        beginPendingMediaUpload(attachment, for: draftKey)
        composerDraftDidChange(for: draftKey)
    }

    func presentVoiceMessageIsSentAloneWarning() {
        lastError = L10n.string("A voice message is sent on its own")
    }

    func presentMaxMediaAttachmentWarning() {
        lastError = String(
            format: L10n.string("You can send up to %lld attachments at once"),
            Int64(OutgoingMediaDraftProcessor.maxAttachmentCount)
        )
    }

    static func requestSystemMicrophoneAccess() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return true
        case .notDetermined:
            return await withCheckedContinuation { continuation in
                AVCaptureDevice.requestAccess(for: .audio) { granted in
                    continuation.resume(returning: granted)
                }
            }
        case .denied, .restricted:
            return false
        @unknown default:
            return false
        }
    }

    func requestMicrophoneAccess() async -> Bool {
        await microphoneAccessProvider()
    }

    func startVoiceRecordingMetering() {
        voiceRecordingMeterTask?.cancel()
        voiceRecordingMeterTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: VoiceRecordingLevelMeter.sampleInterval)
                } catch {
                    return
                }
                guard let self, let recorder = self.voiceRecorder else { return }
                recorder.updateMeters()
                let recordedSeconds = recorder.currentTime
                self.voiceRecordingDurationSeconds = recordedSeconds
                self.appendVoiceRecordingLevels(
                    averagePower: recorder.averagePower(forChannel: 0),
                    peakPower: recorder.peakPower(forChannel: 0),
                    recordedSeconds: recordedSeconds
                )
            }
        }
    }

    /// Files the bars this metered level has earned in both places they are needed: the observable
    /// window the live waveform draws, and the full-length history the sent message's waveform is
    /// derived from. Split in two because they answer different questions — the strip shows the last
    /// few seconds, the bubble shows the shape of the whole take — and because a buffer that grows
    /// for 40 minutes has no business being copied on every repaint.
    ///
    /// How many bars is the recorder's decision, not this wakeup's: `barsOwed` compares the audio
    /// clock against what has already been drawn. A tick that arrives late owes more than one bar
    /// and a duplicate tick owes none, so the strip advances at one bar per 40 ms of *sound* — which
    /// is what makes its horizontal speed constant instead of tracking the scheduler.
    func appendVoiceRecordingLevels(averagePower: Float, peakPower: Float, recordedSeconds: Double) {
        let owed = VoiceRecordingLevelMeter.barsOwed(
            recordedSeconds: recordedSeconds,
            alreadyMetered: voiceRecordingHistory.count,
            maximum: VoiceRecordingWaveform.maximumWindowSampleCount
        )
        guard owed > 0 else { return }
        let level = VoiceRecordingLevelMeter.smoothed(
            VoiceRecordingLevelMeter.amplitude(averagePower: averagePower, peakPower: peakPower),
            previous: voiceRecordingSamples.last
        )

        voiceRecordingSamples.append(contentsOf: repeatElement(level, count: owed))
        if voiceRecordingSamples.count > VoiceRecordingWaveform.maximumWindowSampleCount {
            voiceRecordingSamples.removeFirst(
                voiceRecordingSamples.count - VoiceRecordingWaveform.maximumWindowSampleCount)
        }
        voiceRecordingHistory.append(contentsOf: repeatElement(level, count: owed))
        if voiceRecordingHistory.count > VoiceRecordingLevelMeter.maximumHistorySampleCount {
            voiceRecordingHistory.removeFirst(
                voiceRecordingHistory.count - VoiceRecordingLevelMeter.maximumHistorySampleCount)
        }
    }

    func resetVoiceRecording(deleteFile: Bool) {
        voiceRecordingMeterTask?.cancel()
        voiceRecordingMeterTask = nil
        voiceRecorder?.stop()
        voiceRecorder = nil
        let url = voiceRecordingURL
        voiceRecordingURL = nil
        isRecordingVoiceMessage = false
        voiceRecordingSamples = []
        voiceRecordingHistory = []
        voiceRecordingDurationSeconds = 0
        if deleteFile, let url {
            try? FileManager.default.removeItem(at: url)
        }
    }

    func mediaDownloadKey(message: MessageItem, attachment: MessageMediaAttachment) -> String {
        mediaDownloadKey(
            accountId: activeAccountId ?? "",
            groupIdHex: message.groupIdHex,
            attachmentId: attachment.id
        )
    }

    private func mediaDownloadKey(
        accountId: String,
        groupIdHex: String,
        attachmentId: String
    ) -> String {
        [accountId, groupIdHex, attachmentId].joined(separator: "\u{1F}")
    }

    func pruneMediaDownloadCache(keeping groupIdHex: String?) {
        guard let activeAccountId, let groupIdHex else {
            resetMediaDownloadStateStores()
            return
        }

        let groupPrefix = [activeAccountId, groupIdHex, ""].joined(separator: "\u{1F}")
        let retainedKeys = retainedMediaDownloadKeys(groupIdHex: groupIdHex, accountId: activeAccountId)
        let removedKeys = mediaDownloads.keys.filter { key in
            guard key.hasPrefix(groupPrefix) else { return true }
            return !retainedKeys.contains(key)
        }
        for key in removedKeys {
            guard let store = mediaDownloads[key] else { continue }
            // Notify any lingering per-attachment observers before dropping the store.
            store.update(.idle)
            mediaDownloads[key] = nil
        }
    }

    private func retainedMediaDownloadKeys(groupIdHex: String, accountId: String) -> Set<String> {
        guard let timelineStore = messageTimelineStores[groupIdHex] else { return [] }
        return Set(
            timelineStore.messages.flatMap { message in
                message.mediaAttachments.map { attachment in
                    mediaDownloadKey(
                        accountId: accountId,
                        groupIdHex: groupIdHex,
                        attachmentId: attachment.id
                    )
                }
            }
        )
    }

    func resetMediaDownloadStateStores() {
        for store in mediaDownloads.values {
            // Notify any lingering per-attachment observers before clearing the cache.
            store.update(.idle)
        }
        mediaDownloads.removeAll()
        outgoingMediaWarmPlaintexts.removeAll()
        cancelAllMediaAttachmentDownloadTasks()
        clearMediaReferenceResolutionCache()
        MessageAudioMetadataCache.shared.clear()
    }

    private func sharedMessageMediaDownload(
        cacheID: String,
        cacheKey: MessageMediaDiskCacheKey,
        mediaDownloadKey: String,
        accountId: String,
        accountRef: String,
        groupIdHex: String,
        reference: MediaAttachmentReferenceFfi,
        client: any MarmotRuntime,
        storeGuard: MediaDiskStoreGuard
    ) async throws -> MessageMediaDownload {
        let tracked = mediaAttachmentDownloadTask(
            cacheID: cacheID,
            cacheKey: cacheKey,
            mediaDownloadKey: mediaDownloadKey,
            accountId: accountId,
            accountRef: accountRef,
            groupIdHex: groupIdHex,
            reference: reference,
            client: client,
            storeGuard: storeGuard
        )
        let task = tracked.task
        do {
            return try await withMediaAttachmentDownloadTimeout { [task] in
                do {
                    return try await task.value
                } catch {
                    throw MediaAttachmentDownloadTaskFailure(underlying: error)
                }
            }
        } catch let failure as MediaAttachmentDownloadTaskFailure {
            throw failure.underlying
        } catch is CancellationError {
            throw CancellationError()
        } catch is MediaAttachmentDownloadTimeoutError {
            throw MediaAttachmentDownloadTimeoutError()
        }
    }

    private func mediaAttachmentDownloadTask(
        cacheID: String,
        cacheKey: MessageMediaDiskCacheKey,
        mediaDownloadKey: String,
        accountId: String,
        accountRef: String,
        groupIdHex: String,
        reference: MediaAttachmentReferenceFfi,
        client: any MarmotRuntime,
        storeGuard: MediaDiskStoreGuard
    ) -> MediaAttachmentDownloadTask {
        if let existing = mediaAttachmentDownloadTasks[cacheID] {
            return existing
        }

        nextMediaAttachmentDownloadTaskToken &+= 1
        let token = nextMediaAttachmentDownloadTaskToken
        let downloadTask = Task.detached(priority: .userInitiated) {
            [client, accountRef, groupIdHex, reference, mediaDownloadKey] in
            try await MediaAttachmentDownloadLimiter.shared.withPermit {
                let download = try await client.downloadMedia(
                    accountRef: accountRef,
                    groupIdHex: groupIdHex,
                    reference: reference
                )
                return MessageMediaDownload(
                    payload: DownloadedMediaPayload(
                        id: "\(mediaDownloadKey)|\(UUID().uuidString)",
                        data: download.plaintext
                    ),
                    fileName: download.fileName,
                    mediaType: download.mediaType,
                    sizeBytes: download.sizeBytes
                )
            }
        }
        let tracked = MediaAttachmentDownloadTask(
            token: token,
            task: downloadTask
        )
        mediaAttachmentDownloadTasks[cacheID] = tracked
        Task { @MainActor [weak self, downloadTask, cacheID, cacheKey, accountId, storeGuard, token] in
            defer {
                self?.finishMediaAttachmentDownloadTask(cacheID: cacheID, token: token)
            }
            do {
                let download = try await downloadTask.value
                guard let self,
                    self.mediaAttachmentDownloadTasks[cacheID]?.token == token,
                    self.isMediaDiskStoreAllowed(forAccountId: accountId, storeGuard: storeGuard)
                else {
                    return
                }
                self.scheduleMediaDiskCacheStore(
                    download,
                    for: cacheKey,
                    accountId: accountId,
                    storeGuard: storeGuard
                )
                if let storeTask = self.mediaDiskStoreTasks[cacheID]?.task {
                    await storeTask.value
                }
            } catch {
                // Underlying failures are surfaced to waiters; cleanup happens in defer.
            }
        }
        return tracked
    }

    /// The download already running for `attachment`, if there is one.
    ///
    /// `mediaAttachmentDownloadTask(cacheID:…)` coalesces by cache ID, so this is the very task a
    /// tile's automatic load is waiting on — and its value *is* the download. A caller that finds
    /// one here has something to await rather than a published state to watch for.
    func inFlightMediaAttachmentDownloadTask(
        _ attachment: MessageMediaAttachment,
        for message: MessageItem
    ) -> Task<MessageMediaDownload, Error>? {
        guard let accountId = activeAccountId else { return nil }
        let cacheKey = MessageMediaDiskCacheKey(
            accountId: accountId,
            groupIdHex: message.groupIdHex,
            reference: attachment.reference
        )
        return mediaAttachmentDownloadTasks[cacheKey.cacheID]?.task
    }

    /// The `listMedia` reference resolution already running for `message`'s group, if there is one.
    ///
    /// A load that has published `.loading` spends most of that state in here — resolving the
    /// attachment's reference — and registers no download task until it returns. This is what a
    /// second caller has to wait on to tell "not started yet" from "never going to start".
    func inFlightMediaReferenceIndexTask(for message: MessageItem) -> Task<MediaReferenceIndex, Error>? {
        guard let accountId = activeAccountId else { return nil }
        let cacheKey = MediaReferenceCacheKey(accountId: accountId, groupIdHex: message.groupIdHex)
        return mediaReferenceIndexTasks[cacheKey]?.task
    }

    private func finishMediaAttachmentDownloadTask(cacheID: String, token: UInt64) {
        guard mediaAttachmentDownloadTasks[cacheID]?.token == token else { return }
        mediaAttachmentDownloadTasks[cacheID] = nil
    }

    private func cancelAllMediaAttachmentDownloadTasks() {
        let tracked = Array(mediaAttachmentDownloadTasks.values)
        mediaAttachmentDownloadTasks.removeAll()
        for entry in tracked {
            entry.task.cancel()
        }
    }

    func resolvedMediaReference(
        _ reference: MediaAttachmentReferenceFfi,
        accountId: String,
        accountRef: String,
        groupIdHex: String,
        client: any MarmotRuntime
    ) async throws -> MediaAttachmentReferenceFfi {
        guard reference.sourceEpoch == 0 else {
            return reference
        }

        let cacheKey = MediaReferenceCacheKey(accountId: accountId, groupIdHex: groupIdHex)
        if let cachedIndex = mediaReferenceIndexes[cacheKey] {
            return cachedIndex.resolvedReference(matching: reference) ?? reference
        }

        let index = try await mediaReferenceIndex(
            for: cacheKey,
            accountRef: accountRef,
            groupIdHex: groupIdHex,
            client: client
        )
        return index.resolvedReference(matching: reference) ?? reference
    }

    func mediaReferenceIndex(
        for cacheKey: MediaReferenceCacheKey,
        accountRef: String,
        groupIdHex: String,
        client: any MarmotRuntime
    ) async throws -> MediaReferenceIndex {
        let resolution: MediaReferenceIndexTask
        if let existing = mediaReferenceIndexTasks[cacheKey] {
            resolution = existing
        } else {
            mediaReferenceIndexGeneration &+= 1
            let generation = mediaReferenceIndexGeneration
            let task = Task.detached(priority: .userInitiated) { [client, accountRef, groupIdHex] in
                let records = try await FFIExecutor.run {
                    try client.listMedia(accountRef: accountRef, groupIdHex: groupIdHex, limit: nil)
                }
                return MediaReferenceIndex(records: records)
            }
            resolution = MediaReferenceIndexTask(generation: generation, task: task)
            mediaReferenceIndexTasks[cacheKey] = resolution
        }

        let generation = resolution.generation
        let task = resolution.task
        do {
            // Only the detached FFI task is shared and retained. Each caller can stop waiting
            // without capturing WorkspaceState until the synchronous `listMedia` call returns.
            let index = try await withMediaAttachmentDownloadTimeout { [task] in
                do {
                    return try await task.value
                } catch {
                    throw MediaReferenceIndexTaskFailure(underlying: error)
                }
            }
            if mediaReferenceIndexTasks[cacheKey]?.generation == generation {
                mediaReferenceIndexTasks[cacheKey] = nil
                mediaReferenceIndexes[cacheKey] = index
            }
            return index
        } catch let failure as MediaReferenceIndexTaskFailure {
            if mediaReferenceIndexTasks[cacheKey]?.generation == generation {
                mediaReferenceIndexTasks[cacheKey] = nil
            }
            throw failure.underlying
        } catch let error as CancellationError {
            // Keep the shared FFI task so a later retry joins it instead of starting another call.
            throw error
        } catch let error as MediaAttachmentDownloadTimeoutError {
            // The synchronous FFI may still complete; preserve it for the same bounded retry path.
            throw error
        } catch {
            if mediaReferenceIndexTasks[cacheKey]?.generation == generation {
                mediaReferenceIndexTasks[cacheKey] = nil
            }
            throw error
        }
    }

    func clearMediaReferenceResolutionCache() {
        let tasks = mediaReferenceIndexTasks.values.map(\.task)
        mediaReferenceIndexGeneration &+= 1
        mediaReferenceIndexes.removeAll()
        mediaReferenceIndexTasks.removeAll()
        tasks.forEach { $0.cancel() }
    }

    func clearMediaReferenceResolutionCache(forAccountId accountId: String) {
        let keys = Set(mediaReferenceIndexes.keys.filter { $0.accountId == accountId })
            .union(mediaReferenceIndexTasks.keys.filter { $0.accountId == accountId })
        guard !keys.isEmpty else { return }

        let tasks = keys.compactMap { mediaReferenceIndexTasks[$0]?.task }
        mediaReferenceIndexGeneration &+= 1
        for key in keys {
            mediaReferenceIndexes[key] = nil
            mediaReferenceIndexTasks[key] = nil
        }
        tasks.forEach { $0.cancel() }
    }

    func clearMediaReferenceResolutionCache(forAccountId accountId: String, groupIdHex: String) {
        let key = MediaReferenceCacheKey(accountId: accountId, groupIdHex: groupIdHex)
        guard mediaReferenceIndexes[key] != nil || mediaReferenceIndexTasks[key] != nil else { return }

        let task = mediaReferenceIndexTasks[key]?.task
        mediaReferenceIndexGeneration &+= 1
        mediaReferenceIndexes[key] = nil
        mediaReferenceIndexTasks[key] = nil
        task?.cancel()
    }
}
