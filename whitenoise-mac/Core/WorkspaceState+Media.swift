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

@MainActor
extension WorkspaceState {
    func clearAllComposerDrafts() {
        draftTextByConversation.removeAll()
        replyDraftContextByConversation.removeAll()
        pendingMediaAttachmentsByConversation.removeAll()
    }

    func clearComposerDrafts(for chatIds: [String], accountId: String) {
        for chatId in chatIds {
            let key = ComposerDraftKey(accountId: accountId, chatId: chatId)
            draftTextByConversation[key] = nil
            replyDraftContextByConversation[key] = nil
            pendingMediaAttachmentsByConversation[key] = nil
        }
    }

    func clearComposerDrafts(forAccountId accountId: String) {
        for key in draftTextByConversation.keys.filter({ $0.accountId == accountId }) {
            draftTextByConversation[key] = nil
        }
        for key in replyDraftContextByConversation.keys.filter({ $0.accountId == accountId }) {
            replyDraftContextByConversation[key] = nil
        }
        for key in pendingMediaAttachmentsByConversation.keys.filter({ $0.accountId == accountId }) {
            pendingMediaAttachmentsByConversation[key] = nil
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
                await self?.isMediaDiskStoreAllowed(forAccountId: accountId, storeGuard: storeGuard) == true
            else {
                await self?.finishMediaDiskCacheStore(cacheID: cacheID, token: token)
                return
            }

            await mediaDiskCache.store(download, for: cacheKey)
            await self?.finishMediaDiskCacheStore(cacheID: cacheID, token: token)
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
            guard isMediaDisplayAllowed(forAccountId: accountId, groupIdHex: groupIdHex) else {
                stateStore.update(.idle)
                return
            }
            stateStore.update(.loaded(cachedDownload))
            return
        }

        do {
            let reference = try await resolvedMediaReference(
                attachment.reference,
                accountId: accountId,
                accountRef: accountRef,
                groupIdHex: groupIdHex,
                client: client
            )
            let download = try await client.downloadMedia(
                accountRef: accountRef,
                groupIdHex: groupIdHex,
                reference: reference
            )
            guard isMediaDisplayAllowed(forAccountId: accountId, groupIdHex: groupIdHex) else {
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
        } catch {
            guard isMediaDisplayAllowed(forAccountId: accountId, groupIdHex: groupIdHex) else {
                stateStore.update(.idle)
                return
            }
            stateStore.update(.failed(error.localizedDescription))
        }
    }

    /// Lazily allocates per-attachment stores from SwiftUI body lookup without observing the
    /// backing dictionary; `mediaDownloads` is `@ObservationIgnored`, and pruning bounds it to
    /// the active conversation.
    func mediaDownloadStateStore(forKey key: String) -> MediaDownloadStateStore {
        if let store = mediaDownloads[key] {
            return store
        }
        let store = MediaDownloadStateStore()
        mediaDownloads[key] = store
        return store
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

    func removePendingMediaAttachment(_ id: PendingMediaAttachment.ID) {
        guard let selectedComposerDraftKey else { return }
        var attachments = pendingMediaAttachmentsByConversation[selectedComposerDraftKey] ?? []
        attachments.removeAll { $0.id == id }
        pendingMediaAttachmentsByConversation[selectedComposerDraftKey] = attachments.isEmpty ? nil : attachments
    }

    func toggleVoiceRecording() async {
        if isRecordingVoiceMessage {
            await finishVoiceRecording()
        } else {
            await startVoiceRecording()
        }
    }

    func startVoiceRecording() async {
        guard !isRecordingVoiceMessage else { return }
        guard canBeginMediaAttachmentSelection() else { return }

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
        guard client != nil, selectedChat != nil else { return false }
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
        [activeAccountId ?? "", message.groupIdHex, attachment.id].joined(separator: "\u{1F}")
    }

    func pruneMediaDownloadCache(keeping groupIdHex: String?) {
        guard let activeAccountId, let groupIdHex else {
            resetMediaDownloadStateStores()
            return
        }

        let prefix = [activeAccountId, groupIdHex, ""].joined(separator: "\u{1F}")
        let removedKeys = mediaDownloads.keys.filter { !$0.hasPrefix(prefix) }
        for key in removedKeys {
            // Notify any lingering per-attachment observers before dropping the store.
            mediaDownloads[key]?.update(.idle)
            mediaDownloads[key] = nil
        }
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
        if let existing = mediaReferenceIndexTasks[cacheKey] {
            return try await existing.task.value
        }

        let generation = mediaReferenceIndexGeneration
        let task = Task.detached(priority: .userInitiated) { [client, accountRef, groupIdHex] in
            let records = try await WorkspaceState.runFFI {
                try client.listMedia(accountRef: accountRef, groupIdHex: groupIdHex, limit: nil)
            }
            return MediaReferenceIndex(records: records)
        }
        mediaReferenceIndexTasks[cacheKey] = MediaReferenceIndexTask(generation: generation, task: task)

        do {
            let index = try await task.value
            if mediaReferenceIndexTasks[cacheKey]?.generation == generation {
                mediaReferenceIndexTasks[cacheKey] = nil
                mediaReferenceIndexes[cacheKey] = index
            }
            return index
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
