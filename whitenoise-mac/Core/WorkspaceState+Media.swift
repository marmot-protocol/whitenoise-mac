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

@MainActor
extension WorkspaceState {
    func clearAllComposerDrafts() {
        draftTextByConversation.removeAll()
        replyDraftContextByConversation.removeAll()
        editingMessageContextByConversation.removeAll()
        pendingMediaAttachmentsByConversation.removeAll()
        pendingMediaUploadStatesByConversation.removeAll()
    }

    func clearComposerDrafts(for chatIds: [String], accountId: String) {
        for chatId in chatIds {
            let key = ComposerDraftKey(accountId: accountId, chatId: chatId)
            draftTextByConversation[key] = nil
            replyDraftContextByConversation[key] = nil
            editingMessageContextByConversation[key] = nil
            pendingMediaAttachmentsByConversation[key] = nil
            pendingMediaUploadStatesByConversation[key] = nil
        }
    }

    func clearComposerDrafts(forAccountId accountId: String) {
        for key in draftTextByConversation.keys.filter({ $0.accountId == accountId }) {
            draftTextByConversation[key] = nil
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
        mediaDownloadStateStore(forKey: mediaDownloadKey(message: message, attachment: attachment))
    }

    func loadMediaAttachment(_ attachment: MessageMediaAttachment, for message: MessageItem) async {
        let key = mediaDownloadKey(message: message, attachment: attachment)
        let stateStore = mediaDownloadStateStore(forKey: key)
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

            try await MediaAttachmentDownloadLimiter.shared.acquire()
            defer {
                Task { await MediaAttachmentDownloadLimiter.shared.release() }
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

            let download = try await withMediaAttachmentDownloadTimeout {
                try await client.downloadMedia(
                    accountRef: accountRef,
                    groupIdHex: groupIdHex,
                    reference: reference
                )
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
            let mediaDownload = MessageMediaDownload(
                payload: DownloadedMediaPayload(
                    id: "\(key)|\(UUID().uuidString)",
                    data: download.plaintext
                ),
                fileName: download.fileName,
                mediaType: download.mediaType,
                sizeBytes: download.sizeBytes
            )
            stateStore.update(.loaded(mediaDownload))
            scheduleMediaDiskCacheStore(
                mediaDownload,
                for: cacheKey,
                accountId: accountId,
                storeGuard: storeGuard
            )
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

        for url in selected {
            let isSecurityScoped = url.startAccessingSecurityScopedResource()
            defer {
                if isSecurityScoped {
                    url.stopAccessingSecurityScopedResource()
                }
            }
            do {
                let attachment = try await OutgoingMediaDraftProcessor.preparedAttachment(fromFileURL: url)
                guard appendPendingMediaAttachmentIfSelectionUnchanged(attachment, for: draftKey) else { return }
            } catch is CancellationError {
                return
            } catch {
                lastError = error.localizedDescription
            }
        }
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

        for item in selected {
            do {
                let attachment = try await preparedPastedMediaAttachment(from: item)
                guard appendPendingMediaAttachmentIfSelectionUnchanged(attachment, for: draftKey) else { return }
            } catch is CancellationError {
                return
            } catch {
                lastError = error.localizedDescription
            }
        }
    }

    private func preparedPastedMediaAttachment(
        from item: OutgoingMediaPasteboardAttachment
    ) async throws -> PendingMediaAttachment {
        switch item.payload {
        case .fileURL(let url):
            let isSecurityScoped = url.startAccessingSecurityScopedResource()
            defer {
                if isSecurityScoped {
                    url.stopAccessingSecurityScopedResource()
                }
            }
            return try await OutgoingMediaDraftProcessor.preparedAttachment(fromFileURL: url)
        case .imageData(let data, let typeIdentifier):
            return try await OutgoingMediaDraftProcessor.preparedAttachment(
                fromPastedImageData: data,
                typeIdentifier: typeIdentifier
            )
        }
    }

    func removePendingMediaAttachment(_ id: PendingMediaAttachment.ID) {
        guard let selectedComposerDraftKey else { return }
        var attachments = pendingMediaAttachmentsByConversation[selectedComposerDraftKey] ?? []
        attachments.removeAll { $0.id == id }
        pendingMediaAttachmentsByConversation[selectedComposerDraftKey] = attachments.isEmpty ? nil : attachments
        var uploadStates = pendingMediaUploadStatesByConversation[selectedComposerDraftKey] ?? [:]
        uploadStates[id] = nil
        pendingMediaUploadStatesByConversation[selectedComposerDraftKey] = uploadStates.isEmpty ? nil : uploadStates
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
        guard canBeginMediaAttachmentSelection() else { return }

        isPreparingVoiceRecording = true
        defer { isPreparingVoiceRecording = false }

        let hasPermission = await requestMicrophoneAccess()
        guard hasPermission else {
            lastError = L10n.string("Microphone access is needed to record voice messages.")
            return
        }

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
        let samples = voiceRecordingSamples
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
            // `preparedVoiceAttachment` already removes the recording temp file in a defer, so
            // nothing leaks when the stale-selection guard discards the prepared attachment.
            appendPendingMediaAttachmentIfSelectionUnchanged(attachment, for: draftKey)
        } catch is CancellationError {
            return
        } catch {
            lastError = error.localizedDescription
        }
    }

    func cancelVoiceRecording() {
        resetVoiceRecording(deleteFile: true)
    }

    func canBeginMediaAttachmentSelection() -> Bool {
        // Hidden composers must also refuse new attachments/recordings: drops,
        // importers, paste, and recording shortcuts can still fire while the visible
        // composer is replaced, and collected media would otherwise accumulate
        // invisibly (the pending-media strip is hidden) and never be sent.
        guard client != nil,
            selectedChat?.canUseComposer == true,
            editingMessageContext == nil
        else { return false }
        guard remainingMediaAttachmentSlots > 0 else {
            presentMaxMediaAttachmentWarning()
            return false
        }
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
        if attachment.kind == .audio {
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
        }
    }

    func presentMaxMediaAttachmentWarning() {
        lastError = String(
            format: L10n.string("You can send up to %lld attachments at once"),
            Int64(OutgoingMediaDraftProcessor.maxAttachmentCount)
        )
    }

    func requestMicrophoneAccess() async -> Bool {
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

    func startVoiceRecordingMetering() {
        voiceRecordingMeterTask?.cancel()
        voiceRecordingMeterTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(nanoseconds: 70_000_000)
                } catch {
                    return
                }
                guard let self, let recorder = self.voiceRecorder else { return }
                recorder.updateMeters()
                self.voiceRecordingDurationSeconds = recorder.currentTime
                let power = recorder.averagePower(forChannel: 0)
                let normalized = max(0.05, min(1, CGFloat(pow(10, power / 36))))
                self.voiceRecordingSamples.append(normalized)
                if self.voiceRecordingSamples.count > MediaWaveformAnalyzer.sampleCount {
                    self.voiceRecordingSamples.removeFirst(
                        self.voiceRecordingSamples.count - MediaWaveformAnalyzer.sampleCount)
                }
            }
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

        let prefix = [activeAccountId, groupIdHex, ""].joined(separator: "\u{1F}")
        let retainedKeys = retainedMediaDownloadKeys(groupIdHex: groupIdHex, accountId: activeAccountId)
        let removedKeys = mediaDownloads.keys.filter { key in
            guard key.hasPrefix(prefix) else { return true }
            return !retainedKeys.contains(key)
        }
        for key in removedKeys {
            // Notify any lingering per-attachment observers before dropping the store.
            mediaDownloads[key]?.update(.idle)
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
        clearMediaReferenceResolutionCache()
        MessageAudioMetadataCache.shared.clear()
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
                let records = try await WorkspaceState.runFFI {
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
