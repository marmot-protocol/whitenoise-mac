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
    /// marmot profile autolinks, and OS-level marmot:// deep links): open the New Chat composer
    /// against the referenced profile via the FFI `normalizeMemberRef` path.
    func openProfileReference(_ reference: String) async {
        showNewChat()
        newChatQuery = "nostr:\(reference)"
        _ = await resolveNewChatQuery()
    }
}
