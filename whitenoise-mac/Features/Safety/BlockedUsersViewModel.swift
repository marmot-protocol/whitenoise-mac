import Foundation
import MarmotKit
import Observation

@MainActor
@Observable
final class BlockedUsersViewModel {
    private(set) var revision: UInt64?
    private(set) var users: [BlockedUserFfi] = []
    private(set) var isLoaded = false
    private(set) var mutatingUserIDs: Set<String> = []
    private(set) var uncertainIntent: BlockedUserMutationIntent?
    private(set) var error: String?

    @ObservationIgnored private let accountRef: String
    @ObservationIgnored private let runtime: any MarmotRuntime
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var changeObserver: (@MainActor (Set<String>) async -> Void)?

    init(accountRef: String, runtime: any MarmotRuntime) {
        self.accountRef = accountRef
        self.runtime = runtime
    }

    func start() {
        stop()
        task = Task { [weak self] in await self?.observe() }
    }

    func stop() {
        task?.cancel()
        task = nil
    }

    func setChangeObserver(
        _ observer: (@MainActor (Set<String>) async -> Void)?
    ) async {
        changeObserver = observer
    }

    var blockedAccountIDs: Set<String> {
        Set(users.map { $0.publicKey.lowercased() })
    }

    func isBlocked(accountID: String) -> Bool {
        // Preserve the last confirmed privacy decision if the live stream is temporarily
        // unavailable. Unknown state starts empty, but a transient read failure must not reveal
        // content from somebody already known to be blocked.
        blockedAccountIDs.contains(accountID.lowercased())
    }

    func canMutate(accountID: String) -> Bool {
        let normalized = accountID.lowercased()
        guard isLoaded, !mutatingUserIDs.contains(normalized) else { return false }
        guard let uncertainIntent else { return true }
        return uncertainIntent.accountID == normalized
    }

    func setBlocked(_ blocked: Bool, accountID: String) async {
        let normalized = accountID.lowercased()
        guard canMutate(accountID: normalized) else { return }
        if let uncertainIntent,
            uncertainIntent != BlockedUserMutationIntent(accountID: normalized, blocked: blocked)
        {
            return
        }
        mutatingUserIDs.insert(normalized)
        defer { mutatingUserIDs.remove(normalized) }
        do {
            if blocked {
                try await runtime.blockUser(accountRef: accountRef, userAccountIdHex: normalized)
            } else {
                try await runtime.unblockUser(accountRef: accountRef, userAccountIdHex: normalized)
            }
            users = try await FFIExecutor.run { [runtime, accountRef] in
                try runtime.getBlockedUsers(accountRef: accountRef)
            }
            isLoaded = true
            uncertainIntent = nil
            error = nil
            await changeObserver?(blockedAccountIDs)
        } catch is CancellationError {
            return
        } catch MarmotKitError.BlockPublicationUncertain {
            uncertainIntent = BlockedUserMutationIntent(accountID: normalized, blocked: blocked)
            error = L10n.string(
                "The block-list update could not be confirmed. Retry the same change to check its status."
            )
        } catch {
            self.error = UserFacingError.message(for: error)
        }
    }

    private func observe() async {
        do {
            let subscription = try await FFIExecutor.run { [runtime, accountRef] in
                try runtime.subscribeBlockedUsers(accountRef: accountRef)
            }
            try Task.checkCancellation()
            if let initial = runtime.blockedUsersSnapshot(subscription: subscription) {
                await install(initial)
            }
            while let replacement = try await runtime.nextBlockedUsersSnapshot(subscription: subscription) {
                try Task.checkCancellation()
                await install(replacement)
            }
            if !Task.isCancelled {
                isLoaded = false
            }
        } catch is CancellationError {
            return
        } catch {
            isLoaded = false
            self.error = UserFacingError.message(for: error)
        }
    }

    private func install(_ snapshot: BlockListSnapshotFfi) async {
        guard revision == nil || snapshot.revision > revision! else { return }
        revision = snapshot.revision
        users = snapshot.users
        isLoaded = true
        if uncertainIntent == nil {
            error = nil
        }
        await changeObserver?(blockedAccountIDs)
    }
}

nonisolated struct BlockedUserMutationIntent: Equatable, Sendable {
    let accountID: String
    let blocked: Bool
}
