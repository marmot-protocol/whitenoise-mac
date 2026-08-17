import Foundation

/// Writes decrypted attachment bytes into a destination folder (the Downloads folder in the app).
///
/// Downloading is deliberately non-interactive: one click puts the file in Downloads, the way a
/// browser download does. A save panel per file is fine for the single-file "Save file" row in
/// shared media, but the message action downloads every attachment on a message at once, and a
/// modal per attachment would be a marathon.
///
/// Nothing is ever overwritten — a taken name gets Finder's " 2" suffix — and file names arrive
/// over the wire, so they are sanitized down to a single path component before they are used.
nonisolated enum MediaFileDownloader {
    /// Used when sanitizing leaves nothing usable (a name that was only slashes or dots).
    static let fallbackFileName = "attachment"

    /// APFS/HFS+ cap each path component at 255 bytes; multi-byte names need the headroom.
    ///
    /// Bytes, not characters: the filesystem counts UTF-8, and a name of emoji or CJK spends four
    /// or three bytes a character, so a character-counted cap of 200 would be 800 bytes on disk
    /// and the write would fail with `ENAMETOOLONG`.
    private static let maximumFileNameBytes = 200

    /// The highest " N" suffix tried before falling back to a random one.
    private static let maximumUniquingSuffix = 999

    static func sanitizedFileName(_ fileName: String) -> String {
        // Keep the last path component only: a remote name of `../../evil.sh` must not escape the
        // destination folder.
        var sanitized = fileName.split(separator: "/").last.map(String.init) ?? ""
        // `:` is the legacy HFS path separator and Finder still renders it as `/`.
        sanitized = sanitized.replacing(":", with: "-")
        sanitized = sanitized.trimmingCharacters(in: .whitespacesAndNewlines)
        // A leading dot hides the file, and `.`/`..` are not names at all.
        while sanitized.hasPrefix(".") {
            sanitized.removeFirst()
        }
        sanitized = sanitized.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !sanitized.isEmpty else { return fallbackFileName }
        return truncated(sanitized)
    }

    /// Sanitize `fileName`, then step it past any name `isTaken` reports as already present.
    ///
    /// `isTaken` is a closure rather than a directory so the naming rule stays testable without
    /// touching the filesystem.
    static func uniqueFileName(for fileName: String, isTaken: (String) -> Bool) -> String {
        let sanitized = sanitizedFileName(fileName)
        guard isTaken(sanitized) else { return sanitized }

        let stem = self.stem(of: sanitized)
        let fileExtension = URL(filePath: sanitized).pathExtension

        for suffix in 2...maximumUniquingSuffix {
            let candidate = name(stem: stem, suffix: "\(suffix)", fileExtension: fileExtension)
            if !isTaken(candidate) {
                return candidate
            }
        }
        return name(stem: stem, suffix: UUID().uuidString, fileExtension: fileExtension)
    }

    @discardableResult
    static func write(
        _ data: Data,
        fileName: String,
        into directory: URL,
        fileManager: FileManager = .default
    ) throws -> URL {
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let resolvedName = uniqueFileName(for: fileName) { candidate in
            fileManager.fileExists(atPath: directory.appending(path: candidate).path(percentEncoded: false))
        }
        let destination = directory.appending(path: resolvedName)
        try data.write(to: destination, options: .atomic)
        return destination
    }

    private static func stem(of fileName: String) -> String {
        let stem = URL(filePath: fileName).deletingPathExtension().lastPathComponent
        return stem.isEmpty ? fallbackFileName : stem
    }

    private static func name(stem: String, suffix: String, fileExtension: String) -> String {
        // The separating space, and the dot before a non-empty extension.
        let overhead = byteCount(of: suffix) + byteCount(of: fileExtension) + (fileExtension.isEmpty ? 1 : 2)
        let allowance = max(1, maximumFileNameBytes - overhead)
        // One whole character even when the allowance cannot pay for it: a name of nothing but
        // a suffix reads as a stray file, and the 55 bytes between this cap and the filesystem's
        // 255 exist to absorb exactly this.
        let capped = prefix(of: stem, bytes: allowance)
        let uniqued = "\(capped.isEmpty ? String(stem.prefix(1)) : capped) \(suffix)"
        return fileExtension.isEmpty ? uniqued : "\(uniqued).\(fileExtension)"
    }

    /// Cap the length without eating the extension — the extension is what tells Finder and
    /// Quick Look how to open the file.
    private static func truncated(_ fileName: String) -> String {
        guard byteCount(of: fileName) > maximumFileNameBytes else { return fileName }
        let fileExtension = URL(filePath: fileName).pathExtension
        let extensionBytes = byteCount(of: fileExtension)
        guard !fileExtension.isEmpty, extensionBytes < maximumFileNameBytes / 2 else {
            return prefix(of: fileName, bytes: maximumFileNameBytes)
        }
        let allowance = maximumFileNameBytes - extensionBytes - 1
        return "\(prefix(of: stem(of: fileName), bytes: allowance)).\(fileExtension)"
    }

    private static func byteCount(of text: String) -> Int {
        text.utf8.count
    }

    /// The longest leading run of `text` that fits in `bytes` UTF-8 bytes.
    ///
    /// Characters are kept whole: cutting the UTF-8 view directly would leave a half-written
    /// scalar, and a grapheme cluster is dropped entirely rather than split, so a flag or a
    /// skin-toned emoji cannot come out of this as its own pieces.
    private static func prefix(of text: String, bytes: Int) -> String {
        guard byteCount(of: text) > bytes else { return text }
        var result = ""
        var used = 0
        for character in text {
            let characterBytes = String(character).utf8.count
            guard used + characterBytes <= bytes else { break }
            result.append(character)
            used += characterBytes
        }
        return result
    }
}
