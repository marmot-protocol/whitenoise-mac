import CryptoKit
import Foundation

/// Manages on-disk scratch files used to hand decrypted attachment plaintext to
/// macOS playback/open APIs (`AVPlayer`, `NSWorkspace.open`) that require a file URL.
///
/// For an E2EE messenger, decrypted media must not linger on disk after it has been
/// viewed. The previous implementation wrote plaintext into the shared OS temp
/// directory (`FileManager.temporaryDirectory/WhiteNoiseMediaPlayback`) and never
/// removed it, leaving decrypted media in a predictable, world-adjacent path
/// indefinitely. This store fixes that by:
///
/// - Keeping scratch files inside the app's Application Support container (the same
///   durable, sandbox-friendly location as Marmot storage) rather than the shared
///   temp dir, and excluding that scratch directory from backups.
/// - Applying `.completeFileProtection` so the bytes stay encrypted at rest when the
///   platform supports it.
/// - Giving each consumer its own scratch file so one cleanup timer/teardown cannot
///   delete a file still in use by a later open/playback of the same attachment.
/// - Exposing explicit `remove(at:)` and `purge()` entry points so callers can delete
///   a file as soon as the consuming action finishes and so launch/"Delete All Local
///   Data" can wipe the whole directory.
///
/// All file-system inputs are injectable to keep the logic unit-testable without a real
/// `AVPlayer`/`NSWorkspace`.
nonisolated enum MediaPlaybackTempStore {
    private static let directoryName = "WhiteNoiseMediaPlayback"

    /// Resolves the playback scratch directory inside the app container.
    ///
    /// Mirrors `MarmotStorageRoot`'s Application Support location but lives in a
    /// sibling playback scratch directory so purges never touch Marmot storage.
    static func directoryURL(
        fileManager: FileManager = .default,
        applicationSupportDirectory: (FileManager) throws -> URL = { fileManager in
            try fileManager.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            )
        }
    ) throws -> URL {
        let base = try applicationSupportDirectory(fileManager)
        return directoryURL(baseURL: base)
    }

    static func directoryURL(baseURL: URL) -> URL {
        baseURL
            .appendingPathComponent("White Noise", isDirectory: true)
            .appendingPathComponent(directoryName, isDirectory: true)
    }

    /// The legacy pre-fix location that used the shared OS temp directory. Purges keep
    /// deleting it so already-leaked plaintext from older app versions does not survive
    /// a launch or "Delete All Local Data".
    static func legacySharedTemporaryDirectory(fileManager: FileManager = .default) -> URL {
        fileManager.temporaryDirectory.appendingPathComponent(directoryName, isDirectory: true)
    }

    /// Writes `data` to a per-consumer scratch file for `id`/`fileName` and returns its URL.
    ///
    /// The attachment id contributes a deterministic, collision-resistant stem while
    /// `uniqueID` makes each handoff/playback own an independent file. That prevents a
    /// delayed cleanup from an earlier open from deleting the file a later consumer is
    /// still reading.
    static func materialize(
        data: Data,
        id: String,
        fileName: String,
        fallbackExtension: String,
        directory: URL,
        uniqueID: UUID = UUID(),
        fileManager: FileManager = .default
    ) throws -> URL {
        try prepareDirectory(directory, fileManager: fileManager)
        let sanitized = sanitizedFileName(fileName, fallbackExtension: fallbackExtension)
        let url = directory.appendingPathComponent("\(stableStem(for: id))-\(uniqueID.uuidString)-\(sanitized)")
        try data.write(to: url, options: [.atomic, .completeFileProtection])
        return url
    }

    /// Removes a single scratch file. Missing files are treated as success.
    static func remove(at url: URL, fileManager: FileManager = .default) {
        guard fileManager.fileExists(atPath: url.path) else { return }
        try? fileManager.removeItem(at: url)
    }

    /// Removes the entire playback scratch directory. Used on launch and when the user
    /// deletes all local data. Missing directories are treated as success.
    static func purge(
        fileManager: FileManager = .default,
        applicationSupportDirectory: (FileManager) throws -> URL = { fileManager in
            try fileManager.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            )
        }
    ) {
        guard
            let directory = try? directoryURL(
                fileManager: fileManager,
                applicationSupportDirectory: applicationSupportDirectory
            )
        else {
            purge(directory: legacySharedTemporaryDirectory(fileManager: fileManager), fileManager: fileManager)
            return
        }
        purge(
            directory: directory,
            legacyDirectory: legacySharedTemporaryDirectory(fileManager: fileManager),
            fileManager: fileManager
        )
    }

    static func purge(directory: URL, legacyDirectory: URL? = nil, fileManager: FileManager = .default) {
        purgeSingleDirectory(directory, fileManager: fileManager)
        if let legacyDirectory {
            purgeSingleDirectory(legacyDirectory, fileManager: fileManager)
        }
    }

    private static func prepareDirectory(_ directory: URL, fileManager: FileManager) throws {
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        var directoryURL = directory
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try directoryURL.setResourceValues(values)
    }

    private static func purgeSingleDirectory(_ directory: URL, fileManager: FileManager) {
        guard fileManager.fileExists(atPath: directory.path) else { return }
        try? fileManager.removeItem(at: directory)
    }

    static func stableStem(for id: String) -> String {
        let sanitizedPrefix = id.unicodeScalars.map { scalar in
            CharacterSet.alphanumerics.contains(scalar) ? String(scalar) : "-"
        }
        .joined()
        .prefix(32)

        let digest = SHA256.hash(data: Data(id.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
            .prefix(16)

        let prefix = sanitizedPrefix.isEmpty ? "attachment" : String(sanitizedPrefix)
        return "\(prefix)-\(digest)"
    }

    static func sanitizedFileName(_ fileName: String, fallbackExtension: String) -> String {
        let trimmed = fileName.trimmingCharacters(in: .whitespacesAndNewlines)
        let fallback = "attachment.\(fallbackExtension)"
        let rawName = trimmed.isEmpty ? fallback : trimmed
        let illegal = CharacterSet(charactersIn: "/:\\")
        let components = rawName.components(separatedBy: illegal).filter { !$0.isEmpty }
        let sanitized = components.joined(separator: "-").trimmingCharacters(in: .whitespacesAndNewlines)
        return sanitized.isEmpty ? fallback : sanitized
    }
}
