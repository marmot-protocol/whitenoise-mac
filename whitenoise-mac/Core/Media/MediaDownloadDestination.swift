//
//  MediaDownloadDestination.swift
//  whitenoise-mac
//
//  Persistence for the folder the user picked for attachment downloads.
//

import Foundation
import OSLog

private let mediaDownloadDestinationLogger = Logger(
    subsystem: "com.whitenoise.media", category: "MediaDownloadDestination")

/// A download folder with its sandbox access already open.
///
/// The folder is outside the app container, so access is a security-scoped resource that has to be
/// held across the writes and closed afterwards — which is why this is a value that must be
/// released rather than a bare `URL`. A folder the user just picked in the panel needs no
/// release: the panel issues the extension for the app's lifetime.
nonisolated struct MediaDownloadDestinationAccess: Sendable {
    let url: URL
    let isSecurityScoped: Bool

    func release() {
        guard isSecurityScoped else { return }
        url.stopAccessingSecurityScopedResource()
    }
}

/// Remembers the one folder the user granted, so downloading is a single click after the first one.
@MainActor
protocol MediaDownloadDestinationStoring: AnyObject {
    /// The stored folder with access started, or `nil` when nothing is stored or the grant no
    /// longer resolves (folder deleted, volume gone). A `nil` here means "ask the user again".
    func resolveDestination() -> MediaDownloadDestinationAccess?

    /// Persist a folder the user picked in the panel. A folder that cannot be persisted leaves
    /// nothing stored rather than the folder it was chosen to replace.
    func store(_ url: URL)

    func clear()

    /// The stored folder for display, resolved without opening access to it. `nil` while it does
    /// not resolve, and the grant itself survives that — see `resolveDestination()`.
    var storedDestinationURL: URL? { get }
}

@MainActor
final class UserDefaultsMediaDownloadDestinationStore: MediaDownloadDestinationStoring {
    private enum Key {
        static let bookmark = "whitenoise.mac.mediaDownloadDestinationBookmark"
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func resolveDestination() -> MediaDownloadDestinationAccess? {
        guard defaults.data(forKey: Key.bookmark) != nil else { return nil }
        // Dropping the bookmark belongs here and nowhere else: this is the path where a grant
        // that no longer holds would make every later download fail silently in the same way,
        // so it is worth one more trip through the panel. A read for display must never cost
        // the user their folder — a volume that is merely unmounted comes back.
        guard let url = resolvedURL() else {
            clear()
            return nil
        }
        guard url.startAccessingSecurityScopedResource() else {
            mediaDownloadDestinationLogger.error("Stored download folder grant could not be opened")
            clear()
            return nil
        }
        return MediaDownloadDestinationAccess(url: url, isSecurityScoped: true)
    }

    func store(_ url: URL) {
        if !persistBookmark(for: url) {
            // Whatever is remembered now is a folder the user has just replaced, and the next
            // download would go there without asking — writing somewhere they chose against.
            // Forgetting it costs one trip through the panel; keeping it costs the file. This
            // download still proceeds: it has the panel's own grant.
            clear()
        }
    }

    func clear() {
        defaults.removeObject(forKey: Key.bookmark)
    }

    /// Write a security-scoped bookmark for `url`, reporting whether it took. Callers decide what
    /// a failure means — `store(_:)` treats it as losing the grant, a stale rewrite does not.
    @discardableResult
    private func persistBookmark(for url: URL) -> Bool {
        do {
            let data = try url.bookmarkData(
                options: [.withSecurityScope],
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
            defaults.set(data, forKey: Key.bookmark)
            return true
        } catch {
            mediaDownloadDestinationLogger.error(
                "Could not persist the chosen download folder: \(error.localizedDescription, privacy: .public)"
            )
            return false
        }
    }

    var storedDestinationURL: URL? {
        resolvedURL()
    }

    /// Resolving a security-scoped bookmark does not open access — `startAccessingSecurityScopedResource()`
    /// does — so this is safe for the Settings row as well as for the download path.
    ///
    /// A failure here is reported, never acted on: `resolveDestination()` decides whether it is
    /// worth discarding the grant over.
    private func resolvedURL() -> URL? {
        guard let data = defaults.data(forKey: Key.bookmark) else { return nil }
        var isStale = false
        do {
            let url = try URL(
                resolvingBookmarkData: data,
                options: [.withSecurityScope],
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            )
            // A stale bookmark still resolves; it just needs rewriting so the next launch does not
            // have to chase the folder again. Deliberately not `store(_:)`: this is a refresh of
            // the folder already remembered, not a replacement of it, so a failed rewrite leaves
            // the user with the working bookmark they had rather than with nothing.
            if isStale {
                persistBookmark(for: url)
            }
            return url
        } catch {
            mediaDownloadDestinationLogger.error(
                "Stored download folder could not be resolved: \(error.localizedDescription, privacy: .public)"
            )
            return nil
        }
    }
}
