//
//  TestStorageRoot.swift
//  whitenoise-macTests
//
//  Where a test's on-disk state goes, and why it is never a fixed shared path.
//

import CryptoKit
import Foundation
import Testing

/// The directory a test double writes into.
///
/// Tests write real files. `WorkspaceState` builds a `HiddenMessageFileStore`,
/// `PinnedChatFileStore`, `ContactNicknameFileStore` and `DirectPeerMemoryFileStore`
/// under `runtime.storageRootPath` for every store the test did not inject, and
/// `MessageMediaDiskCache` keeps encrypted payloads under a root of its own. While
/// that path was one fixed constant (`/tmp/whitenoise-mac-tests`), a test that
/// omitted store injection read whatever an earlier test — or an earlier *run* —
/// had left there, and could pass for the wrong reason.
///
/// Remembering to isolate is not a thing anyone should have to remember, so
/// `.isolated` is the default everywhere this type is accepted and naming a shared
/// directory is the case you have to write out.
nonisolated enum TestStorageRoot: Sendable {
    /// A directory belonging to the running test alone, inside a directory belonging
    /// to this process alone.
    ///
    /// Two doubles built during the same test share it — a relaunch test needs its
    /// second runtime to read what the first one wrote — while nothing built during
    /// another test, or another run of the suite, can reach it.
    case isolated

    /// An explicit path, for the rare test that needs to name the directory itself
    /// (asserting on the path, or handing the same directory to something that does
    /// not take a `TestStorageRoot`).
    case explicit(String)

    /// The absolute directory path. Nothing is created here: the file stores and the
    /// media cache each create their own directories on first write.
    ///
    /// `function` and `fileID` are defaulted *at this call site* on purpose. Magic
    /// literals only resolve to the caller when they are direct default arguments, so
    /// a `TestStorageRoot.isolated` factory could not capture them on its own — the
    /// initializer that takes the root has to pass them down.
    func resolvedPath(function: StaticString = #function, fileID: StaticString = #fileID) -> String {
        switch self {
        case .explicit(let path):
            return path
        case .isolated:
            return Self.processRoot
                .appending(path: Self.testToken(function: function, fileID: fileID))
                .path(percentEncoded: false)
        }
    }

    // MARK: - Per-process root

    /// The parent every isolated path hangs off, unique to this process.
    ///
    /// Per *process* rather than per *test* is what retires the "passes the first
    /// time, fails on every later local run" failure: a record written by a previous
    /// `xcodebuild test` is in a directory this run cannot name.
    static let processRoot: URL = {
        let container = FileManager.default.temporaryDirectory
            .appending(path: "whitenoise-mac-tests", directoryHint: .isDirectory)
        let root = container.appending(
            path: "run-\(ProcessInfo.processInfo.processIdentifier)-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        sweepStaleRuns(in: container, keeping: root)
        return root
    }()

    /// Drops roots left by runs that are long over, so an unattended machine does not
    /// accumulate one directory tree per `just test`. The cutoff is deliberately far
    /// past any plausible run length — concurrent sessions on this machine are normal,
    /// and sweeping a live run's root out from under it would be worse than the litter.
    private static func sweepStaleRuns(in container: URL, keeping current: URL) {
        let fileManager = FileManager.default
        let cutoff = Date(timeIntervalSinceNow: -24 * 60 * 60)
        let runs =
            (try? fileManager.contentsOfDirectory(
                at: container,
                includingPropertiesForKeys: [.contentModificationDateKey],
                options: [.skipsHiddenFiles]
            )) ?? []
        for run in runs where run.lastPathComponent != current.lastPathComponent {
            let modified = try? run.resourceValues(forKeys: [.contentModificationDateKey])
                .contentModificationDate
            guard let modified, modified < cutoff else { continue }
            try? fileManager.removeItem(at: run)
        }
    }

    // MARK: - Per-test token

    /// A filesystem-safe name for the running test.
    ///
    /// `Test.current` is the test that is running however deep the call is, so a
    /// double constructed inside a shared helper still lands in the calling test's
    /// directory. `#function` cannot do that — it would name the helper, and every
    /// test that called the helper would share one directory again. The literals are
    /// the fallback for construction outside a test's task, where `Test.current` is nil.
    static func testToken(function: StaticString, fileID: StaticString) -> String {
        if let id = Test.current?.id {
            return sanitized(String(describing: id))
        }
        return sanitized("\(fileID).\(function)")
    }

    /// Path components have to survive being a directory name, and a Swift Testing id
    /// carries the whole suite path, so long names are truncated onto a digest of the
    /// full one rather than colliding at the prefix.
    private static func sanitized(_ token: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_."))
        let scrubbed = String(
            String.UnicodeScalarView(
                token.unicodeScalars.map { allowed.contains($0) ? $0 : "-" }
            )
        )
        guard scrubbed.count > 120 else { return scrubbed.isEmpty ? "unnamed-test" : scrubbed }
        let digest = SHA256.hash(data: Data(token.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
            .prefix(16)
        return "\(scrubbed.prefix(100))-\(digest)"
    }
}
