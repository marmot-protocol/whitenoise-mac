import Foundation
import MarmotKit
import Observation

enum AttachmentFeatureError: Error, Equatable {
    case unavailable(String)
    case invalidPage
    case assetBecameUnavailable
    case truncatedAsset
}

nonisolated struct RetainedAttachmentItem: Identifiable, Hashable, Sendable {
    let id: String
    let messageIdHex: String
    let sourceMessageIdHex: String
    let category: AttachmentCategoryFfi
    let attachmentIndex: UInt32
    let reference: MediaAttachmentReferenceFfi?
    let rejection: MediaAttachmentRejectionFfi?

    init(entry: AttachmentEntryFfi) {
        messageIdHex = entry.messageIdHex
        sourceMessageIdHex = entry.sourceMessageIdHex
        category = entry.category
        switch entry.attachment {
        case .accepted(let attachmentIndex, let reference):
            self.attachmentIndex = attachmentIndex
            self.reference = reference
            rejection = nil
        case .rejected(let attachmentIndex, let rejection):
            self.attachmentIndex = attachmentIndex
            reference = nil
            self.rejection = rejection
        }
        id = "\(entry.messageIdHex)|\(entry.sourceMessageIdHex)|\(attachmentIndex)"
    }

    var target: AttachmentLocalTargetFfi? {
        guard reference != nil else { return nil }
        return AttachmentLocalTargetFfi(
            messageIdHex: messageIdHex,
            sourceMessageIdHex: sourceMessageIdHex,
            attachmentIndex: attachmentIndex
        )
    }

    var isVisualMedia: Bool {
        category == .image || category == .video
    }
}

/// Conversation-scoped retained-attachment state. History pages and transfer snapshots are
/// consumed as MarmotKit projections; the host never invents transfer state from cache files.
@MainActor
@Observable
final class AttachmentViewModel {
    let groupIdHex: String
    private(set) var entries: [AttachmentEntryFfi] = []
    private(set) var transfers = AttachmentTransferSnapshotFfi(items: [])
    private(set) var localAssetsByTarget: [AttachmentLocalTargetFfi: AttachmentLocalAssetFfi] = [:]
    private(set) var transfersByTarget: [AttachmentLocalTargetFfi: AttachmentTransferStatusFfi] = [:]
    private(set) var hasMore = false
    private(set) var isLoading = false
    private(set) var error: AttachmentFeatureError?

    var items: [RetainedAttachmentItem] {
        entries.map(RetainedAttachmentItem.init)
    }

    @ObservationIgnored private let accountRef: String
    @ObservationIgnored private let runtime: any MarmotRuntime
    @ObservationIgnored private var cursor: AttachmentHistoryCursor?
    @ObservationIgnored private var version: AttachmentHistoryVersion?
    @ObservationIgnored private var transferSubscription: AttachmentTransferSubscription?
    @ObservationIgnored private var transferTask: Task<Void, Never>?

    init(accountRef: String, groupIdHex: String, runtime: any MarmotRuntime) {
        self.accountRef = accountRef
        self.groupIdHex = groupIdHex
        self.runtime = runtime
    }

    func refreshHistory(limit: UInt32 = 50) async {
        cursor = nil
        version = nil
        entries = []
        hasMore = false
        await loadPage(limit: limit, restarting: true)
    }

    func loadMore(limit: UInt32 = 50) async {
        guard hasMore, !isLoading else { return }
        await loadPage(limit: limit, restarting: false)
    }

    func observeTransfers(for targets: [AttachmentLocalTargetFfi]) {
        stopTransferObservation()
        let observedTargets = Array(targets.prefix(64))
        guard !observedTargets.isEmpty else {
            transfers = AttachmentTransferSnapshotFfi(items: [])
            transfersByTarget = [:]
            return
        }
        transferTask = Task { [weak self] in
            await self?.runTransferSubscription(targets: observedTargets)
        }
    }

    func stopTransferObservation() {
        transferTask?.cancel()
        transferTask = nil
        if let transferSubscription {
            self.transferSubscription = nil
            runtime.cancelAttachmentTransfers(subscription: transferSubscription)
        }
    }

    /// Explicit user acquisition is intentionally independent of the automatic-download fence.
    /// A tap promotes live or not-yet-requested work without resetting its retry budget or
    /// backoff; only a source whose work has ended is rearmed with download-again, because the
    /// explicit request deliberately leaves that work alone and the tap would otherwise do nothing.
    @discardableResult
    func downloadExplicitly(_ target: AttachmentLocalTargetFfi) async throws -> String? {
        let reference =
            if await currentTransferState(of: target)?.needsRearmToDownload ?? true {
                try await runtime.downloadAttachmentAgain(
                    accountRef: accountRef, groupIdHex: groupIdHex, target: target)
            } else {
                try await runtime.requestExplicitAttachment(
                    accountRef: accountRef, groupIdHex: groupIdHex, target: target)
            }
        await refreshLocalAssets()
        return reference
    }

    /// The target's state read from the core at tap time. The observed `transfersByTarget` cannot
    /// answer this: it covers only the first 64 loaded targets and is empty until the first
    /// snapshot arrives, and an absent row says nothing about terminal work. Falls back to the
    /// observed row when the read fails; `nil` (unknown) is treated as needing a rearm, the
    /// behavior every tap had before explicit requests existed.
    private func currentTransferState(of target: AttachmentLocalTargetFfi) async -> AttachmentTransferStateFfi? {
        if let snapshot = try? await runtime.attachmentTransferSnapshot(
            accountRef: accountRef, groupIdHex: groupIdHex, targets: [target]),
            snapshot.items.count == 1
        {
            return snapshot.items[0].state
        }
        return transfersByTarget[target]?.state
    }

    @discardableResult
    func requestAutomatically(_ target: AttachmentLocalTargetFfi) async throws -> AutomaticAttachmentRequestFfi {
        try await runtime.requestAutomaticAttachment(accountRef: accountRef, groupIdHex: groupIdHex, target: target)
    }

    @discardableResult
    func control(reference: String, _ control: AttachmentControlFfi) async throws -> Bool {
        let didApply = try await runtime.controlAttachment(
            accountRef: accountRef, reference: reference, control: control)
        if didApply, control == .remove {
            await refreshLocalAssets()
        }
        return didApply
    }

    func localAssets(for targets: [AttachmentLocalTargetFfi]) async throws -> [AttachmentLocalAssetFfi] {
        try await runtime.attachmentLocalAssets(accountRef: accountRef, groupIdHex: groupIdHex, targets: targets)
    }

    func refreshLocalAssets() async {
        let targets = acceptedTargets
        guard !targets.isEmpty else {
            localAssetsByTarget = [:]
            observeTransfers(for: [])
            return
        }
        do {
            var replacements: [AttachmentLocalTargetFfi: AttachmentLocalAssetFfi] = [:]
            for start in stride(from: 0, to: targets.count, by: 64) {
                let end = min(start + 64, targets.count)
                let chunk = Array(targets[start..<end])
                let assets = try await localAssets(for: chunk)
                guard assets.count == chunk.count else { throw AttachmentFeatureError.invalidPage }
                for (target, asset) in zip(chunk, assets) {
                    replacements[target] = asset
                }
            }
            try Task.checkCancellation()
            localAssetsByTarget = replacements
            observeTransfers(for: targets)
            error = nil
        } catch is CancellationError {
            return
        } catch let featureError as AttachmentFeatureError {
            error = featureError
        } catch {
            self.error = .unavailable(error.localizedDescription)
        }
    }

    /// Reads one retained plaintext asset without allowing an unbounded FFI allocation.
    /// If the locator becomes unavailable mid-read, all partially assembled bytes are discarded.
    func readRetainedAsset(reference: String, byteCount: UInt64) async throws -> Data {
        let chunkSize: UInt32 = 1_048_576
        var result = Data()
        if byteCount <= UInt64(Int.max) {
            result.reserveCapacity(Int(byteCount))
        }
        var offset: UInt64 = 0
        repeat {
            try Task.checkCancellation()
            let remaining = byteCount - offset
            let requested = UInt32(min(UInt64(chunkSize), max(remaining, 1)))
            let chunk = try await runtime.readAttachmentAsset(
                accountRef: accountRef, reference: reference, offset: offset, limit: requested
            )
            guard chunk.available else { throw AttachmentFeatureError.assetBecameUnavailable }
            if chunk.bytes.isEmpty {
                guard offset == byteCount else { throw AttachmentFeatureError.truncatedAsset }
                break
            }
            guard UInt64(chunk.bytes.count) <= remaining else { throw AttachmentFeatureError.truncatedAsset }
            result.append(chunk.bytes)
            offset += UInt64(chunk.bytes.count)
        } while offset < byteCount
        guard offset == byteCount else { throw AttachmentFeatureError.truncatedAsset }
        return result
    }

    private func loadPage(limit: UInt32, restarting: Bool) async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let read = try await runtime.attachmentHistoryPage(
                accountRef: accountRef,
                groupIdHex: groupIdHex,
                limit: limit,
                cursor: restarting ? nil : cursor
            )
            switch read {
            case .page(let page):
                if restarting {
                    entries = page.entries
                } else {
                    entries.append(contentsOf: page.entries)
                }
                version = page.version
                cursor = page.nextCursor
                hasMore = page.hasMore
                error = nil
                await refreshLocalAssets()
            case .restartRequired, .cursorMismatch:
                if restarting {
                    error = .invalidPage
                } else {
                    cursor = nil
                    version = nil
                    entries = []
                    hasMore = false
                    isLoading = false
                    await loadPage(limit: limit, restarting: true)
                    return
                }
            case .invalidLimit:
                error = .invalidPage
            }
        } catch is CancellationError {
            return
        } catch {
            self.error = .unavailable(error.localizedDescription)
        }
    }

    private func runTransferSubscription(targets: [AttachmentLocalTargetFfi]) async {
        do {
            let subscription = try await runtime.subscribeAttachmentTransfers(
                accountRef: accountRef, groupIdHex: groupIdHex, targets: targets
            )
            try Task.checkCancellation()
            transferSubscription = subscription
            while let replacement = try await runtime.nextAttachmentTransferSnapshot(subscription: subscription) {
                try Task.checkCancellation()
                guard replacement.items.count == targets.count else {
                    error = .invalidPage
                    continue
                }
                transfers = replacement
                var indexed: [AttachmentLocalTargetFfi: AttachmentTransferStatusFfi] = [:]
                for (target, status) in zip(targets, replacement.items) {
                    indexed[target] = status
                }
                transfersByTarget = indexed
            }
        } catch is CancellationError {
            return
        } catch {
            self.error = .unavailable(error.localizedDescription)
        }
    }

    private var acceptedTargets: [AttachmentLocalTargetFfi] {
        entries.compactMap { entry in
            guard case .accepted(let attachmentIndex, _) = entry.attachment else { return nil }
            return AttachmentLocalTargetFfi(
                messageIdHex: entry.messageIdHex,
                sourceMessageIdHex: entry.sourceMessageIdHex,
                attachmentIndex: attachmentIndex
            )
        }
    }
}

extension AttachmentTransferStateFfi {
    /// Work an explicit request will not restart. MDK's attachment-access contract leaves
    /// cancelled, removed, failed and exhausted sources to a deliberate download-again, and a
    /// source whose bytes are gone or were blocked by policy gets no reacquisition without one.
    var needsRearmToDownload: Bool {
        switch self {
        case .failed, .cancelled, .removed, .retryExhausted, .policyBlocked, .previouslyAcquiredUnavailable,
            .completedUnretained:
            true
        case .unavailable, .notRequested, .queued, .downloading, .verifyingCiphertext, .decrypting,
            .verifyingPlaintext, .ready, .retryScheduled, .paused:
            false
        }
    }
}
