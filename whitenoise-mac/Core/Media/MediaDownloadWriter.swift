import Foundation

/// Serializes every attachment write in the app, off the main actor.
///
/// `MediaFileDownloader.write(_:fileName:into:)` picks a free name and then creates the file, so
/// two downloads running at once — the per-message lock allows one per message — could both claim
/// `photo.jpg` and have the second overwrite the first. Funnelling them through a single actor
/// keeps the check and the create indivisible without putting a lock around file I/O, and keeps
/// multi-megabyte writes away from the main actor that is drawing the transcript.
actor MediaDownloadWriter {
    static let shared = MediaDownloadWriter()

    @discardableResult
    func write(_ data: Data, fileName: String, into directory: URL) throws -> URL {
        try MediaFileDownloader.write(data, fileName: fileName, into: directory)
    }
}
