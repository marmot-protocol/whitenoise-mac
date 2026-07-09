//
//  WorkspaceState+Links.swift
//  whitenoise-mac
//
//  Link-opening policy for untrusted message Markdown.
//

import Foundation
import SwiftUI

@MainActor
extension WorkspaceState {
    /// Gate every tappable link rendered from peer-controlled Markdown before SwiftUI can fall
    /// through to LaunchServices. Only browser-safe web links may use the system action; Nostr
    /// and marmot profile links are consumed in-app, and every other scheme is dropped.
    func handleMessageLinkOpen(_ url: URL) -> OpenURLAction.Result {
        guard MarkdownLinkPolicy.isAllowed(url) else { return .discarded }

        if MarkdownLinkPolicy.isInternalNostrURL(url) {
            Task { await handleNostrMessageLink(url) }
            return .handled
        }

        if let reference = MarmotProfileLink.profileReference(from: url) {
            Task { await openProfileReference(reference) }
            return .handled
        }

        guard MarkdownLinkPolicy.isAllowedExternalURL(url) else { return .discarded }
        return .systemAction
    }

    private func handleNostrMessageLink(_ url: URL) async {
        guard let reference = MarkdownLinkPolicy.nostrReference(from: url) else { return }

        if MarkdownLinkPolicy.isResolvableProfileReference(reference) {
            await openProfileReference(reference)
        } else {
            backgroundStatus = L10n.string("This Nostr link type is not supported yet.")
        }
    }

    /// Shared destination for every profile reference the app consumes in-app (nostr autolinks,
    /// marmot profile autolinks, and OS-level marmot:// deep links): open or augment the New Chat
    /// composer against the referenced profile via the FFI `normalizeMemberRef` path.
    func openProfileReference(_ reference: String) async {
        let query = "nostr:\(reference)"
        if isNewChatComposerVisible {
            leaveActiveConversation()
            lastError = nil
            if hasInProgressNewChatComposition {
                await appendProfileReferenceToCurrentNewChat(query: query)
            } else {
                invalidateNewChatLookup()
                newChatRecipient = nil
                newChatQuery = query
                _ = await resolveNewChatQuery()
            }
        } else {
            showNewChat()
            newChatQuery = query
            _ = await resolveNewChatQuery()
        }
    }

    private func appendProfileReferenceToCurrentNewChat(query: String) async {
        let previousQuery = newChatQuery
        let previousRecipient = newChatRecipient

        invalidateNewChatLookup()
        newChatRecipient = nil
        newChatQuery = query
        if let recipient = await resolveNewChatQuery() {
            _ = appendNewChatRecipient(recipient)
        }
        invalidateNewChatLookup()
        newChatQuery = previousQuery
        newChatRecipient = previousRecipient
    }
}
