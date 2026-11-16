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

/// Where one download gesture writes: a single file named in the Save As panel, or a folder that
/// takes every attachment under a name no file there already has.
enum MediaDownloadTarget {
    case file(URL)
    case folder(MediaDownloadDestinationAccess)
}

/// The default download folder — Downloads until the user picks another — and whether the user
/// would rather be asked every time.
@MainActor
protocol MediaDownloadDestinationStoring: AnyObject {
    /// The default folder with access started — the one the user picked, or Downloads until they
    /// pick one. `nil` when neither is usable (a picked folder's grant no longer resolves, or there
    /// is no Downloads folder), which means "ask the user again".
    func resolveDestination() -> MediaDownloadDestinationAccess?

    /// Persist a folder the user picked in the panel. A folder that cannot be persisted leaves
    /// nothing stored rather than the folder it was chosen to replace.
    func store(_ url: URL)

    /// The default folder for display and for panels to open in, resolved without opening access
    /// to it. `nil` while a picked folder does not resolve, and the grant itself survives that —
    /// see `resolveDestination()`.
    var defaultFolderURL: URL? { get }

    /// Whether every download asks where to go (Save As for one file, a folder for several) rather
    /// than going straight into the stored folder. Off unless the user turns it on.
    var alwaysAsksWhereToSave: Bool { get set }
}

@MainActor
final class UserDefaultsMediaDownloadDestinationStore: MediaDownloadDestinationStoring {
    private enum Key {
        static let bookmark = "whitenoise.mac.mediaDownloadDestinationBookmark"
        static let alwaysAsks = "whitenoise.mac.mediaDownloadAlwaysAsksWhereToSave"
    }

    private let defaults: UserDefaults
    /// The default before the user picks a folder. The sandbox grants it by entitlement
    /// (`files.downloads.read-write`), so there is no bookmark and nothing to release.
    private let downloadsFolder: URL?

    init(defaults: UserDefaults = .standard, downloadsFolder: URL? = userDownloadsFolder) {
        self.defaults = defaults
        self.downloadsFolder = downloadsFolder
    }

    /// `~/Downloads`. Inside the sandbox the system answers with the container's link to it, so
    /// the link is resolved: the real folder is what Settings shows and what the grant covers.
    nonisolated static var userDownloadsFolder: URL? {
        FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first?
            .resolvingSymlinksInPath()
    }

    func resolveDestination() -> MediaDownloadDestinationAccess? {
        guard defaults.data(forKey: Key.bookmark) != nil else {
            return downloadsFolder.map { MediaDownloadDestinationAccess(url: $0, isSecurityScoped: false) }
        }
        // A grant that does not open means "ask", never "forget": with no bookmark the next
        // download would go to Downloads without asking, yet the folder — an ejected drive, a
        // sleeping share — may simply come back. The grant is dropped only by `store(_:)`, once
        // the user has picked a replacement.
        guard let url = resolvedURL() else { return nil }
        guard url.startAccessingSecurityScopedResource() else {
            mediaDownloadDestinationLogger.error("Stored download folder grant could not be opened")
            return nil
        }
        return MediaDownloadDestinationAccess(url: url, isSecurityScoped: true)
    }

    func store(_ url: URL) {
        if !persistBookmark(for: url) {
            // Whatever is remembered now is a folder the user has just replaced, and the next
            // download would go there without asking — writing somewhere they chose against.
            // Forgetting it sends later downloads to Downloads instead, the default the user
            // started from. This download still proceeds: it has the panel's own grant.
            clear()
        }
    }

    private func clear() {
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

    var defaultFolderURL: URL? {
        guard defaults.data(forKey: Key.bookmark) != nil else { return downloadsFolder }
        return resolvedURL()
    }

    /// Off by default: downloads go to the default folder, chosen in Storage settings or on the
    /// first download. Asking every time is the opt-in.
    var alwaysAsksWhereToSave: Bool {
        get { defaults.bool(forKey: Key.alwaysAsks) }
        set { defaults.set(newValue, forKey: Key.alwaysAsks) }
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
