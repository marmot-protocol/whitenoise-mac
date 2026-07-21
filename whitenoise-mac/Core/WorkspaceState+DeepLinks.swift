//
//  WorkspaceState+DeepLinks.swift
//  whitenoise-mac
//
//  OS-level marmot:// deep-link entry, delivered through SwiftUI `.onOpenURL`
//  (kAEGetURL). Registered via CFBundleURLTypes in Config/Info.plist.
//

import Foundation

@MainActor
extension WorkspaceState {
    /// The `marmot://` scheme is not exclusive to this app and any process can send an
    /// open-URL event, so inbound URLs are untrusted input: only the strict
    /// `marmot://profile/<npub|nprofile>` form is accepted, everything else is dropped
    /// with a status hint. FFI-side `normalizeMemberRef` remains the authoritative parse.
    func handleDeepLinkURL(_ url: URL) {
        guard let reference = MarmotProfileLink.profileReference(from: url) else {
            backgroundStatus = L10n.string("This link type is not supported.")
            return
        }

        guard phase == .ready, client != nil else {
            // Cold start: .onOpenURL fires before bootstrap() finishes, and the link may
            // also arrive while signed out. Queue the reference; every path to `.ready`
            // funnels through activateReadyState(), which flushes it without activating.
            pendingDeepLinkProfileReference = reference
            if phase == .onboarding {
                backgroundStatus = L10n.string("Sign in to start a chat from this link.")
            }
            return
        }

        appActivationHandler(false)
        Task { await openProfileReferenceFromDeepLink(reference) }
    }

    func flushPendingDeepLinkIfReady() {
        guard phase == .ready, client != nil,
            let reference = pendingDeepLinkProfileReference
        else { return }
        pendingDeepLinkProfileReference = nil
        // Queued links came from an earlier untrusted URL event. Handle them once ready,
        // but do not foreground the app later as a delayed side effect.
        Task { await openProfileReferenceFromDeepLink(reference) }
    }

    /// OS-level links are unsolicited. Do not let them interrupt active work; profile links
    /// explicitly tapped inside the app still use the normal `openProfileReference` behavior.
    private func openProfileReferenceFromDeepLink(_ reference: String) async {
        guard !isRecordingVoiceMessage, !isPreparingVoiceRecording else {
            backgroundStatus = L10n.string("Finish the current voice recording before opening this link.")
            return
        }

        guard !(isNewChatComposerVisible && hasInProgressNewChatComposition) else {
            backgroundStatus = L10n.string(
                "Finish or discard the current New Chat draft before opening this link."
            )
            return
        }

        guard !isExportingGroupTranscript, groupTranscriptExportTask == nil else {
            backgroundStatus = L10n.string(
                "Finish exporting the current transcript before opening this link."
            )
            return
        }

        await openProfileReference(reference)
    }
}
