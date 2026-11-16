//
//  MediaFileUpload.swift
//  whitenoise-mac
//
//  Outgoing attachments may reach MDK's 512 MiB blob limit. Large ones are read through a mapped
//  clone instead of into resident memory, checked against MDK's per-send batch bound, and handed to
//  MDK's file-backed upload so their bytes never cross the FFI as one array.
//

import Foundation
import MarmotKit

nonisolated enum MediaFileUploadFailure: LocalizedError, Equatable, Sendable {
    /// A source file for the file-backed upload could not be written.
    case sourceUnavailable

    var errorDescription: String? {
        switch self {
        case .sourceUnavailable:
            L10n.string("That attachment could not be prepared.")
        }
    }
}

nonisolated enum MediaFileUploadLimit {
    static let aeadTagBytes: UInt64 = 16

    /// Ciphertext bytes MDK counts against its batch bound: each attachment's plaintext plus its
    /// AEAD tag. Nil when the sum overflows.
    static func ciphertextBytes(plaintextByteCounts: [Int]) -> UInt64? {
        var total: UInt64 = 0
        for count in plaintextByteCounts {
            let (withBody, bodyOverflow) = total.addingReportingOverflow(UInt64(max(0, count)))
            let (withTag, tagOverflow) = withBody.addingReportingOverflow(aeadTagBytes)
            if bodyOverflow || tagOverflow { return nil }
            total = withTag
        }
        return total
    }

    /// Whether an attachment of `byteCount` plaintext bytes still fits in one send beside
    /// attachments of `counts`. Two attachments under the per-file cap can add up past MDK's batch
    /// bound, which a send would then reject only after the user pressed it.
    static func fits(
        _ byteCount: Int,
        alongside counts: [Int],
        limit: UInt64 = maxFileMediaCiphertextBytes()
    ) -> Bool {
        guard let total = ciphertextBytes(plaintextByteCounts: counts + [byteCount]) else { return false }
        return total <= limit
    }
}

/// Which MDK upload carries an outgoing message's attachments.
nonisolated enum MediaUploadRoute: Equatable, Sendable {
    /// `uploadMediaWithClientToken`: plaintext crosses the FFI as a byte array.
    case bytes
    /// `uploadMediaFilesWithClientToken`: MDK streams each attachment from a source file, with no
    /// fixed worker-response timeout.
    case files

    /// Everything the old 50 MB attachment cap admitted keeps the byte route it always had; only a
    /// batch carrying something larger streams from files.
    static func route(byteCounts: [Int]) -> MediaUploadRoute {
        byteCounts.contains { $0 > OutgoingMediaDraftProcessor.maxDraftAttachmentBytes } ? .files : .bytes
    }
}

/// Reads a picked file without making it resident memory. The file is cloned into a private
/// directory, mapped, and unlinked at once, so the mapping is the clone's only reference: its pages
/// stay file-backed and reclaimable, and the source (which the user may edit, move or eject) is not
/// what is mapped.
nonisolated enum PickedMediaFile {
    static let directoryName = "WhiteNoisePickedMedia"
    /// Clones are unlinked before `mappedData` returns, so anything older is a crash's leftover.
    static let staleAge: TimeInterval = 60 * 60

    static func defaultDirectory() throws -> URL {
        try MediaUploadScratch.directory(named: directoryName)
    }

    static func mappedData(from url: URL, in requestedDirectory: URL? = nil, now: Date = Date()) throws -> Data {
        let clone = try makeClone(of: url, in: requestedDirectory, now: now)
        defer { try? FileManager.default.removeItem(at: clone) }
        return try Data(contentsOf: clone, options: .alwaysMapped)
    }

    /// Clones `url` into the scratch directory as a regular file dated `now`. The caller owns the
    /// clone and removes it.
    static func makeClone(of url: URL, in requestedDirectory: URL? = nil, now: Date) throws -> URL {
        let manager = FileManager.default
        let directory = try requestedDirectory ?? defaultDirectory()
        try MediaProtectedTempDirectory.prepareDirectory(directory, fileManager: manager)
        MediaUploadSourceFiles.removeStale(in: directory, olderThan: staleAge, now: now)
        let clone = directory.appendingPathComponent(UUID().uuidString, isDirectory: false)
        try manager.copyItem(at: url, to: clone)
        do {
            guard MediaUploadSourceFiles.isRegularFile(at: clone) else { throw CocoaError(.fileReadUnknown) }
            // A clone keeps its source's modification date, so a clone of a file last edited over
            // `staleAge` ago would look like a crash's leftover to a concurrent pick's sweep.
            try manager.setAttributes([.modificationDate: now], ofItemAtPath: clone.path)
        } catch {
            try? manager.removeItem(at: clone)
            throw error
        }
        return clone
    }
}

/// Plaintext copies of outgoing attachments as regular files MDK can snapshot. They live only for
/// one upload call.
nonisolated struct MediaUploadSourceFiles: Sendable {
    static let directoryName = "WhiteNoiseMediaUploads"
    /// Leftovers from an interrupted process; live uploads are much younger.
    static let staleAge: TimeInterval = 24 * 60 * 60

    let urls: [URL]
    let requests: [MediaFileUploadAttachmentRequestFfi]

    static func defaultDirectory() throws -> URL {
        try MediaUploadScratch.directory(named: directoryName)
    }

    /// Writes each attachment off the main actor, removing everything it wrote if any write fails.
    static func stage(
        _ attachments: [PendingMediaAttachment],
        in directory: URL? = nil,
        now: Date = Date()
    ) async throws -> MediaUploadSourceFiles {
        try await Task.detached(priority: .userInitiated) {
            try stageSynchronously(attachments, in: directory, now: now)
        }.value
    }

    /// `fileName` is a seam for tests; production names every source with a fresh UUID.
    static func stageSynchronously(
        _ attachments: [PendingMediaAttachment],
        in requestedDirectory: URL?,
        now: Date,
        fileName: () -> String = { UUID().uuidString }
    ) throws -> MediaUploadSourceFiles {
        let manager = FileManager.default
        let directory: URL
        do {
            directory = try requestedDirectory ?? defaultDirectory()
            try MediaProtectedTempDirectory.prepareDirectory(directory, fileManager: manager)
        } catch {
            throw MediaFileUploadFailure.sourceUnavailable
        }
        removeStale(in: directory, olderThan: staleAge, now: now)

        var urls: [URL] = []
        var requests: [MediaFileUploadAttachmentRequestFfi] = []
        do {
            for attachment in attachments {
                let url = directory.appendingPathComponent(fileName(), isDirectory: false)
                try write(attachment.data, to: url)
                urls.append(url)
                guard isRegularFile(at: url) else { throw MediaFileUploadFailure.sourceUnavailable }
                requests.append(
                    MediaFileUploadAttachmentRequestFfi(
                        sourcePath: url.path,
                        expectedSize: UInt64(attachment.data.count),
                        fileName: attachment.fileName,
                        mediaType: attachment.mediaType,
                        dim: attachment.dim,
                        thumbhash: attachment.thumbhash
                    ))
            }
        } catch {
            remove(urls)
            throw MediaFileUploadFailure.sourceUnavailable
        }
        return MediaUploadSourceFiles(urls: urls, requests: requests)
    }

    /// Without overwriting: an existing entry, symlink included, fails the write and is left alone,
    /// since it is not ours. Any other failure may have left part of the plaintext at `url`, which
    /// is removed before the error propagates.
    private static func write(_ data: Data, to url: URL) throws {
        do {
            try data.write(to: url, options: [.withoutOverwriting, .completeFileProtection])
        } catch let error as CocoaError where error.code == .fileWriteFileExists {
            throw error
        } catch {
            try? FileManager.default.removeItem(at: url)
            throw error
        }
    }

    /// Call only after the MDK call that read these files has returned.
    func remove() async {
        let urls = urls
        await Task.detached(priority: .utility) { Self.remove(urls) }.value
    }

    static func remove(_ urls: [URL]) {
        for url in urls {
            try? FileManager.default.removeItem(at: url)
        }
    }

    /// True only for a regular file; a symlink is reported as itself, not its target.
    static func isRegularFile(at url: URL) -> Bool {
        guard let type = try? FileManager.default.attributesOfItem(atPath: url.path)[.type] as? FileAttributeType
        else { return false }
        return type == .typeRegular
    }

    static func removeStale(in directory: URL, olderThan age: TimeInterval, now: Date) {
        let manager = FileManager.default
        guard
            let children = try? manager.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.contentModificationDateKey]
            )
        else { return }
        for child in children {
            let modified = (try? child.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate
            guard let modified, now.timeIntervalSince(modified) > age else { continue }
            try? manager.removeItem(at: child)
        }
    }
}

nonisolated enum MediaFileUploadRunner {
    /// Stages `attachments` as source files, runs `upload` over them, and removes the files once MDK
    /// has returned. Cancelling the awaiting task cancels `control`, the only way to stop MDK's copy.
    static func run<Value: Sendable>(
        _ attachments: [PendingMediaAttachment],
        control: MediaFileTransferControlFfi,
        directory: URL? = nil,
        upload: @escaping @Sendable ([MediaFileUploadAttachmentRequestFfi]) async throws -> Value
    ) async throws -> Value {
        try await withTaskCancellationHandler {
            let sources = try await MediaUploadSourceFiles.stage(attachments, in: directory)
            do {
                let value = try await upload(sources.requests)
                await sources.remove()
                return value
            } catch {
                await sources.remove()
                throw error
            }
        } onCancel: {
            control.cancel()
        }
    }
}

/// The plaintext scratch the outgoing-attachment paths write: picked-file clones and upload
/// sources. Both are removed as soon as their call returns, so anything here at launch or at
/// Delete All Local Data is a crash's leftover.
nonisolated enum MediaUploadScratch {
    #if DEBUG
        /// XCTest is only linked into the host process when the host is running tests, the same
        /// signal `MessageMediaDiskCache.shared` uses.
        static let isRunningUnderTest =
            NSClassFromString("XCTestCase") != nil
            || ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil

        /// Under a test run the scratch lives in a temporary root no other process can name, never in
        /// the host's Application Support directory.
        static let testProcessRoot = FileManager.default.temporaryDirectory
            .appending(path: "whitenoise-mac-tests", directoryHint: .isDirectory)
            .appending(
                path: "media-upload-scratch-\(ProcessInfo.processInfo.processIdentifier)-\(UUID().uuidString)",
                directoryHint: .isDirectory
            )
    #else
        static let isRunningUnderTest = false
    #endif

    static func directory(named directoryName: String) throws -> URL {
        #if DEBUG
            if isRunningUnderTest {
                return testProcessRoot.appending(path: directoryName, directoryHint: .isDirectory)
            }
        #endif
        return try MediaProtectedTempDirectory.directoryURL(
            directoryName: directoryName,
            fileManager: .default,
            applicationSupportDirectory: { fileManager in
                try fileManager.url(
                    for: .applicationSupportDirectory,
                    in: .userDomainMask,
                    appropriateFor: nil,
                    create: true
                )
            }
        )
    }

    /// Does nothing under a test run: every test that bootstraps a workspace calls this, while
    /// suites running in parallel are staging into the same directories.
    static func purge(fileManager: FileManager = .default) {
        guard !isRunningUnderTest else { return }
        let directories = [try? PickedMediaFile.defaultDirectory(), try? MediaUploadSourceFiles.defaultDirectory()]
        purge(directories: directories.compactMap { $0 }, fileManager: fileManager)
    }

    static func purge(directories: [URL], fileManager: FileManager = .default) {
        MediaProtectedTempDirectory.purge(directories: directories, fileManager: fileManager)
    }
}
