//
//  WorkspaceState+DirectPeerMemory.swift
//  whitenoise-mac
//
//  Local, account-scoped memory of who a conversation was a one-to-one chat with, so a DM keeps
//  naming its peer after that peer leaves and the roster has nobody left to name it with.
//

import Foundation
import OSLog

private let directPeerMemoryLogger = Logger(subsystem: "com.whitenoise.storage", category: "DirectPeers")

@MainActor
extension WorkspaceState {
    func loadRememberedDirectPeers() {
        guard let directPeerMemoryStore else { return }
        do {
            rememberedDirectPeersByAccount = try directPeerMemoryStore.loadAll()
        } catch {
            directPeerMemoryLogger.error(
                "Failed to load protected direct-peer state: \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    func rememberedDirectPeer(groupIdHex: String, accountId: String) -> RememberedDirectPeer? {
        rememberedDirectPeersByAccount[accountId]?[groupIdHex]
    }

    /// Record the peer of a two-person conversation while they are still reachable in the roster.
    ///
    /// Re-recording an unchanged peer is a no-op, so the steady state of chat-list enrichment does
    /// no disk writes at all — only an actual change to who the other party is costs a write.
    func rememberDirectPeer(_ peer: RememberedDirectPeer, groupIdHex: String, accountId: String) {
        guard !groupIdHex.isEmpty, !peer.accountIdHex.isEmpty else { return }
        guard rememberedDirectPeersByAccount[accountId]?[groupIdHex] != peer else { return }
        rememberedDirectPeersByAccount[accountId, default: [:]][groupIdHex] = peer
        persistRememberedDirectPeers(forAccountId: accountId)
    }

    /// Drop the remembered peer once a conversation is no longer a two-person chat: a group with
    /// several other members is not describable by a single peer, so a stale one must not resurface
    /// if that group later empties out.
    func forgetDirectPeer(groupIdHex: String, accountId: String) {
        guard rememberedDirectPeersByAccount[accountId]?[groupIdHex] != nil else { return }
        rememberedDirectPeersByAccount[accountId]?[groupIdHex] = nil
        if rememberedDirectPeersByAccount[accountId]?.isEmpty == true {
            rememberedDirectPeersByAccount[accountId] = nil
        }
        persistRememberedDirectPeers(forAccountId: accountId)
    }

    /// Forget every peer an account recorded. Called on account removal, where the owner is gone;
    /// ordinary sign-out deliberately retains them, like pinned chats and hidden messages.
    func purgeRememberedDirectPeers(accountId: String) {
        rememberedDirectPeersByAccount[accountId] = nil
        do {
            try directPeerMemoryStore?.remove(forAccountId: accountId)
        } catch {
            directPeerMemoryLogger.error(
                "Failed to purge direct-peer state for an account: \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    /// Forget every remembered peer on the device — part of the "Delete All Local Data" reset.
    func clearAllRememberedDirectPeers() {
        rememberedDirectPeersByAccount = [:]
        unrecoverableDirectPeerGroupIds.removeAll()
        do {
            try directPeerMemoryStore?.removeAll()
        } catch {
            directPeerMemoryLogger.error(
                "Failed to clear direct-peer state: \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    private func persistRememberedDirectPeers(forAccountId accountId: String) {
        guard let directPeerMemoryStore else { return }
        do {
            let peers = rememberedDirectPeersByAccount[accountId] ?? [:]
            if peers.isEmpty {
                try directPeerMemoryStore.remove(forAccountId: accountId)
            } else {
                try directPeerMemoryStore.write(peers, forAccountId: accountId)
            }
        } catch {
            directPeerMemoryLogger.error(
                "Failed to persist direct-peer state: \(error.localizedDescription, privacy: .public)"
            )
        }
    }
}
