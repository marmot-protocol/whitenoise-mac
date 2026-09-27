import Foundation
import MarmotKit
import Observation

enum ChatListFeatureError: Equatable {
    case unavailable(String)
}

/// Screen projection for one account's chat list. MarmotKit owns title/avatar/preview
/// selection; the host applies only private, device-local nickname overlays.
@MainActor
@Observable
final class ChatListViewModel {
    let account: AccountItem
    private(set) var presentedRows: [PresentedChatRowFfi] = []
    private(set) var avatarBytesByReference: [String: AvatarBytesFfi] = [:]
    private(set) var windowSnapshot: ChatListWindowSnapshotFfi?
    private(set) var isLoading = false
    private(set) var isPaging = false
    private(set) var error: ChatListFeatureError?

    @ObservationIgnored private let runtime: any MarmotRuntime
    private let blockedUsersModel: BlockedUsersViewModel?
    @ObservationIgnored private var subscriptionTask: Task<Void, Never>?
    @ObservationIgnored private var windowTask: Task<Void, Never>?
    @ObservationIgnored private var windowCommandTask: Task<Void, Never>?
    @ObservationIgnored private var windowSubscription: ChatListWindowSubscription?
    @ObservationIgnored private var latestSnapshot: PresentedChatListSnapshotFfi?
    @ObservationIgnored private var snapshotObserver: (@MainActor (PresentedChatListSnapshotFfi) async -> Void)?

    init(
        account: AccountItem,
        runtime: any MarmotRuntime,
        blockedUsersModel: BlockedUsersViewModel? = nil
    ) {
        self.account = account
        self.runtime = runtime
        self.blockedUsersModel = blockedUsersModel
    }

    func start() {
        guard subscriptionTask == nil else { return }
        isLoading = presentedRows.isEmpty
        subscriptionTask = Task { [weak self] in
            await self?.runSubscription()
        }
        windowTask = Task { [weak self] in
            await self?.runWindowSubscription()
        }
    }

    func stop() {
        subscriptionTask?.cancel()
        subscriptionTask = nil
        windowTask?.cancel()
        windowTask = nil
        windowCommandTask?.cancel()
        windowCommandTask = nil
        windowSubscription = nil
    }

    func setSnapshotObserver(
        _ observer: (@MainActor (PresentedChatListSnapshotFfi) async -> Void)?
    ) async {
        snapshotObserver = observer
        if let latestSnapshot, let observer {
            await observer(latestSnapshot)
        }
    }

    func refreshRow(groupIdHex: String) async {
        do {
            guard
                let row = try await runtime.presentedChatListRow(
                    accountRef: account.accountRef,
                    groupIdHex: groupIdHex
                ), !Task.isCancelled
            else { return }
            if let index = presentedRows.firstIndex(where: { $0.row.groupIdHex == groupIdHex }) {
                presentedRows[index] = row
            } else {
                presentedRows.append(row)
            }
            error = nil
        } catch is CancellationError {
            return
        } catch {
            self.error = .unavailable(error.localizedDescription)
        }
    }

    func chats(
        view: ChatListViewFfi,
        nicknames: ContactNicknames,
        useWindow: Bool = true
    ) -> [ChatItem] {
        let sourceRows =
            view == .chats && useWindow
            ? windowSnapshot?.rows ?? presentedRows
            : presentedRows
        return
            sourceRows
            .filter { presented in
                switch view {
                case .chats, .unread:
                    !presented.row.archived
                case .archived:
                    presented.row.archived
                case .left:
                    true
                }
            }
            .map { presented in
                let peerNickname = presented.presentation.peerId.flatMap {
                    nicknames.nickname(forContactAccountIdHex: $0)
                }
                let senderNickname: String?
                if let sender = presented.row.lastMessage?.sender {
                    senderNickname = nicknames.nickname(forContactAccountIdHex: sender)
                } else {
                    senderNickname = nil
                }
                return ChatItem(
                    presented: presented,
                    activeAccountIdHex: account.accountIdHex,
                    nickname: peerNickname,
                    lastSenderNickname: senderNickname,
                    avatarBytes: presented.avatarAsset?.reference.flatMap { avatarBytesByReference[$0] },
                    isBlockedDirectPeer: presented.presentation.peerId.map {
                        blockedUsersModel?.isBlocked(accountID: $0) == true
                    } ?? false
                )
            }
            .filter { chat in
                switch view {
                case .chats:
                    !chat.isNoLongerMember
                case .unread:
                    !chat.isNoLongerMember && chat.hasUnread
                case .archived:
                    true
                case .left:
                    chat.isNoLongerMember
                }
            }
    }

    func setVisibleWindowAnchor(groupIdHex: String) {
        guard let snapshot = windowSnapshot,
            snapshot.rows.contains(where: { $0.row.groupIdHex == groupIdHex }),
            let windowSubscription
        else { return }
        if case .retained(let current, _) = snapshot.anchor, current == groupIdHex { return }
        enqueueWindowCommand { subscription, sequence in
            try await subscription.setVisibleAnchor(
                sequence: sequence,
                groupIdHex: groupIdHex
            )
        }
    }

    func pageWindow(_ direction: ChatListPageDirectionFfi, count: UInt32 = 50) async {
        guard !isPaging, let snapshot = windowSnapshot else { return }
        if direction == .forward, !snapshot.hasMoreAfter { return }
        if direction == .backward, !snapshot.hasMoreBefore { return }
        isPaging = true
        defer { isPaging = false }
        let command = enqueueWindowCommand { subscription, sequence in
            try await subscription.page(
                sequence: sequence,
                direction: direction,
                count: count
            )
        }
        await command?.value
    }

    @discardableResult
    private func enqueueWindowCommand(
        _ operation:
            @escaping @Sendable (ChatListWindowSubscription, UInt64) async throws
            -> ChatListWindowSnapshotFfi
    ) -> Task<Void, Never>? {
        guard let subscription = windowSubscription else { return nil }
        let previous = windowCommandTask
        let command = Task { [weak self] in
            await previous?.value
            guard let self, !Task.isCancelled, self.windowSubscription === subscription,
                let sequence = self.windowSnapshot?.sequence
            else { return }
            do {
                let replacement = try await operation(subscription, sequence)
                guard !Task.isCancelled, self.windowSubscription === subscription else { return }
                await self.installWindow(replacement)
            } catch is CancellationError {
                return
            } catch MarmotKitError.ChatWindowStale {
                return
            } catch {
                self.error = .unavailable(error.localizedDescription)
            }
        }
        windowCommandTask = command
        return command
    }

    private func runSubscription() async {
        defer {
            if Task.isCancelled {
                subscriptionTask = nil
            }
        }

        var retryNanoseconds: UInt64 = 250_000_000
        while !Task.isCancelled {
            do {
                let subscription = try await runtime.openPresentedChatList(
                    accountRef: account.accountRef,
                    includeArchived: true
                )
                try Task.checkCancellation()
                let initialSnapshot = try await FFIExecutor.run { [runtime] in
                    runtime.presentedChatListSubscriptionSnapshot(subscription: subscription)
                }
                guard let initial = initialSnapshot else {
                    throw CancellationError()
                }
                await install(initial.snapshot)
                var generation = initial.subscriptionGeneration
                var sequence = initial.sequence
                var storeEpoch = initial.snapshot.presentationVersion.accountStoreEpoch
                retryNanoseconds = 250_000_000

                while let update = try await runtime.nextPresentedChatListUpdate(subscription: subscription) {
                    try Task.checkCancellation()
                    guard update.subscriptionGeneration == generation,
                        update.snapshot.presentationVersion.accountStoreEpoch == storeEpoch
                    else {
                        generation = update.subscriptionGeneration
                        storeEpoch = update.snapshot.presentationVersion.accountStoreEpoch
                        break
                    }
                    guard update.sequence > sequence else { continue }
                    sequence = update.sequence
                    await install(update.snapshot)
                }
            } catch is CancellationError {
                return
            } catch {
                if presentedRows.isEmpty {
                    self.error = .unavailable(error.localizedDescription)
                }
                isLoading = false
            }

            guard !Task.isCancelled else { return }
            do {
                try await Task.sleep(nanoseconds: retryNanoseconds)
            } catch {
                return
            }
            retryNanoseconds = min(retryNanoseconds * 2, 4_000_000_000)
        }
    }

    private func runWindowSubscription() async {
        var retryNanoseconds: UInt64 = 250_000_000
        while !Task.isCancelled {
            do {
                let subscription = try await runtime.openChatListWindow(
                    accountRef: account.accountRef,
                    view: .chats,
                    initialRows: 50
                )
                try Task.checkCancellation()
                windowSubscription = subscription
                guard let initial = runtime.chatListWindowSnapshot(subscription: subscription) else {
                    throw CancellationError()
                }
                await installWindow(initial, reopening: true)
                retryNanoseconds = 250_000_000
                let generation = initial.subscriptionGeneration
                while let replacement = try await runtime.nextChatListWindowSnapshot(subscription: subscription) {
                    try Task.checkCancellation()
                    guard replacement.subscriptionGeneration == generation else { break }
                    await installWindow(replacement)
                }
            } catch is CancellationError {
                return
            } catch {
                // The complete presented list remains an authoritative fallback while a bounded
                // handle is reopening, so a window transport failure does not blank the inbox.
            }
            windowSubscription = nil
            guard !Task.isCancelled else { return }
            do {
                try await Task.sleep(nanoseconds: retryNanoseconds)
            } catch {
                return
            }
            retryNanoseconds = min(retryNanoseconds * 2, 4_000_000_000)
        }
    }

    private func installWindow(
        _ replacement: ChatListWindowSnapshotFfi,
        reopening: Bool = false
    ) async {
        if let current = windowSnapshot {
            guard
                reopening
                    || (current.subscriptionGeneration == replacement.subscriptionGeneration
                        && replacement.sequence >= current.sequence)
            else { return }
        }
        // Re-read when the core's content revision moves, not only when the reference is new: a
        // `.stale` picture and its refreshed replacement share one reference.
        let missingReferences = AvatarAssetReads.readableReferences(
            replacement.rows.map(\.avatarAsset).filter { asset in
                guard let reference = asset?.reference else { return false }
                return avatarBytesByReference[reference]?.contentRevision != asset?.contentRevision
            }
        )
        if !missingReferences.isEmpty {
            do {
                let payloads = try await AvatarAssetReads.read(
                    runtime: runtime,
                    accountRef: account.accountRef,
                    references: missingReferences
                )
                avatarBytesByReference.merge(payloads) { _, latest in latest }
            } catch is CancellationError {
                return
            } catch {
                // Remote URL/placeholder presentation remains available for this replacement.
            }
        }
        windowSnapshot = replacement
        isLoading = false
        error = nil
    }

    private func install(_ snapshot: PresentedChatListSnapshotFfi) async {
        let readyReferences = AvatarAssetReads.readableReferences(snapshot.rows.map(\.avatarAsset))
        if readyReferences.isEmpty {
            avatarBytesByReference = [:]
        } else {
            do {
                avatarBytesByReference = try await AvatarAssetReads.read(
                    runtime: runtime,
                    accountRef: account.accountRef,
                    references: readyReferences
                )
            } catch is CancellationError {
                return
            } catch {
                avatarBytesByReference = [:]
            }
        }
        latestSnapshot = snapshot
        presentedRows = snapshot.rows
        error = nil
        isLoading = false
        if let snapshotObserver {
            await snapshotObserver(snapshot)
        }
    }
}
