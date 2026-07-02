import CryptoKit
import Foundation

/// Manages on-disk scratch files used to hand attachment plaintext to macOS APIs
/// (`AVPlayer`, `NSWorkspace.open`, `AVAudioRecorder`) that require a file URL.
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
/// All file-system inputs are injectable to keep the logic unit-testable without real
/// playback/recording APIs.
nonisolated enum MediaPlaybackTempStore {
    private static let directoryName = "WhiteNoiseMediaPlayback"
    private static let voiceRecordingsDirectoryName = "WhiteNoiseVoiceRecordings"

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
        try MediaProtectedTempDirectory.directoryURL(
            directoryName: directoryName,
            fileManager: fileManager,
            applicationSupportDirectory: applicationSupportDirectory
        )
    }

    static func directoryURL(baseURL: URL) -> URL {
        MediaProtectedTempDirectory.directoryURL(baseURL: baseURL, directoryName: directoryName)
    }

    /// Resolves the outgoing voice-recording scratch directory inside the app container.
    static func voiceRecordingsDirectoryURL(
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
        try MediaProtectedTempDirectory.directoryURL(
            directoryName: voiceRecordingsDirectoryName,
            fileManager: fileManager,
            applicationSupportDirectory: applicationSupportDirectory
        )
    }

    static func voiceRecordingsDirectoryURL(baseURL: URL) -> URL {
        MediaProtectedTempDirectory.directoryURL(baseURL: baseURL, directoryName: voiceRecordingsDirectoryName)
    }

    /// The legacy pre-fix location that used the shared OS temp directory. Purges keep
    /// deleting it so already-leaked plaintext from older app versions does not survive
    /// a launch or "Delete All Local Data".
    static func legacySharedTemporaryDirectory(fileManager: FileManager = .default) -> URL {
        MediaProtectedTempDirectory.legacySharedTemporaryDirectory(
            directoryName: directoryName,
            fileManager: fileManager
        )
    }

    /// The legacy outgoing voice-recording location that used the shared OS temp
    /// directory. Purges keep deleting it so already-orphaned microphone plaintext
    /// from older app versions does not survive launch or "Delete All Local Data".
    static func legacySharedVoiceRecordingsDirectory(fileManager: FileManager = .default) -> URL {
        MediaProtectedTempDirectory.legacySharedTemporaryDirectory(
            directoryName: voiceRecordingsDirectoryName,
            fileManager: fileManager
        )
    }

    /// Reserves a protected file for `AVAudioRecorder` to write an outgoing voice note.
    static func prepareVoiceRecordingFile(
        in directory: URL,
        uniqueID: UUID = UUID(),
        fileManager: FileManager = .default
    ) throws -> URL {
        try MediaProtectedTempDirectory.prepareDirectory(directory, fileManager: fileManager)
        let url = directory.appendingPathComponent("voice-\(uniqueID.uuidString).m4a")
        try MediaProtectedTempDirectory.writeProtectedData(Data(), to: url, fileManager: fileManager)
        return url
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
        try MediaProtectedTempDirectory.prepareDirectory(directory, fileManager: fileManager)
        let sanitized = sanitizedFileName(fileName, fallbackExtension: fallbackExtension)
        let url = directory.appendingPathComponent("\(stableStem(for: id))-\(uniqueID.uuidString)-\(sanitized)")
        try MediaProtectedTempDirectory.writeProtectedData(data, to: url, fileManager: fileManager)
        return url
    }

    /// Removes a single scratch file. Missing files are treated as success.
    static func remove(at url: URL, fileManager: FileManager = .default) {
        MediaProtectedTempDirectory.remove(at: url, fileManager: fileManager)
    }

    /// Removes playback and voice-recording scratch directories. Used on launch and
    /// when the user deletes all local data. Missing directories are treated as success.
    static func purge(
        fileManager: FileManager = .default,
        applicationSupportDirectory: (FileManager) throws -> URL = { fileManager in
            try fileManager.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            )
        },
        legacyPlaybackDirectory: (FileManager) -> URL = { fileManager in
            MediaPlaybackTempStore.legacySharedTemporaryDirectory(fileManager: fileManager)
        },
        legacyVoiceRecordingsDirectory: (FileManager) -> URL = { fileManager in
            MediaPlaybackTempStore.legacySharedVoiceRecordingsDirectory(fileManager: fileManager)
        }
    ) {
        let legacyDirectories = [
            legacyPlaybackDirectory(fileManager),
            legacyVoiceRecordingsDirectory(fileManager),
        ]
        guard let base = try? applicationSupportDirectory(fileManager) else {
            MediaProtectedTempDirectory.purge(directories: legacyDirectories, fileManager: fileManager)
            return
        }
        MediaProtectedTempDirectory.purge(
            directories: [
                directoryURL(baseURL: base),
                voiceRecordingsDirectoryURL(baseURL: base),
            ] + legacyDirectories,
            fileManager: fileManager
        )
    }

    static func purge(directory: URL, legacyDirectory: URL? = nil, fileManager: FileManager = .default) {
        MediaProtectedTempDirectory.purge(
            directory: directory,
            legacyDirectory: legacyDirectory,
            fileManager: fileManager
        )
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

/// Scratch store for outgoing attachment metadata extraction.
///
/// Image/video/audio metadata APIs need a file URL even though the attachment is still
/// only being prepared for send. These plaintext work files must follow the same privacy
/// rules as playback scratch: app-container location, backup exclusion, complete file
/// protection, best-effort removal after use, and whole-directory purges on launch / data
/// deletion. The legacy shared-temp directory is still purged so files leaked by older
/// builds do not survive an upgrade.
nonisolated enum OutgoingMediaMetadataTempStore {
    private static let directoryName = "WhiteNoiseMediaWork"

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
        try MediaProtectedTempDirectory.directoryURL(
            directoryName: directoryName,
            fileManager: fileManager,
            applicationSupportDirectory: applicationSupportDirectory
        )
    }

    static func directoryURL(baseURL: URL) -> URL {
        MediaProtectedTempDirectory.directoryURL(baseURL: baseURL, directoryName: directoryName)
    }

    static func legacySharedTemporaryDirectory(fileManager: FileManager = .default) -> URL {
        MediaProtectedTempDirectory.legacySharedTemporaryDirectory(
            directoryName: directoryName,
            fileManager: fileManager
        )
    }

    static func materialize(
        data: Data,
        fileExtension: String,
        directory: URL,
        uniqueID: UUID = UUID(),
        fileManager: FileManager = .default
    ) throws -> URL {
        try MediaProtectedTempDirectory.prepareDirectory(directory, fileManager: fileManager)
        let url =
            directory
            .appendingPathComponent("metadata-\(uniqueID.uuidString)")
            .appendingPathExtension(sanitizedFileExtension(fileExtension))
        try MediaProtectedTempDirectory.writeProtectedData(data, to: url, fileManager: fileManager)
        return url
    }

    static func remove(at url: URL, fileManager: FileManager = .default) {
        MediaProtectedTempDirectory.remove(at: url, fileManager: fileManager)
    }

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
        MediaProtectedTempDirectory.purge(
            directory: directory,
            legacyDirectory: legacyDirectory,
            fileManager: fileManager
        )
    }

    static func sanitizedFileExtension(_ fileExtension: String) -> String {
        let allowed = CharacterSet.alphanumerics
        let sanitized =
            fileExtension
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .unicodeScalars
            .map { scalar in allowed.contains(scalar) ? String(scalar) : "-" }
            .joined()
            .trimmingCharacters(in: CharacterSet(charactersIn: "-."))
            .lowercased()
        return sanitized.isEmpty ? "bin" : sanitized
    }
}

private enum MediaProtectedTempDirectory {
    static func directoryURL(
        directoryName: String,
        fileManager: FileManager,
        applicationSupportDirectory: (FileManager) throws -> URL
    ) throws -> URL {
        let base = try applicationSupportDirectory(fileManager)
        return directoryURL(baseURL: base, directoryName: directoryName)
    }

    static func directoryURL(baseURL: URL, directoryName: String) -> URL {
        baseURL
            .appendingPathComponent("White Noise", isDirectory: true)
            .appendingPathComponent(directoryName, isDirectory: true)
    }

    static func legacySharedTemporaryDirectory(directoryName: String, fileManager: FileManager) -> URL {
        fileManager.temporaryDirectory.appendingPathComponent(directoryName, isDirectory: true)
    }

    static func prepareDirectory(_ directory: URL, fileManager: FileManager) throws {
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        var directoryURL = directory
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try directoryURL.setResourceValues(values)
    }

    static func writeProtectedData(_ data: Data, to url: URL, fileManager: FileManager) throws {
        try data.write(to: url, options: [.atomic, .completeFileProtection])
        // Some macOS volumes downgrade or reject explicit protection changes; keep the
        // scratch write usable, but request the strongest class when the volume accepts it.
        try? fileManager.setAttributes(
            [.protectionKey: FileProtectionType.complete],
            ofItemAtPath: url.path
        )
    }

    static func remove(at url: URL, fileManager: FileManager) {
        guard fileManager.fileExists(atPath: url.path) else { return }
        try? fileManager.removeItem(at: url)
    }

    static func purge(directory: URL, legacyDirectory: URL? = nil, fileManager: FileManager) {
        purge(directories: [directory] + [legacyDirectory].compactMap { $0 }, fileManager: fileManager)
    }

    static func purge(directories: [URL], fileManager: FileManager) {
        for directory in directories {
            purgeSingleDirectory(directory, fileManager: fileManager)
        }
    }

    private static func purgeSingleDirectory(_ directory: URL, fileManager: FileManager) {
        guard fileManager.fileExists(atPath: directory.path) else { return }
        try? fileManager.removeItem(at: directory)
    }
}
