//
//  WorkspaceState+NewChat.swift
//  whitenoise-mac
//
//  NewChat behavior extracted from WorkspaceState.swift (no behavior change).
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
    @discardableResult
    func resolveNewChatQuery() async -> NewChatRecipient? {
        let query = newChatQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let client else { return nil }
        guard !query.isEmpty else {
            invalidateNewChatLookup()
            newChatRecipient = nil
            lastError = L10n.string("Enter an npub, profile link, or public key.")
            return nil
        }

        lastError = nil
        let lookupGeneration = beginNewChatLookup()
        isResolvingNewChat = true
        defer {
            if isCurrentNewChatLookup(generation: lookupGeneration, query: query) {
                isResolvingNewChat = false
            }
        }

        do {
            let member = try await runOffMain {
                try client.normalizeMemberRef(memberRef: query)
            }
            try? await client.refreshProfile(accountIdHex: member.accountIdHex, relays: MarmotClient.seedRelays)
            peerProfileFFICache[member.accountIdHex] = nil
            let resolved = try? await runOffMain { () -> ResolvedPeerFFI in
                let profile = try? client.userProfile(accountIdHex: member.accountIdHex)
                return ResolvedPeerFFI(
                    profileDisplayName: profile?.displayName,
                    profileName: profile?.name,
                    profilePicture: profile?.picture,
                    directoryDisplayName: client.displayName(accountIdHex: member.accountIdHex)
                )
            }
            let displayName = firstNonBlank([
                resolved?.profileDisplayName,
                resolved?.profileName,
                resolved?.directoryDisplayName,
            ])
            let recipient = NewChatRecipient(
                sourceQuery: query,
                memberRef: member.memberRef,
                accountIdHex: member.accountIdHex,
                npub: member.npub,
                displayName: displayName,
                pictureURL: resolved?.profilePicture
            )
            guard isCurrentNewChatLookup(generation: lookupGeneration, query: query) else {
                return nil
            }
            newChatRecipient = recipient
            return recipient
        } catch {
            guard isCurrentNewChatLookup(generation: lookupGeneration, query: query) else {
                return nil
            }
            newChatRecipient = nil
            lastError = L10n.string("Enter a valid npub, profile link, or hex public key.")
            return nil
        }
    }

    func resolveNewChatQueryIfReady() async {
        let query = newChatQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            invalidateNewChatLookup()
            newChatRecipient = nil
            lastError = nil
            return
        }
        guard looksLikeMemberRef(query) else {
            invalidateNewChatLookup()
            newChatRecipient = nil
            return
        }
        guard resolvedNewChatRecipient == nil else { return }

        await resolveNewChatQuery()
    }

    func createNewChat() async {
        guard let client, let activeAccount, !isCreatingChat else { return }
        let recipient: NewChatRecipient?
        if let resolvedNewChatRecipient {
            recipient = resolvedNewChatRecipient
        } else {
            recipient = await resolveNewChatQuery()
        }
        guard let recipient else { return }

        lastError = nil
        isCreatingChat = true
        defer { isCreatingChat = false }

        do {
            let trimmedName = newChatName.trimmingCharacters(in: .whitespacesAndNewlines)
            let trimmedDescription = newChatDescription.trimmingCharacters(in: .whitespacesAndNewlines)
            let groupIdHex = try await client.createGroup(
                accountRef: activeAccount.accountRef,
                name: trimmedName.isEmpty ? recipient.title : trimmedName,
                memberRefs: [recipient.memberRef],
                description: trimmedDescription.isEmpty ? nil : trimmedDescription
            )
            await reloadChats()
            insertCreatedChatIfNeeded(
                groupIdHex: groupIdHex,
                title: trimmedName.isEmpty ? recipient.title : trimmedName,
                avatarSeed: recipient.accountIdHex,
                pictureURL: recipient.pictureURL
            )
            selection = .chat(groupIdHex)
            closeNewChatComposer()
            beginTimelineInitialLoadIfNeeded(groupIdHex: groupIdHex)
            await loadMessages(groupIdHex: groupIdHex)
        } catch {
            lastError = error.localizedDescription
        }
    }

    func resetNewChatComposer() {
        invalidateNewChatLookup()
        newChatQuery = ""
        newChatName = ""
        newChatDescription = ""
        newChatRecipient = nil
    }

    func beginNewChatLookup() -> Int {
        newChatLookupGeneration += 1
        return newChatLookupGeneration
    }

    func invalidateNewChatLookup() {
        newChatLookupGeneration += 1
        isResolvingNewChat = false
    }

    func isCurrentNewChatLookup(generation: Int, query: String) -> Bool {
        newChatLookupGeneration == generation
            && newChatQuery.trimmingCharacters(in: .whitespacesAndNewlines) == query
    }

    func insertCreatedChatIfNeeded(groupIdHex: String, title: String, avatarSeed: String, pictureURL: String?) {
        guard let activeAccountId else { return }
        let chats = chatsByAccount[activeAccountId] ?? []
        guard !chats.contains(where: { $0.id == groupIdHex }) else { return }

        let chat = ChatItem(
            id: groupIdHex,
            title: title,
            subtitle: L10n.string("Direct message"),
            preview: L10n.string("No messages yet"),
            updatedAt: nil,
            avatarSeed: avatarSeed,
            pictureURL: pictureURL,
            unreadCount: 0,
            isDirect: true
        )
        chatsByAccount[activeAccountId] = ChatListOrdering.upserting(chat, into: chats)
    }

    func looksLikeMemberRef(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let lowercased = trimmed.lowercased()
        if lowercased.hasPrefix("npub") || lowercased.hasPrefix("nostr:npub") {
            return true
        }
        if lowercased.hasPrefix("darkmatter://profile/") {
            return true
        }
        return trimmed.count == 64 && trimmed.allSatisfy(\.isHexDigit)
    }
}
