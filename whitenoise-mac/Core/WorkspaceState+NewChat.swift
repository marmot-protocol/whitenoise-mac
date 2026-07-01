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

    /// Resolve the current query (if needed) and move that recipient into the
    /// confirmed members list, clearing the input so the next pubkey can be added.
    @discardableResult
    func addCurrentNewChatRecipient() async -> Bool {
        let recipient: NewChatRecipient?
        if let resolvedNewChatRecipient {
            recipient = resolvedNewChatRecipient
        } else {
            recipient = await resolveNewChatQuery()
        }
        guard let recipient else { return false }

        appendNewChatRecipient(recipient)
        invalidateNewChatLookup()
        newChatQuery = ""
        newChatRecipient = nil
        lastError = nil
        return true
    }

    func appendNewChatRecipient(_ recipient: NewChatRecipient) {
        guard !newChatRecipients.contains(where: { $0.accountIdHex == recipient.accountIdHex }) else { return }
        newChatRecipients.append(recipient)
    }

    func removeNewChatRecipient(_ recipient: NewChatRecipient) {
        newChatRecipients.removeAll { $0.accountIdHex == recipient.accountIdHex }
    }

    func createNewChat() async {
        guard let client, let activeAccount, !isCreatingChat else { return }

        // Capture the creating account on entry so a mid-await A→B account switch (e.g. via
        // a notification tap while `createGroup`/`reloadChats` are suspended) cannot graft
        // account A's freshly created group onto account B's chat list or select/load it
        // under B's context. The group's FFI data stays partitioned by account ref; this
        // only guards the workspace UI state. See whitenoise-mac#229.
        let accountId = activeAccount.id

        // Gather every member: the confirmed list plus any pubkey still sitting
        // resolved-but-unadded in the input, falling back to resolving the raw
        // query when nothing has been added yet. Dedup by account so the same
        // person can't be invited twice.
        var recipients = newChatRecipients
        if let resolvedNewChatRecipient,
            !recipients.contains(where: { $0.accountIdHex == resolvedNewChatRecipient.accountIdHex })
        {
            recipients.append(resolvedNewChatRecipient)
        } else if recipients.isEmpty, let resolved = await resolveNewChatQuery() {
            recipients.append(resolved)
        }
        guard let primary = recipients.first else { return }
        let isDirect = recipients.count == 1

        lastError = nil
        isCreatingChat = true
        defer { isCreatingChat = false }

        do {
            let trimmedName = newChatName.trimmingCharacters(in: .whitespacesAndNewlines)
            let trimmedDescription = newChatDescription.trimmingCharacters(in: .whitespacesAndNewlines)
            let fallbackTitle =
                isDirect
                ? primary.title
                : recipients.map(\.title).joined(separator: ", ")
            let groupName = trimmedName.isEmpty ? fallbackTitle : trimmedName
            let groupIdHex = try await client.createGroup(
                accountRef: activeAccount.accountRef,
                name: groupName,
                memberRefs: recipients.map(\.memberRef),
                description: trimmedDescription.isEmpty ? nil : trimmedDescription
            )
            await reloadChats(forceFreshSnapshot: true)
            guard activeAccountId == accountId else { return }
            insertCreatedChatIfNeeded(
                groupIdHex: groupIdHex,
                title: groupName,
                avatarSeed: primary.accountIdHex,
                pictureURL: isDirect ? primary.pictureURL : nil,
                isDirect: isDirect
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
        newChatRecipients = []
    }

    func beginNewChatLookup() -> UInt64 {
        newChatLookupGeneration &+= 1
        return newChatLookupGeneration
    }

    func invalidateNewChatLookup() {
        newChatLookupGeneration &+= 1
        isResolvingNewChat = false
    }

    func isCurrentNewChatLookup(generation: UInt64, query: String) -> Bool {
        newChatLookupGeneration == generation
            && newChatQuery.trimmingCharacters(in: .whitespacesAndNewlines) == query
    }

    func insertCreatedChatIfNeeded(
        groupIdHex: String,
        title: String,
        avatarSeed: String,
        pictureURL: String?,
        isDirect: Bool = true
    ) {
        guard let activeAccountId else { return }
        guard chatItem(accountId: activeAccountId, chatId: groupIdHex) == nil else { return }

        let chat = ChatItem(
            id: groupIdHex,
            title: title,
            subtitle: isDirect ? L10n.string("Direct message") : L10n.string("Group chat"),
            preview: L10n.string("No messages yet"),
            updatedAt: nil,
            avatarSeed: avatarSeed,
            pictureURL: pictureURL,
            unreadCount: 0,
            isDirect: isDirect
        )
        upsertChat(chat, forAccountId: activeAccountId)
    }

    func looksLikeMemberRef(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let lowercased = trimmed.lowercased()
        if MarkdownLinkPolicy.isProfileReferenceInput(trimmed) {
            return true
        }
        if lowercased.hasPrefix("darkmatter://profile/") {
            return true
        }
        return trimmed.count == 64 && trimmed.allSatisfy(\.isHexDigit)
    }
}
