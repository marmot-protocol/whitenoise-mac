//
//  AutomaticMediaDownloadCoordinator.swift
//  whitenoise-mac
//

import Foundation

/// The lifetime of a tile's automatic download, held apart from the view modifier that reports
/// events to it.
///
/// Transcript rows are deliberately eager, so a row scrolled out of the viewport is still built and
/// `onDisappear` never runs for it. That makes "the download is let go of when the tile leaves the
/// screen" a promise the view cannot keep on its own, and it is the promise that matters: without
/// it a transcript full of media keeps every download it ever started running behind the reader.
///
/// The download itself is supplied per event rather than held here, because the workspace it goes
/// through reaches the modifier from the environment and not from an initialiser.
@MainActor
final class AutomaticMediaDownloadCoordinator {
    private var task: Task<Void, Never>?
    private var isVisibleInScrollView = false

    /// Whether a download this coordinator started is still in flight. The one thing every event
    /// below is about, and the only thing a test needs to look at.
    var isDownloading: Bool {
        guard let task else { return false }
        return !task.isCancelled
    }

    /// A tile that scrolled into the viewport starts; one that scrolled out lets go at once.
    func scrollVisibilityChanged(
        to isVisible: Bool,
        isReady: Bool,
        download: @escaping () async -> Void
    ) {
        isVisibleInScrollView = isVisible
        if isVisible {
            startIfReady(isReady, download: download)
        } else {
            cancel()
        }
    }

    /// The non-scrolling case — a tile outside a `ScrollView` has no visibility to wait for.
    func appeared(isReady: Bool, download: @escaping () async -> Void) {
        startIfReady(isReady, download: download)
    }

    /// A tile reused for another attachment drops the download it was running for the old one,
    /// which would otherwise finish and be filed against the attachment now on screen.
    func attachmentChanged(
        isReady: Bool,
        requiresScrollVisibility: Bool,
        download: @escaping () async -> Void
    ) {
        cancel()
        guard shouldStartForCurrentVisibility(requiresScrollVisibility: requiresScrollVisibility) else {
            return
        }
        startIfReady(isReady, download: download)
    }

    /// The store went back to `.idle` — a retry, or a download that was cleared — so a visible tile
    /// picks it up again without waiting to be scrolled.
    func readinessChanged(
        to isReady: Bool,
        requiresScrollVisibility: Bool,
        download: @escaping () async -> Void
    ) {
        guard isReady,
            shouldStartForCurrentVisibility(requiresScrollVisibility: requiresScrollVisibility)
        else { return }
        startIfReady(isReady, download: download)
    }

    /// SwiftUI took the tile away entirely.
    func disappeared() {
        cancel()
    }

    func cancel() {
        task?.cancel()
        task = nil
    }

    private func shouldStartForCurrentVisibility(requiresScrollVisibility: Bool) -> Bool {
        !requiresScrollVisibility || isVisibleInScrollView
    }

    private func startIfReady(_ isReady: Bool, download: @escaping () async -> Void) {
        guard isReady else { return }
        task?.cancel()
        task = Task { await download() }
    }
}
