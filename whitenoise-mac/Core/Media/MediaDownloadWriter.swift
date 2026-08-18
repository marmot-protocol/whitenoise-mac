import Foundation

/// The one way an attachment reaches the disk, off the main actor.
actor MediaDownloadWriter {
    static let shared = MediaDownloadWriter()

    /// How many times a name may lose a race to something outside the app before giving up.
    /// Only a genuine collision costs an attempt — a folder that already holds the name is
    /// handled by `uniqueFileName` before any file is created.
    private static let nameCollisionAttempts = 5

    /// Write `data` into `directory` under a name no file there already has.
    ///
    /// Two things have to be true at once, and they pull against each other.
    ///
    /// *Nothing already on disk is replaced.* Being an actor orders the app's own writes, but it
    /// says nothing about the rest of the machine, and the chosen folder is usually one other apps
    /// write to as well: a browser finishing its own `photo.jpg` between a `fileExists` check and
    /// the write is all it takes for that promise to stop being true. So the name is claimed by
    /// the filesystem, never by a check this writer makes and then acts on — losing the race is an
    /// `EEXIST`, and the next name is tried.
    ///
    /// *The attachment's name never appears on a partial file.* The bytes are written to a staging
    /// file first and published in one operation, so an interrupted download leaves a stray hidden
    /// file rather than a `photo.jpg` that opens as a broken image.
    ///
    /// The actor remains because multi-megabyte writes belong off the main actor that is drawing
    /// the transcript.
    @discardableResult
    func write(
        _ data: Data,
        fileName: String,
        into directory: URL,
        fileManager: FileManager = .default
    ) throws -> URL {
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)

        // Names this call created and lost the race for. `uniqueFileName` cannot know about them:
        // the winner may not exist any more by the time it looks.
        var lostRaces: Set<String> = []
        // The bytes land under a name of this call's own first, so the attachment's real name only
        // ever appears on a file that is already complete: a crash halfway through leaves a stray
        // staging file rather than a truncated `photo.jpg` that looks like a finished download.
        // Same directory as the destination, because publishing is a rename — it cannot cross
        // filesystems, and the sandbox grant covers this folder and nowhere else.
        let staging = directory.appending(path: Self.stagingName())
        try Self.createExclusively(data, at: staging, fileManager: fileManager)
        // A successful publish consumes the staging file (rename) or leaves it to be unlinked
        // (link); every failure leaves it behind. This removes only the file this call created.
        defer { try? fileManager.removeItem(at: staging) }

        for _ in 0..<Self.nameCollisionAttempts {
            let resolvedName = MediaFileDownloader.uniqueFileName(for: fileName) { candidate in
                lostRaces.contains(candidate)
                    || fileManager.fileExists(
                        atPath: directory.appending(path: candidate).path(percentEncoded: false))
            }
            let destination = directory.appending(path: resolvedName)

            switch Self.publish(staging, as: destination) {
            case .published:
                return destination
            case .nameTaken:
                lostRaces.insert(resolvedName)
            case .failed(let code):
                throw Self.failure(code, at: destination)
            }
        }
        throw Self.failure(EEXIST, at: directory.appending(path: fileName))
    }

    /// Hidden and unguessable: it shares the download folder with the user's own files, and it is
    /// only theirs to see if something goes wrong badly enough to leave it there.
    private static func stagingName() -> String {
        ".whitenoise-\(UUID().uuidString).partial"
    }

    private enum Publication {
        case published
        /// Something else holds the name. Not an error — the next one is tried.
        case nameTaken
        case failed(Int32)
    }

    /// Move `staging` onto `destination` without ever replacing what is already there.
    ///
    /// `RENAME_EXCL` is the whole point: a plain `rename` is atomic but silently clobbers, which is
    /// the failure this writer exists to prevent. Volumes that do not implement the flag — network
    /// shares, mostly, and the download folder is one the user chose — fall back to `link`, which
    /// predates it, is equally atomic, and equally refuses to replace. There is no path here that
    /// overwrites.
    private static func publish(_ staging: URL, as destination: URL) -> Publication {
        staging.withUnsafeFileSystemRepresentation { from in
            destination.withUnsafeFileSystemRepresentation { to in
                guard let from, let to else { return .failed(EINVAL) }

                if renameatx_np(AT_FDCWD, from, AT_FDCWD, to, UInt32(RENAME_EXCL)) == 0 {
                    return .published
                }
                let renameFailure = errno
                if renameFailure == EEXIST {
                    return .nameTaken
                }
                guard renameFailure == ENOTSUP || renameFailure == ENOSYS || renameFailure == EINVAL
                else {
                    return .failed(renameFailure)
                }

                if link(from, to) == 0 {
                    return .published
                }
                let linkFailure = errno
                return linkFailure == EEXIST ? .nameTaken : .failed(linkFailure)
            }
        }
    }

    /// Create `url` and fill it, failing rather than touching a file that is already there.
    private static func createExclusively(_ data: Data, at url: URL, fileManager: FileManager) throws {
        let descriptor = url.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else { return -1 }
            return open(path, O_WRONLY | O_CREAT | O_EXCL, 0o644)
        }
        guard descriptor >= 0 else { throw failure(errno, at: url) }

        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
        do {
            try handle.write(contentsOf: data)
            try handle.close()
        } catch {
            try? handle.close()
            try? fileManager.removeItem(at: url)
            throw error
        }
    }

    private static func failure(_ code: Int32, at url: URL) -> Error {
        NSError(
            domain: NSPOSIXErrorDomain,
            code: Int(code),
            userInfo: [
                NSFilePathErrorKey: url.path(percentEncoded: false),
                NSLocalizedDescriptionKey: String(cString: strerror(code)),
            ]
        )
    }
}
