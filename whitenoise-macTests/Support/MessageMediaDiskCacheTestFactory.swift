//
//  MessageMediaDiskCacheTestFactory.swift
//  whitenoise-macTests
//
//  Building a media cache that belongs to one test and nothing else.
//

import CryptoKit
import Foundation

@testable import whitenoise_mac

nonisolated extension MessageMediaDiskCache {
    /// A cache in a directory belonging to the running test alone, keyed by a fixed
    /// in-memory key rather than the user's Keychain.
    ///
    /// Prefer this over constructing `MessageMediaDiskCache` directly: the directory
    /// resolver is the parameter it is easiest to leave at its default, and its default
    /// is the user's real Application Support directory.
    ///
    /// `function` and `fileID` are the fallback the isolated root uses when it is built
    /// outside a running test's task — do not pass them.
    static func makeIsolated(
        keyData: Data = Data(repeating: 0x42, count: 32),
        evictionPolicy: EvictionPolicy = .standard,
        timestampProvider: @escaping TimestampProvider = { Date().timeIntervalSince1970 },
        sessionStartedAtUnixSeconds: TimeInterval = Date().timeIntervalSince1970,
        keyDeleter: @escaping KeyDeleter = {},
        function: StaticString = #function,
        fileID: StaticString = #fileID
    ) -> MessageMediaDiskCache {
        let root = isolatedDirectoryURL(function: function, fileID: fileID)
        return MessageMediaDiskCache(
            directoryResolver: { root },
            keyProvider: { SymmetricKey(data: keyData) },
            keyDeleter: keyDeleter,
            timestampProvider: timestampProvider,
            evictionPolicy: evictionPolicy,
            sessionStartedAtUnixSeconds: sessionStartedAtUnixSeconds
        )
    }

    /// The directory `makeIsolated` would use, for a test that needs to look at the
    /// files on disk or hand the same root to a second cache instance.
    static func isolatedDirectoryURL(
        function: StaticString = #function,
        fileID: StaticString = #fileID
    ) -> URL {
        URL(
            fileURLWithPath: TestStorageRoot.isolated.resolvedPath(function: function, fileID: fileID),
            isDirectory: true
        )
        .appending(path: "media-cache", directoryHint: .isDirectory)
    }
}
