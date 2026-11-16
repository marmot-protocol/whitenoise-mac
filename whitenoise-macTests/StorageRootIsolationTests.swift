//
//  StorageRootIsolationTests.swift
//  whitenoise-macTests
//
//  The guarantees `TestStorageRoot` exists to make. This file lives outside
//  `whitenoise_macTests.swift` on purpose: constructing `FakeMarmotRuntime` here at
//  all is half of what is under test.
//

import Foundation
import MarmotKit
import Testing

@testable import whitenoise_mac

/// Roots handed out during this run, so a test can assert it did not receive one that
/// another test already holds. Serialized, so the appends do not race.
private nonisolated final class RootLedger: @unchecked Sendable {
    static let shared = RootLedger()
    private let lock = NSLock()
    private var roots: [String: String] = [:]

    /// Records `root` under `owner` and returns the roots every *other* owner holds.
    func claim(_ root: String, owner: String) -> [String] {
        lock.lock()
        defer { lock.unlock() }
        roots[owner] = root
        return roots.filter { $0.key != owner }.map(\.value)
    }
}

private func account(_ idHex: String) -> AccountSummaryFfi {
    AccountSummaryFfi(
        label: idHex,
        accountIdHex: idHex,
        localSigning: true,
        externalSigning: false,
        signedOut: false,
        running: false,
        unlinked: false
    )
}

/// A fake built somewhere other than the test body — the case `#function` alone gets
/// wrong, because it would name this helper for every test that called it.
private func runtimeFromASharedHelper() -> FakeMarmotRuntime {
    FakeMarmotRuntime(accounts: [account(String(repeating: "1", count: 64))])
}

@Suite(.serialized)
struct StorageRootIsolationTests {

    @Test func aRuntimeBuiltWithNoArgumentsGetsAnIsolatedRoot() {
        let runtime = FakeMarmotRuntime(accounts: [])

        // The old fixed constant, which every suite shared.
        #expect(runtime.storageRootPath != "/tmp/whitenoise-mac-tests")
        #expect(runtime.storageRootPath.hasPrefix(TestStorageRoot.processRoot.path(percentEncoded: false)))
    }

    @Test func twoRuntimesInOneTestShareARoot() {
        // A relaunch test builds a second runtime and expects it to read what the first
        // one wrote, so isolation is per test, not per instance.
        let first = FakeMarmotRuntime(accounts: [])
        let second = FakeMarmotRuntime(accounts: [account(String(repeating: "b", count: 64))])

        #expect(first.storageRootPath == second.storageRootPath)
    }

    @Test func aRuntimeBuiltInsideAHelperStillLandsInTheCallingTestsRoot() {
        let direct = FakeMarmotRuntime(accounts: [])
        let viaHelper = runtimeFromASharedHelper()

        #expect(direct.storageRootPath == viaHelper.storageRootPath)
    }

    @Test func noOtherTestInThisRunHoldsThisTestsRoot() {
        let root = FakeMarmotRuntime(accounts: []).storageRootPath
        let othersHold = RootLedger.shared.claim(root, owner: #function)

        #expect(!othersHold.contains(root))
    }

    /// The twin of the test above: two tests claiming, so whichever runs second is
    /// actually comparing against something.
    @Test func noOtherTestInThisRunHoldsThisTestsRootEither() {
        let root = FakeMarmotRuntime(accounts: []).storageRootPath
        let othersHold = RootLedger.shared.claim(root, owner: #function)

        #expect(!othersHold.contains(root))
    }

    @Test func anExplicitRootIsHonouredVerbatim() {
        let shared = "/tmp/whitenoise-mac-tests"
        let runtime = FakeMarmotRuntime(accounts: [], storageRoot: .explicit(shared))

        #expect(runtime.storageRootPath == shared)
    }

    /// What isolation is *for*: a store the test did not inject reads an empty directory
    /// rather than whatever an earlier test left behind.
    @Test func anUninjectedStoreStartsEmptyUnderAnIsolatedRoot() throws {
        let runtime = FakeMarmotRuntime(accounts: [])
        let owner = String(repeating: "c", count: 64)

        let contact = String(repeating: "d", count: 64)

        let store = ContactNicknameFileStore(storageRootPath: runtime.storageRootPath)
        #expect(try store.loadAll().isEmpty)

        try store.write([contact: "Mum"], forOwnerAccountIdHex: owner)

        // Written under this test's root, and nowhere near the constant that used to be shared.
        let reread = ContactNicknameFileStore(storageRootPath: runtime.storageRootPath)
        #expect(try reread.loadAll()[owner]?[contact] == "Mum")
    }

    // MARK: - Media cache

    @Test func theSharedMediaCacheNeverResolvesIntoApplicationSupport() throws {
        let resolved = try #require(MessageMediaDiskCache.shared.testingResolvedDirectoryURL)
        let applicationSupport = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: false
        )

        #expect(!resolved.path(percentEncoded: false).hasPrefix(applicationSupport.path(percentEncoded: false)))
        #expect(
            resolved.path(percentEncoded: false)
                .hasPrefix(FileManager.default.temporaryDirectory.path(percentEncoded: false))
        )
    }

    // MARK: - Outgoing attachment scratch

    @Test func theUploadScratchNeverResolvesIntoApplicationSupport() throws {
        let applicationSupport = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: false
        )
        for resolved in [try PickedMediaFile.defaultDirectory(), try MediaUploadSourceFiles.defaultDirectory()] {
            #expect(!resolved.path(percentEncoded: false).hasPrefix(applicationSupport.path(percentEncoded: false)))
            #expect(
                resolved.path(percentEncoded: false)
                    .hasPrefix(FileManager.default.temporaryDirectory.path(percentEncoded: false))
            )
        }
    }

    /// Every bootstrapping test runs the launch purge while other suites stage attachments in
    /// parallel, so under a test run it must leave the scratch alone.
    @Test func theLaunchPurgeLeavesTheTestScratchAlone() throws {
        let directory = try MediaUploadSourceFiles.defaultDirectory()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let staged = directory.appendingPathComponent(UUID().uuidString)
        try Data("in flight".utf8).write(to: staged)
        defer { try? FileManager.default.removeItem(at: staged) }

        MediaUploadScratch.purge()

        #expect(FileManager.default.fileExists(atPath: staged.path))
    }

    @Test func purgingScratchDirectoriesRemovesThem() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let picked = root.appendingPathComponent(PickedMediaFile.directoryName, isDirectory: true)
        let uploads = root.appendingPathComponent(MediaUploadSourceFiles.directoryName, isDirectory: true)
        for directory in [picked, uploads] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try Data("leftover".utf8).write(to: directory.appendingPathComponent("clone"))
        }

        MediaUploadScratch.purge(directories: [picked, uploads])

        #expect(!FileManager.default.fileExists(atPath: picked.path))
        #expect(!FileManager.default.fileExists(atPath: uploads.path))
    }

    /// `WorkspaceState` defaults `mediaDiskCache` to `.shared`, which is the parameter
    /// ~500 tests leave alone. That default must be the test-scoped instance.
    @MainActor
    @Test func aWorkspaceBuiltWithNoCacheGetsTheTestScopedOne() throws {
        let state = WorkspaceState()
        let resolved = try #require(state.mediaDiskCache.testingResolvedDirectoryURL)

        #expect(
            resolved.path(percentEncoded: false)
                .hasPrefix(FileManager.default.temporaryDirectory.path(percentEncoded: false))
        )
    }

    @Test func anIsolatedMediaCacheRoundTripsInsideItsOwnRoot() async throws {
        let root = MessageMediaDiskCache.isolatedDirectoryURL()
        let cache = MessageMediaDiskCache.makeIsolated()
        let plaintext = Data("isolated payload".utf8)
        let key = MessageMediaDiskCacheKey(
            accountId: String(repeating: "e", count: 64),
            groupIdHex: "group",
            reference: MediaAttachmentReferenceFfi(
                locators: [],
                ciphertextSha256: String(repeating: "ab", count: 32),
                // The cache verifies a payload it reads back against this digest, so it has
                // to be the real hash of the bytes, not a placeholder.
                plaintextSha256: MessageMediaDiskCacheKey.plaintextDigest(for: plaintext),
                nonceHex: String(repeating: "00", count: 12),
                fileName: "notes.txt",
                mediaType: "text/plain",
                version: .v1,
                sourceEpoch: 7,
                dim: nil,
                thumbhash: nil
            )
        )

        await cache.store(
            MessageMediaDownload(
                data: plaintext,
                fileName: "notes.txt",
                mediaType: "text/plain",
                sizeBytes: UInt64(plaintext.count),
                payloadId: "isolated-root"
            ),
            for: key
        )

        #expect(await cache.cachedDownload(for: key)?.data == plaintext)
        #expect(FileManager.default.fileExists(atPath: root.path(percentEncoded: false)))
        #expect(root.path(percentEncoded: false).hasPrefix(TestStorageRoot.processRoot.path(percentEncoded: false)))
    }
}
