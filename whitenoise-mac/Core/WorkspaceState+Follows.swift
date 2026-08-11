//
//  WorkspaceState+Follows.swift
//  whitenoise-mac
//
//  The active account's kind-3 follow list: cached reads, and the follow/unfollow
//  mutation. Unlike almost every other MarmotKit call the mutations really do hit the
//  network — the core fetches the account's current contact-list event from its known
//  outbox/default relays before republishing — so they carry a spinner and a failure path.
//

import Foundation
import MarmotKit

/// What a contact's follow control can show. There is no "unknown" case on purpose: an
/// unresolved relationship is either still loading or a failed read the user can retry.
enum ContactFollowStatus: Equatable {
    case loading
    case known(Bool)
    case unavailable
}

@MainActor
extension WorkspaceState {
    /// Lowercased account-id hex of everyone the active account is known to follow.
    var followedAccountIdsHex: Set<String> {
        Set(followStateByAccountIdHex.lazy.filter(\.value).map(\.key))
    }

    /// `nil` while the relationship is still unknown. The follow control must not offer
    /// "Follow" for someone the account may already be following.
    func isFollowingContact(accountIdHex: String) -> Bool? {
        let hex = Self.normalizedFollowKey(accountIdHex)
        guard !hex.isEmpty else { return nil }
        if let known = followStateByAccountIdHex[hex] { return known }
        return hasCompleteFollowList ? false : nil
    }

    /// What the follow control should render. "Unknown" is never a resting state: it is either
    /// still being read, or it failed and the user is offered the read again.
    func contactFollowStatus(accountIdHex: String) -> ContactFollowStatus {
        if let isFollowing = isFollowingContact(accountIdHex: accountIdHex) {
            return .known(isFollowing)
        }
        let hex = Self.normalizedFollowKey(accountIdHex)
        if followStatusContactIdHex == hex, followStatusReadFailed, !isLoadingFollowStatus {
            return .unavailable
        }
        return .loading
    }

    /// True when `accountIdHex` belongs to *any* identity on this device, not just the
    /// active one. `ContactDetailsView.isSelf` only compares the active account, so a
    /// multi-account user could otherwise follow their own other identity.
    func isLocalAccount(accountIdHex: String) -> Bool {
        let hex = Self.normalizedFollowKey(accountIdHex)
        guard !hex.isEmpty else { return false }
        return accounts.contains { $0.accountIdHex.lowercased() == hex }
    }

    /// Whether a follow control belongs on screen for `accountIdHex` at all. A blank key has
    /// nobody to act on, and every identity on this device is excluded — you cannot follow
    /// yourself, on the active account or any other one signed in here.
    func canOfferFollow(accountIdHex: String) -> Bool {
        let hex = Self.normalizedFollowKey(accountIdHex)
        return !hex.isEmpty && !isLocalAccount(accountIdHex: hex)
    }

    /// Resolve the follow state of a direct chat's peer, so chat info can offer the same control
    /// the profile does. Keyed off `directPeerAccountIdHex` rather than the avatar seed: a
    /// note-to-self chat seeds from the group id and has nobody to follow.
    func refreshDirectPeerFollowStatus(for chat: ChatItem) async {
        guard let peerAccountIdHex = chat.directPeerAccountIdHex else { return }
        await refreshFollowStatus(forContactIdHex: peerAccountIdHex)
    }

    /// How many times a per-contact read is attempted before the control offers a manual retry.
    static let followStatusAttemptLimit = 2
    static let followStatusRetryDelay = Duration.milliseconds(250)

    /// Resolve one contact's follow state. Network-free read of the local kind-3 cache, retried
    /// once on failure; if it still cannot be read the control shows a retry rather than
    /// vanishing, because a hidden control is indistinguishable from an unbuilt feature.
    func refreshFollowStatus(forContactIdHex accountIdHex: String) async {
        let hex = Self.normalizedFollowKey(accountIdHex)
        guard !hex.isEmpty, let client, let activeAccount, let accountId = activeAccountId else { return }

        followStatusGeneration &+= 1
        let generation = followStatusGeneration
        let epoch = followCacheEpoch
        let accountRef = activeAccount.accountRef
        followStatusContactIdHex = hex
        followStatusReadFailed = false
        isLoadingFollowStatus = true
        defer {
            if followStatusGeneration == generation {
                isLoadingFollowStatus = false
            }
        }

        for attempt in 1...Self.followStatusAttemptLimit {
            do {
                let isFollowing = try await FFIExecutor.run {
                    try client.isFollowing(accountRef: accountRef, userRef: hex)
                }
                guard followStatusGeneration == generation, activeAccountId == accountId else { return }
                // A complete list applied while this read was in flight — a mutation's published
                // list, or a whole-list refresh — is newer than the answer this read is holding.
                // Writing the older answer back would flip the control away from what was just
                // published, and invite a second publish of a follow that already landed.
                guard followCacheEpoch == epoch else { return }
                followStateByAccountIdHex[hex] = isFollowing
                return
            } catch {
                guard followStatusGeneration == generation, activeAccountId == accountId else { return }
                guard attempt < Self.followStatusAttemptLimit else { break }
                try? await Task.sleep(for: Self.followStatusRetryDelay)
                guard followStatusGeneration == generation, activeAccountId == accountId else { return }
            }
        }

        // Keep whatever is already known: failing closed would show "Follow" for someone this
        // account is known to follow. The unavailable state only applies while it is unknown.
        followStatusReadFailed = isFollowingContact(accountIdHex: hex) == nil
    }

    /// Read the account's complete follow list. Network-free, and the only read that can
    /// prove a *negative* relationship for a contact that was never resolved individually.
    @discardableResult
    func refreshFollowedAccounts() async -> Bool {
        guard let client, let activeAccount, let accountId = activeAccountId else { return false }

        followListGeneration &+= 1
        let generation = followListGeneration
        let epoch = followCacheEpoch
        let accountRef = activeAccount.accountRef
        do {
            let follows = try await FFIExecutor.run {
                try client.accountFollows(accountRef: accountRef)
            }
            guard followListGeneration == generation, activeAccountId == accountId else { return false }
            // Same staleness rule the per-contact read follows: a mutation that published while
            // this read was in flight is the newer truth, and a whole list clobbers *everything*.
            guard followCacheEpoch == epoch else { return false }
            applyCompleteFollowList(follows)
            return true
        } catch {
            return false
        }
    }

    /// Follow or unfollow `accountIdHex`, depending on the currently known relationship.
    func toggleFollow(accountIdHex: String) async {
        let hex = Self.normalizedFollowKey(accountIdHex)
        guard
            !hex.isEmpty,
            !isTogglingFollow,
            !isLocalAccount(accountIdHex: hex),
            let isFollowing = isFollowingContact(accountIdHex: hex),
            let client,
            let activeAccount,
            let accountId = activeAccountId
        else { return }

        followMutationGeneration &+= 1
        let generation = followMutationGeneration
        // Any read already in flight resolved before this mutation, so it is stale the moment
        // the mutation starts and loses its claim now rather than racing the epoch check later.
        invalidateFollowStatusRead()
        invalidateFollowListRead()
        let accountRef = activeAccount.accountRef
        lastError = nil
        isTogglingFollow = true
        defer {
            if followMutationGeneration == generation {
                isTogglingFollow = false
            }
        }

        do {
            // Both mutations preserve every other entry and return the complete updated
            // list, so the resulting relationship is read back from that list rather than
            // assumed from the mutation we asked for.
            let updated =
                isFollowing
                ? try await client.unfollowUser(accountRef: accountRef, userRef: hex)
                : try await client.followUser(accountRef: accountRef, userRef: hex)
            guard followMutationGeneration == generation, activeAccountId == accountId else { return }
            applyCompleteFollowList(updated)
        } catch {
            guard followMutationGeneration == generation, activeAccountId == accountId else { return }
            lastError = Self.followMutationErrorMessage(for: error)
        }
    }

    /// Replace the cache with a whole-list snapshot, which also settles every contact that
    /// is *not* in it.
    func applyCompleteFollowList(_ follows: [String]) {
        var state: [String: Bool] = [:]
        state.reserveCapacity(follows.count)
        for entry in follows {
            let hex = Self.normalizedFollowKey(entry)
            guard !hex.isEmpty else { continue }
            state[hex] = true
        }
        followStateByAccountIdHex = state
        hasCompleteFollowList = true
        // Everything resolved against the previous cache is now stale, whoever asked for it.
        followCacheEpoch &+= 1
    }

    /// Drop an in-flight mutation's claim on the UI. Called when the contact sheet closes,
    /// so a late completion cannot resurrect the spinner or post an error against a screen
    /// the user already left (the shape of issue #135). The published mutation still stands;
    /// the next read of the list picks it up.
    func invalidateFollowMutation() {
        followMutationGeneration &+= 1
        isTogglingFollow = false
    }

    /// Drop an in-flight per-contact read's claim on the loading/unavailable state, so a closed
    /// sheet cannot leave a spinner or a retry behind for the next contact opened.
    func invalidateFollowStatusRead() {
        followStatusGeneration &+= 1
        followStatusContactIdHex = nil
        isLoadingFollowStatus = false
        followStatusReadFailed = false
    }

    /// Drop an in-flight whole-list read's claim. Separate from the per-contact read above so the
    /// two cannot invalidate each other merely by starting: a profile opening must not silently
    /// discard the list refresh a compose panel is waiting on, which would leave every contact it
    /// never named reading as unknown.
    func invalidateFollowListRead() {
        followListGeneration &+= 1
    }

    /// Follows are per-account, so an account switch must not leak one identity's list into
    /// another's UI.
    func clearFollows() {
        followStateByAccountIdHex = [:]
        hasCompleteFollowList = false
        // The cleared cache is a new epoch, and both reads lose their claim: an in-flight read
        // for the previous identity must not land on the next one's empty list.
        followCacheEpoch &+= 1
        invalidateFollowStatusRead()
        invalidateFollowListRead()
        invalidateFollowMutation()
    }

    /// `FollowListUnavailable` is the core *refusing* to publish: it could not establish the
    /// current contact-list event, and would rather fail than replace a full list with a
    /// one-entry one. Nothing changed, and retrying after relay recovery is safe — which is
    /// the opposite of what a generic failure message implies.
    nonisolated static func followMutationErrorMessage(for error: Error) -> String {
        if let error = error as? MarmotKitError, case .FollowListUnavailable = error {
            return L10n.string(
                "Couldn't reach your relays to update your follow list. Nothing changed — try again."
            )
        }
        return error.localizedDescription
    }

    nonisolated static func normalizedFollowKey(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}
