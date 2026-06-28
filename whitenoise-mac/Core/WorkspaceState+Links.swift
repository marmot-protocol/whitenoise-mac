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
    /// links are consumed in-app, and every other scheme is dropped.
    func handleMessageLinkOpen(_ url: URL) -> OpenURLAction.Result {
        guard MarkdownLinkPolicy.isAllowed(url) else { return .discarded }

        if MarkdownLinkPolicy.isInternalNostrURL(url) {
            Task { await handleNostrMessageLink(url) }
            return .handled
        }

        guard MarkdownLinkPolicy.isAllowedExternalURL(url) else { return .discarded }
        return .systemAction
    }

    private func handleNostrMessageLink(_ url: URL) async {
        guard let reference = MarkdownLinkPolicy.nostrReference(from: url) else { return }

        if MarkdownLinkPolicy.isResolvableProfileReference(reference) {
            showNewChat()
            newChatQuery = "nostr:\(reference)"
            _ = await resolveNewChatQuery()
        } else {
            backgroundStatus = L10n.string("This Nostr link type is not supported yet.")
        }
    }
}
