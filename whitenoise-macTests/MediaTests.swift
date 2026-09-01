//
//  MediaTests.swift
//  whitenoise-macTests
//
//  Attachments end to end: media JSON parsing, the grid, downloads and their limiter,
//  the players, the encrypted disk cache and the remote image loader.
//
//  Split out of `whitenoise_macTests.swift` verbatim: every test body below is the
//  one that lived in that file, moved rather than rewritten.
//

import AppKit
import Combine
import CryptoKit
import Darwin
import Foundation
import ImageIO
import MarmotKit
import Observation
import SwiftUI
import Testing
import UniformTypeIdentifiers
import UserNotifications

@testable import whitenoise_mac

struct MediaTests: WorkspaceTestSupport {
    @Test func mediaPlaybackTempStoreLivesInsideAppContainerNotSharedTemp() {
        let base = URL(fileURLWithPath: "/Container", isDirectory: true)
        let directory = MediaPlaybackTempStore.directoryURL(baseURL: base)

        #expect(
            directory.path == "/Container/White Noise/WhiteNoiseMediaPlayback"
        )
        #expect(!directory.path.contains(FileManager.default.temporaryDirectory.path))
    }

    @Test func hiddenMessageStoreUsesOpaqueProtectedBackupExcludedPerChatFiles() throws {
        let fileManager = FileManager.default
        let directory = fileManager.temporaryDirectory
            .appendingPathComponent("whitenoise-hidden-message-store-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: directory) }
        let store = HiddenMessageFileStore(fileManager: fileManager, directoryURL: directory)
        let firstScope = HiddenMessageScope(accountId: "account-one", groupIdHex: "group-one")
        let secondScope = HiddenMessageScope(accountId: "account-two", groupIdHex: "group-two")

        try store.write(["message-b", "message-a"], for: firstScope)
        try store.write(["message-c"], for: secondScope)

        #expect(
            try store.loadAll()
                == [
                    firstScope: ["message-a", "message-b"],
                    secondScope: ["message-c"],
                ]
        )
        let directoryValues = try directory.resourceValues(forKeys: [.isExcludedFromBackupKey])
        #expect(directoryValues.isExcludedFromBackup == true)
        let files = try fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isExcludedFromBackupKey],
            options: [.skipsHiddenFiles]
        )
        #expect(files.count == 2)
        for file in files {
            #expect(file.pathExtension == "json")
            #expect(file.deletingPathExtension().lastPathComponent.count == 64)
            #expect(!file.lastPathComponent.contains(firstScope.accountId))
            #expect(!file.lastPathComponent.contains(firstScope.groupIdHex))
            #expect(!file.lastPathComponent.contains(secondScope.accountId))
            #expect(!file.lastPathComponent.contains(secondScope.groupIdHex))
            #expect(try file.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup == true)
            let attributes = try fileManager.attributesOfItem(atPath: file.path)
            if let protection = attributes[.protectionKey] as? FileProtectionType {
                #expect(protection == .complete || protection == .completeUntilFirstUserAuthentication)
            }
        }

        try store.remove(for: firstScope)
        #expect(try store.loadAll() == [secondScope: ["message-c"]])
        try store.removeAll()
        #expect(!fileManager.fileExists(atPath: directory.path))
    }

    @Test func pinnedChatStoreUsesOpaqueProtectedBackupExcludedPerAccountFiles() throws {
        let fileManager = FileManager.default
        let directory = fileManager.temporaryDirectory
            .appendingPathComponent("whitenoise-pinned-chat-store-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: directory) }
        let store = PinnedChatFileStore(fileManager: fileManager, directoryURL: directory)

        try store.write(["shared-group", "alpha-group"], forAccountId: "account-one")
        try store.write(["shared-group"], forAccountId: "account-two")

        #expect(
            try store.loadAll()
                == [
                    "account-one": ["alpha-group", "shared-group"],
                    "account-two": ["shared-group"],
                ]
        )
        let directoryValues = try directory.resourceValues(forKeys: [.isExcludedFromBackupKey])
        #expect(directoryValues.isExcludedFromBackup == true)
        let files = try fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isExcludedFromBackupKey],
            options: [.skipsHiddenFiles]
        )
        #expect(files.count == 2)
        for file in files {
            #expect(file.pathExtension == "json")
            #expect(file.deletingPathExtension().lastPathComponent.count == 64)
            #expect(!file.lastPathComponent.contains("account-one"))
            #expect(!file.lastPathComponent.contains("account-two"))
            #expect(try file.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup == true)
            let attributes = try fileManager.attributesOfItem(atPath: file.path)
            if let protection = attributes[.protectionKey] as? FileProtectionType {
                #expect(protection == .complete || protection == .completeUntilFirstUserAuthentication)
            }
        }

        try store.remove(forAccountId: "account-one")
        #expect(try store.loadAll() == ["account-two": ["shared-group"]])

        try store.removeAll()
        #expect(try store.loadAll().isEmpty)
    }

    @Test func mediaPlaybackTempStoreVoiceRecordingsLiveInsideAppContainerNotSharedTemp() {
        let base = URL(fileURLWithPath: "/Container", isDirectory: true)
        let directory = MediaPlaybackTempStore.voiceRecordingsDirectoryURL(baseURL: base)

        #expect(
            directory.path == "/Container/White Noise/WhiteNoiseVoiceRecordings"
        )
        #expect(!directory.path.contains(FileManager.default.temporaryDirectory.path))
    }

    @Test func mediaPlaybackTempStorePreparesVoiceRecordingFile() throws {
        let fileManager = FileManager.default
        let directory = fileManager.temporaryDirectory
            .appendingPathComponent("whitenoise-voice-recording-tests-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: directory) }

        let uniqueID = UUID(uuidString: "00000000-0000-0000-0000-000000000005")!
        let url = try MediaPlaybackTempStore.prepareVoiceRecordingFile(
            in: directory,
            uniqueID: uniqueID,
            fileManager: fileManager
        )

        #expect(fileManager.fileExists(atPath: url.path))
        let fileAttributes = try fileManager.attributesOfItem(atPath: url.path)
        if let protection = fileAttributes[.protectionKey] as? FileProtectionType {
            #expect(protection == .complete || protection == .completeUntilFirstUserAuthentication)
        }
        #expect(url.lastPathComponent == "voice-\(uniqueID.uuidString).m4a")
        #expect(url.deletingLastPathComponent().path == directory.path)
        let values = try directory.resourceValues(forKeys: [.isExcludedFromBackupKey])
        #expect(values.isExcludedFromBackup == true)
    }

    @Test func mediaPlaybackTempStoreMaterializesIndependentConsumerFiles() throws {
        let fileManager = FileManager.default
        let directory = fileManager.temporaryDirectory
            .appendingPathComponent("whitenoise-playback-tests-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: directory) }

        let firstConsumer = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let secondConsumer = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
        let url = try MediaPlaybackTempStore.materialize(
            data: Data("secret".utf8),
            id: "attachment-id/with:illegal",
            mediaType: "video/mp4",
            directory: directory,
            uniqueID: firstConsumer
        )

        #expect(fileManager.fileExists(atPath: url.path))
        let stem = MediaPlaybackTempStore.stableStem(for: "attachment-id/with:illegal")
        #expect(url.lastPathComponent == "\(stem)-\(firstConsumer.uuidString).mp4")
        #expect(url.deletingLastPathComponent().path == directory.path)

        // Re-materializing the same attachment for a later consumer must not reuse the
        // previous URL; an older cleanup timer could otherwise delete the later handoff.
        let again = try MediaPlaybackTempStore.materialize(
            data: Data("different".utf8),
            id: "attachment-id/with:illegal",
            mediaType: "video/mp4",
            directory: directory,
            uniqueID: secondConsumer
        )
        #expect(again != url)
        #expect(again.lastPathComponent.contains(secondConsumer.uuidString))
        #expect(try Data(contentsOf: url) == Data("secret".utf8))
        #expect(try Data(contentsOf: again) == Data("different".utf8))
    }

    @Test func mediaPlaybackTempStoreUsesFullIdHashInStem() throws {
        let fileManager = FileManager.default
        let directory = fileManager.temporaryDirectory
            .appendingPathComponent("whitenoise-playback-tests-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: directory) }

        let sharedPrefix = String(repeating: "a", count: 64)
        let firstID = "\(sharedPrefix)-one"
        let secondID = "\(sharedPrefix)-two"
        let firstStem = MediaPlaybackTempStore.stableStem(for: firstID)
        let secondStem = MediaPlaybackTempStore.stableStem(for: secondID)
        let first = try MediaPlaybackTempStore.materialize(
            data: Data("first".utf8),
            id: firstID,
            mediaType: "application/pdf",
            directory: directory,
            uniqueID: UUID(uuidString: "00000000-0000-0000-0000-000000000003")!
        )
        let second = try MediaPlaybackTempStore.materialize(
            data: Data("second".utf8),
            id: secondID,
            mediaType: "application/pdf",
            directory: directory,
            uniqueID: UUID(uuidString: "00000000-0000-0000-0000-000000000004")!
        )

        #expect(firstStem.prefix(32) == secondStem.prefix(32))
        #expect(firstStem != secondStem)
        #expect(first.lastPathComponent.hasPrefix("\(firstStem)-"))
        #expect(second.lastPathComponent.hasPrefix("\(secondStem)-"))
        #expect(try Data(contentsOf: first) == Data("first".utf8))
        #expect(try Data(contentsOf: second) == Data("second".utf8))
    }

    @Test func mediaPlaybackTempStoreUsesCanonicalSuffixWithoutPeerFileName() throws {
        let fileManager = FileManager.default
        let directory = fileManager.temporaryDirectory
            .appendingPathComponent("whitenoise-playback-tests-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: directory) }

        let attachmentID = "attachment-id"
        let uniqueID = UUID(uuidString: "00000000-0000-0000-0000-000000000005")!
        let stem = MediaPlaybackTempStore.stableStem(for: attachmentID)
        let url = try MediaPlaybackTempStore.materialize(
            data: Data("secret".utf8),
            id: attachmentID,
            mediaType: "application/pdf",
            directory: directory,
            uniqueID: uniqueID
        )

        #expect(fileManager.fileExists(atPath: url.path))
        #expect(url.lastPathComponent == "\(stem)-\(uniqueID.uuidString).pdf")
        #expect(url.pathExtension == "pdf")
        #expect(try Data(contentsOf: url) == Data("secret".utf8))
    }

    @Test func mediaPlaybackTempStoreUsesOnlyBoundedCanonicalPeerSuffixHints() throws {
        let fileManager = FileManager.default
        let directory = fileManager.temporaryDirectory
            .appendingPathComponent("whitenoise-playback-tests-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: directory) }

        let attachmentID = "attachment-id"
        let stem = MediaPlaybackTempStore.stableStem(for: attachmentID)
        let cases: [(mediaType: String, fileName: String, suffix: String)] = [
            ("application/octet-stream", "archive.pdf", "pdf"),
            ("application/octet-stream", "clip.mp4", "mp4"),
            ("", "clip.mp4", "mp4"),
            ("application/octet-stream", "photo.jfif", "bin"),
            ("application/octet-stream", "innocent.HIV-results", "bin"),
            ("video/mp4", "report.pdf", "mp4"),
        ]

        for item in cases {
            let uniqueID = UUID()
            let url = try MediaPlaybackTempStore.materialize(
                data: Data("secret".utf8),
                id: attachmentID,
                mediaType: item.mediaType,
                fileName: item.fileName,
                directory: directory,
                uniqueID: uniqueID
            )

            #expect(url.lastPathComponent == "\(stem)-\(uniqueID.uuidString).\(item.suffix)")
        }
    }

    @Test func mediaPlaybackTempStoreUsesBinSuffixForUnknownMediaType() throws {
        let fileManager = FileManager.default
        let directory = fileManager.temporaryDirectory
            .appendingPathComponent("whitenoise-playback-tests-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: directory) }

        let attachmentID = "attachment-id"
        let uniqueID = UUID(uuidString: "00000000-0000-0000-0000-000000000006")!
        let stem = MediaPlaybackTempStore.stableStem(for: attachmentID)
        let adversarialMediaType = "application/HIV-results"
        let url = try MediaPlaybackTempStore.materialize(
            data: Data("secret".utf8),
            id: attachmentID,
            mediaType: adversarialMediaType,
            directory: directory,
            uniqueID: uniqueID
        )

        #expect(fileManager.fileExists(atPath: url.path))
        #expect(url.lastPathComponent == "\(stem)-\(uniqueID.uuidString).bin")
        #expect(url.pathExtension == "bin")
        #expect(!url.path.contains("HIV-results"))
        #expect(try Data(contentsOf: url) == Data("secret".utf8))
    }

    @Test func mediaPlaybackTempStoreExcludesScratchDirectoryFromBackups() throws {
        let fileManager = FileManager.default
        let directory = fileManager.temporaryDirectory
            .appendingPathComponent("whitenoise-playback-tests-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: directory) }

        _ = try MediaPlaybackTempStore.materialize(
            data: Data("secret".utf8),
            id: "attachment",
            mediaType: "application/pdf",
            directory: directory
        )

        let values = try directory.resourceValues(forKeys: [.isExcludedFromBackupKey])
        #expect(values.isExcludedFromBackup == true)
    }

    @Test func mediaPlaybackTempStoreRemovesSingleFile() throws {
        let fileManager = FileManager.default
        let directory = fileManager.temporaryDirectory
            .appendingPathComponent("whitenoise-playback-tests-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: directory) }

        let url = try MediaPlaybackTempStore.materialize(
            data: Data("bytes".utf8),
            id: "video",
            mediaType: "video/mp4",
            directory: directory
        )
        #expect(fileManager.fileExists(atPath: url.path))

        MediaPlaybackTempStore.remove(at: url)
        #expect(!fileManager.fileExists(atPath: url.path))

        // Removing a missing file is a no-op.
        MediaPlaybackTempStore.remove(at: url)
        #expect(!fileManager.fileExists(atPath: url.path))
    }

    @Test func mediaPlaybackTempStorePurgesDirectory() throws {
        let fileManager = FileManager.default
        let directory = fileManager.temporaryDirectory
            .appendingPathComponent("whitenoise-playback-tests-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: directory) }

        _ = try MediaPlaybackTempStore.materialize(
            data: Data("a".utf8),
            id: "one",
            mediaType: "text/plain",
            directory: directory
        )
        _ = try MediaPlaybackTempStore.materialize(
            data: Data("b".utf8),
            id: "two",
            mediaType: "text/plain",
            directory: directory
        )
        #expect(fileManager.fileExists(atPath: directory.path))

        let legacyDirectory = fileManager.temporaryDirectory
            .appendingPathComponent("whitenoise-legacy-playback-tests-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: legacyDirectory, withIntermediateDirectories: true)
        try Data("legacy".utf8).write(to: legacyDirectory.appendingPathComponent("old-video.mp4"))
        defer { try? fileManager.removeItem(at: legacyDirectory) }

        MediaPlaybackTempStore.purge(directory: directory, legacyDirectory: legacyDirectory)
        #expect(!fileManager.fileExists(atPath: directory.path))
        #expect(!fileManager.fileExists(atPath: legacyDirectory.path))

        // Purging a missing directory is a no-op.
        MediaPlaybackTempStore.purge(directory: directory, legacyDirectory: legacyDirectory)
        #expect(!fileManager.fileExists(atPath: directory.path))
        #expect(!fileManager.fileExists(atPath: legacyDirectory.path))
    }

    @Test func mediaPlaybackTempStorePurgesVoiceRecordingDirectories() throws {
        let fileManager = FileManager.default
        let sandbox = fileManager.temporaryDirectory
            .appendingPathComponent("whitenoise-playback-purge-tests-\(UUID().uuidString)", isDirectory: true)
        let appSupport = sandbox.appendingPathComponent("ApplicationSupport", isDirectory: true)
        let legacyPlayback = sandbox.appendingPathComponent("LegacyPlayback", isDirectory: true)
        let legacyVoiceRecordings = sandbox.appendingPathComponent("LegacyVoiceRecordings", isDirectory: true)
        defer { try? fileManager.removeItem(at: sandbox) }

        let playback = MediaPlaybackTempStore.directoryURL(baseURL: appSupport)
        let voiceRecordings = MediaPlaybackTempStore.voiceRecordingsDirectoryURL(baseURL: appSupport)
        for directory in [playback, voiceRecordings, legacyPlayback, legacyVoiceRecordings] {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            try Data("plaintext".utf8).write(to: directory.appendingPathComponent("left-behind.bin"))
            #expect(fileManager.fileExists(atPath: directory.path))
        }

        MediaPlaybackTempStore.purge(
            fileManager: fileManager,
            applicationSupportDirectory: { _ in appSupport },
            legacyPlaybackDirectory: { _ in legacyPlayback },
            legacyVoiceRecordingsDirectory: { _ in legacyVoiceRecordings }
        )

        #expect(!fileManager.fileExists(atPath: playback.path))
        #expect(!fileManager.fileExists(atPath: voiceRecordings.path))
        #expect(!fileManager.fileExists(atPath: legacyPlayback.path))
        #expect(!fileManager.fileExists(atPath: legacyVoiceRecordings.path))
    }

    @Test func outgoingMediaMetadataTempStoreLivesInsideAppContainerNotSharedTemp() {
        let base = URL(fileURLWithPath: "/Container", isDirectory: true)
        let directory = OutgoingMediaMetadataTempStore.directoryURL(baseURL: base)

        #expect(
            directory.path == "/Container/White Noise/WhiteNoiseMediaWork"
        )
        #expect(!directory.path.contains(FileManager.default.temporaryDirectory.path))
    }

    @Test func outgoingMediaMetadataTempStoreMaterializesProtectedWorkFile() throws {
        let fileManager = FileManager.default
        let directory = fileManager.temporaryDirectory
            .appendingPathComponent("whitenoise-outgoing-media-tests-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: directory) }

        let uniqueID = UUID(uuidString: "00000000-0000-0000-0000-000000000006")!
        let url = try OutgoingMediaMetadataTempStore.materialize(
            data: Data("draft media plaintext".utf8),
            fileExtension: "MOV / unsafe",
            directory: directory,
            uniqueID: uniqueID
        )

        #expect(fileManager.fileExists(atPath: url.path))
        #expect(url.deletingLastPathComponent().path == directory.path)
        #expect(url.lastPathComponent == "metadata-\(uniqueID.uuidString).mov---unsafe")
        #expect(try Data(contentsOf: url) == Data("draft media plaintext".utf8))

        let values = try directory.resourceValues(forKeys: [.isExcludedFromBackupKey])
        #expect(values.isExcludedFromBackup == true)

        OutgoingMediaMetadataTempStore.remove(at: url)
        #expect(!fileManager.fileExists(atPath: url.path))
    }

    @Test func outgoingMediaMetadataTempStorePurgesCurrentAndLegacyDirectories() throws {
        let fileManager = FileManager.default
        let directory = fileManager.temporaryDirectory
            .appendingPathComponent("whitenoise-outgoing-media-tests-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: directory) }

        _ = try OutgoingMediaMetadataTempStore.materialize(
            data: Data("draft".utf8),
            fileExtension: "jpg",
            directory: directory
        )
        #expect(fileManager.fileExists(atPath: directory.path))

        let legacyDirectory = fileManager.temporaryDirectory
            .appendingPathComponent("whitenoise-legacy-outgoing-media-tests-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: legacyDirectory, withIntermediateDirectories: true)
        try Data("legacy".utf8).write(to: legacyDirectory.appendingPathComponent("old-work.jpg"))
        defer { try? fileManager.removeItem(at: legacyDirectory) }

        OutgoingMediaMetadataTempStore.purge(directory: directory, legacyDirectory: legacyDirectory)
        #expect(!fileManager.fileExists(atPath: directory.path))
        #expect(!fileManager.fileExists(atPath: legacyDirectory.path))

        // Purging a missing directory is a no-op.
        OutgoingMediaMetadataTempStore.purge(directory: directory, legacyDirectory: legacyDirectory)
        #expect(!fileManager.fileExists(atPath: directory.path))
        #expect(!fileManager.fileExists(atPath: legacyDirectory.path))
    }

    @Test func temporaryOutgoingMediaFileUsesFallbackWhenScratchUnavailable() {
        var invokedWork = false
        let result = TemporaryOutgoingMediaFile.withURL(
            data: Data("draft".utf8),
            fileExtension: "jpg",
            directoryResolver: {
                throw NSError(domain: "OutgoingMediaMetadataTempStoreTests", code: 1, userInfo: nil)
            },
            fallback: "fallback",
            { url in
                invokedWork = true
                return url.path
            }
        )

        #expect(result == "fallback")
        #expect(!invokedWork)
    }

    @MainActor
    @Test func mediaCacheFootprintLoadsOffMainActor() async throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("whitenoise-media-cache-tests-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: root) }

        let resolvedOffMain = MutableFlag(false)
        let cache = MessageMediaDiskCache(
            directoryResolver: {
                resolvedOffMain.value = !Thread.isMainThread
                return root
            },
            keyProvider: { SymmetricKey(data: Data(repeating: 0x42, count: 32)) },
            keyDeleter: {}
        )
        let state = WorkspaceState(mediaDiskCache: cache)

        await state.refreshMediaCacheFootprint()

        #expect(resolvedOffMain.value)
        #expect(state.mediaCacheFootprint == .zero)
        #expect(!state.isLoadingMediaCacheFootprint)
    }

    @Test func messageMediaDiskCacheFootprintCountsCommittedEntries() async throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("whitenoise-media-cache-tests-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: root) }

        let cache = messageMediaDiskCache(root: root)
        let firstPlaintext = Data("first footprint entry".utf8)
        let secondPlaintext = Data("second footprint entry".utf8)
        let fixtures = [
            (
                firstPlaintext,
                MessageMediaDiskCacheKey(
                    accountId: "account-a",
                    groupIdHex: "group-a",
                    reference: mediaDiskCacheReference(plaintext: firstPlaintext, ciphertextByte: 0xa1)
                )
            ),
            (
                secondPlaintext,
                MessageMediaDiskCacheKey(
                    accountId: "account-b",
                    groupIdHex: "group-b",
                    reference: mediaDiskCacheReference(plaintext: secondPlaintext, ciphertextByte: 0xa2)
                )
            ),
        ]

        for (index, fixture) in fixtures.enumerated() {
            await cache.store(
                MessageMediaDownload(
                    data: fixture.0,
                    fileName: "fixture-\(index).bin",
                    mediaType: "application/octet-stream",
                    sizeBytes: UInt64(fixture.0.count),
                    payloadId: "fixture-\(index)"
                ),
                for: fixture.1
            )
        }

        let footprint = await cache.footprint()
        #expect(footprint.entryCount == 2)
        #expect(footprint.byteCount > UInt64(firstPlaintext.count + secondPlaintext.count))

        await cache.purgeAll()
        #expect(await cache.footprint() == .zero)
    }

    @Test func messageMediaDiskCachePurgeWaitsForStoreAlreadyInStaging() async throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("whitenoise-media-cache-tests-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: root) }

        let keyProviderGate = OneShotKeyProviderGate()
        let cache = MessageMediaDiskCache(
            directoryResolver: { root },
            keyProvider: keyProviderGate.symmetricKey,
            keyDeleter: {}
        )
        let plaintext = Data("store entered staging before clear".utf8)
        let key = MessageMediaDiskCacheKey(
            accountId: "account-a",
            groupIdHex: "group-a",
            reference: mediaDiskCacheReference(plaintext: plaintext)
        )
        let store = Task {
            await cache.store(
                MessageMediaDownload(
                    data: plaintext,
                    fileName: "staged.bin",
                    mediaType: "application/octet-stream",
                    sizeBytes: UInt64(plaintext.count),
                    payloadId: "staged"
                ),
                for: key
            )
        }
        await Task.detached {
            keyProviderGate.waitUntilReached()
        }.value

        let purgeCompleted = DispatchSemaphore(value: 0)
        let purge = Task {
            await cache.purgeAll()
            purgeCompleted.signal()
        }
        #expect(
            await waitForSemaphore(purgeCompleted, timeout: .now() + .milliseconds(200)) == .timedOut
        )

        keyProviderGate.releaseGate()
        await store.value
        await purge.value

        #expect(await cache.cachedDownload(for: key) == nil)
        #expect(await cache.footprint() == .zero)
        #expect(!fileManager.fileExists(atPath: root.path))
    }

    @MainActor
    @Test func workspaceClearMediaCacheResetsUIProjectionsAndKeepsEncryptionKey() async throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("whitenoise-media-cache-tests-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: root) }

        let didDeleteKey = MutableFlag(false)
        let cache = messageMediaDiskCache(
            root: root,
            keyDeleter: {
                didDeleteKey.value = true
            })
        let plaintext = Data("cached attachment cleared from settings".utf8)
        let reference = mediaDiskCacheReference(plaintext: plaintext)
        let key = MessageMediaDiskCacheKey(
            accountId: "account-a",
            groupIdHex: "group-a",
            reference: reference
        )
        let download = MessageMediaDownload(
            data: plaintext,
            fileName: "cached.jpg",
            mediaType: "image/jpeg",
            sizeBytes: UInt64(plaintext.count),
            payloadId: "loaded-before-clear"
        )
        await cache.store(download, for: key)

        let state = WorkspaceState(mediaDiskCache: cache)
        state.activeAccountId = "account-a"
        let message = MessageItem(
            id: "message-a",
            groupIdHex: "group-a",
            senderName: "Alice",
            body: "",
            sentAt: Date(timeIntervalSince1970: 1_700_000_000),
            isOutgoing: false,
            mediaAttachments: [
                MessageMediaAttachment(id: "attachment-a", reference: reference)
            ]
        )
        let attachment = try #require(message.mediaAttachments.first)
        let stateStore = state.mediaDownloadStateStore(for: message, attachment: attachment)
        stateStore.update(.loaded(download))
        state.sharedMediaThumbnailCache = ["thumbnail": plaintext]
        state.sharedMediaThumbnailCacheOrder = ["thumbnail"]
        state.sharedMediaThumbnailCacheBytes = plaintext.count
        let before = await cache.footprint()
        state.mediaCacheFootprint = before
        let generation = state.mediaCacheGeneration

        await state.clearMediaCache()

        #expect(!state.isClearingMediaCache)
        #expect(state.mediaCacheFootprint == .zero)
        #expect(state.mediaCacheReclaimedByteCount == before.byteCount)
        #expect(state.mediaCacheGeneration == generation + 1)
        #expect(stateStore.state == .idle)
        #expect(state.mediaDownloads.isEmpty)
        #expect(state.sharedMediaThumbnailCache.isEmpty)
        #expect(state.sharedMediaThumbnailCacheOrder.isEmpty)
        #expect(state.sharedMediaThumbnailCacheBytes == 0)
        #expect(!didDeleteKey.value)
        #expect(await cache.cachedDownload(for: key) == nil)
    }

    @Test func outgoingMediaMetadataTempStoreSanitizesEmptyExtensionsToBin() {
        #expect(OutgoingMediaMetadataTempStore.sanitizedFileExtension("") == "bin")
        #expect(OutgoingMediaMetadataTempStore.sanitizedFileExtension(" .. / ") == "bin")
    }

    @Test func messageMediaDiskCacheRoundTripsEncryptedPayload() async throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("whitenoise-media-cache-tests-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: root) }

        let cache = messageMediaDiskCache(root: root)
        let plaintext = Data("durable cached media bytes".utf8)
        let reference = mediaDiskCacheReference(plaintext: plaintext)
        let key = MessageMediaDiskCacheKey(accountId: "account-a", groupIdHex: "group-a", reference: reference)
        let download = MessageMediaDownload(
            data: plaintext,
            fileName: "photo.png",
            mediaType: "image/png",
            sizeBytes: UInt64(plaintext.count),
            payloadId: "network-download"
        )

        await cache.store(download, for: key)

        let restored = try #require(await cache.cachedDownload(for: key))
        #expect(restored.data == plaintext)
        #expect(restored.fileName == "photo.png")
        #expect(restored.mediaType == "image/png")
        #expect(restored.sizeBytes == UInt64(plaintext.count))
        #expect(restored.payload.id == key.payloadID)

        let cacheFiles = try fileManager.subpathsOfDirectory(atPath: root.path)
        #expect(cacheFiles.contains { $0.hasSuffix("metadata.bin") })
        #expect(cacheFiles.contains { $0.hasSuffix("payload.bin") })
        for relativePath in cacheFiles where relativePath.hasSuffix(".bin") {
            let bytes = try Data(contentsOf: root.appendingPathComponent(relativePath))
            #expect(!dataContains(bytes, plaintext))
        }
    }

    @Test func messageMediaDiskCacheReadsEntryWhenDeclaredSizeDiffersFromPlaintext() async throws {
        // #313: `sizeBytes` is the FFI-reported/declared size and is not guaranteed to equal
        // the decrypted plaintext length. A valid, cryptographically authenticated entry must
        // survive repeated reads even when the two diverge, rather than self-deleting.
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("whitenoise-media-cache-tests-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: root) }

        let cache = messageMediaDiskCache(root: root)
        let plaintext = Data("bytes whose declared size lies".utf8)
        let reference = mediaDiskCacheReference(plaintext: plaintext)
        let key = MessageMediaDiskCacheKey(accountId: "account-a", groupIdHex: "group-a", reference: reference)
        let declaredSize = UInt64(plaintext.count) + 999
        let download = MessageMediaDownload(
            data: plaintext,
            fileName: "photo.png",
            mediaType: "image/png",
            sizeBytes: declaredSize,
            payloadId: "network-download"
        )

        await cache.store(download, for: key)
        let entryDirectory = try #require(cache.entryDirectory(for: key))

        let firstRead = try #require(await cache.cachedDownload(for: key))
        #expect(firstRead.data == plaintext)
        #expect(firstRead.sizeBytes == declaredSize)
        #expect(fileManager.fileExists(atPath: entryDirectory.path))

        let secondRead = try #require(await cache.cachedDownload(for: key))
        #expect(secondRead.data == plaintext)
        #expect(fileManager.fileExists(atPath: entryDirectory.path))
    }

    @Test func messageMediaDiskCachePlaintextHashMismatchDoesNotEvictValidEntry() async throws {
        // #389: cacheID must include plaintextSha256 so a peer-crafted reference reusing a
        // real ciphertext hash cannot share an entry directory and delete the valid cache on read.
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("whitenoise-media-cache-tests-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: root) }

        let cache = messageMediaDiskCache(root: root)
        let plaintext = Data("legitimate cached media bytes".utf8)
        let sharedCiphertextSha256 = String(repeating: "cc", count: 32)
        let validReference = mediaDiskCacheReference(
            plaintext: plaintext,
            ciphertextSha256: sharedCiphertextSha256
        )
        let bogusReference = mediaDiskCacheReference(
            plaintext: Data("bogus plaintext claim".utf8),
            ciphertextSha256: sharedCiphertextSha256
        )
        let validKey = MessageMediaDiskCacheKey(
            accountId: "account-a",
            groupIdHex: "group-a",
            reference: validReference
        )
        let bogusKey = MessageMediaDiskCacheKey(
            accountId: "account-a",
            groupIdHex: "group-a",
            reference: bogusReference
        )
        let download = MessageMediaDownload(
            data: plaintext,
            fileName: "photo.png",
            mediaType: "image/png",
            sizeBytes: UInt64(plaintext.count),
            payloadId: "network-download"
        )

        #expect(validKey.cacheID != bogusKey.cacheID)

        await cache.store(download, for: validKey)
        let validEntryDirectory = try #require(cache.entryDirectory(for: validKey))

        #expect(await cache.cachedDownload(for: bogusKey) == nil)
        #expect(fileManager.fileExists(atPath: validEntryDirectory.path))

        let restored = try #require(await cache.cachedDownload(for: validKey))
        #expect(restored.data == plaintext)
        #expect(fileManager.fileExists(atPath: validEntryDirectory.path))
    }

    @Test func messageMediaDiskCacheEvictsCorruptEntries() async throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("whitenoise-media-cache-tests-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: root) }

        let cache = messageMediaDiskCache(root: root)
        let plaintext = Data("media that will be corrupted".utf8)
        let reference = mediaDiskCacheReference(plaintext: plaintext)
        let key = MessageMediaDiskCacheKey(accountId: "account-a", groupIdHex: "group-a", reference: reference)
        let download = MessageMediaDownload(
            data: plaintext,
            fileName: "clip.mp4",
            mediaType: "video/mp4",
            sizeBytes: UInt64(plaintext.count),
            payloadId: "network-download"
        )

        await cache.store(download, for: key)
        let entryDirectory = try #require(cache.entryDirectory(for: key))
        try Data("not a sealed payload".utf8).write(to: entryDirectory.appendingPathComponent("payload.bin"))

        #expect(await cache.cachedDownload(for: key) == nil)
        #expect(!fileManager.fileExists(atPath: entryDirectory.path))
    }

    @Test func messageMediaDiskCacheEvictsCorruptMetadata() async throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("whitenoise-media-cache-tests-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: root) }

        let cache = messageMediaDiskCache(root: root)
        let plaintext = Data("media whose metadata will be corrupted".utf8)
        let reference = mediaDiskCacheReference(plaintext: plaintext)
        let key = MessageMediaDiskCacheKey(accountId: "account-a", groupIdHex: "group-a", reference: reference)
        let download = MessageMediaDownload(
            data: plaintext,
            fileName: "photo.png",
            mediaType: "image/png",
            sizeBytes: UInt64(plaintext.count),
            payloadId: "network-download"
        )

        await cache.store(download, for: key)
        let entryDirectory = try #require(cache.entryDirectory(for: key))
        try Data("not sealed metadata".utf8).write(to: entryDirectory.appendingPathComponent("metadata.bin"))

        #expect(await cache.cachedDownload(for: key) == nil)
        #expect(!fileManager.fileExists(atPath: entryDirectory.path))
    }

    @Test func messageMediaDiskCacheReadDeletionDoesNotEvictUnrelatedEntry() async throws {
        // The read path deletes an entry whose sealed metadata cannot be opened. A subsequent
        // store must reconcile that deletion without evicting an unrelated entry when the actual
        // cache remains at the entry cap.
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("whitenoise-media-cache-tests-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: root) }

        let cachedAtCounter = AtomicCounter()
        let cache = messageMediaDiskCache(
            root: root,
            evictionPolicy: .init(maxEntryCount: 2, maxTotalBytes: UInt64.max),
            timestampProvider: { TimeInterval(cachedAtCounter.increment()) }
        )
        let victimPlaintext = Data("entry whose metadata is corrupted before read".utf8)
        let sentinelPlaintext = Data("corrupt sentinel that only a full scan would sweep".utf8)
        let replacementPlaintext = Data("replacement media stored after the read deletion".utf8)
        let victimKey = MessageMediaDiskCacheKey(
            accountId: "account-a",
            groupIdHex: "group-a",
            reference: mediaDiskCacheReference(plaintext: victimPlaintext, ciphertextByte: 0xa1)
        )
        let sentinelKey = MessageMediaDiskCacheKey(
            accountId: "account-a",
            groupIdHex: "group-a",
            reference: mediaDiskCacheReference(plaintext: sentinelPlaintext, ciphertextByte: 0xa2)
        )
        let replacementKey = MessageMediaDiskCacheKey(
            accountId: "account-a",
            groupIdHex: "group-a",
            reference: mediaDiskCacheReference(plaintext: replacementPlaintext, ciphertextByte: 0xa3)
        )

        await cache.store(
            MessageMediaDownload(
                data: victimPlaintext,
                fileName: "victim.jpg",
                mediaType: "image/jpeg",
                sizeBytes: UInt64(victimPlaintext.count),
                payloadId: "victim"
            ),
            for: victimKey
        )
        await cache.store(
            MessageMediaDownload(
                data: sentinelPlaintext,
                fileName: "sentinel.jpg",
                mediaType: "image/jpeg",
                sizeBytes: UInt64(sentinelPlaintext.count),
                payloadId: "sentinel"
            ),
            for: sentinelKey
        )
        let victimEntryDirectory = try #require(cache.entryDirectory(for: victimKey))
        let sentinelEntryDirectory = try #require(cache.entryDirectory(for: sentinelKey))
        // Corrupt both sealed metadata blobs. Reading the victim exercises read-path deletion;
        // the unrelated sentinel must remain untouched by the subsequent store.
        try Data("not sealed metadata".utf8).write(to: victimEntryDirectory.appendingPathComponent("metadata.bin"))
        try Data("not sealed metadata".utf8).write(to: sentinelEntryDirectory.appendingPathComponent("metadata.bin"))

        #expect(await cache.cachedDownload(for: victimKey) == nil)
        #expect(!fileManager.fileExists(atPath: victimEntryDirectory.path))

        await cache.store(
            MessageMediaDownload(
                data: replacementPlaintext,
                fileName: "replacement.jpg",
                mediaType: "image/jpeg",
                sizeBytes: UInt64(replacementPlaintext.count),
                payloadId: "replacement"
            ),
            for: replacementKey
        )

        #expect(fileManager.fileExists(atPath: sentinelEntryDirectory.path))
        #expect(try #require(await cache.cachedDownload(for: replacementKey)).data == replacementPlaintext)
    }

    @Test func messageMediaDiskCachePreservesEntryWhenMetadataCannotBeRead() async throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("whitenoise-media-cache-tests-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: root) }

        let cache = messageMediaDiskCache(root: root)
        let plaintext = Data("media with temporarily unreadable metadata".utf8)
        let reference = mediaDiskCacheReference(plaintext: plaintext)
        let key = MessageMediaDiskCacheKey(accountId: "account-a", groupIdHex: "group-a", reference: reference)
        let download = MessageMediaDownload(
            data: plaintext,
            fileName: "photo.png",
            mediaType: "image/png",
            sizeBytes: UInt64(plaintext.count),
            payloadId: "network-download"
        )

        await cache.store(download, for: key)
        let entryDirectory = try #require(cache.entryDirectory(for: key))
        let metadataURL = entryDirectory.appendingPathComponent("metadata.bin")
        let payloadURL = entryDirectory.appendingPathComponent("payload.bin")
        try fileManager.removeItem(at: metadataURL)
        try fileManager.createDirectory(at: metadataURL, withIntermediateDirectories: false)

        #expect(await cache.cachedDownload(for: key) == nil)
        var metadataIsDirectory = ObjCBool(false)
        #expect(fileManager.fileExists(atPath: metadataURL.path, isDirectory: &metadataIsDirectory))
        #expect(metadataIsDirectory.boolValue)
        #expect(fileManager.fileExists(atPath: payloadURL.path))
    }

    @Test func messageMediaDiskCachePreservesEntryWhenPayloadCannotBeRead() async throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("whitenoise-media-cache-tests-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: root) }

        let cache = messageMediaDiskCache(root: root)
        let plaintext = Data("media with temporarily unreadable payload".utf8)
        let reference = mediaDiskCacheReference(plaintext: plaintext)
        let key = MessageMediaDiskCacheKey(accountId: "account-a", groupIdHex: "group-a", reference: reference)
        let download = MessageMediaDownload(
            data: plaintext,
            fileName: "photo.png",
            mediaType: "image/png",
            sizeBytes: UInt64(plaintext.count),
            payloadId: "network-download"
        )

        await cache.store(download, for: key)
        let entryDirectory = try #require(cache.entryDirectory(for: key))
        let metadataURL = entryDirectory.appendingPathComponent("metadata.bin")
        let payloadURL = entryDirectory.appendingPathComponent("payload.bin")
        try fileManager.removeItem(at: payloadURL)
        try fileManager.createDirectory(at: payloadURL, withIntermediateDirectories: false)

        #expect(await cache.cachedDownload(for: key) == nil)
        #expect(fileManager.fileExists(atPath: metadataURL.path))
        var payloadIsDirectory = ObjCBool(false)
        #expect(fileManager.fileExists(atPath: payloadURL.path, isDirectory: &payloadIsDirectory))
        #expect(payloadIsDirectory.boolValue)
    }

    @Test func messageMediaDiskCacheEvictsOldestEntriesWhenEntryLimitExceeded() async throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("whitenoise-media-cache-tests-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: root) }

        let cachedAtCounter = AtomicCounter()
        let cache = messageMediaDiskCache(
            root: root,
            evictionPolicy: .init(maxEntryCount: 2, maxTotalBytes: UInt64.max),
            timestampProvider: { TimeInterval(cachedAtCounter.increment()) }
        )
        let firstPlaintext = Data("first cached media".utf8)
        let secondPlaintext = Data("second cached media".utf8)
        let thirdPlaintext = Data("third cached media".utf8)
        let firstKey = MessageMediaDiskCacheKey(
            accountId: "account-a",
            groupIdHex: "group-a",
            reference: mediaDiskCacheReference(plaintext: firstPlaintext, ciphertextByte: 0xa1)
        )
        let secondKey = MessageMediaDiskCacheKey(
            accountId: "account-a",
            groupIdHex: "group-a",
            reference: mediaDiskCacheReference(plaintext: secondPlaintext, ciphertextByte: 0xa2)
        )
        let thirdKey = MessageMediaDiskCacheKey(
            accountId: "account-a",
            groupIdHex: "group-a",
            reference: mediaDiskCacheReference(plaintext: thirdPlaintext, ciphertextByte: 0xa3)
        )

        await cache.store(
            MessageMediaDownload(
                data: firstPlaintext,
                fileName: "first.jpg",
                mediaType: "image/jpeg",
                sizeBytes: UInt64(firstPlaintext.count),
                payloadId: "first"
            ),
            for: firstKey
        )
        await cache.store(
            MessageMediaDownload(
                data: secondPlaintext,
                fileName: "second.jpg",
                mediaType: "image/jpeg",
                sizeBytes: UInt64(secondPlaintext.count),
                payloadId: "second"
            ),
            for: secondKey
        )
        await cache.store(
            MessageMediaDownload(
                data: thirdPlaintext,
                fileName: "third.jpg",
                mediaType: "image/jpeg",
                sizeBytes: UInt64(thirdPlaintext.count),
                payloadId: "third"
            ),
            for: thirdKey
        )

        #expect(await cache.cachedDownload(for: firstKey) == nil)
        #expect(try #require(await cache.cachedDownload(for: secondKey)).data == secondPlaintext)
        #expect(try #require(await cache.cachedDownload(for: thirdKey)).data == thirdPlaintext)

        let cacheFiles = try fileManager.subpathsOfDirectory(atPath: root.path)
        #expect(cacheFiles.filter { $0.hasSuffix("payload.bin") }.count == 2)
    }

    @Test func messageMediaDiskCacheEvictionUsesPersistedTimestampWithoutOpeningMetadata() async throws {
        // Eviction ordering comes from the entry directory timestamp, not encrypted metadata.
        // Corrupting the newest survivor distinguishes those paths: decrypting metadata would
        // discard it, while the persisted ordering correctly evicts the older readable entry.
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("whitenoise-media-cache-tests-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: root) }

        let cachedAtCounter = AtomicCounter()
        let cache = messageMediaDiskCache(
            root: root,
            evictionPolicy: .init(maxEntryCount: 2, maxTotalBytes: UInt64.max),
            timestampProvider: { TimeInterval(cachedAtCounter.increment()) }
        )
        let plaintexts = (0..<4).map { Data("cached media \($0)".utf8) }
        let keys = plaintexts.enumerated().map { index, plaintext in
            MessageMediaDiskCacheKey(
                accountId: "account-a",
                groupIdHex: "group-a",
                reference: mediaDiskCacheReference(
                    plaintext: plaintext,
                    ciphertextByte: UInt8(0xb0 + index)
                )
            )
        }

        for index in 0..<3 {
            await cache.store(
                MessageMediaDownload(
                    data: plaintexts[index],
                    fileName: "photo-\(index).jpg",
                    mediaType: "image/jpeg",
                    sizeBytes: UInt64(plaintexts[index].count),
                    payloadId: "photo-\(index)"
                ),
                for: keys[index]
            )
        }

        let secondEntryDirectory = try #require(cache.entryDirectory(for: keys[1]))
        let thirdEntryDirectory = try #require(cache.entryDirectory(for: keys[2]))
        let thirdModifiedAt = try #require(
            thirdEntryDirectory.resourceValues(
                forKeys: [.contentModificationDateKey]
            ).contentModificationDate
        )
        #expect(thirdModifiedAt.timeIntervalSince1970 == 3)
        #expect(await cache.cachedDownload(for: keys[0]) == nil)
        try Data("not sealed metadata".utf8).write(
            to: thirdEntryDirectory.appendingPathComponent("metadata.bin")
        )

        await cache.store(
            MessageMediaDownload(
                data: plaintexts[3],
                fileName: "photo-3.jpg",
                mediaType: "image/jpeg",
                sizeBytes: UInt64(plaintexts[3].count),
                payloadId: "photo-3"
            ),
            for: keys[3]
        )

        #expect(!fileManager.fileExists(atPath: secondEntryDirectory.path))
        #expect(fileManager.fileExists(atPath: thirdEntryDirectory.path))
        #expect(try #require(await cache.cachedDownload(for: keys[3])).data == plaintexts[3])
    }

    @Test func messageMediaDiskCacheReplaceEntryDoesNotEvictOthersAtEntryLimit() async throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("whitenoise-media-cache-tests-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: root) }

        let cachedAtCounter = AtomicCounter()
        let cache = messageMediaDiskCache(
            root: root,
            evictionPolicy: .init(maxEntryCount: 2, maxTotalBytes: UInt64.max),
            timestampProvider: { TimeInterval(cachedAtCounter.increment()) }
        )
        let firstPlaintext = Data("first cached media".utf8)
        let secondPlaintext = Data("second cached media".utf8)
        let firstKey = MessageMediaDiskCacheKey(
            accountId: "account-a",
            groupIdHex: "group-a",
            reference: mediaDiskCacheReference(plaintext: firstPlaintext, ciphertextByte: 0xa1)
        )
        let secondKey = MessageMediaDiskCacheKey(
            accountId: "account-a",
            groupIdHex: "group-a",
            reference: mediaDiskCacheReference(plaintext: secondPlaintext, ciphertextByte: 0xa2)
        )

        await cache.store(
            MessageMediaDownload(
                data: firstPlaintext,
                fileName: "first.jpg",
                mediaType: "image/jpeg",
                sizeBytes: UInt64(firstPlaintext.count),
                payloadId: "first"
            ),
            for: firstKey
        )
        await cache.store(
            MessageMediaDownload(
                data: secondPlaintext,
                fileName: "second.jpg",
                mediaType: "image/jpeg",
                sizeBytes: UInt64(secondPlaintext.count),
                payloadId: "second"
            ),
            for: secondKey
        )
        await cache.store(
            MessageMediaDownload(
                data: firstPlaintext,
                fileName: "first-renamed.jpg",
                mediaType: "image/jpeg",
                sizeBytes: UInt64(firstPlaintext.count),
                payloadId: "first-renamed"
            ),
            for: firstKey
        )

        #expect(try #require(await cache.cachedDownload(for: firstKey)).fileName == "first-renamed.jpg")
        #expect(try #require(await cache.cachedDownload(for: secondKey)).data == secondPlaintext)

        let cacheFiles = try fileManager.subpathsOfDirectory(atPath: root.path)
        #expect(cacheFiles.filter { $0.hasSuffix("payload.bin") }.count == 2)
    }

    @Test func messageMediaDiskCacheRestoresReplacementAfterCommitMoveFailure() async throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("whitenoise-media-cache-tests-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: root) }

        let cache = messageMediaDiskCache(root: root)
        let plaintext = Data("replacement remains recoverable".utf8)
        let key = MessageMediaDiskCacheKey(
            accountId: "account-a",
            groupIdHex: "group-a",
            reference: mediaDiskCacheReference(plaintext: plaintext)
        )
        let original = MessageMediaDownload(
            data: plaintext,
            fileName: "original.jpg",
            mediaType: "image/jpeg",
            sizeBytes: UInt64(plaintext.count),
            payloadId: "original"
        )
        let replacement = MessageMediaDownload(
            data: plaintext,
            fileName: "replacement.jpg",
            mediaType: "image/jpeg",
            sizeBytes: UInt64(plaintext.count),
            payloadId: "replacement"
        )

        await cache.store(original, for: key)
        #expect(cache.testingTrackedFootprintIsInitialized())

        let moveAttempts = AtomicCounter()
        cache.testingSetBeforePreparedEntryMoveHook {
            if moveAttempts.increment() == 1 {
                throw FakeMarmotRuntimeError.unused
            }
        }
        await cache.store(replacement, for: key)

        #expect(try #require(await cache.cachedDownload(for: key)).fileName == "original.jpg")
        #expect(!cache.testingTrackedFootprintIsInitialized())

        await cache.store(replacement, for: key)
        #expect(try #require(await cache.cachedDownload(for: key)).fileName == "replacement.jpg")
        #expect(cache.testingTrackedFootprintIsInitialized())
    }

    @Test func messageMediaDiskCacheEvictsAfterManyStoresUnderCap() async throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("whitenoise-media-cache-tests-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: root) }

        let cachedAtCounter = AtomicCounter()
        let cache = messageMediaDiskCache(
            root: root,
            evictionPolicy: .init(maxEntryCount: 4, maxTotalBytes: UInt64.max),
            timestampProvider: { TimeInterval(cachedAtCounter.increment()) }
        )
        var keys: [MessageMediaDiskCacheKey] = []
        for index in 0..<5 {
            let plaintext = Data("cached media \(index)".utf8)
            let key = MessageMediaDiskCacheKey(
                accountId: "account-a",
                groupIdHex: "group-a",
                reference: mediaDiskCacheReference(plaintext: plaintext, ciphertextByte: UInt8(0xb0 + index))
            )
            keys.append(key)
            await cache.store(
                MessageMediaDownload(
                    data: plaintext,
                    fileName: "photo-\(index).jpg",
                    mediaType: "image/jpeg",
                    sizeBytes: UInt64(plaintext.count),
                    payloadId: "photo-\(index)"
                ),
                for: key
            )
        }

        #expect(await cache.cachedDownload(for: keys[0]) == nil)
        for index in 1..<5 {
            let restored = try #require(await cache.cachedDownload(for: keys[index]))
            #expect(restored.data == Data("cached media \(index)".utf8))
        }

        let cacheFiles = try fileManager.subpathsOfDirectory(atPath: root.path)
        #expect(cacheFiles.filter { $0.hasSuffix("payload.bin") }.count == 4)
    }

    @Test func messageMediaDiskCacheEvictsEntryWhenByteLimitExceeded() async throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("whitenoise-media-cache-tests-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: root) }

        let cache = messageMediaDiskCache(
            root: root,
            evictionPolicy: .init(maxEntryCount: 10, maxTotalBytes: 1)
        )
        let plaintext = Data("media larger than the byte cap".utf8)
        let key = MessageMediaDiskCacheKey(
            accountId: "account-a",
            groupIdHex: "group-a",
            reference: mediaDiskCacheReference(plaintext: plaintext)
        )

        await cache.store(
            MessageMediaDownload(
                data: plaintext,
                fileName: "oversized.jpg",
                mediaType: "image/jpeg",
                sizeBytes: UInt64(plaintext.count),
                payloadId: "oversized"
            ),
            for: key
        )

        #expect(await cache.cachedDownload(for: key) == nil)
        let cacheFiles = (try? fileManager.subpathsOfDirectory(atPath: root.path)) ?? []
        #expect(!cacheFiles.contains { $0.hasSuffix("payload.bin") })
    }

    @Test func messageMediaDiskCacheEvictionReclaimsUnavailableEntriesBeforeReadableEntries() async throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("whitenoise-media-cache-tests-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: root) }

        let cachedAtCounter = AtomicCounter()
        let cache = messageMediaDiskCache(
            root: root,
            evictionPolicy: .init(maxEntryCount: 2, maxTotalBytes: UInt64.max),
            timestampProvider: { TimeInterval(cachedAtCounter.increment()) }
        )
        let readablePlaintext = Data("readable cached media".utf8)
        let unavailablePlaintext = Data("temporarily unavailable cached media".utf8)
        let pressurePlaintext = Data("pressure-triggering cached media".utf8)
        let readableKey = MessageMediaDiskCacheKey(
            accountId: "account-a",
            groupIdHex: "group-a",
            reference: mediaDiskCacheReference(plaintext: readablePlaintext, ciphertextByte: 0xa1)
        )
        let unavailableKey = MessageMediaDiskCacheKey(
            accountId: "account-a",
            groupIdHex: "group-a",
            reference: mediaDiskCacheReference(plaintext: unavailablePlaintext, ciphertextByte: 0xa2)
        )
        let pressureKey = MessageMediaDiskCacheKey(
            accountId: "account-a",
            groupIdHex: "group-a",
            reference: mediaDiskCacheReference(plaintext: pressurePlaintext, ciphertextByte: 0xa3)
        )

        await cache.store(
            MessageMediaDownload(
                data: readablePlaintext,
                fileName: "readable.jpg",
                mediaType: "image/jpeg",
                sizeBytes: UInt64(readablePlaintext.count),
                payloadId: "readable"
            ),
            for: readableKey
        )
        await cache.store(
            MessageMediaDownload(
                data: unavailablePlaintext,
                fileName: "unavailable.jpg",
                mediaType: "image/jpeg",
                sizeBytes: UInt64(unavailablePlaintext.count),
                payloadId: "unavailable"
            ),
            for: unavailableKey
        )
        let unavailableEntryDirectory = try #require(cache.entryDirectory(for: unavailableKey))
        let unavailableMetadataURL = unavailableEntryDirectory.appendingPathComponent("metadata.bin")
        try fileManager.removeItem(at: unavailableMetadataURL)
        try fileManager.createDirectory(at: unavailableMetadataURL, withIntermediateDirectories: false)
        try fileManager.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 2)],
            ofItemAtPath: unavailableEntryDirectory.path
        )

        await cache.store(
            MessageMediaDownload(
                data: pressurePlaintext,
                fileName: "pressure.jpg",
                mediaType: "image/jpeg",
                sizeBytes: UInt64(pressurePlaintext.count),
                payloadId: "pressure"
            ),
            for: pressureKey
        )

        #expect(!fileManager.fileExists(atPath: unavailableEntryDirectory.path))
        #expect(try #require(await cache.cachedDownload(for: readableKey)).data == readablePlaintext)
        #expect(try #require(await cache.cachedDownload(for: pressureKey)).data == pressurePlaintext)
    }

    @Test func messageMediaDiskCacheCountsInSessionStagingBytesAgainstByteLimit() async throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("whitenoise-media-cache-tests-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: root) }

        let stagedPayload = Data(repeating: 0xab, count: 128 * 1_024)
        let stagingDirectory =
            root
            .appendingPathComponent("staging", isDirectory: true)
            .appendingPathComponent("active-store", isDirectory: true)
        let stagingPayloadURL = stagingDirectory.appendingPathComponent("payload.bin")
        try fileManager.createDirectory(at: stagingDirectory, withIntermediateDirectories: true)
        try stagedPayload.write(to: stagingPayloadURL)

        let cache = messageMediaDiskCache(
            root: root,
            evictionPolicy: .init(maxEntryCount: 10, maxTotalBytes: UInt64(stagedPayload.count)),
            sessionStartedAtUnixSeconds: 0
        )
        let plaintext = Data("committed media that does not fit beside active staging".utf8)
        let key = MessageMediaDiskCacheKey(
            accountId: "account-a",
            groupIdHex: "group-a",
            reference: mediaDiskCacheReference(plaintext: plaintext)
        )

        await cache.store(
            MessageMediaDownload(
                data: plaintext,
                fileName: "committed.jpg",
                mediaType: "image/jpeg",
                sizeBytes: UInt64(plaintext.count),
                payloadId: "committed"
            ),
            for: key
        )

        #expect(fileManager.fileExists(atPath: stagingPayloadURL.path))
        #expect(await cache.cachedDownload(for: key) == nil)
    }

    @Test func messageMediaDiskCacheSerializesConcurrentStorePreparation() async throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("whitenoise-media-cache-tests-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: root) }

        let directoryResolutionCount = AtomicCounter()
        let secondStoreResolvedDirectory = DispatchSemaphore(value: 0)
        let timestampProviderCalls = AtomicCounter()
        let firstTimestampProviderCall = DispatchSemaphore(value: 0)
        let secondTimestampProviderCall = DispatchSemaphore(value: 0)
        let releaseFirstTimestampProviderCall = DispatchSemaphore(value: 0)
        let cache = MessageMediaDiskCache(
            directoryResolver: {
                if directoryResolutionCount.increment() == 2 {
                    secondStoreResolvedDirectory.signal()
                }
                return root
            },
            keyProvider: { SymmetricKey(data: Data(repeating: 0x42, count: 32)) },
            keyDeleter: {},
            timestampProvider: {
                let call = timestampProviderCalls.increment()
                if call == 1 {
                    firstTimestampProviderCall.signal()
                    releaseFirstTimestampProviderCall.wait()
                } else if call == 2 {
                    secondTimestampProviderCall.signal()
                }
                return TimeInterval(call)
            }
        )
        let firstPlaintext = Data("first concurrently stored media".utf8)
        let secondPlaintext = Data("second concurrently stored media".utf8)
        let firstKey = MessageMediaDiskCacheKey(
            accountId: "account-a",
            groupIdHex: "group-a",
            reference: mediaDiskCacheReference(plaintext: firstPlaintext, ciphertextByte: 0xa1)
        )
        let secondKey = MessageMediaDiskCacheKey(
            accountId: "account-a",
            groupIdHex: "group-a",
            reference: mediaDiskCacheReference(plaintext: secondPlaintext, ciphertextByte: 0xa2)
        )

        let firstStore = Task {
            await cache.store(
                MessageMediaDownload(
                    data: firstPlaintext,
                    fileName: "first.jpg",
                    mediaType: "image/jpeg",
                    sizeBytes: UInt64(firstPlaintext.count),
                    payloadId: "first"
                ),
                for: firstKey
            )
        }
        #expect(
            await waitForSemaphore(
                firstTimestampProviderCall,
                timeout: .now() + .seconds(1)
            ) == .success
        )

        let secondStore = Task {
            await cache.store(
                MessageMediaDownload(
                    data: secondPlaintext,
                    fileName: "second.jpg",
                    mediaType: "image/jpeg",
                    sizeBytes: UInt64(secondPlaintext.count),
                    payloadId: "second"
                ),
                for: secondKey
            )
        }

        #expect(
            await waitForSemaphore(
                secondStoreResolvedDirectory,
                timeout: .now() + .seconds(1)
            ) == .success
        )
        #expect(
            await waitForSemaphore(
                secondTimestampProviderCall,
                timeout: .now() + .milliseconds(200)
            ) == .timedOut
        )
        releaseFirstTimestampProviderCall.signal()
        await firstStore.value
        await secondStore.value
        #expect(
            await waitForSemaphore(
                secondTimestampProviderCall,
                timeout: .now() + .seconds(1)
            ) == .success
        )
        #expect(try #require(await cache.cachedDownload(for: firstKey)).data == firstPlaintext)
        #expect(try #require(await cache.cachedDownload(for: secondKey)).data == secondPlaintext)
    }

    @Test func messageMediaDiskCacheAccountPurgeCleansUnreadableEntriesAfterAccountPass() async throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("whitenoise-media-cache-tests-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: root) }

        let cache = messageMediaDiskCache(root: root)
        let purgedPlaintext = Data("purged account media".utf8)
        let unreadablePlaintext = Data("other account media with unreadable metadata".utf8)
        let preservedPlaintext = Data("other account readable media".utf8)
        let purgedKey = MessageMediaDiskCacheKey(
            accountId: "account-a",
            groupIdHex: "group-a",
            reference: mediaDiskCacheReference(plaintext: purgedPlaintext, ciphertextByte: 0xaa)
        )
        let unreadableKey = MessageMediaDiskCacheKey(
            accountId: "account-b",
            groupIdHex: "group-b",
            reference: mediaDiskCacheReference(plaintext: unreadablePlaintext, ciphertextByte: 0xbb)
        )
        let preservedKey = MessageMediaDiskCacheKey(
            accountId: "account-b",
            groupIdHex: "group-b",
            reference: mediaDiskCacheReference(plaintext: preservedPlaintext, ciphertextByte: 0xbc)
        )

        await cache.store(
            MessageMediaDownload(
                data: purgedPlaintext,
                fileName: "purged.jpg",
                mediaType: "image/jpeg",
                sizeBytes: UInt64(purgedPlaintext.count),
                payloadId: "purged"
            ),
            for: purgedKey
        )
        await cache.store(
            MessageMediaDownload(
                data: unreadablePlaintext,
                fileName: "unreadable.jpg",
                mediaType: "image/jpeg",
                sizeBytes: UInt64(unreadablePlaintext.count),
                payloadId: "unreadable"
            ),
            for: unreadableKey
        )
        await cache.store(
            MessageMediaDownload(
                data: preservedPlaintext,
                fileName: "preserved.jpg",
                mediaType: "image/jpeg",
                sizeBytes: UInt64(preservedPlaintext.count),
                payloadId: "preserved"
            ),
            for: preservedKey
        )

        let purgedEntryDirectory = try #require(cache.entryDirectory(for: purgedKey))
        let unreadableEntryDirectory = try #require(cache.entryDirectory(for: unreadableKey))
        try Data("not sealed metadata".utf8).write(
            to: unreadableEntryDirectory.appendingPathComponent("metadata.bin")
        )

        await cache.purgeAccount("account-a")

        #expect(!fileManager.fileExists(atPath: purgedEntryDirectory.path))
        // The corrupt-entry cleanup is account-agnostic: readable entries for other
        // accounts survive, while entries whose metadata no account can decode are removed.
        #expect(!fileManager.fileExists(atPath: unreadableEntryDirectory.path))
        #expect(try #require(await cache.cachedDownload(for: preservedKey)).data == preservedPlaintext)
    }

    @Test func messageMediaDiskCacheAccountPurgePreservesEntriesWhenMetadataCannotBeRead() async throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("whitenoise-media-cache-tests-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: root) }

        let cache = messageMediaDiskCache(root: root)
        let purgedPlaintext = Data("purged account media".utf8)
        let unavailablePlaintext = Data("other account media with unavailable metadata".utf8)
        let purgedKey = MessageMediaDiskCacheKey(
            accountId: "account-a",
            groupIdHex: "group-a",
            reference: mediaDiskCacheReference(plaintext: purgedPlaintext, ciphertextByte: 0xaa)
        )
        let unavailableKey = MessageMediaDiskCacheKey(
            accountId: "account-b",
            groupIdHex: "group-b",
            reference: mediaDiskCacheReference(plaintext: unavailablePlaintext, ciphertextByte: 0xbd)
        )

        await cache.store(
            MessageMediaDownload(
                data: purgedPlaintext,
                fileName: "purged.jpg",
                mediaType: "image/jpeg",
                sizeBytes: UInt64(purgedPlaintext.count),
                payloadId: "purged"
            ),
            for: purgedKey
        )
        await cache.store(
            MessageMediaDownload(
                data: unavailablePlaintext,
                fileName: "unavailable.jpg",
                mediaType: "image/jpeg",
                sizeBytes: UInt64(unavailablePlaintext.count),
                payloadId: "unavailable"
            ),
            for: unavailableKey
        )

        let purgedEntryDirectory = try #require(cache.entryDirectory(for: purgedKey))
        let unavailableEntryDirectory = try #require(cache.entryDirectory(for: unavailableKey))
        let unavailableMetadataURL = unavailableEntryDirectory.appendingPathComponent("metadata.bin")
        let unavailablePayloadURL = unavailableEntryDirectory.appendingPathComponent("payload.bin")
        try fileManager.removeItem(at: unavailableMetadataURL)
        try fileManager.createDirectory(at: unavailableMetadataURL, withIntermediateDirectories: false)

        await cache.purgeAccount("account-a")

        #expect(!fileManager.fileExists(atPath: purgedEntryDirectory.path))
        var metadataIsDirectory = ObjCBool(false)
        #expect(fileManager.fileExists(atPath: unavailableMetadataURL.path, isDirectory: &metadataIsDirectory))
        #expect(metadataIsDirectory.boolValue)
        #expect(fileManager.fileExists(atPath: unavailablePayloadURL.path))
    }

    @Test func messageMediaDiskCacheAccountPurgePreservesFutureMetadataVersions() async throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("whitenoise-media-cache-tests-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: root) }

        let keyData = Data(repeating: 0x42, count: 32)
        let cache = messageMediaDiskCache(root: root, keyData: keyData)
        let purgedPlaintext = Data("purged account media".utf8)
        let futurePlaintext = Data("other account media with future metadata".utf8)
        let purgedKey = MessageMediaDiskCacheKey(
            accountId: "account-a",
            groupIdHex: "group-a",
            reference: mediaDiskCacheReference(plaintext: purgedPlaintext, ciphertextByte: 0xaa)
        )
        let futureKey = MessageMediaDiskCacheKey(
            accountId: "account-b",
            groupIdHex: "group-b",
            reference: mediaDiskCacheReference(plaintext: futurePlaintext, ciphertextByte: 0xbe)
        )

        await cache.store(
            MessageMediaDownload(
                data: purgedPlaintext,
                fileName: "purged.jpg",
                mediaType: "image/jpeg",
                sizeBytes: UInt64(purgedPlaintext.count),
                payloadId: "purged"
            ),
            for: purgedKey
        )
        await cache.store(
            MessageMediaDownload(
                data: futurePlaintext,
                fileName: "future.jpg",
                mediaType: "image/jpeg",
                sizeBytes: UInt64(futurePlaintext.count),
                payloadId: "future"
            ),
            for: futureKey
        )

        let purgedEntryDirectory = try #require(cache.entryDirectory(for: purgedKey))
        let futureEntryDirectory = try #require(cache.entryDirectory(for: futureKey))
        let futureMetadataURL = futureEntryDirectory.appendingPathComponent("metadata.bin")
        let futurePayloadURL = futureEntryDirectory.appendingPathComponent("payload.bin")
        let futureMetadataPlaintext = try JSONSerialization.data(withJSONObject: [
            "version": 2,
            "accountDigest": futureKey.accountDigest,
            "ciphertextSha256": futureKey.ciphertextSha256,
            "plaintextSha256": futureKey.plaintextSha256,
            "fileName": "future.jpg",
            "mediaType": "image/jpeg",
            "sizeBytes": UInt64(futurePlaintext.count),
            "cachedAtUnixSeconds": 1_234,
        ])
        let futureMetadataBox = try AES.GCM.seal(
            futureMetadataPlaintext,
            using: SymmetricKey(data: keyData),
            authenticating: Data("white-noise-media-cache-metadata-v1|\(futureKey.cacheID)".utf8)
        )
        let futureMetadataData = try #require(futureMetadataBox.combined)
        try futureMetadataData.write(to: futureMetadataURL)

        await cache.purgeAccount("account-a")

        #expect(!fileManager.fileExists(atPath: purgedEntryDirectory.path))
        #expect(fileManager.fileExists(atPath: futureMetadataURL.path))
        #expect(fileManager.fileExists(atPath: futurePayloadURL.path))
    }

    @Test func messageMediaDiskCacheAccountPurgeSweepsCrashOrphanedStagingEntries() async throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("whitenoise-media-cache-tests-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: root) }

        let stagingRoot = root.appendingPathComponent("staging", isDirectory: true)
        let staleStagingDirectory = stagingRoot.appendingPathComponent("crash-orphan", isDirectory: true)
        let inSessionStagingDirectory = stagingRoot.appendingPathComponent("in-session", isDirectory: true)
        try fileManager.createDirectory(at: staleStagingDirectory, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: inSessionStagingDirectory, withIntermediateDirectories: true)
        try Data("orphaned encrypted payload".utf8).write(
            to: staleStagingDirectory.appendingPathComponent("payload.bin")
        )
        try Data("active encrypted payload".utf8).write(
            to: inSessionStagingDirectory.appendingPathComponent("payload.bin")
        )
        try fileManager.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 100)],
            ofItemAtPath: staleStagingDirectory.path
        )
        try fileManager.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 2_000)],
            ofItemAtPath: inSessionStagingDirectory.path
        )

        let cache = messageMediaDiskCache(root: root, sessionStartedAtUnixSeconds: 1_000)

        await cache.purgeAccount("account-a")

        #expect(!fileManager.fileExists(atPath: staleStagingDirectory.path))
        #expect(fileManager.fileExists(atPath: inSessionStagingDirectory.path))
    }

    @Test func messageMediaDiskCacheConcurrentStoreWaitsForInitialStagingSweep() async throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("whitenoise-media-cache-tests-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: root) }

        let stagingRoot = root.appendingPathComponent("staging", isDirectory: true)
        let staleStagingDirectory = stagingRoot.appendingPathComponent("crash-orphan", isDirectory: true)
        try fileManager.createDirectory(at: staleStagingDirectory, withIntermediateDirectories: true)
        try Data("orphaned encrypted payload".utf8).write(
            to: staleStagingDirectory.appendingPathComponent("payload.bin")
        )
        try fileManager.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 100)],
            ofItemAtPath: staleStagingDirectory.path
        )

        let sweepGate = BlockingFfiGate()
        sweepGate.isEnabled = true
        let directoryResolutionCount = AtomicCounter()
        let secondStoreResolvedDirectory = DispatchSemaphore(value: 0)
        let keyProviderEntered = DispatchSemaphore(value: 0)
        let keyProviderGate = OneShotKeyProviderGate()
        let cache = MessageMediaDiskCache(
            directoryResolver: {
                if directoryResolutionCount.increment() == 2 {
                    secondStoreResolvedDirectory.signal()
                }
                return root
            },
            keyProvider: {
                keyProviderEntered.signal()
                return try keyProviderGate.symmetricKey()
            },
            keyDeleter: {},
            sessionStartedAtUnixSeconds: 1_000
        )
        cache.testingSetBeforeStagingSweepHook { sweepGate.passIfArmed() }
        let firstPlaintext = Data("first store blocked behind initial staging sweep".utf8)
        let secondPlaintext = Data("second store must wait for staging sweep".utf8)
        let firstKey = MessageMediaDiskCacheKey(
            accountId: "account-a",
            groupIdHex: "group-a",
            reference: mediaDiskCacheReference(plaintext: firstPlaintext, ciphertextByte: 0xa1)
        )
        let secondKey = MessageMediaDiskCacheKey(
            accountId: "account-a",
            groupIdHex: "group-a",
            reference: mediaDiskCacheReference(plaintext: secondPlaintext, ciphertextByte: 0xa2)
        )

        let firstStore = Task {
            await cache.store(
                MessageMediaDownload(
                    data: firstPlaintext,
                    fileName: "first.jpg",
                    mediaType: "image/jpeg",
                    sizeBytes: UInt64(firstPlaintext.count),
                    payloadId: "first"
                ),
                for: firstKey
            )
        }
        while !sweepGate.didReach {
            await Task.yield()
        }

        let secondStore = Task {
            await cache.store(
                MessageMediaDownload(
                    data: secondPlaintext,
                    fileName: "second.jpg",
                    mediaType: "image/jpeg",
                    sizeBytes: UInt64(secondPlaintext.count),
                    payloadId: "second"
                ),
                for: secondKey
            )
        }
        #expect(
            await waitForSemaphore(
                secondStoreResolvedDirectory,
                timeout: .now() + .seconds(1)
            ) == .success
        )
        #expect(
            await waitForSemaphore(keyProviderEntered, timeout: .now() + .milliseconds(200)) == .timedOut
        )

        sweepGate.release()
        keyProviderGate.releaseGate()
        await firstStore.value
        await secondStore.value

        #expect(try #require(await cache.cachedDownload(for: firstKey)).data == firstPlaintext)
        #expect(try #require(await cache.cachedDownload(for: secondKey)).data == secondPlaintext)
        #expect(!fileManager.fileExists(atPath: staleStagingDirectory.path))
    }

    @Test func messageMediaDiskCachePostSweepReadDoesNotWaitForFileMutationLock() async throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("whitenoise-media-cache-tests-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: root) }

        let cache = messageMediaDiskCache(root: root)
        let plaintext = Data("cached read should not block on file mutation lock".utf8)
        let reference = mediaDiskCacheReference(plaintext: plaintext)
        let key = MessageMediaDiskCacheKey(accountId: "account-a", groupIdHex: "group-a", reference: reference)
        let download = MessageMediaDownload(
            data: plaintext,
            fileName: "read.png",
            mediaType: "image/png",
            sizeBytes: UInt64(plaintext.count),
            payloadId: "read-lock-test"
        )

        await cache.store(download, for: key)
        _ = try #require(await cache.cachedDownload(for: key))

        let lockHeld = DispatchSemaphore(value: 0)
        let releaseLock = DispatchSemaphore(value: 0)
        let holderTask = Task.detached {
            cache.testingWithFileMutationLock {
                lockHeld.signal()
                _ = releaseLock.wait(timeout: .now() + 5)
            }
        }
        #expect(await waitForSemaphore(lockHeld, timeout: .now() + 2) == .success)

        let readCompleted = DispatchSemaphore(value: 0)
        let readTask = Task {
            let restored = await cache.cachedDownload(for: key)
            readCompleted.signal()
            return restored
        }
        let readCompletedWhileLockHeld = await waitForSemaphore(readCompleted, timeout: .now() + 2)

        // Release the lock even when the bounded wait fails so the task can finish cleanly.
        releaseLock.signal()
        await holderTask.value
        let restored = try #require(await readTask.value)

        #expect(readCompletedWhileLockHeld == .success)
        #expect(restored.data == plaintext)
    }

    @Test func messageMediaDiskCacheUnrelatedAccountPurgeDoesNotCancelInFlightStore() async throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("whitenoise-media-cache-tests-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: root) }

        let keyProviderGate = OneShotKeyProviderGate()
        let directoryResolutionCount = AtomicCounter()
        let purgeResolvedDirectory = DispatchSemaphore(value: 0)
        let cache = MessageMediaDiskCache(
            directoryResolver: {
                if directoryResolutionCount.increment() == 2 {
                    purgeResolvedDirectory.signal()
                }
                return root
            },
            keyProvider: keyProviderGate.symmetricKey,
            keyDeleter: {}
        )
        let plaintext = Data("active account store survives unrelated account purge".utf8)
        let key = MessageMediaDiskCacheKey(
            accountId: "account-b",
            groupIdHex: "group-b",
            reference: mediaDiskCacheReference(plaintext: plaintext, ciphertextByte: 0xbc)
        )
        let download = MessageMediaDownload(
            data: plaintext,
            fileName: "active.jpg",
            mediaType: "image/jpeg",
            sizeBytes: UInt64(plaintext.count),
            payloadId: "active"
        )

        let storeTask = Task {
            await cache.store(download, for: key)
        }
        await Task.detached {
            keyProviderGate.waitUntilReached()
        }.value

        let purgeTask = Task {
            await cache.purgeAccount("account-a")
        }
        #expect(
            await waitForSemaphore(
                purgeResolvedDirectory,
                timeout: .now() + .seconds(1)
            ) == .success
        )
        keyProviderGate.releaseGate()
        await purgeTask.value
        await storeTask.value

        let restored = try #require(await cache.cachedDownload(for: key))
        #expect(restored.data == plaintext)
        #expect(restored.fileName == "active.jpg")
    }

    @Test func messageMediaDiskCacheMatchingAccountPurgeCancelsInFlightStore() async throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("whitenoise-media-cache-tests-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: root) }

        let keyProviderGate = OneShotKeyProviderGate()
        let directoryResolutionCount = AtomicCounter()
        let purgeResolvedDirectory = DispatchSemaphore(value: 0)
        let cache = MessageMediaDiskCache(
            directoryResolver: {
                if directoryResolutionCount.increment() == 2 {
                    purgeResolvedDirectory.signal()
                }
                return root
            },
            keyProvider: keyProviderGate.symmetricKey,
            keyDeleter: {}
        )
        let plaintext = Data("matching account store should be discarded".utf8)
        let key = MessageMediaDiskCacheKey(
            accountId: "account-b",
            groupIdHex: "group-b",
            reference: mediaDiskCacheReference(plaintext: plaintext, ciphertextByte: 0xbd)
        )
        let download = MessageMediaDownload(
            data: plaintext,
            fileName: "matching.jpg",
            mediaType: "image/jpeg",
            sizeBytes: UInt64(plaintext.count),
            payloadId: "matching"
        )

        let storeTask = Task {
            await cache.store(download, for: key)
        }
        await Task.detached {
            keyProviderGate.waitUntilReached()
        }.value

        let purgeTask = Task {
            await cache.purgeAccount("account-b")
        }
        #expect(
            await waitForSemaphore(
                purgeResolvedDirectory,
                timeout: .now() + .seconds(1)
            ) == .success
        )
        keyProviderGate.releaseGate()
        await purgeTask.value
        await storeTask.value

        #expect(await cache.cachedDownload(for: key) == nil)
        #expect(!fileManager.fileExists(atPath: root.path))
    }

    @Test func messageMediaDiskCachePurgesByAccountAndFullWipeDeletesKey() async throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("whitenoise-media-cache-tests-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: root) }

        let didDeleteKey = MutableFlag(false)
        let cache = messageMediaDiskCache(
            root: root,
            keyDeleter: {
                didDeleteKey.value = true
            })
        let firstPlaintext = Data("first account media".utf8)
        let secondPlaintext = Data("second account media".utf8)
        let firstKey = MessageMediaDiskCacheKey(
            accountId: "account-a",
            groupIdHex: "group-a",
            reference: mediaDiskCacheReference(plaintext: firstPlaintext, ciphertextByte: 0xaa)
        )
        let secondKey = MessageMediaDiskCacheKey(
            accountId: "account-b",
            groupIdHex: "group-b",
            reference: mediaDiskCacheReference(plaintext: secondPlaintext, ciphertextByte: 0xbb)
        )

        await cache.store(
            MessageMediaDownload(
                data: firstPlaintext,
                fileName: "a.jpg",
                mediaType: "image/jpeg",
                sizeBytes: UInt64(firstPlaintext.count),
                payloadId: "first"
            ),
            for: firstKey
        )
        await cache.store(
            MessageMediaDownload(
                data: secondPlaintext,
                fileName: "b.jpg",
                mediaType: "image/jpeg",
                sizeBytes: UInt64(secondPlaintext.count),
                payloadId: "second"
            ),
            for: secondKey
        )

        await cache.purgeAccount("account-a")
        #expect(await cache.cachedDownload(for: firstKey) == nil)
        #expect(try #require(await cache.cachedDownload(for: secondKey)).data == secondPlaintext)

        await cache.purgeAll(removeEncryptionKey: true)
        #expect(await cache.cachedDownload(for: secondKey) == nil)
        #expect(didDeleteKey.value)
        #expect(!fileManager.fileExists(atPath: root.path))
    }

    @Test func messageMediaDiskCacheMemoizesEncryptionKeyUntilDeletion() async throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("whitenoise-media-cache-tests-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: root) }

        let keyProviderCalls = AtomicCounter()
        let keyDeleterCalls = AtomicCounter()
        let cache = MessageMediaDiskCache(
            directoryResolver: { root },
            keyProvider: {
                let call = keyProviderCalls.increment()
                return SymmetricKey(data: Data(repeating: UInt8(call), count: 32))
            },
            keyDeleter: { keyDeleterCalls.increment() }
        )
        let plaintext = Data("memoized cache key".utf8)
        let key = MessageMediaDiskCacheKey(
            accountId: "account-a",
            groupIdHex: "group-a",
            reference: mediaDiskCacheReference(plaintext: plaintext)
        )
        let download = MessageMediaDownload(
            data: plaintext,
            fileName: "memoized.jpg",
            mediaType: "image/jpeg",
            sizeBytes: UInt64(plaintext.count),
            payloadId: "memoized"
        )

        await cache.store(download, for: key)
        #expect(try #require(await cache.cachedDownload(for: key)).data == plaintext)
        #expect(keyProviderCalls.value == 1)

        await cache.purgeAll()
        await cache.store(download, for: key)
        #expect(try #require(await cache.cachedDownload(for: key)).data == plaintext)
        #expect(keyProviderCalls.value == 1)
        #expect(keyDeleterCalls.value == 0)

        await cache.purgeAll(removeEncryptionKey: true)
        #expect(keyDeleterCalls.value == 1)
        await cache.store(download, for: key)
        #expect(try #require(await cache.cachedDownload(for: key)).data == plaintext)
        #expect(keyProviderCalls.value == 2)
    }

    @Test func messageMediaDiskCacheRejectsDirectStoreDuringFullWipe() async throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("whitenoise-media-cache-tests-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: root) }

        let keyProviderCalls = AtomicCounter()
        let deleterEntered = DispatchSemaphore(value: 0)
        let releaseDeleter = DispatchSemaphore(value: 0)
        let cache = MessageMediaDiskCache(
            directoryResolver: { root },
            keyProvider: {
                keyProviderCalls.increment()
                return SymmetricKey(data: Data(repeating: 0x42, count: 32))
            },
            keyDeleter: {
                deleterEntered.signal()
                _ = releaseDeleter.wait(timeout: .now() + 5)
            }
        )
        let plaintext = Data("store racing full wipe".utf8)
        let reference = mediaDiskCacheReference(plaintext: plaintext)
        let key = MessageMediaDiskCacheKey(accountId: "account-a", groupIdHex: "group-a", reference: reference)
        let download = MessageMediaDownload(
            data: plaintext,
            fileName: "race.png",
            mediaType: "image/png",
            sizeBytes: UInt64(plaintext.count),
            payloadId: "network-download"
        )

        let purge = Task {
            await cache.purgeAll(removeEncryptionKey: true)
        }
        #expect(await waitForSemaphore(deleterEntered, timeout: .now() + 2) == .success)

        await cache.store(download, for: key)
        #expect(keyProviderCalls.value == 0)
        #expect(!fileManager.fileExists(atPath: root.path))

        releaseDeleter.signal()
        await purge.value
        #expect(keyProviderCalls.value == 0)
        #expect(!fileManager.fileExists(atPath: root.path))
    }

    @MainActor
    @Test func mediaOnlyTimelineMessageMapsAttachmentWithoutUnsupportedText() async throws {
        let reference = mediaAttachmentReference(mediaType: "image/png", fileName: "photo.png")
        let page = TimelinePageFfi(
            messages: [
                timelineMessage(
                    id: "media-message",
                    groupIdHex: "group",
                    sender: "alice",
                    plaintext: "",
                    recordedAt: 1_700_000_000,
                    mediaJson: mediaJson(for: reference)
                )
            ],
            hasMoreBefore: false,
            hasMoreAfter: false
        )

        let messages = MessageItem.timeline(from: page, activeAccountIdHex: "self")
        let message = try #require(messages.first)

        #expect(message.presentation == .chat)
        #expect(message.body.isEmpty)
        #expect(message.replyPreviewText == "Photo")
        #expect(message.mediaAttachments.count == 1)
        #expect(message.mediaAttachments.first?.reference.plaintextSha256 == reference.plaintextSha256)
        #expect(message.canReply)
        #expect(!message.canCopyText)
    }

    @MainActor
    @Test func fallbackMediaJSONCapsWideAttachmentArrays() async throws {
        // Regression for whitenoise-mac#404: the depth guard bounds nesting only. A flat
        // legacy `mediaJson` array must also be capped so one message cannot allocate and
        // render an unbounded number of fallback attachment tiles.
        let cap = OutgoingMediaDraftProcessor.maxAttachmentCount
        let references = (0..<(cap + 15)).map { index in
            mediaAttachmentReference(mediaType: "image/png", fileName: "wide-\(index).png")
        }
        let mediaObjects: [[String: Any]] = references.map { reference in
            ["imeta": [mediaIMetaTag(for: reference).values]]
        }
        let page = TimelinePageFfi(
            messages: [
                timelineMessage(
                    id: "wide-media-json",
                    groupIdHex: "group",
                    sender: "alice",
                    plaintext: "",
                    recordedAt: 1_700_000_000,
                    mediaJson: mediaJSONString(fromJSONObject: mediaObjects)
                )
            ],
            hasMoreBefore: false,
            hasMoreAfter: false
        )

        let messages = MessageItem.timeline(from: page, activeAccountIdHex: "self")
        let message = try #require(messages.first)

        #expect(message.mediaAttachments.count == cap)
        #expect(message.mediaAttachments.map(\.reference.fileName) == Array(references.prefix(cap)).map(\.fileName))
    }

    @MainActor
    @Test func resolvedMediaBypassesFallbackAttachmentCap() async throws {
        // The fallback cap is intentionally local to legacy `mediaJson`/`imeta` parsing.
        // Non-empty core-resolved media is already validated upstream and remains intact.
        let cap = OutgoingMediaDraftProcessor.maxAttachmentCount
        let resolvedReferences = (0..<(cap + 2)).map { index in
            mediaAttachmentReference(mediaType: "image/png", fileName: "resolved-\(index).png")
        }
        let fallbackReferences = (0..<(cap + 15)).map { index in
            mediaAttachmentReference(mediaType: "image/png", fileName: "fallback-\(index).png")
        }
        let mediaObjects: [[String: Any]] = fallbackReferences.map { reference in
            ["imeta": [mediaIMetaTag(for: reference).values]]
        }
        let page = TimelinePageFfi(
            messages: [
                timelineMessage(
                    id: "resolved-media",
                    groupIdHex: "group",
                    sender: "alice",
                    plaintext: "",
                    recordedAt: 1_700_000_000,
                    mediaJson: mediaJSONString(fromJSONObject: mediaObjects),
                    media: resolvedReferences
                )
            ],
            hasMoreBefore: false,
            hasMoreAfter: false
        )

        let messages = MessageItem.timeline(from: page, activeAccountIdHex: "self")
        let message = try #require(messages.first)

        #expect(message.mediaAttachments.count == resolvedReferences.count)
        #expect(message.mediaAttachments.map(\.reference.fileName) == resolvedReferences.map(\.fileName))
    }

    @MainActor
    @Test func mediaOnlyChatPreviewShowsAttachmentLabelInsteadOfUnsupported() async throws {
        // Regression for whitenoise-mac#175: `ChatListMessagePreviewFfi` carries no media
        // payload, so a media-only chat message arrives with empty plaintext. The chat-list
        // preview must fall back to "Attachment" rather than "Unsupported message".
        // An incoming chat-bubble preview from another member is attributed with the sender
        // name, so the media fallback reads "Alice: Attachment" — consistent with text previews.
        let directRow = ChatListRowFfi(
            groupIdHex: "direct-group",
            archived: false,
            pendingConfirmation: false,
            title: "Alice",
            groupName: "",
            avatarUrl: nil,
            avatar: nil,
            lastMessage: ChatListMessagePreviewFfi(
                messageIdHex: "media-preview",
                sender: "alice1234567890alice1234567890alice1234567890alice1234567890",
                senderDisplayName: "Alice",
                plaintext: "",
                contentTokens: emptyMarkdownDocument(),
                kind: 9,
                timelineAt: 1_700_000_000,
                deleted: false
            ),
            unreadCount: 0,
            hasUnread: false,
            unreadMentionCount: 0,
            unreadMention: false,
            firstUnreadMessageIdHex: nil,
            lastReadMessageIdHex: nil,
            lastReadTimelineAt: nil,
            updatedAt: 1_700_000_000,
            selfMembership: .member
        )

        let directChat = ChatItem(row: directRow, activeAccountIdHex: "self")
        #expect(directChat.preview == "\(isolated("Alice")): Attachment")

        let groupRow = ChatListRowFfi(
            groupIdHex: "group",
            archived: false,
            pendingConfirmation: false,
            title: "Planning",
            groupName: "Planning",
            avatarUrl: nil,
            avatar: nil,
            lastMessage: ChatListMessagePreviewFfi(
                messageIdHex: "media-preview",
                sender: "alice1234567890alice1234567890alice1234567890alice1234567890",
                senderDisplayName: "Alice",
                plaintext: "",
                contentTokens: emptyMarkdownDocument(),
                kind: 9,
                timelineAt: 1_700_000_000,
                deleted: false
            ),
            unreadCount: 0,
            hasUnread: false,
            unreadMentionCount: 0,
            unreadMention: false,
            firstUnreadMessageIdHex: nil,
            lastReadMessageIdHex: nil,
            lastReadTimelineAt: nil,
            updatedAt: 1_700_000_000,
            selfMembership: .member
        )

        let groupChat = ChatItem(row: groupRow, activeAccountIdHex: "self")
        #expect(groupChat.preview == "\(isolated("Alice")): Attachment")
    }

    @MainActor
    @Test func literalUnsupportedChatPreviewPreservesMessageText() async throws {
        // A valid chat body can equal the localized unsupported-message label. That
        // literal text must not be mistaken for the empty media-only preview sentinel.
        let literalText = L10n.string("Unsupported message")
        let row = chatListRow(
            groupIdHex: "group",
            title: "Planning",
            preview: literalText,
            sender: "alice1234567890alice1234567890alice1234567890alice1234567890",
            timelineAt: 1_700_000_001
        )

        let chat = ChatItem(row: row, activeAccountIdHex: "self")
        #expect(chat.preview == literalText)
    }

    @MainActor
    @Test func imetaInsideJSONReadsSourceEpochInBothSpellings() async throws {
        // Regression for whitenoise-mac#137: the imeta-within-object branch must
        // accept both snake_case `source_epoch` and camelCase `sourceEpoch` so a
        // camelCase payload does not silently default the epoch to 0.
        let reference = mediaAttachmentReference(sourceEpoch: 7, mediaType: "image/png", fileName: "photo.png")
        let page = TimelinePageFfi(
            messages: [
                timelineMessage(
                    id: "snake-epoch",
                    groupIdHex: "group",
                    sender: "alice",
                    plaintext: "",
                    recordedAt: 1_700_000_000,
                    mediaJson: mediaJson(for: reference, sourceEpochKey: "source_epoch")
                ),
                timelineMessage(
                    id: "camel-epoch",
                    groupIdHex: "group",
                    sender: "alice",
                    plaintext: "",
                    recordedAt: 1_700_000_001,
                    mediaJson: mediaJson(for: reference, sourceEpochKey: "sourceEpoch")
                ),
            ],
            hasMoreBefore: false,
            hasMoreAfter: false
        )

        let messages = MessageItem.timeline(from: page, activeAccountIdHex: "self")

        #expect(messages.count == 2)
        #expect(messages.allSatisfy { $0.mediaAttachments.first?.reference.sourceEpoch == 7 })
    }

    @MainActor
    @Test func imetaBlurhashFieldDoesNotDropAttachment() async throws {
        // Regression for whitenoise-mac#208: `blurhash` is a standard optional NIP-92
        // imeta field. The macOS client does not consume it, but its presence must not
        // make the local-parse fallback discard the whole media attachment.
        let reference = mediaAttachmentReference(mediaType: "image/png", fileName: "photo.png")
        let page = TimelinePageFfi(
            messages: [
                timelineMessage(
                    id: "blurhash-imeta",
                    groupIdHex: "group",
                    sender: "alice",
                    plaintext: "",
                    recordedAt: 1_700_000_000,
                    mediaJson: mediaJson(
                        for: reference,
                        appendingIMetaField: "blurhash LEHV6nWB2yk8pyo0adR*.7kCMdnj"
                    )
                )
            ],
            hasMoreBefore: false,
            hasMoreAfter: false
        )

        let messages = MessageItem.timeline(from: page, activeAccountIdHex: "self")
        let message = try #require(messages.first)

        #expect(message.mediaAttachments.count == 1)
        #expect(message.mediaAttachments.first?.reference.fileName == reference.fileName)
        #expect(message.mediaAttachments.first?.reference.thumbhash == nil)
    }

    @MainActor
    @Test func invalidNumericSourceEpochFallsBackToZeroInsteadOfWrapping() async throws {
        // Regression for whitenoise-mac#179: a peer-controlled `source_epoch` is the MLS
        // decryption epoch, so a negative (`-1` would wrap to `UInt64.max`), fractional
        // (`3.9` would truncate to `3`), out-of-range (`1e30` would saturate), or boolean
        // (`true` would parse as `1`) JSON value must be rejected by `unsignedInteger(_:)`
        // instead of flowing through as a garbage epoch. Rejected values default the parsed
        // attachment epoch to 0, matching `nil` from `unsignedInteger`.
        let reference = mediaAttachmentReference(sourceEpoch: 0, mediaType: "image/png", fileName: "photo.png")
        let invalidEpochs: [NSNumber] = [
            NSNumber(value: -1),
            NSNumber(value: 3.9),
            NSNumber(value: 1e30),
            NSNumber(value: true),
            NSNumber(value: false),
        ]
        let page = TimelinePageFfi(
            messages: invalidEpochs.enumerated().flatMap { index, rawEpoch in
                ["source_epoch", "sourceEpoch"].enumerated().map { keyIndex, key in
                    timelineMessage(
                        id: "invalid-epoch-\(index)-\(keyIndex)",
                        groupIdHex: "group",
                        sender: "alice",
                        plaintext: "",
                        recordedAt: 1_700_000_000 + UInt64(index * 2 + keyIndex),
                        mediaJson: mediaJson(for: reference, sourceEpochKey: key, rawSourceEpoch: rawEpoch)
                    )
                }
            },
            hasMoreBefore: false,
            hasMoreAfter: false
        )

        let messages = MessageItem.timeline(from: page, activeAccountIdHex: "self")

        #expect(messages.count == invalidEpochs.count * 2)
        #expect(messages.allSatisfy { $0.mediaAttachments.count == 1 })
        #expect(messages.allSatisfy { $0.mediaAttachments.first?.reference.sourceEpoch == 0 })
    }

    @MainActor
    @Test func booleanMediaJSONStringFieldsDoNotFabricateAttachmentReference() async throws {
        // Regression for whitenoise-mac#246: JSON booleans bridge back from
        // JSONSerialization as CFBoolean-backed NSNumber values. Required string fields
        // must reject them instead of accepting NSNumber.stringValue ("1"/"0").
        let page = TimelinePageFfi(
            messages: [
                timelineMessage(
                    id: "boolean-media-json-fields",
                    groupIdHex: "group",
                    sender: "alice",
                    plaintext: "",
                    recordedAt: 1_700_000_000,
                    mediaJson: mediaJSONString(fromJSONObject: [
                        "ciphertext_sha256": true,
                        "plaintext_sha256": true,
                        "nonce": true,
                        "file_name": true,
                        "media_type": true,
                        "version": true,
                        "locators": [
                            ["kind": "blossom", "value": "https://blob.example/bool"]
                        ],
                    ])
                )
            ],
            hasMoreBefore: false,
            hasMoreAfter: false
        )

        let messages = MessageItem.timeline(from: page, activeAccountIdHex: "self")
        let message = try #require(messages.first)

        #expect(message.mediaAttachments.isEmpty)
    }

    @MainActor
    @Test func directMediaJSONLocatorKeepsValidSiblingsWhenMalformedElementPresent() async throws {
        // Regression for whitenoise-mac#364: a single malformed locator sibling must not
        // make the direct-reference JSON parser drop every valid locator in the array.
        let reference = mediaAttachmentReference(mediaType: "image/png", fileName: "photo.png")
        let page = TimelinePageFfi(
            messages: [
                timelineMessage(
                    id: "mixed-locator-elements",
                    groupIdHex: "group",
                    sender: "alice",
                    plaintext: "",
                    recordedAt: 1_700_000_000,
                    mediaJson: mediaJSONString(fromJSONObject: [
                        "ciphertext_sha256": reference.ciphertextSha256,
                        "plaintext_sha256": reference.plaintextSha256,
                        "nonce": reference.nonceHex,
                        "file_name": reference.fileName,
                        "media_type": reference.mediaType,
                        "version": mediaVersionJSONString(reference.version),
                        "locators": [
                            ["kind": "blossom", "value": "https://blob.example/valid"],
                            0,
                        ] as [Any],
                    ])
                )
            ],
            hasMoreBefore: false,
            hasMoreAfter: false
        )

        let messages = MessageItem.timeline(from: page, activeAccountIdHex: "self")
        let message = try #require(messages.first)
        let attachment = try #require(message.mediaAttachments.first)
        let locator = try #require(attachment.reference.locators.first)

        #expect(message.mediaAttachments.count == 1)
        #expect(attachment.reference.locators.count == 1)
        #expect(locator.kind == "blossom")
        #expect(locator.value == "https://blob.example/valid")
    }

    @MainActor
    @Test func directMediaJSONCapsWideLocatorArrays() async throws {
        // Regression for whitenoise-mac#629: attachment count is capped, but a single direct
        // JSON reference must also bound its `locators` array so one attachment cannot retain
        // an unbounded locator list for equality and rendering.
        let cap = OutgoingMediaDraftProcessor.maxAttachmentCount
        let reference = mediaAttachmentReference(mediaType: "image/png", fileName: "photo.png")
        let locators: [[String: String]] = (0..<(cap + 15)).map { index in
            ["kind": "blossom", "value": "https://blob.example/locator-\(index)"]
        }
        let page = TimelinePageFfi(
            messages: [
                timelineMessage(
                    id: "wide-direct-locators",
                    groupIdHex: "group",
                    sender: "alice",
                    plaintext: "",
                    recordedAt: 1_700_000_000,
                    mediaJson: mediaJSONString(fromJSONObject: [
                        "ciphertext_sha256": reference.ciphertextSha256,
                        "plaintext_sha256": reference.plaintextSha256,
                        "nonce": reference.nonceHex,
                        "file_name": reference.fileName,
                        "media_type": reference.mediaType,
                        "version": mediaVersionJSONString(reference.version),
                        "locators": locators,
                    ])
                )
            ],
            hasMoreBefore: false,
            hasMoreAfter: false
        )

        let messages = MessageItem.timeline(from: page, activeAccountIdHex: "self")
        let message = try #require(messages.first)
        let attachment = try #require(message.mediaAttachments.first)

        #expect(message.mediaAttachments.count == 1)
        #expect(attachment.reference.locators.count == cap)
        #expect(
            attachment.reference.locators.map(\.value)
                == (0..<cap).map { "https://blob.example/locator-\($0)" }
        )
    }

    @MainActor
    @Test func imetaFallbackCapsWideLocatorFields() async throws {
        // Regression for whitenoise-mac#629: excess `locator` imeta fields must be capped
        // without dropping the attachment when required fields follow the wide locator run.
        let cap = OutgoingMediaDraftProcessor.maxAttachmentCount
        let reference = mediaAttachmentReference(mediaType: "image/png", fileName: "photo.png")
        var tagValues = ["imeta"]
        tagValues.append(
            contentsOf: (0..<(cap + 15)).map { index in
                "locator blossom https://blob.example/locator-\(index)"
            }
        )
        tagValues.append(contentsOf: [
            "ciphertext_sha256 \(reference.ciphertextSha256)",
            "plaintext_sha256 \(reference.plaintextSha256)",
            "nonce \(reference.nonceHex)",
            "filename \(reference.fileName)",
            "m \(reference.mediaType)",
            "v \(mediaVersionJSONString(reference.version))",
        ])
        let page = TimelinePageFfi(
            messages: [
                timelineMessage(
                    id: "wide-imeta-locators",
                    groupIdHex: "group",
                    sender: "alice",
                    plaintext: "",
                    tags: [MessageTagFfi(values: tagValues)],
                    recordedAt: 1_700_000_000
                )
            ],
            hasMoreBefore: false,
            hasMoreAfter: false
        )

        let messages = MessageItem.timeline(from: page, activeAccountIdHex: "self")
        let message = try #require(messages.first)
        let attachment = try #require(message.mediaAttachments.first)

        #expect(message.mediaAttachments.count == 1)
        #expect(attachment.reference.locators.count == cap)
        #expect(
            attachment.reference.locators.map(\.value)
                == (0..<cap).map { "https://blob.example/locator-\($0)" }
        )
        #expect(attachment.reference.fileName == reference.fileName)
    }

    @MainActor
    @Test func directMediaJSONBoundsFallbackLocatorUTF8Bytes() async throws {
        // Regression for whitenoise-mac#673: reject oversized locators whole; limits are UTF-8 bytes.
        let twoByte = "é"
        let boundaryKind = String(repeating: twoByte, count: 32)
        let overKind = String(repeating: twoByte, count: 33)
        let boundaryValue = String(repeating: twoByte, count: 1024)
        let overValue = String(repeating: twoByte, count: 1025)
        #expect(boundaryKind.utf8.count == 64)
        #expect(overKind.utf8.count == 66)
        #expect(boundaryValue.utf8.count == 2048)
        #expect(overValue.utf8.count == 2050)

        let reference = mediaAttachmentReference(mediaType: "image/png", fileName: "photo.png")
        let page = TimelinePageFfi(
            messages: [
                timelineMessage(
                    id: "bounded-direct-locators",
                    groupIdHex: "group",
                    sender: "alice",
                    plaintext: "",
                    recordedAt: 1_700_000_000,
                    mediaJson: mediaJSONString(fromJSONObject: [
                        "ciphertext_sha256": reference.ciphertextSha256,
                        "plaintext_sha256": reference.plaintextSha256,
                        "nonce": reference.nonceHex,
                        "file_name": reference.fileName,
                        "media_type": reference.mediaType,
                        "version": mediaVersionJSONString(reference.version),
                        "locators": [
                            ["kind": overKind, "value": "https://blob.example/over-kind"],
                            ["kind": "blossom", "value": overValue],
                            ["kind": boundaryKind, "value": boundaryValue],
                            ["kind": "blossom", "value": "https://blob.example/valid"],
                        ],
                    ])
                )
            ],
            hasMoreBefore: false,
            hasMoreAfter: false
        )

        let messages = MessageItem.timeline(from: page, activeAccountIdHex: "self")
        let message = try #require(messages.first)
        let attachment = try #require(message.mediaAttachments.first)

        #expect(message.mediaAttachments.count == 1)
        #expect(attachment.reference.locators.count == 2)
        #expect(attachment.reference.locators[0].kind == boundaryKind)
        #expect(attachment.reference.locators[0].value == boundaryValue)
        #expect(attachment.reference.locators[1].kind == "blossom")
        #expect(attachment.reference.locators[1].value == "https://blob.example/valid")
    }

    @MainActor
    @Test func imetaFallbackBoundsLocatorUTF8Bytes() async throws {
        // Regression for whitenoise-mac#673: same locator bounds for imeta fallback parsing.
        let twoByte = "é"
        let boundaryKind = String(repeating: twoByte, count: 32)
        let overKind = String(repeating: twoByte, count: 33)
        let boundaryValue = String(repeating: twoByte, count: 1024)
        let overValue = String(repeating: twoByte, count: 1025)
        #expect(boundaryKind.utf8.count == 64)
        #expect(overKind.utf8.count == 66)
        #expect(boundaryValue.utf8.count == 2048)
        #expect(overValue.utf8.count == 2050)

        let reference = mediaAttachmentReference(mediaType: "image/png", fileName: "photo.png")
        let page = TimelinePageFfi(
            messages: [
                timelineMessage(
                    id: "bounded-imeta-locators",
                    groupIdHex: "group",
                    sender: "alice",
                    plaintext: "",
                    tags: [
                        MessageTagFfi(values: [
                            "imeta",
                            "locator \(overKind) https://blob.example/over-kind",
                            "locator blossom \(overValue)",
                            "locator \(boundaryKind) \(boundaryValue)",
                            "locator blossom https://blob.example/valid",
                            "ciphertext_sha256 \(reference.ciphertextSha256)",
                            "plaintext_sha256 \(reference.plaintextSha256)",
                            "nonce \(reference.nonceHex)",
                            "filename \(reference.fileName)",
                            "m \(reference.mediaType)",
                            "v \(mediaVersionJSONString(reference.version))",
                        ])
                    ],
                    recordedAt: 1_700_000_000
                )
            ],
            hasMoreBefore: false,
            hasMoreAfter: false
        )

        let messages = MessageItem.timeline(from: page, activeAccountIdHex: "self")
        let message = try #require(messages.first)
        let attachment = try #require(message.mediaAttachments.first)

        #expect(message.mediaAttachments.count == 1)
        #expect(attachment.reference.locators.count == 2)
        #expect(attachment.reference.locators[0].kind == boundaryKind)
        #expect(attachment.reference.locators[0].value == boundaryValue)
        #expect(attachment.reference.locators[1].kind == "blossom")
        #expect(attachment.reference.locators[1].value == "https://blob.example/valid")
        #expect(attachment.reference.fileName == reference.fileName)
    }

    @MainActor
    @Test func booleanMediaJSONStringAliasValuesFallThroughAndBadLocatorsAreDropped() async throws {
        // `string(_:keys:)` searches aliases in order. A boolean at an earlier alias
        // should be treated as malformed for that key, not as "1" and not as a reason
        // to reject a later valid alias.
        let reference = mediaAttachmentReference(mediaType: "image/png", fileName: "photo.png")
        let page = TimelinePageFfi(
            messages: [
                timelineMessage(
                    id: "boolean-media-json-aliases",
                    groupIdHex: "group",
                    sender: "alice",
                    plaintext: "",
                    recordedAt: 1_700_000_000,
                    mediaJson: mediaJSONString(fromJSONObject: [
                        "ciphertext_sha256": true,
                        "ciphertextSha256": reference.ciphertextSha256,
                        "plaintext_sha256": true,
                        "plaintextSha256": reference.plaintextSha256,
                        "nonce_hex": true,
                        "nonceHex": true,
                        "nonce": reference.nonceHex,
                        "file_name": true,
                        "fileName": true,
                        "filename": reference.fileName,
                        "media_type": true,
                        "mediaType": true,
                        "m": reference.mediaType,
                        "version": true,
                        "v": mediaVersionJSONString(reference.version),
                        "dim": true,
                        "thumbhash": true,
                        "locators": [
                            ["kind": true, "value": "https://blob.example/bad-kind"],
                            ["kind": "blossom", "value": true],
                            ["kind": "blossom", "value": "https://blob.example/valid"],
                        ],
                    ])
                )
            ],
            hasMoreBefore: false,
            hasMoreAfter: false
        )

        let messages = MessageItem.timeline(from: page, activeAccountIdHex: "self")
        let message = try #require(messages.first)
        let attachment = try #require(message.mediaAttachments.first)
        let locator = try #require(attachment.reference.locators.first)

        #expect(message.mediaAttachments.count == 1)
        #expect(attachment.reference.ciphertextSha256 == reference.ciphertextSha256)
        #expect(attachment.reference.plaintextSha256 == reference.plaintextSha256)
        #expect(attachment.reference.nonceHex == reference.nonceHex)
        #expect(attachment.reference.fileName == reference.fileName)
        #expect(attachment.reference.mediaType == reference.mediaType)
        #expect(attachment.reference.version == reference.version)
        #expect(attachment.reference.dim == nil)
        #expect(attachment.reference.thumbhash == nil)
        #expect(attachment.reference.locators.count == 1)
        #expect(locator.kind == "blossom")
        #expect(locator.value == "https://blob.example/valid")
    }

    @MainActor
    @Test func mediaJSONObjectWithIMetaAndFlatKeysMapsSingleAttachment() async throws {
        // Regression for whitenoise-mac#185: a single peer-controlled object carrying
        // both an `imeta` array and the flat direct-reference keys must not emit both the
        // imeta-derived reference and a separate direct reference for the same logical
        // attachment. Object branches are mutually exclusive (`imeta`, else `media`, else
        // flat), so the object maps to exactly one attachment instead of rendering twice.
        let reference = mediaAttachmentReference(mediaType: "image/png", fileName: "photo.png")
        let page = TimelinePageFfi(
            messages: [
                timelineMessage(
                    id: "imeta-and-flat",
                    groupIdHex: "group",
                    sender: "alice",
                    plaintext: "",
                    recordedAt: 1_700_000_000,
                    mediaJson: mediaJsonWithIMetaAndFlatKeys(for: reference)
                )
            ],
            hasMoreBefore: false,
            hasMoreAfter: false
        )

        let messages = MessageItem.timeline(from: page, activeAccountIdHex: "self")
        let message = try #require(messages.first)

        #expect(message.mediaAttachments.count == 1)
        #expect(message.mediaAttachments.first?.reference.plaintextSha256 == reference.plaintextSha256)
        #expect(message.mediaAttachments.first?.reference.fileName == reference.fileName)
    }

    @Test func mediaGridRowCountsMatchFlutterLayout() {
        #expect(MessageMediaGridPresentation.rowCounts(totalCount: 0) == [])
        #expect(MessageMediaGridPresentation.rowCounts(totalCount: 1) == [1])
        #expect(MessageMediaGridPresentation.rowCounts(totalCount: 2) == [2])
        #expect(MessageMediaGridPresentation.rowCounts(totalCount: 3) == [3])
        #expect(MessageMediaGridPresentation.rowCounts(totalCount: 4) == [2, 2])
        #expect(MessageMediaGridPresentation.rowCounts(totalCount: 5) == [3, 2])
        #expect(MessageMediaGridPresentation.rowCounts(totalCount: 6) == [3, 3])
        #expect(MessageMediaGridPresentation.rowCounts(totalCount: 20) == [3, 3])
        #expect(MessageMediaGridPresentation.rowCounts(totalCount: -1) == [])
    }

    @Test func mediaGridOverflowBadgeStartsAtSeven() {
        #expect(MessageMediaGridPresentation.visibleCount(totalCount: 6) == 6)
        #expect(MessageMediaGridPresentation.hiddenCount(totalCount: 6) == 0)
        #expect(MessageMediaGridPresentation.visibleCount(totalCount: 7) == 6)
        #expect(MessageMediaGridPresentation.hiddenCount(totalCount: 7) == 1)
        #expect(MessageMediaGridPresentation.hiddenCount(totalCount: 0) == 0)
        // rowCounts always sums to visibleCount — no short rows, ever.
        for total in 0...12 {
            #expect(
                MessageMediaGridPresentation.rowCounts(totalCount: total).reduce(0, +)
                    == MessageMediaGridPresentation.visibleCount(totalCount: total)
            )
        }
    }

    @Test func mediaGridRowRangesPartitionTheVisibleAttachments() {
        #expect(MessageMediaGridPresentation.rowRanges(totalCount: 0) == [])
        #expect(MessageMediaGridPresentation.rowRanges(totalCount: 1) == [0..<1])
        #expect(MessageMediaGridPresentation.rowRanges(totalCount: 2) == [0..<2])
        #expect(MessageMediaGridPresentation.rowRanges(totalCount: 3) == [0..<3])
        #expect(MessageMediaGridPresentation.rowRanges(totalCount: 4) == [0..<2, 2..<4])
        #expect(MessageMediaGridPresentation.rowRanges(totalCount: 5) == [0..<3, 3..<5])
        #expect(MessageMediaGridPresentation.rowRanges(totalCount: 6) == [0..<3, 3..<6])
        #expect(MessageMediaGridPresentation.rowRanges(totalCount: 9) == [0..<3, 3..<6])

        // Contiguous from 0 and covering exactly the visible prefix: every visible tile is
        // placed once, and no range can ever run past `visibleAttachments`.
        for total in 0...12 {
            let ranges = MessageMediaGridPresentation.rowRanges(totalCount: total)
            let visible = MessageMediaGridPresentation.visibleCount(totalCount: total)
            #expect((ranges.first?.lowerBound ?? 0) == 0)
            #expect((ranges.last?.upperBound ?? 0) == visible)
            #expect(ranges.allSatisfy { !$0.isEmpty })
            for (previous, next) in zip(ranges, ranges.dropFirst()) {
                #expect(previous.upperBound == next.lowerBound)
            }
        }
    }

    @Test func mediaGridTileSidesAreSquareAndFillTheWidth() {
        #expect(MessageMediaGridPresentation.tileSide(rowCount: 1, maxWidth: 360, spacing: 3) == 360)
        #expect(MessageMediaGridPresentation.tileSide(rowCount: 2, maxWidth: 360, spacing: 3) == 178.5)
        #expect(MessageMediaGridPresentation.tileSide(rowCount: 3, maxWidth: 360, spacing: 3) == 118)
        #expect(MessageMediaGridPresentation.tileSide(rowCount: 0, maxWidth: 360, spacing: 3) == 1)

        #expect(MessageMediaGridPresentation.gridHeight(totalCount: 0, maxWidth: 360, spacing: 3) == 0)
        #expect(MessageMediaGridPresentation.gridHeight(totalCount: 1, maxWidth: 360, spacing: 3) == 360)
        #expect(MessageMediaGridPresentation.gridHeight(totalCount: 2, maxWidth: 360, spacing: 3) == 178.5)
        #expect(MessageMediaGridPresentation.gridHeight(totalCount: 3, maxWidth: 360, spacing: 3) == 118)
        #expect(MessageMediaGridPresentation.gridHeight(totalCount: 4, maxWidth: 360, spacing: 3) == 360)
        #expect(MessageMediaGridPresentation.gridHeight(totalCount: 5, maxWidth: 360, spacing: 3) == 299.5)
        #expect(MessageMediaGridPresentation.gridHeight(totalCount: 6, maxWidth: 360, spacing: 3) == 239)
    }

    @MainActor
    @Test func messageItemPrecomputesBubbleRenderContent() async throws {
        let image = MessageMediaAttachment(
            id: "image",
            reference: mediaAttachmentReference(mediaType: "image/png", fileName: "photo.png")
        )
        let audio = MessageMediaAttachment(
            id: "audio",
            reference: mediaAttachmentReference(mediaType: "audio/mp4", fileName: "clip.m4a")
        )
        let video = MessageMediaAttachment(
            id: "video",
            reference: mediaAttachmentReference(mediaType: "video/mp4", fileName: "clip.mp4")
        )
        let file = MessageMediaAttachment(
            id: "file",
            reference: mediaAttachmentReference(mediaType: "application/pdf", fileName: "notes.pdf")
        )
        let replyContext = MessageReplyContext(
            targetMessageId: "parent",
            senderName: "Alice",
            body: "Earlier note"
        )

        let message = MessageItem(
            id: "mixed-media",
            senderName: "Bob",
            body: "  Render once  ",
            sentAt: Date(timeIntervalSince1970: 1_800_000_000),
            isOutgoing: false,
            replyContext: replyContext,
            mediaAttachments: [image, audio, video, file]
        )

        #expect(message.trimmedBody == "Render once")
        #expect(message.hasBubbleContent)
        #expect(message.visualMediaAttachments.map(\.id) == ["image", "video"])
        #expect(message.nonvisualMediaAttachments.map(\.id) == ["audio", "file"])

        let attachmentOnly = MessageItem(
            id: "attachment-only",
            senderName: "Bob",
            body: "  \n  ",
            sentAt: Date(timeIntervalSince1970: 1_800_000_001),
            isOutgoing: false,
            mediaAttachments: [image]
        )
        #expect(attachmentOnly.trimmedBody.isEmpty)
        #expect(!attachmentOnly.hasBubbleContent)
        #expect(attachmentOnly.replyPreviewText == "Photo")
        #expect(!attachmentOnly.canCopyText)
    }

    @MainActor
    @Test func incomingNonDecodableImageAttachmentIsClassifiedAsFileNotVisualMedia() async throws {
        let svg = MessageMediaAttachment(
            id: "svg",
            reference: mediaAttachmentReference(mediaType: "image/svg+xml", fileName: "diagram.svg")
        )
        let png = MessageMediaAttachment(
            id: "png",
            reference: mediaAttachmentReference(mediaType: "image/png", fileName: "photo.png")
        )

        #expect(svg.kind == .file)
        #expect(png.kind == .image)

        let message = MessageItem(
            id: "svg-media",
            senderName: "Bob",
            body: "",
            sentAt: Date(timeIntervalSince1970: 1_800_000_002),
            isOutgoing: false,
            mediaAttachments: [svg, png]
        )

        #expect(message.visualMediaAttachments.map(\.id) == ["png"])
        #expect(message.nonvisualMediaAttachments.map(\.id) == ["svg"])
    }

    @Test func pendingMediaAttachmentDurationLabelFormatsSubhourHourBoundaryAndClampsNegative() {
        let longAttachment = PendingMediaAttachment(
            fileName: "long.m4a",
            mediaType: "audio/mp4",
            data: Data(),
            dim: nil,
            durationSeconds: 4_500.9
        )
        let shortAttachment = PendingMediaAttachment(
            fileName: "short.m4a",
            mediaType: "audio/mp4",
            data: Data(),
            dim: nil,
            durationSeconds: 65.9
        )
        let negativeAttachment = PendingMediaAttachment(
            fileName: "negative.m4a",
            mediaType: "audio/mp4",
            data: Data(),
            dim: nil,
            durationSeconds: -2
        )

        #expect(longAttachment.durationLabel == "1:15:00")
        #expect(shortAttachment.durationLabel == "1:05")
        #expect(negativeAttachment.durationLabel == "0:00")
        #expect(MediaDurationLabel.string(for: 3_599) == "59:59")
        #expect(MediaDurationLabel.string(for: 3_600) == "1:00:00")
    }

    @MainActor
    @Test func deeplyNestedMediaJSONDoesNotProduceAttachments() async throws {
        // Regression for whitenoise-mac#120: mediaJson is decrypted peer content.
        // Overly deep objects/arrays must be ignored instead of recursively walking
        // attacker-controlled nesting on the timeline mapping path.
        let reference = mediaAttachmentReference(mediaType: "image/png", fileName: "nested.png")
        let page = TimelinePageFfi(
            messages: [
                timelineMessage(
                    id: "deep-media-objects",
                    groupIdHex: "group",
                    sender: "alice",
                    plaintext: "",
                    recordedAt: 1_700_000_000,
                    mediaJson: mediaJson(for: reference, mediaObjectDepth: 40)
                ),
                timelineMessage(
                    id: "deep-media-arrays",
                    groupIdHex: "group",
                    sender: "alice",
                    plaintext: "",
                    recordedAt: 1_700_000_001,
                    mediaJson: mediaJson(for: reference, arrayDepth: 40)
                ),
            ],
            hasMoreBefore: false,
            hasMoreAfter: false
        )

        let messages = MessageItem.timeline(from: page, activeAccountIdHex: "self")

        #expect(messages.count == 2)
        #expect(messages.allSatisfy { $0.mediaAttachments.isEmpty })
        #expect(messages.allSatisfy { $0.body == "Unsupported message" })
    }

    @MainActor
    @Test func deeplyNestedTimelinePayloadJSONFallsBackWithoutDecoding() async throws {
        // Regression for whitenoise-mac#403: agent/group-system plaintext JSON is peer content.
        // Overly deep nesting must be rejected before JSONDecoder runs on the timeline path.
        let deepActivityJSON = timelinePayloadJSONWithNesting(
            inner: ["v": 1, "text": "Thinking"],
            objectDepth: 40
        )
        let deepOperationJSON = timelinePayloadJSONWithNesting(
            inner: ["v": 1, "event_type": "tool_call", "preview": "glp-1"],
            objectDepth: 40
        )
        let deepSystemJSON = timelinePayloadJSONWithNesting(
            inner: ["v": 1, "system_type": "group_renamed", "text": "Group renamed"],
            objectDepth: 40
        )
        let page = TimelinePageFfi(
            messages: [
                timelineMessage(
                    id: "deep-activity",
                    groupIdHex: "group",
                    sender: "agent",
                    plaintext: deepActivityJSON,
                    kind: 1201,
                    recordedAt: 1_700_000_000
                ),
                timelineMessage(
                    id: "deep-operation",
                    groupIdHex: "group",
                    sender: "agent",
                    plaintext: deepOperationJSON,
                    kind: 1202,
                    recordedAt: 1_700_000_001
                ),
                timelineMessage(
                    id: "deep-system",
                    groupIdHex: "group",
                    sender: "",
                    plaintext: deepSystemJSON,
                    kind: 1210,
                    recordedAt: 1_700_000_002
                ),
                timelineMessage(
                    id: "shallow-activity",
                    groupIdHex: "group",
                    sender: "agent",
                    plaintext: #"{"v":1,"text":"Thinking"}"#,
                    kind: 1201,
                    recordedAt: 1_700_000_003
                ),
            ],
            hasMoreBefore: false,
            hasMoreAfter: false
        )

        let messages = MessageItem.timeline(from: page, activeAccountIdHex: "self")

        #expect(messages.count == 4)
        #expect(messages[0].body == deepActivityJSON)
        #expect(messages[1].body == deepOperationJSON)
        #expect(messages[2].body == deepSystemJSON)
        #expect(messages[3].body == "Thinking")
    }

    @MainActor
    @Test func boundedNestedMediaJSONStillProducesAttachments() async throws {
        // Base helper shape is object + imeta array + tag array, so 29 wrappers
        // reaches the current raw nesting limit of 32 without exceeding it.
        let reference = mediaAttachmentReference(
            mediaType: "image/png",
            fileName: "bounded-[literal-{brackets}].png"
        )
        let page = TimelinePageFfi(
            messages: [
                timelineMessage(
                    id: "bounded-media-objects",
                    groupIdHex: "group",
                    sender: "alice",
                    plaintext: "",
                    recordedAt: 1_700_000_002,
                    mediaJson: mediaJson(for: reference, mediaObjectDepth: 29)
                ),
                timelineMessage(
                    id: "bounded-media-arrays",
                    groupIdHex: "group",
                    sender: "alice",
                    plaintext: "",
                    recordedAt: 1_700_000_003,
                    mediaJson: mediaJson(for: reference, arrayDepth: 29)
                ),
            ],
            hasMoreBefore: false,
            hasMoreAfter: false
        )

        let messages = MessageItem.timeline(from: page, activeAccountIdHex: "self")

        #expect(messages.count == 2)
        #expect(messages.allSatisfy { $0.body.isEmpty })
        #expect(messages.allSatisfy { $0.mediaAttachments.count == 1 })
        #expect(messages.allSatisfy { $0.mediaAttachments.first?.reference.fileName == reference.fileName })
    }

    @MainActor
    @Test func workspaceDownloadsMediaAttachmentAndCachesResult() async throws {
        let account = AccountSummaryFfi(
            label: "Desktop Account",
            accountIdHex: "abcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890",
            localSigning: true,
            externalSigning: false,
            signedOut: false,
            running: false
        )
        let timelineReference = mediaAttachmentReference(sourceEpoch: 0, mediaType: "audio/mp4", fileName: "voice.m4a")
        let fullReference = mediaAttachmentReference(sourceEpoch: 7, mediaType: "audio/mp4", fileName: "voice.m4a")
        let download = MediaDownloadResultFfi(
            plaintext: Data([0x00, 0x01, 0x02, 0x03]),
            fileName: "voice.m4a",
            mediaType: "audio/mp4",
            sizeBytes: 4
        )
        let runtime = FakeMarmotRuntime(accounts: [account])
        runtime.installGroup(messageGroup())
        runtime.installMediaRecord(
            MediaRecordFfi(
                messageIdHex: "media-message",
                attachmentIndex: 0,
                direction: "inbound",
                groupIdHex: "group",
                sender: "alice",
                reference: fullReference,
                caption: nil,
                recordedAt: 1_700_000_000,
                receivedAt: 1_700_000_000
            ),
            download: download
        )
        let state = WorkspaceState(clientFactory: { runtime })
        await state.bootstrap()
        state.selection = .chat("group")
        let message = MessageItem(
            id: "media-message",
            groupIdHex: "group",
            senderName: "Alice",
            body: "",
            sentAt: Date(timeIntervalSince1970: 1_700_000_000),
            isOutgoing: false,
            mediaAttachments: [
                MessageMediaAttachment(
                    id: "media-message#0#\(timelineReference.plaintextSha256)",
                    reference: timelineReference
                )
            ]
        )
        let attachment = try #require(message.mediaAttachments.first)
        state.replaceMessages([message], groupIdHex: "group")

        await state.loadMediaAttachment(attachment, for: message)
        let stateAfterFirstLoad = state.mediaDownloadState(for: message, attachment: attachment)

        guard case .loaded(let loaded) = stateAfterFirstLoad else {
            Issue.record("Expected media download to load")
            return
        }
        #expect(loaded.data == download.plaintext)
        #expect(runtime.listMediaCallCount == 1)
        #expect(runtime.downloadMediaCallCount == 1)

        await state.loadMediaAttachment(attachment, for: message)

        #expect(runtime.listMediaCallCount == 1)
        #expect(runtime.downloadMediaCallCount == 1)
    }

    @MainActor
    @Test func mediaDownloadDestinationKeepsTheGrantWhenOnlyDisplayReadsFail() throws {
        // The Settings row reads the stored folder every time the pane opens. A folder whose
        // volume is merely unmounted resolves again once it is back, so a read for display must
        // never be what costs the user the grant they gave.
        let suiteName = "whitenoise.mac.tests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let key = "whitenoise.mac.mediaDownloadDestinationBookmark"
        // Not a bookmark at all — resolution throws, which is the failure both paths see.
        defaults.set(Data([0x00, 0x01, 0x02, 0x03]), forKey: key)
        let store = UserDefaultsMediaDownloadDestinationStore(defaults: defaults)

        #expect(store.storedDestinationURL == nil)
        #expect(defaults.data(forKey: key) != nil)

        // The download path is the one place a dead grant actually blocks a write, so that is
        // where it is discarded and the user is asked again.
        #expect(store.resolveDestination()?.url == nil)
        #expect(defaults.data(forKey: key) == nil)
    }

    @MainActor
    @Test func mediaDownloadDestinationForgetsTheOldFolderWhenTheNewOneCannotBePersisted() throws {
        // Changing the folder in Settings and having the write fail must not leave the previous
        // folder in place: the next download would go there silently, which is the one folder the
        // user has just said no to. Nothing stored means the panel asks, which is the safe answer.
        let suiteName = "whitenoise.mac.tests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let key = "whitenoise.mac.mediaDownloadDestinationBookmark"
        let store = UserDefaultsMediaDownloadDestinationStore(defaults: defaults)

        let folder = try uniqueTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        store.store(folder)
        #expect(defaults.data(forKey: key) != nil)

        // A folder that is gone by the time it is bookmarked: `bookmarkData` throws, which is the
        // failure the panel's own grant cannot help with.
        let replacement = try uniqueTemporaryDirectory()
        try FileManager.default.removeItem(at: replacement)
        store.store(replacement)

        #expect(defaults.data(forKey: key) == nil)
        #expect(store.storedDestinationURL == nil)
        #expect(store.resolveDestination()?.url == nil)
    }

    @Test func mediaFileDownloaderSanitizesRemoteAttachmentNames() {
        // File names arrive over the wire, so they are treated as one path component and nothing
        // more: no escaping the destination folder, no invisible dotfiles, no HFS separators.
        #expect(MediaFileDownloader.sanitizedFileName("photo.jpg") == "photo.jpg")
        #expect(MediaFileDownloader.sanitizedFileName("../../etc/passwd") == "passwd")
        #expect(MediaFileDownloader.sanitizedFileName(".hidden.png") == "hidden.png")
        #expect(MediaFileDownloader.sanitizedFileName("Q3:report.pdf") == "Q3-report.pdf")
        #expect(MediaFileDownloader.sanitizedFileName("   ") == MediaFileDownloader.fallbackFileName)
        #expect(MediaFileDownloader.sanitizedFileName("..") == MediaFileDownloader.fallbackFileName)
    }

    @Test func mediaFileDownloaderCapsMultibyteNamesByBytesNotCharacters() {
        // APFS counts a path component in UTF-8 bytes, so a name of emoji or CJK hits the 255-byte
        // ceiling four and three times faster than its character count suggests. A cap measured in
        // characters would let this through and the write would fail with ENAMETOOLONG.
        let ceiling = 255
        let emoji = String(repeating: "😀", count: 300) + ".jpg"
        let sanitized = MediaFileDownloader.sanitizedFileName(emoji)
        #expect(sanitized.utf8.count <= ceiling)
        #expect(sanitized.hasSuffix(".jpg"))
        // Characters are kept whole — a half-written scalar is not a name.
        #expect(!sanitized.contains("\u{FFFD}"))
        #expect(sanitized.dropLast(4).allSatisfy { $0 == "😀" })

        let cjk = String(repeating: "文", count: 400)
        let withoutExtension = MediaFileDownloader.sanitizedFileName(cjk)
        #expect(withoutExtension.utf8.count <= ceiling)
        #expect(withoutExtension.allSatisfy { $0 == "文" })

        // And the " N" suffix has to fit inside the same budget, not be bolted onto a name that
        // already fills it.
        var taken: Set<String> = [sanitized]
        let uniqued = MediaFileDownloader.uniqueFileName(for: emoji) { taken.contains($0) }
        #expect(uniqued != sanitized)
        #expect(uniqued.utf8.count <= ceiling)
        #expect(uniqued.hasSuffix(" 2.jpg"))
        taken.insert(uniqued)
        let third = MediaFileDownloader.uniqueFileName(for: emoji) { taken.contains($0) }
        #expect(third.utf8.count <= ceiling)
        #expect(third.hasSuffix(" 3.jpg"))
    }

    @Test func mediaFileDownloaderNeverOverwritesAnExistingFile() {
        // Two people sending `IMG_0001.jpg` must not silently replace each other's download.
        var taken: Set<String> = ["photo.jpg"]
        let second = MediaFileDownloader.uniqueFileName(for: "photo.jpg") { taken.contains($0) }
        #expect(second == "photo 2.jpg")
        taken.insert(second)
        #expect(MediaFileDownloader.uniqueFileName(for: "photo.jpg") { taken.contains($0) } == "photo 3.jpg")
        #expect(MediaFileDownloader.uniqueFileName(for: "notes") { taken.contains($0) } == "notes")
        taken.insert("notes")
        #expect(MediaFileDownloader.uniqueFileName(for: "notes") { taken.contains($0) } == "notes 2")
    }

    @MainActor
    @Test func downloadMediaAttachmentsWritesEveryAttachmentAndReportsTheCount() async throws {
        let folder = try uniqueTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let destination = FakeMediaDownloadDestination(storedURL: folder)
        let firstData = Data([0x01, 0x02, 0x03, 0x04])
        let secondData = Data([0x05, 0x06])
        let fixture = await mediaDownloadFixture(
            attachments: [
                (fileName: "photo.jpg", mediaType: "image/jpeg", data: firstData, isAvailable: true),
                (fileName: "notes.pdf", mediaType: "application/pdf", data: secondData, isAvailable: true),
            ],
            destination: destination
        )

        await fixture.state.downloadMediaAttachments(
            fixture.message.mediaAttachments, for: fixture.message)

        let feedback = try #require(fixture.state.mediaDownloadFeedback)
        #expect(feedback.savedCount == 2)
        #expect(feedback.failedCount == 0)
        #expect(!feedback.hasFailures)
        #expect(try Data(contentsOf: folder.appending(path: "photo.jpg")) == firstData)
        #expect(try Data(contentsOf: folder.appending(path: "notes.pdf")) == secondData)
        // An existing grant is used as-is: no panel, and nothing re-stored.
        #expect(destination.pickCallCount == 0)
        #expect(destination.storeCallCount == 0)
        // The gesture releases its per-message lock, so the button re-enables.
        #expect(!fixture.state.isDownloadingMediaAttachments(for: fixture.message))
        fixture.state.dismissMediaDownloadFeedback()
        #expect(fixture.state.mediaDownloadFeedback == nil)
    }

    @MainActor
    @Test func downloadMediaAttachmentsAsksForAFolderOnceAndRemembersIt() async throws {
        let folder = try uniqueTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        // Nothing stored yet, and the panel answers with `folder`.
        let destination = FakeMediaDownloadDestination(storedURL: nil, pickedURL: folder)
        let payload = Data([0x0A, 0x0B])
        let fixture = await mediaDownloadFixture(
            attachments: [(fileName: "photo.jpg", mediaType: "image/jpeg", data: payload, isAvailable: true)],
            destination: destination
        )

        await fixture.state.downloadMediaAttachments(
            fixture.message.mediaAttachments, for: fixture.message)

        #expect(destination.pickCallCount == 1)
        #expect(destination.storeCallCount == 1)
        #expect(destination.storedURL == folder)
        #expect(try Data(contentsOf: folder.appending(path: "photo.jpg")) == payload)
        // The chosen folder is what Storage settings shows.
        fixture.state.refreshMediaDownloadDestinationPath()
        #expect(fixture.state.mediaDownloadDestinationPath == folder.path(percentEncoded: false))

        await fixture.state.downloadMediaAttachments(
            fixture.message.mediaAttachments, for: fixture.message)

        // Second download: the grant is remembered, so the user is not asked again.
        #expect(destination.pickCallCount == 1)
        #expect(try Data(contentsOf: folder.appending(path: "photo 2.jpg")) == payload)
    }

    @MainActor
    @Test func downloadMediaAttachmentsAsksAgainWhenTheStoredFolderNoLongerResolves() async throws {
        let folder = try uniqueTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let destination = FakeMediaDownloadDestination(storedURL: folder, pickedURL: folder)
        // A grant that no longer opens: folder deleted, volume ejected, permissions revoked.
        destination.failsToResolve = true
        let fixture = await mediaDownloadFixture(
            attachments: [(fileName: "photo.jpg", mediaType: "image/jpeg", data: Data([0x2A]), isAvailable: true)],
            destination: destination
        )

        await fixture.state.downloadMediaAttachments(
            fixture.message.mediaAttachments, for: fixture.message)

        #expect(destination.pickCallCount == 1)
        let feedback = try #require(fixture.state.mediaDownloadFeedback)
        #expect(feedback.savedCount == 1)
    }

    @MainActor
    @Test func downloadMediaAttachmentsWritesNothingWhenTheFolderPanelIsCancelled() async throws {
        // Nothing stored, and the panel returns nil — the user closed it without choosing.
        let destination = FakeMediaDownloadDestination(storedURL: nil, pickedURL: nil)
        let fixture = await mediaDownloadFixture(
            attachments: [(fileName: "photo.jpg", mediaType: "image/jpeg", data: Data([0x01]), isAvailable: true)],
            destination: destination
        )

        await fixture.state.downloadMediaAttachments(
            fixture.message.mediaAttachments, for: fixture.message)

        #expect(destination.pickCallCount == 1)
        #expect(destination.storeCallCount == 0)
        // A cancelled panel is not a failure: no toast at all, not a "couldn't download" one.
        #expect(fixture.state.mediaDownloadFeedback == nil)
        #expect(!fixture.state.isDownloadingMediaAttachments(for: fixture.message))
    }

    @MainActor
    @Test func changeMediaDownloadDestinationStoresTheNewFolderAndKeepsItOnCancel() async throws {
        let folder = try uniqueTemporaryDirectory()
        let replacement = try uniqueTemporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: folder)
            try? FileManager.default.removeItem(at: replacement)
        }
        let destination = FakeMediaDownloadDestination(storedURL: folder, pickedURL: replacement)
        let fixture = await mediaDownloadFixture(attachments: [], destination: destination)

        fixture.state.changeMediaDownloadDestination()

        #expect(destination.storedURL == replacement)
        #expect(fixture.state.mediaDownloadDestinationPath == replacement.path(percentEncoded: false))

        // Cancelling the Settings panel must leave the folder that was already granted.
        destination.pickedURL = nil
        fixture.state.changeMediaDownloadDestination()

        #expect(destination.storedURL == replacement)
        #expect(fixture.state.mediaDownloadDestinationPath == replacement.path(percentEncoded: false))
    }

    @MainActor
    @Test func downloadMediaAttachmentsReportsAttachmentsItCouldNotFetch() async throws {
        let folder = try uniqueTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let destination = FakeMediaDownloadDestination(storedURL: folder)
        let available = Data([0x11, 0x22])
        let fixture = await mediaDownloadFixture(
            attachments: [
                (fileName: "photo.jpg", mediaType: "image/jpeg", data: available, isAvailable: true),
                (fileName: "gone.jpg", mediaType: "image/jpeg", data: Data([0x33]), isAvailable: false),
            ],
            destination: destination
        )

        await fixture.state.downloadMediaAttachments(
            fixture.message.mediaAttachments, for: fixture.message)

        let feedback = try #require(fixture.state.mediaDownloadFeedback)
        #expect(feedback.savedCount == 1)
        #expect(feedback.failedCount == 1)
        #expect(feedback.hasFailures)
        #expect(try Data(contentsOf: folder.appending(path: "photo.jpg")) == available)
        #expect(!FileManager.default.fileExists(atPath: folder.appending(path: "gone.jpg").path))
    }

    @MainActor
    @Test func downloadMediaAttachmentsReportsFailureWhenTheFolderCannotBeWritten() async throws {
        let folder = try uniqueTemporaryDirectory()
        // A regular file where the folder should be: `createDirectory` and the write both fail.
        let blocked = folder.appending(path: "not-a-folder")
        try Data([0x00]).write(to: blocked)
        defer { try? FileManager.default.removeItem(at: folder) }
        let destination = FakeMediaDownloadDestination(storedURL: blocked)
        let fixture = await mediaDownloadFixture(
            attachments: [(fileName: "photo.jpg", mediaType: "image/jpeg", data: Data([0x01]), isAvailable: true)],
            destination: destination
        )

        await fixture.state.downloadMediaAttachments(
            fixture.message.mediaAttachments, for: fixture.message)

        let feedback = try #require(fixture.state.mediaDownloadFeedback)
        #expect(feedback.savedCount == 0)
        #expect(feedback.failedCount == 1)
    }

    @MainActor
    @Test func mediaDownloadWriterNeverOverwritesAFileItDidNotCreate() async throws {
        // The actor orders the app's own writes, but the chosen folder is one other apps write to
        // as well — a browser finishing its own `photo.jpg` in the window between this writer
        // checking the name and creating the file. `RacingFileManager` is that window: it reports
        // the name free and creates it before the answer is used, which is what a check-then-write
        // cannot survive and an exclusive create can.
        let folder = try uniqueTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let intruder = RacingFileManager.intruder
        let racing = RacingFileManager()

        let written = try await MediaDownloadWriter.shared.write(
            Data([0x02]), fileName: "photo.jpg", into: folder, fileManager: racing)

        #expect(racing.plantedPath != nil)
        // The download stepped to the next name rather than replacing the file it lost the race to.
        #expect(written.lastPathComponent != "photo.jpg")
        #expect(try Data(contentsOf: folder.appending(path: "photo.jpg")) == intruder)
        #expect(try Data(contentsOf: written) == Data([0x02]))
        // Publishing consumed the staging file, including on the attempt that lost the race.
        #expect(try folderContents(of: folder).allSatisfy { !$0.hasSuffix(".partial") })
    }

    @Test func mediaDownloadWriterLeavesNoStagingFileBehind() async throws {
        // The bytes are staged under a name of the writer's own before they are published, and
        // that file lives in the user's download folder. It must never outlive the write.
        let folder = try uniqueTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }

        let written = try await MediaDownloadWriter.shared.write(
            Data([0x01, 0x02]), fileName: "photo.jpg", into: folder)

        #expect(written.lastPathComponent == "photo.jpg")
        #expect(try folderContents(of: folder) == ["photo.jpg"])
    }

    @Test func mediaDownloadWriterReportsAFolderItCannotWriteInto() async throws {
        // A failure that is not a name collision is propagated rather than retried away.
        let folder = try uniqueTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let blocked = folder.appending(path: "not-a-folder")
        try Data([0x00]).write(to: blocked)

        await #expect(throws: (any Error).self) {
            try await MediaDownloadWriter.shared.write(Data([0x01]), fileName: "photo.jpg", into: blocked)
        }
    }

    @MainActor
    @Test func downloadFeedbackAddsUpGesturesThatFinishWhileTheToastIsStillUp() async throws {
        // The per-message lock does not stop two messages downloading at once, so a second gesture
        // can finish while the first one's toast is still on screen. Replacing the count there
        // would report one file when two were saved.
        let destination = FakeMediaDownloadDestination()
        let fixture = await mediaDownloadFixture(attachments: [], destination: destination)

        fixture.state.presentMediaDownloadFeedback(savedCount: 1, failedCount: 0)
        fixture.state.presentMediaDownloadFeedback(savedCount: 2, failedCount: 1)

        let feedback = try #require(fixture.state.mediaDownloadFeedback)
        #expect(feedback.savedCount == 3)
        #expect(feedback.failedCount == 1)
        #expect(feedback.hasFailures)

        // Once the toast is gone the next gesture starts a tally of its own, rather than inheriting
        // counts for files the user has already been told about.
        fixture.state.dismissMediaDownloadFeedback()
        fixture.state.presentMediaDownloadFeedback(savedCount: 1, failedCount: 0)

        let afterDismissal = try #require(fixture.state.mediaDownloadFeedback)
        #expect(afterDismissal.savedCount == 1)
        #expect(afterDismissal.failedCount == 0)
        fixture.state.dismissMediaDownloadFeedback()
    }

    @MainActor
    @Test func mediaDownloadActionIsTheOneGestureEveryEntryPointBuilds() async throws {
        // The hover bar's download button only exists while the pointer is on the row, and a
        // document or an audio attachment has no viewer to save from either, so the right-click
        // menu and the gallery carry the action too. All three build it from here: whether it is
        // offered, what it is called and whether one is already running are decided once, and a
        // `nil` is the "nothing to download" answer no call site can render a control around.
        let folder = try uniqueTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let destination = FakeMediaDownloadDestination(storedURL: folder)
        let fixture = await mediaDownloadFixture(
            attachments: [
                (fileName: "photo.jpg", mediaType: "image/jpeg", data: Data([0x01]), isAvailable: true),
                (fileName: "notes.pdf", mediaType: "application/pdf", data: Data([0x02]), isAvailable: true),
            ],
            destination: destination
        )
        let message = fixture.message

        let everything = try #require(MessageMediaDownloadAction(message: message, workspace: fixture.state))
        #expect(everything.title == L10n.string("Download attachments"))
        #expect(!everything.isInFlight)

        // The gallery's variant names the photo on screen, not the message's two files.
        let onScreen = try #require(message.mediaAttachments.first)
        let single = try #require(
            MessageMediaDownloadAction(message: message, attachments: [onScreen], workspace: fixture.state))
        #expect(single.title == L10n.string("Download"))

        // A message with nothing to download offers no action at all, so there is no control for
        // any of the three to draw.
        let textOnly = MessageItem(
            id: "text-message",
            groupIdHex: "group",
            senderName: "Alice",
            body: "Hello",
            sentAt: Date(timeIntervalSince1970: 1_700_000_000),
            isOutgoing: false
        )
        #expect(MessageMediaDownloadAction(message: textOnly, workspace: fixture.state) == nil)
        #expect(MessageMediaDownloadAction(message: message, attachments: [], workspace: fixture.state) == nil)

        // And the in-flight flag every entry point disables against is the per-message lock the
        // running gesture holds.
        fixture.state.mediaDownloadingMessageIds.insert(message.id)
        let running = try #require(MessageMediaDownloadAction(message: message, workspace: fixture.state))
        #expect(running.isInFlight)
        fixture.state.mediaDownloadingMessageIds.remove(message.id)
    }

    @Test func mediaDownloadActionTitleNamesOneAttachmentOrSeveral() {
        let reference = mediaAttachmentReference(
            sourceEpoch: 0,
            mediaType: "application/pdf",
            fileName: "notes.pdf",
            plaintextSha256: String(repeating: "b", count: 64)
        )
        func message(attachmentCount: Int) -> MessageItem {
            MessageItem(
                id: "media-message",
                groupIdHex: "group",
                senderName: "Alice",
                body: "",
                sentAt: Date(timeIntervalSince1970: 1_700_000_000),
                isOutgoing: false,
                mediaAttachments: (0..<attachmentCount).map {
                    MessageMediaAttachment(id: "media-message#\($0)", reference: reference)
                }
            )
        }

        #expect(message(attachmentCount: 1).mediaDownloadActionTitle == L10n.string("Download"))
        #expect(message(attachmentCount: 2).mediaDownloadActionTitle == L10n.string("Download attachments"))
    }

    @MainActor
    @Test func downloadMediaAttachmentsGivesUpOnAnAttachmentWhoseDownloadIsStalled() async throws {
        // Clicking download while the tile's own automatic download is mid-flight waits on that
        // task rather than reporting a failure for a file that is seconds away. The wait is
        // bounded: a download that never returns must not hold the gesture — and with it the
        // disabled control — for the rest of the session.
        let folder = try uniqueTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let destination = FakeMediaDownloadDestination(storedURL: folder)
        let fixture = await mediaDownloadFixture(
            attachments: [(fileName: "photo.jpg", mediaType: "image/jpeg", data: Data([0x01]), isAvailable: true)],
            destination: destination
        )
        let runtime = fixture.runtime
        let attachment = try #require(fixture.message.mediaAttachments.first)

        runtime.mediaDownloadGateEnabled = true
        let automaticLoad = Task { await fixture.state.loadMediaAttachment(attachment, for: fixture.message) }
        defer {
            runtime.releaseMediaDownloadGate()
            runtime.mediaDownloadGateEnabled = false
            automaticLoad.cancel()
        }
        for _ in 0..<200 where !runtime.didReachMediaDownloadGate {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        guard runtime.didReachMediaDownloadGate else {
            Issue.record("Expected the automatic attachment load to reach the fake download gate")
            return
        }

        // Shortened only now, so the load already in flight keeps the default ceiling and stays
        // `.loading` — the state the download path has to wait out.
        let previousTimeout = MediaAttachmentDownloadConcurrency.ffiDownloadTimeoutNanoseconds
        defer { MediaAttachmentDownloadConcurrency.ffiDownloadTimeoutNanoseconds = previousTimeout }
        MediaAttachmentDownloadConcurrency.ffiDownloadTimeoutNanoseconds = 20_000_000

        await fixture.state.downloadMediaAttachments(
            fixture.message.mediaAttachments, for: fixture.message)

        let feedback = try #require(fixture.state.mediaDownloadFeedback)
        #expect(feedback.savedCount == 0)
        #expect(feedback.failedCount == 1)
        #expect(!fixture.state.isDownloadingMediaAttachments(for: fixture.message))
    }

    @MainActor
    @Test func downloadMediaAttachmentsIgnoresAMessageWithoutAttachments() async throws {
        let folder = try uniqueTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let destination = FakeMediaDownloadDestination(storedURL: folder)
        let fixture = await mediaDownloadFixture(attachments: [], destination: destination)

        await fixture.state.downloadMediaAttachments([], for: fixture.message)

        // No attachments means no gesture at all — an empty toast would be noise, and the folder
        // panel must not open either.
        #expect(fixture.state.mediaDownloadFeedback == nil)
        #expect(destination.pickCallCount == 0)
        #expect(!fixture.message.canDownloadMediaAttachments)
    }

    @MainActor
    @Test func messageOffersAttachmentDownloadOnlyWithAttachments() {
        // The hover strip's download control is gated on this and nothing else. Its geometry is
        // not: the strip is measured by SwiftUI, so a control added to the row cannot be forgotten
        // by an offset that counts them.
        let base = MessageItem(
            id: "text-message",
            groupIdHex: "group",
            senderName: "Alice",
            body: "Hello",
            sentAt: Date(timeIntervalSince1970: 1_700_000_000),
            isOutgoing: false
        )
        let withMedia = MessageItem(
            id: "media-message",
            groupIdHex: "group",
            senderName: "Alice",
            body: "",
            sentAt: Date(timeIntervalSince1970: 1_700_000_000),
            isOutgoing: false,
            mediaAttachments: [
                MessageMediaAttachment(
                    id: "media-message#0",
                    reference: mediaAttachmentReference(mediaType: "image/jpeg", fileName: "photo.jpg")
                )
            ]
        )

        #expect(!base.canDownloadMediaAttachments)
        #expect(withMedia.canDownloadMediaAttachments)
    }

    @Test func sharedMediaProjectionKeepsIdentityStableAcrossInputReordering() {
        let first = MediaRecordFfi(
            messageIdHex: "first-message",
            attachmentIndex: 0,
            direction: "inbound",
            groupIdHex: "group",
            sender: "alice",
            reference: mediaAttachmentReference(
                mediaType: "image/png",
                fileName: "first.png",
                plaintextSha256: String(repeating: "1", count: 64)
            ),
            caption: nil,
            recordedAt: 1_700_000_000,
            receivedAt: 1_700_000_001
        )
        let second = MediaRecordFfi(
            messageIdHex: "second-message",
            attachmentIndex: 0,
            direction: "inbound",
            groupIdHex: "group",
            sender: "bob",
            reference: mediaAttachmentReference(
                mediaType: "application/pdf",
                fileName: "second.pdf",
                plaintextSha256: String(repeating: "2", count: 64)
            ),
            caption: nil,
            recordedAt: 1_700_000_010,
            receivedAt: 1_700_000_011
        )

        let original = GroupSharedMediaProjection(records: [first, second, first])
        let reordered = GroupSharedMediaProjection(records: [second, first])

        #expect(original.media.count == 1)
        #expect(original.files.count == 1)
        #expect(original.media.map(\.id) == reordered.media.map(\.id))
        #expect(original.files.map(\.id) == reordered.files.map(\.id))
    }

    @MainActor
    @Test func workspaceCachesSourceEpochZeroMediaReferenceMissesUntilInvalidated() async throws {
        let account = AccountSummaryFfi(
            label: "Desktop Account",
            accountIdHex: "abcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890",
            localSigning: true,
            externalSigning: false,
            signedOut: false,
            running: false
        )
        let accountItem = AccountItem(summary: account)
        let runtime = FakeMarmotRuntime(accounts: [account])
        let state = WorkspaceState(clientFactory: { runtime })
        let timelineReference = mediaAttachmentReference(
            sourceEpoch: 0,
            mediaType: "image/png",
            fileName: "missing-then-present.png",
            ciphertextSha256: String(repeating: "c", count: 64),
            plaintextSha256: String(repeating: "d", count: 64)
        )

        let firstMiss = try await state.resolvedMediaReference(
            timelineReference,
            accountId: accountItem.id,
            accountRef: accountItem.accountRef,
            groupIdHex: "group",
            client: runtime
        )
        #expect(firstMiss.sourceEpoch == 0)
        #expect(runtime.listMediaCallCount == 1)

        let secondMiss = try await state.resolvedMediaReference(
            timelineReference,
            accountId: accountItem.id,
            accountRef: accountItem.accountRef,
            groupIdHex: "group",
            client: runtime
        )
        #expect(secondMiss.sourceEpoch == 0)
        #expect(runtime.listMediaCallCount == 1)

        let fullReference = mediaAttachmentReference(
            sourceEpoch: 7,
            mediaType: "image/png",
            fileName: "missing-then-present.png",
            ciphertextSha256: timelineReference.ciphertextSha256,
            plaintextSha256: timelineReference.plaintextSha256
        )
        runtime.installMediaRecord(
            MediaRecordFfi(
                messageIdHex: "media-message",
                attachmentIndex: 0,
                direction: "inbound",
                groupIdHex: "group",
                sender: "alice",
                reference: fullReference,
                caption: nil,
                recordedAt: 1_700_000_000,
                receivedAt: 1_700_000_000
            ),
            download: MediaDownloadResultFfi(
                plaintext: Data([0x01, 0x02, 0x03, 0x04]),
                fileName: "missing-then-present.png",
                mediaType: "image/png",
                sizeBytes: 4
            )
        )

        let cachedMiss = try await state.resolvedMediaReference(
            timelineReference,
            accountId: accountItem.id,
            accountRef: accountItem.accountRef,
            groupIdHex: "group",
            client: runtime
        )
        #expect(cachedMiss.sourceEpoch == 0)
        #expect(runtime.listMediaCallCount == 1)

        state.clearMediaReferenceResolutionCache(forAccountId: accountItem.id, groupIdHex: "group")
        let refreshed = try await state.resolvedMediaReference(
            timelineReference,
            accountId: accountItem.id,
            accountRef: accountItem.accountRef,
            groupIdHex: "group",
            client: runtime
        )

        #expect(refreshed.sourceEpoch == fullReference.sourceEpoch)
        #expect(runtime.listMediaCallCount == 2)
    }

    @MainActor
    @Test func timelineMediaProjectionInvalidatesMediaReferenceMissCache() async throws {
        let account = AccountSummaryFfi(
            label: "Desktop Account",
            accountIdHex: "abcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890",
            localSigning: true,
            externalSigning: false,
            signedOut: false,
            running: true
        )
        let accountItem = AccountItem(summary: account)
        let runtime = FakeMarmotRuntime(accounts: [account])
        let chat = ChatItem(
            id: "group",
            title: "Test Group",
            subtitle: "Group message",
            preview: "Attachment",
            updatedAt: nil,
            avatarSeed: "group",
            pictureURL: nil,
            unreadCount: 0
        )
        let state = WorkspaceState(
            accounts: [accountItem],
            chatsByAccount: [accountItem.id: [chat]],
            messagesByChat: ["group": []],
            appActivityProvider: { true },
            conversationWindowVisibilityProvider: { true },
            clientFactory: { runtime }
        )
        state.activeAccountId = accountItem.id
        state.selection = .chat("group")
        let timelineReference = mediaAttachmentReference(
            sourceEpoch: 0,
            mediaType: "image/png",
            fileName: "inbound.png",
            ciphertextSha256: String(repeating: "e", count: 64),
            plaintextSha256: String(repeating: "f", count: 64)
        )
        let initial = try await state.resolvedMediaReference(
            timelineReference,
            accountId: accountItem.id,
            accountRef: accountItem.accountRef,
            groupIdHex: "group",
            client: runtime
        )
        #expect(initial.sourceEpoch == 0)
        #expect(runtime.listMediaCallCount == 1)

        let fullReference = mediaAttachmentReference(
            sourceEpoch: 11,
            mediaType: "image/png",
            fileName: "inbound.png",
            ciphertextSha256: timelineReference.ciphertextSha256,
            plaintextSha256: timelineReference.plaintextSha256
        )
        runtime.installMediaRecord(
            MediaRecordFfi(
                messageIdHex: "inbound-media-message",
                attachmentIndex: 0,
                direction: "inbound",
                groupIdHex: "group",
                sender: "alice",
                reference: fullReference,
                caption: nil,
                recordedAt: 1_700_000_001,
                receivedAt: 1_700_000_001
            ),
            download: MediaDownloadResultFfi(
                plaintext: Data([0x05, 0x06, 0x07, 0x08]),
                fileName: "inbound.png",
                mediaType: "image/png",
                sizeBytes: 4
            )
        )
        let stillCachedMiss = try await state.resolvedMediaReference(
            timelineReference,
            accountId: accountItem.id,
            accountRef: accountItem.accountRef,
            groupIdHex: "group",
            client: runtime
        )
        #expect(stillCachedMiss.sourceEpoch == 0)
        #expect(runtime.listMediaCallCount == 1)

        await state.applyTimelineProjection(
            TimelineProjectionUpdateFfi(
                groupIdHex: "group",
                messages: [],
                changes: [
                    .upsert(
                        trigger: .newMessage,
                        message: timelineMessage(
                            id: "inbound-media-message",
                            groupIdHex: "group",
                            sender: "alice",
                            plaintext: "",
                            recordedAt: 1_700_000_001,
                            mediaJson: mediaJson(for: timelineReference)
                        ))
                ],
                chatListRow: nil,
                chatListTrigger: .newLastMessage
            ),
            groupIdHex: "group",
            account: accountItem,
            client: runtime
        )

        let refreshed = try await state.resolvedMediaReference(
            timelineReference,
            accountId: accountItem.id,
            accountRef: accountItem.accountRef,
            groupIdHex: "group",
            client: runtime
        )
        #expect(refreshed.sourceEpoch == fullReference.sourceEpoch)
        #expect(runtime.listMediaCallCount == 2)
    }

    @MainActor
    @Test func timelineMediaProjectionKeepsMediaReferenceCacheForUnchangedMediaTick() async throws {
        let account = AccountSummaryFfi(
            label: "Desktop Account",
            accountIdHex: "abcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890",
            localSigning: true,
            externalSigning: false,
            signedOut: false,
            running: true
        )
        let accountItem = AccountItem(summary: account)
        let runtime = FakeMarmotRuntime(accounts: [account])
        let chat = ChatItem(
            id: "group",
            title: "Test Group",
            subtitle: "Group message",
            preview: "Attachment",
            updatedAt: nil,
            avatarSeed: "group",
            pictureURL: nil,
            unreadCount: 0
        )
        let state = WorkspaceState(
            accounts: [accountItem],
            chatsByAccount: [accountItem.id: [chat]],
            messagesByChat: ["group": []],
            appActivityProvider: { true },
            conversationWindowVisibilityProvider: { true },
            clientFactory: { runtime }
        )
        state.activeAccountId = accountItem.id
        state.selection = .chat("group")
        let timelineReference = mediaAttachmentReference(
            sourceEpoch: 0,
            mediaType: "image/png",
            fileName: "inbound.png",
            ciphertextSha256: String(repeating: "e", count: 64),
            plaintextSha256: String(repeating: "f", count: 64)
        )

        // Seed the store with the media message. This first projection is a genuine new-media
        // event, so it is *expected* to invalidate the (empty) cache.
        let mediaJsonPayload = mediaJson(for: timelineReference)
        await state.applyTimelineProjection(
            TimelineProjectionUpdateFfi(
                groupIdHex: "group",
                messages: [],
                changes: [
                    .upsert(
                        trigger: .newMessage,
                        message: timelineMessage(
                            id: "inbound-media-message",
                            groupIdHex: "group",
                            sender: "alice",
                            plaintext: "",
                            recordedAt: 1_700_000_001,
                            mediaJson: mediaJsonPayload
                        ))
                ],
                chatListRow: nil,
                chatListTrigger: .newLastMessage
            ),
            groupIdHex: "group",
            account: accountItem,
            client: runtime
        )

        // Prime the resolution cache with a miss for the unresolved (sourceEpoch == 0) ref.
        let initial = try await state.resolvedMediaReference(
            timelineReference,
            accountId: accountItem.id,
            accountRef: accountItem.accountRef,
            groupIdHex: "group",
            client: runtime
        )
        #expect(initial.sourceEpoch == 0)
        #expect(runtime.listMediaCallCount == 1)

        // Install a now-resolvable record: if the delivery-state tick were to wrongly clear the
        // cache, the follow-up resolve would rebuild the index and surface this full reference.
        let fullReference = mediaAttachmentReference(
            sourceEpoch: 11,
            mediaType: "image/png",
            fileName: "inbound.png",
            ciphertextSha256: timelineReference.ciphertextSha256,
            plaintextSha256: timelineReference.plaintextSha256
        )
        runtime.installMediaRecord(
            MediaRecordFfi(
                messageIdHex: "inbound-media-message",
                attachmentIndex: 0,
                direction: "inbound",
                groupIdHex: "group",
                sender: "alice",
                reference: fullReference,
                caption: nil,
                recordedAt: 1_700_000_001,
                receivedAt: 1_700_000_001
            ),
            download: MediaDownloadResultFfi(
                plaintext: Data([0x05, 0x06, 0x07, 0x08]),
                fileName: "inbound.png",
                mediaType: "image/png",
                sizeBytes: 4
            )
        )

        // A pure delivery-state tick for the same message re-carries the identical media
        // fields, so the mapped `mediaAttachments` are unchanged and the cache must be kept.
        await state.applyTimelineProjection(
            TimelineProjectionUpdateFfi(
                groupIdHex: "group",
                messages: [],
                changes: [
                    .upsert(
                        trigger: .deliveryOrSendStateChanged,
                        message: timelineMessage(
                            id: "inbound-media-message",
                            groupIdHex: "group",
                            sender: "alice",
                            plaintext: "",
                            recordedAt: 1_700_000_001,
                            mediaJson: mediaJsonPayload
                        ))
                ],
                chatListRow: nil,
                chatListTrigger: .newLastMessage
            ),
            groupIdHex: "group",
            account: accountItem,
            client: runtime
        )

        let stillCachedMiss = try await state.resolvedMediaReference(
            timelineReference,
            accountId: accountItem.id,
            accountRef: accountItem.accountRef,
            groupIdHex: "group",
            client: runtime
        )
        #expect(stillCachedMiss.sourceEpoch == 0)
        #expect(runtime.listMediaCallCount == 1)
    }

    @MainActor
    @Test func timelineMediaProjectionDefersMediaReferenceCacheInvalidationUntilRetained() async throws {
        // Regression for whitenoise-mac#631: inbound media newer than a detached window head is
        // suppressed without invalidating the cache, then invalidates once the row is retained.
        let account = AccountSummaryFfi(
            label: "Desktop Account",
            accountIdHex: "abcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890",
            localSigning: true,
            externalSigning: false,
            signedOut: false,
            running: true
        )
        let accountItem = AccountItem(summary: account)
        let runtime = FakeMarmotRuntime(accounts: [account])
        let chat = ChatItem(
            id: "group",
            title: "Test Group",
            subtitle: "Group message",
            preview: "Attachment",
            updatedAt: nil,
            avatarSeed: "group",
            pictureURL: nil,
            unreadCount: 0
        )
        let historicalMessage = MessageItem(
            id: "historical-text-message",
            groupIdHex: "group",
            senderName: "alice",
            body: "historical",
            sentAt: Date(timeIntervalSince1970: 1_700_000_000),
            timelineAt: 1_700_000_000,
            isOutgoing: false
        )
        let inboundReference = mediaAttachmentReference(
            sourceEpoch: 0,
            mediaType: "image/png",
            fileName: "inbound.png",
            ciphertextSha256: String(repeating: "c", count: 64),
            plaintextSha256: String(repeating: "d", count: 64)
        )
        let state = WorkspaceState(
            accounts: [accountItem],
            chatsByAccount: [accountItem.id: [chat]],
            messagesByChat: ["group": [historicalMessage]],
            appActivityProvider: { true },
            conversationWindowVisibilityProvider: { true },
            clientFactory: { runtime }
        )
        state.activeAccountId = accountItem.id
        state.selection = .chat("group")
        state.timelinePagingByChat["group"] = TimelinePagingState(
            hasMoreBefore: true,
            hasMoreAfter: true,
            isLoadingBefore: false,
            isLoadingAfter: false
        )

        let initial = try await state.resolvedMediaReference(
            inboundReference,
            accountId: accountItem.id,
            accountRef: accountItem.accountRef,
            groupIdHex: "group",
            client: runtime
        )
        #expect(initial.sourceEpoch == 0)
        #expect(runtime.listMediaCallCount == 1)

        let fullReference = mediaAttachmentReference(
            sourceEpoch: 11,
            mediaType: "image/png",
            fileName: "inbound.png",
            ciphertextSha256: inboundReference.ciphertextSha256,
            plaintextSha256: inboundReference.plaintextSha256
        )
        runtime.installMediaRecord(
            MediaRecordFfi(
                messageIdHex: "inbound-media-message",
                attachmentIndex: 0,
                direction: "inbound",
                groupIdHex: "group",
                sender: "alice",
                reference: fullReference,
                caption: nil,
                recordedAt: 1_700_000_100,
                receivedAt: 1_700_000_100
            ),
            download: MediaDownloadResultFfi(
                plaintext: Data([0x01, 0x02, 0x03, 0x04]),
                fileName: "inbound.png",
                mediaType: "image/png",
                sizeBytes: 4
            )
        )
        await state.applyTimelineProjection(
            TimelineProjectionUpdateFfi(
                groupIdHex: "group",
                messages: [],
                changes: [
                    .upsert(
                        trigger: .newMessage,
                        message: timelineMessage(
                            id: "inbound-media-message",
                            groupIdHex: "group",
                            sender: "alice",
                            plaintext: "",
                            recordedAt: 1_700_000_100,
                            mediaJson: mediaJson(for: inboundReference)
                        ))
                ],
                chatListRow: nil,
                chatListTrigger: .newLastMessage
            ),
            groupIdHex: "group",
            account: accountItem,
            client: runtime
        )

        #expect(state.messagesByChat["group"]?.map(\.id) == ["historical-text-message"])

        let stillCachedMiss = try await state.resolvedMediaReference(
            inboundReference,
            accountId: accountItem.id,
            accountRef: accountItem.accountRef,
            groupIdHex: "group",
            client: runtime
        )
        #expect(stillCachedMiss.sourceEpoch == 0)
        #expect(runtime.listMediaCallCount == 1)

        let acceptedRecords = [
            timelineMessage(
                id: "historical-text-message",
                groupIdHex: "group",
                sender: "alice",
                plaintext: "historical",
                recordedAt: 1_700_000_000
            ),
            timelineMessage(
                id: "inbound-media-message",
                groupIdHex: "group",
                sender: "alice",
                plaintext: "",
                recordedAt: 1_700_000_100,
                mediaJson: mediaJson(for: inboundReference)
            ),
        ]
        let subscription = FakeTimelineMessagesSubscription(
            messages: acceptedRecords,
            limit: acceptedRecords.count,
            windowCap: acceptedRecords.count
        )
        state.activeTimelineSubscription = subscription
        state.activeTimelineGroupId = "group"
        let acceptedPage = try #require(subscription.snapshot())
        await state.applyTimelineWindow(
            acceptedPage,
            groupIdHex: "group",
            account: accountItem,
            client: runtime,
            owner: .subscription(subscription)
        )
        #expect(
            state.messagesByChat["group"]?.map(\.id) == [
                "historical-text-message",
                "inbound-media-message",
            ])

        let refreshed = try await state.resolvedMediaReference(
            inboundReference,
            accountId: accountItem.id,
            accountRef: accountItem.accountRef,
            groupIdHex: "group",
            client: runtime
        )
        #expect(refreshed.sourceEpoch == fullReference.sourceEpoch)
        #expect(runtime.listMediaCallCount == 2)
    }

    @MainActor
    @Test func workspaceCoalescesAndCachesSourceEpochZeroMediaReferenceResolution() async throws {
        let account = AccountSummaryFfi(
            label: "Desktop Account",
            accountIdHex: "abcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890",
            localSigning: true,
            externalSigning: false,
            signedOut: false,
            running: false
        )
        let runtime = FakeMarmotRuntime(accounts: [account])
        runtime.installGroup(messageGroup())

        var fixtures: [MediaResolutionFixture] = []
        for index in 0..<4 {
            let plaintextSHA = String(repeating: String(index + 1), count: 64)
            let ciphertextSHA = String(repeating: String(index + 5), count: 64)
            let timelineReference = mediaAttachmentReference(
                sourceEpoch: 0,
                mediaType: "image/png",
                fileName: "coalesced-\(index).png",
                ciphertextSha256: ciphertextSHA,
                plaintextSha256: plaintextSHA
            )
            let fullReference = mediaAttachmentReference(
                sourceEpoch: UInt64(index + 10),
                mediaType: "image/png",
                fileName: "coalesced-\(index).png",
                ciphertextSha256: ciphertextSHA,
                plaintextSha256: plaintextSHA
            )
            let plaintext = Data([UInt8(index + 1), 0xaa, 0xbb, 0xcc])
            runtime.installMediaRecord(
                MediaRecordFfi(
                    messageIdHex: "coalesced-media-message-\(index)",
                    attachmentIndex: 0,
                    direction: "inbound",
                    groupIdHex: "group",
                    sender: "alice",
                    reference: fullReference,
                    caption: nil,
                    recordedAt: UInt64(1_700_000_000 + index),
                    receivedAt: UInt64(1_700_000_000 + index)
                ),
                download: MediaDownloadResultFfi(
                    plaintext: plaintext,
                    fileName: "coalesced-\(index).png",
                    mediaType: "image/png",
                    sizeBytes: UInt64(plaintext.count)
                )
            )
            let attachment = MessageMediaAttachment(
                id: "coalesced-media-message-\(index)#0#\(timelineReference.plaintextSha256)",
                reference: timelineReference
            )
            let message = MessageItem(
                id: "coalesced-media-message-\(index)",
                groupIdHex: "group",
                senderName: "Alice",
                body: "",
                sentAt: Date(timeIntervalSince1970: TimeInterval(1_700_000_000 + index)),
                isOutgoing: false,
                mediaAttachments: [attachment]
            )
            fixtures.append(
                MediaResolutionFixture(
                    message: message,
                    attachment: attachment,
                    plaintext: plaintext,
                    expectedSourceEpoch: fullReference.sourceEpoch
                )
            )
        }

        let state = WorkspaceState(clientFactory: { runtime })
        await state.bootstrap()

        runtime.listMediaGateEnabled = true
        let firstFixture = fixtures[0]
        let secondFixture = fixtures[1]
        let thirdFixture = fixtures[2]
        async let firstLoad: Void = state.loadMediaAttachment(firstFixture.attachment, for: firstFixture.message)
        while !runtime.didReachListMediaGate {
            await Task.yield()
        }

        async let secondLoad: Void = state.loadMediaAttachment(secondFixture.attachment, for: secondFixture.message)
        async let thirdLoad: Void = state.loadMediaAttachment(thirdFixture.attachment, for: thirdFixture.message)
        for _ in 0..<20 {
            await Task.yield()
        }
        #expect(runtime.listMediaCallCount == 1)

        runtime.releaseListMediaGate()
        await firstLoad
        await secondLoad
        await thirdLoad

        #expect(runtime.listMediaCallCount == 1)
        #expect(runtime.downloadMediaCallCount == 3)
        let firstDownloadEpochsByPlaintext = runtime.downloadedMediaReferences.reduce(
            into: [String: UInt64]()
        ) { result, reference in
            result[reference.plaintextSha256] = reference.sourceEpoch
        }
        for fixture in fixtures.prefix(3) {
            guard
                case .loaded(let loaded) = state.mediaDownloadState(
                    for: fixture.message,
                    attachment: fixture.attachment
                )
            else {
                Issue.record("Expected coalesced media download to load")
                return
            }
            #expect(loaded.data == fixture.plaintext)
            #expect(
                firstDownloadEpochsByPlaintext[fixture.attachment.reference.plaintextSha256]
                    == fixture.expectedSourceEpoch)
        }

        await state.loadMediaAttachment(fixtures[3].attachment, for: fixtures[3].message)

        #expect(runtime.listMediaCallCount == 1)
        #expect(runtime.downloadMediaCallCount == 4)
        let allDownloadEpochsByPlaintext = runtime.downloadedMediaReferences.reduce(
            into: [String: UInt64]()
        ) { result, reference in
            result[reference.plaintextSha256] = reference.sourceEpoch
        }
        #expect(
            allDownloadEpochsByPlaintext[fixtures[3].attachment.reference.plaintextSha256]
                == fixtures[3].expectedSourceEpoch)
        guard
            case .loaded(let loaded) = state.mediaDownloadState(
                for: fixtures[3].message,
                attachment: fixtures[3].attachment
            )
        else {
            Issue.record("Expected cached-index media download to load")
            return
        }
        #expect(loaded.data == fixtures[3].plaintext)
    }

    @MainActor
    @Test func workspaceLoadsMediaAttachmentFromDurableCacheWithoutRuntimeDownload() async throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("whitenoise-media-cache-tests-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: root) }

        let account = AccountSummaryFfi(
            label: "Desktop Account",
            accountIdHex: "abcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890",
            localSigning: true,
            externalSigning: false,
            signedOut: false,
            running: false
        )
        let plaintext = Data([0x10, 0x20, 0x30, 0x40])
        let reference = mediaAttachmentReference(
            sourceEpoch: 7,
            mediaType: "image/png",
            fileName: "cached.png",
            plaintextSha256: hexSHA256(plaintext)
        )
        let mediaDiskCache = messageMediaDiskCache(root: root)
        let cacheKey = MessageMediaDiskCacheKey(
            accountId: AccountItem(summary: account).id,
            groupIdHex: "group",
            reference: reference
        )
        await mediaDiskCache.store(
            MessageMediaDownload(
                data: plaintext,
                fileName: "cached.png",
                mediaType: "image/png",
                sizeBytes: UInt64(plaintext.count),
                payloadId: "preseeded"
            ),
            for: cacheKey
        )

        let runtime = FakeMarmotRuntime(accounts: [account])
        let state = WorkspaceState(
            mediaDiskCache: mediaDiskCache,
            clientFactory: { runtime }
        )
        await state.bootstrap()
        let message = MessageItem(
            id: "media-message",
            groupIdHex: "group",
            senderName: "Alice",
            body: "",
            sentAt: Date(timeIntervalSince1970: 1_700_000_000),
            isOutgoing: false,
            mediaAttachments: [
                MessageMediaAttachment(
                    id: "media-message#0#\(reference.plaintextSha256)",
                    reference: reference
                )
            ]
        )
        let attachment = try #require(message.mediaAttachments.first)

        await state.loadMediaAttachment(attachment, for: message)

        guard case .loaded(let loaded) = state.mediaDownloadState(for: message, attachment: attachment) else {
            Issue.record("Expected cached media download to load")
            return
        }
        #expect(loaded.data == plaintext)
        #expect(loaded.payload.id == cacheKey.payloadID)
        #expect(runtime.listMediaCallCount == 0)
        #expect(runtime.downloadMediaCallCount == 0)
    }

    @MainActor
    @Test func workspaceLoadsCachedMediaWhileDiskStoresAreSuppressed() async throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("whitenoise-media-cache-tests-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: root) }

        let account = AccountSummaryFfi(
            label: "Desktop Account",
            accountIdHex: "abcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890",
            localSigning: true,
            externalSigning: false,
            signedOut: false,
            running: false
        )
        let plaintext = Data([0x50, 0x51, 0x52, 0x53])
        let reference = mediaAttachmentReference(
            sourceEpoch: 7,
            mediaType: "image/png",
            fileName: "suppressed-cached.png",
            plaintextSha256: hexSHA256(plaintext)
        )
        let mediaDiskCache = messageMediaDiskCache(root: root)
        let cacheKey = MessageMediaDiskCacheKey(
            accountId: AccountItem(summary: account).id,
            groupIdHex: "group",
            reference: reference
        )
        await mediaDiskCache.store(
            MessageMediaDownload(
                data: plaintext,
                fileName: "suppressed-cached.png",
                mediaType: "image/png",
                sizeBytes: UInt64(plaintext.count),
                payloadId: "suppressed-cached"
            ),
            for: cacheKey
        )

        let runtime = FakeMarmotRuntime(accounts: [account])
        runtime.installGroup(messageGroup())
        let state = WorkspaceState(
            mediaDiskCache: mediaDiskCache,
            clientFactory: { runtime }
        )
        await state.bootstrap()
        let chat = try #require(state.activeChats.first)
        state.selection = .chat(chat.id)
        let message = MessageItem(
            id: "suppressed-cached-message",
            groupIdHex: "group",
            senderName: "Alice",
            body: "",
            sentAt: Date(timeIntervalSince1970: 1_700_000_000),
            isOutgoing: false,
            mediaAttachments: [
                MessageMediaAttachment(
                    id: "suppressed-cached-message#0#\(reference.plaintextSha256)",
                    reference: reference
                )
            ]
        )
        let attachment = try #require(message.mediaAttachments.first)
        state.replaceMessages([message], groupIdHex: chat.id)

        state.suppressAllMediaDiskStores()
        await state.loadMediaAttachment(attachment, for: message)
        state.resumeAllMediaDiskStores()

        guard case .loaded(let loaded) = state.mediaDownloadState(for: message, attachment: attachment) else {
            Issue.record("Expected cached media to display even while disk writes are suppressed")
            return
        }
        #expect(loaded.data == plaintext)
        #expect(runtime.listMediaCallCount == 0)
        #expect(runtime.downloadMediaCallCount == 0)
    }

    @MainActor
    @Test func workspaceDisplaysLateMediaDownloadAfterFailedDeleteAllData() async throws {
        let previousActiveAccount = UserDefaults.standard.object(forKey: "whitenoise.mac.activeAccountId")
        defer { restoreDefault(previousActiveAccount, forKey: "whitenoise.mac.activeAccountId") }
        UserDefaults.standard.set("Desktop Account", forKey: "whitenoise.mac.activeAccountId")

        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("whitenoise-media-cache-tests-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: root) }

        let account = AccountSummaryFfi(
            label: "Desktop Account",
            accountIdHex: "abcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890",
            localSigning: true,
            externalSigning: false,
            signedOut: false,
            running: false
        )
        let plaintext = Data([0x60, 0x61, 0x62, 0x63])
        let reference = mediaAttachmentReference(
            sourceEpoch: 7,
            mediaType: "image/png",
            fileName: "late-after-failed-delete.png",
            plaintextSha256: hexSHA256(plaintext)
        )
        let download = MediaDownloadResultFfi(
            plaintext: plaintext,
            fileName: "late-after-failed-delete.png",
            mediaType: "image/png",
            sizeBytes: UInt64(plaintext.count)
        )
        let runtime = FakeMarmotRuntime(accounts: [account])
        runtime.installGroup(messageGroup())
        runtime.installMediaRecord(
            MediaRecordFfi(
                messageIdHex: "late-after-failed-delete-message",
                attachmentIndex: 0,
                direction: "inbound",
                groupIdHex: "group",
                sender: "alice",
                reference: reference,
                caption: nil,
                recordedAt: 1_700_000_000,
                receivedAt: 1_700_000_000
            ),
            download: download
        )
        runtime.deleteAllLocalDataError = FakeMarmotRuntimeError.unused
        let mediaDiskCache = messageMediaDiskCache(root: root)
        let state = WorkspaceState(
            mediaDiskCache: mediaDiskCache,
            clientFactory: { runtime }
        )
        await state.bootstrap()
        let chat = try #require(state.activeChats.first)
        state.selection = .chat(chat.id)
        let page = TimelinePageFfi(
            messages: [
                timelineMessage(
                    id: "late-after-failed-delete-message",
                    groupIdHex: "group",
                    sender: "alice",
                    plaintext: "",
                    recordedAt: 1_700_000_000,
                    mediaJson: mediaJson(for: reference)
                )
            ],
            hasMoreBefore: false,
            hasMoreAfter: false
        )
        runtime.installTimelinePage(page, groupIdHex: "group")
        let message = try #require(
            MessageItem.timeline(
                from: page,
                activeAccountIdHex: AccountItem(summary: account).id
            ).first
        )
        let attachment = try #require(message.mediaAttachments.first)
        state.replaceMessages([message], groupIdHex: "group")
        // `deleteAllData()` recovery reloads the selected timeline after a failed wipe. Keep this
        // fixture message in that recovered window so the test continues to model a visible tile
        // whose late download is still allowed to publish.
        let stateStore = state.mediaDownloadStateStore(for: message, attachment: attachment)
        let cacheKey = MessageMediaDiskCacheKey(
            accountId: AccountItem(summary: account).id,
            groupIdHex: "group",
            reference: reference
        )

        runtime.mediaDownloadGateEnabled = true
        async let load: Void = state.loadMediaAttachment(attachment, for: message)
        while !runtime.didReachMediaDownloadGate {
            await Task.yield()
        }

        await state.deleteAllData()
        runtime.releaseMediaDownloadGate()
        await load
        for _ in 0..<20 where !state.mediaDiskStoreTasks.isEmpty {
            await Task.yield()
        }

        guard case .loaded(let loaded) = stateStore.state else {
            Issue.record("Expected late media download to display after a failed deleteAllData()")
            return
        }
        #expect(loaded.data == plaintext)
        #expect(state.mediaDiskStoreTasks.isEmpty)
        #expect(await mediaDiskCache.cachedDownload(for: cacheKey) == nil)
    }

    @MainActor
    @Test func mediaDownloadCoalescesAcrossChatSwitchBeforeFirstFetchCompletes() async throws {
        let previousActiveAccount = UserDefaults.standard.object(forKey: "whitenoise.mac.activeAccountId")
        defer { restoreDefault(previousActiveAccount, forKey: "whitenoise.mac.activeAccountId") }
        UserDefaults.standard.set("Desktop Account", forKey: "whitenoise.mac.activeAccountId")

        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("whitenoise-media-cache-tests-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: root) }

        let account = AccountSummaryFfi(
            label: "Desktop Account",
            accountIdHex: "abcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890",
            localSigning: true,
            externalSigning: false,
            signedOut: false,
            running: false
        )
        let plaintext = Data([0x70, 0x71, 0x72, 0x73])
        let reference = mediaAttachmentReference(
            sourceEpoch: 7,
            mediaType: "image/png",
            fileName: "pruned-late.png",
            plaintextSha256: hexSHA256(plaintext)
        )
        let download = MediaDownloadResultFfi(
            plaintext: plaintext,
            fileName: "pruned-late.png",
            mediaType: "image/png",
            sizeBytes: UInt64(plaintext.count)
        )
        let runtime = FakeMarmotRuntime(accounts: [account])
        runtime.installGroup(messageGroup())
        runtime.installMediaRecord(
            MediaRecordFfi(
                messageIdHex: "pruned-late-media-message",
                attachmentIndex: 0,
                direction: "inbound",
                groupIdHex: "group",
                sender: "alice",
                reference: reference,
                caption: nil,
                recordedAt: 1_700_000_000,
                receivedAt: 1_700_000_000
            ),
            download: download
        )
        let mediaDiskCache = messageMediaDiskCache(root: root)
        let state = WorkspaceState(
            mediaDiskCache: mediaDiskCache,
            clientFactory: { runtime }
        )
        await state.bootstrap()
        let chat = try #require(state.activeChats.first)
        state.selection = .chat(chat.id)
        let message = MessageItem(
            id: "pruned-late-media-message",
            groupIdHex: "group",
            senderName: "Alice",
            body: "",
            sentAt: Date(timeIntervalSince1970: 1_700_000_000),
            isOutgoing: false,
            mediaAttachments: [
                MessageMediaAttachment(
                    id: "pruned-late-media-message#0#\(reference.plaintextSha256)",
                    reference: reference
                )
            ]
        )
        let attachment = try #require(message.mediaAttachments.first)
        state.replaceMessages([message], groupIdHex: "group")
        let key = state.mediaDownloadKey(message: message, attachment: attachment)
        let stateStore = state.mediaDownloadStateStore(for: message, attachment: attachment)
        let cacheKey = MessageMediaDiskCacheKey(
            accountId: AccountItem(summary: account).id,
            groupIdHex: "group",
            reference: reference
        )

        runtime.mediaDownloadGateEnabled = true
        defer {
            runtime.releaseMediaDownloadGate()
            runtime.mediaDownloadGateEnabled = false
        }
        let load = Task { await state.loadMediaAttachment(attachment, for: message) }
        guard await waitFor({ runtime.didReachMediaDownloadGate }) else {
            Issue.record("Expected first media download to reach the fake runtime gate")
            return
        }
        #expect(state.mediaAttachmentDownloadTasks[cacheKey.cacheID] != nil)

        state.selection = .chat("other-group")
        // Model AutomaticMediaDownloadModifier.onDisappear: the view stops waiting, but the
        // underlying FFI download can remain in flight and must stay joinable by the returning tile.
        load.cancel()
        await load.value
        #expect(stateStore.state == .idle)
        state.replaceMessages([], groupIdHex: "group")
        state.pruneMediaDownloadCache(keeping: "other-group")
        #expect(state.mediaDownloads[key] == nil)
        #expect(state.mediaAttachmentDownloadTasks[cacheKey.cacheID] != nil)

        state.selection = .chat("group")
        state.replaceMessages([message], groupIdHex: "group")
        let recreatedStateStore = state.mediaDownloadStateStore(for: message, attachment: attachment)
        #expect(recreatedStateStore !== stateStore)
        #expect(recreatedStateStore.state == .idle)

        // Model AutomaticMediaDownloadModifier: replacement load starts while the first
        // runtime download is still gated, before the prune-era fetch can finish.
        async let replacementLoad: Void = state.loadMediaAttachment(attachment, for: message)
        let replacementEngaged = await waitFor {
            if case .loading = recreatedStateStore.state {
                return true
            }
            return runtime.downloadMediaCallCount > 1
        }
        guard replacementEngaged else {
            Issue.record("Expected replacement media load to engage while the first runtime download is gated")
            return
        }
        #expect(runtime.downloadMediaCallCount == 1)

        runtime.releaseMediaDownloadGate()
        await replacementLoad
        guard
            await waitFor({
                state.mediaDiskStoreTasks.isEmpty && state.mediaAttachmentDownloadTasks.isEmpty
            })
        else {
            Issue.record("Expected media download and disk-cache store tasks to finish")
            return
        }

        #expect(stateStore.state == .idle)
        guard case .loaded(let loadedFromCoalescedFetch) = recreatedStateStore.state else {
            Issue.record("Expected recreated store to load from the coalesced runtime download")
            return
        }
        #expect(loadedFromCoalescedFetch.data == plaintext)
        #expect(state.mediaDiskStoreTasks.isEmpty)
        guard let cachedDownload = await mediaDiskCache.cachedDownload(for: cacheKey) else {
            Issue.record("Expected pruned late download to persist to encrypted disk cache")
            return
        }
        #expect(cachedDownload.data == plaintext)
        #expect(runtime.downloadMediaCallCount == 1)

        await state.loadMediaAttachment(attachment, for: message)
        guard case .loaded(let loaded) = recreatedStateStore.state else {
            Issue.record("Expected recreated store to load from disk cache without re-downloading")
            return
        }
        #expect(loaded.data == plaintext)
        #expect(runtime.downloadMediaCallCount == 1)
    }

    @MainActor
    @Test func mediaDownloadFinishingAfterDeleteAllDataDoesNotRecreateDiskCache() async throws {
        let previousActiveAccount = UserDefaults.standard.object(forKey: "whitenoise.mac.activeAccountId")
        defer { restoreDefault(previousActiveAccount, forKey: "whitenoise.mac.activeAccountId") }
        UserDefaults.standard.set("Desktop Account", forKey: "whitenoise.mac.activeAccountId")

        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("whitenoise-media-cache-tests-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: root) }

        let account = AccountSummaryFfi(
            label: "Desktop Account",
            accountIdHex: "abcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890",
            localSigning: true,
            externalSigning: false,
            signedOut: false,
            running: false
        )
        let plaintext = Data([0xde, 0xad, 0xbe, 0xef])
        let reference = mediaAttachmentReference(
            sourceEpoch: 7,
            mediaType: "image/png",
            fileName: "late.png",
            plaintextSha256: hexSHA256(plaintext)
        )
        let download = MediaDownloadResultFfi(
            plaintext: plaintext,
            fileName: "late.png",
            mediaType: "image/png",
            sizeBytes: UInt64(plaintext.count)
        )
        let runtime = FakeMarmotRuntime(accounts: [account])
        runtime.installMediaRecord(
            MediaRecordFfi(
                messageIdHex: "late-media-message",
                attachmentIndex: 0,
                direction: "inbound",
                groupIdHex: "group",
                sender: "alice",
                reference: reference,
                caption: nil,
                recordedAt: 1_700_000_000,
                receivedAt: 1_700_000_000
            ),
            download: download
        )
        let mediaDiskCache = messageMediaDiskCache(root: root)
        let state = WorkspaceState(
            mediaDiskCache: mediaDiskCache,
            clientFactory: { runtime }
        )
        await state.bootstrap()
        let message = MessageItem(
            id: "late-media-message",
            groupIdHex: "group",
            senderName: "Alice",
            body: "",
            sentAt: Date(timeIntervalSince1970: 1_700_000_000),
            isOutgoing: false,
            mediaAttachments: [
                MessageMediaAttachment(
                    id: "late-media-message#0#\(reference.plaintextSha256)",
                    reference: reference
                )
            ]
        )
        let attachment = try #require(message.mediaAttachments.first)
        let stateStore = state.mediaDownloadStateStore(for: message, attachment: attachment)
        let cacheKey = MessageMediaDiskCacheKey(
            accountId: AccountItem(summary: account).id,
            groupIdHex: "group",
            reference: reference
        )

        runtime.mediaDownloadGateEnabled = true
        async let load: Void = state.loadMediaAttachment(attachment, for: message)
        while !runtime.didReachMediaDownloadGate {
            await Task.yield()
        }
        #expect(state.mediaAttachmentDownloadTasks[cacheKey.cacheID] != nil)

        await state.deleteAllData()
        #expect(!fileManager.fileExists(atPath: root.path))

        runtime.releaseMediaDownloadGate()
        await load
        for _ in 0..<20 where !state.mediaDiskStoreTasks.isEmpty {
            await Task.yield()
        }

        #expect(state.mediaDiskStoreTasks.isEmpty)
        #expect(state.mediaAttachmentDownloadTasks.isEmpty)
        if case .loaded = stateStore.state {
            Issue.record("Late download should not update loaded state after deleteAllData()")
        }
        #expect(await mediaDiskCache.cachedDownload(for: cacheKey) == nil)
        #expect(!fileManager.fileExists(atPath: root.path))
    }

    @Test func messageMediaDiskCacheCancelledStoreDoesNotCommitAfterKeyProviderReturns() async throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("whitenoise-media-cache-tests-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: root) }

        let keyProviderGate = OneShotKeyProviderGate()
        let cache = MessageMediaDiskCache(
            directoryResolver: { root },
            keyProvider: keyProviderGate.symmetricKey,
            keyDeleter: {}
        )
        let plaintext = Data("late store should not commit".utf8)
        let reference = mediaDiskCacheReference(plaintext: plaintext)
        let key = MessageMediaDiskCacheKey(accountId: "account-a", groupIdHex: "group-a", reference: reference)
        let download = MessageMediaDownload(
            data: plaintext,
            fileName: "late.bin",
            mediaType: "application/octet-stream",
            sizeBytes: UInt64(plaintext.count),
            payloadId: "late-store"
        )

        let storeTask = Task {
            await cache.store(download, for: key)
        }
        await Task.detached {
            keyProviderGate.waitUntilReached()
        }.value
        storeTask.cancel()
        keyProviderGate.releaseGate()
        await storeTask.value

        #expect(await cache.cachedDownload(for: key) == nil)
        #expect(!fileManager.fileExists(atPath: root.path))
    }

    @Test func messageAudioMetadataCacheCoalescesAndCachesPayloadAnalysis() async throws {
        let analysisCount = AtomicCounter()
        let expected = MediaWaveformAnalyzer.Metadata(
            durationSeconds: 12.5,
            samples: Array(repeating: 0.42, count: MediaWaveformAnalyzer.sampleCount)
        )
        let cache = MessageAudioMetadataCache(entryLimit: 4) { _, _ in
            analysisCount.increment()
            Thread.sleep(forTimeInterval: 0.02)
            return expected
        }
        let payload = DownloadedMediaPayload(id: "audio-payload", data: Data(repeating: 0x7f, count: 1024))

        async let first = cache.metadata(for: payload, mediaType: "audio/mp4")
        async let second = cache.metadata(for: payload, mediaType: "audio/mp4")
        async let third = cache.metadata(for: payload, mediaType: "audio/mp4")

        let values = await [first, second, third]

        #expect(values == [expected, expected, expected])
        #expect(analysisCount.value == 1)
        #expect(await cache.metadata(for: payload, mediaType: "audio/mp4") == expected)
        #expect(analysisCount.value == 1)
    }

    @Test func messageMediaDownloadDetailTextPerformanceGuard() {
        let download = MessageMediaDownload(
            data: Data(repeating: 0x52, count: 8 * 1024 * 1024),
            fileName: "image.png",
            mediaType: "image/png",
            sizeBytes: 8 * 1024 * 1024,
            payloadId: "detail-performance"
        )
        var cachedTotal = 0
        var repeatedFormatterTotal = 0

        let cachedMilliseconds = measuredMilliseconds {
            for _ in 0..<100_000 {
                cachedTotal += download.detailText(fallbackMediaType: "image/png").count
            }
        }

        let repeatedFormatterMilliseconds = measuredMilliseconds {
            for _ in 0..<100_000 {
                let size = ByteCountFormatter.string(
                    fromByteCount: Int64(clamping: download.sizeBytes),
                    countStyle: .file
                )
                repeatedFormatterTotal += "\(download.mediaType) - \(size)".count
            }
        }

        print(
            """
            PERF media_detail_cached_ms=\(formatMilliseconds(cachedMilliseconds)) \
            repeated_formatter_ms=\(formatMilliseconds(repeatedFormatterMilliseconds)) calls=100000
            """
        )
        #expect(cachedTotal == repeatedFormatterTotal)
        #expect(cachedMilliseconds < repeatedFormatterMilliseconds)
    }

    @MainActor
    @Test func mediaDownloadStateStoreAutoloadGateStartsOnlyFromIdle() {
        let store = MediaDownloadStateStore()
        let download = MessageMediaDownload(
            data: Data([0x01, 0x02, 0x03]),
            fileName: "image.png",
            mediaType: "image/png",
            sizeBytes: 3,
            payloadId: "autoload-gate"
        )

        #expect(store.shouldStartAutomaticDownload)
        store.update(.loading)
        #expect(!store.shouldStartAutomaticDownload)
        store.update(.loaded(download))
        #expect(!store.shouldStartAutomaticDownload)
        store.update(.failed("boom"))
        #expect(!store.shouldStartAutomaticDownload)
        store.update(.idle)
        #expect(store.shouldStartAutomaticDownload)
    }

    @MainActor
    @Test func visualMediaTileTapActionRetriesFailedVideoBeforeGallery() {
        #expect(
            MessageVisualMediaTileInteraction.tapAction(
                downloadState: .failed("network"),
                attachmentKind: .video
            ) == .retryDownload
        )
        #expect(
            MessageVisualMediaTileInteraction.tapAction(
                downloadState: .failed("network"),
                attachmentKind: .image
            ) == .retryDownload
        )
        #expect(
            MessageVisualMediaTileInteraction.tapAction(
                downloadState: .idle,
                attachmentKind: .image
            ) == .openImageGallery
        )
        #expect(
            MessageVisualMediaTileInteraction.tapAction(
                downloadState: .idle,
                attachmentKind: .video
            ) == .none
        )
    }

    @Test func visualMediaTilePrimaryActionRoutesRetryToDownload() throws {
        // MessageVisualMediaTile is a SwiftUI control that the unit tests cannot activate
        // directly here. Guard the wiring shape so a failed-tile retry action remains
        // connected to the explicit download entry point, while the pure decision helper
        // above guards that failed video tiles choose that action.
        let tileSource = try SourceContract.declaration("MessageVisualMediaTile")

        #expect(tileSource.contains("MessageVisualMediaTileInteraction.tapAction"))
        #expect(tileSource.contains("case .retryDownload:"))
        #expect(tileSource.contains("Task { await workspace.loadMediaAttachment(attachment, for: message) }"))
    }

    @MainActor
    @Test func visualMediaTileAccessibilityLabelMatchesPrimaryAction() {
        #expect(
            MessageVisualMediaTileInteraction.accessibilityLabel(for: .retryDownload)
                == L10n.string("Retry download")
        )
        #expect(
            MessageVisualMediaTileInteraction.accessibilityLabel(for: .openImageGallery)
                == L10n.string("Open image")
        )
        #expect(MessageVisualMediaTileInteraction.accessibilityLabel(for: .none) == nil)
    }

    @MainActor
    @Test func videoAttachmentPlayerAccessibilityLabelMatchesPlaybackState() {
        #expect(
            MessageVideoAttachmentPlayerAccessibility.label(
                isPreparingPlayback: false,
                didFail: true
            ) == L10n.string("Retry video")
        )
        #expect(
            MessageVideoAttachmentPlayerAccessibility.label(
                isPreparingPlayback: true,
                didFail: false
            ) == L10n.string("Cancel video loading")
        )
        #expect(
            MessageVideoAttachmentPlayerAccessibility.label(
                isPreparingPlayback: false,
                didFail: false
            ) == L10n.string("Play video")
        )
    }

    @Test func mediaTilesExposeButtonAccessibilitySemantics() throws {
        // MessageVisualMediaTile and MessageVideoAttachmentPlayer are SwiftUI surfaces
        // the unit tests cannot activate directly. Guard their source contract: pointer,
        // keyboard, and VoiceOver users must reach the same primary action through real
        // Button controls with explicit labels instead of bare tap gestures. Once playback
        // starts, the live VideoPlayer must sit outside that button so AVKit controls stay
        // interactive and exposed to assistive technologies.

        let tileSource = try SourceContract.declaration("MessageVisualMediaTile")
        let normalizedTileSource = tileSource.components(separatedBy: .whitespacesAndNewlines).joined()

        #expect(tileSource.contains("Button(action: performPrimaryAction)"))
        #expect(normalizedTileSource.contains(".buttonStyle(.plain)"))
        #expect(
            normalizedTileSource.contains(
                "MessageVisualMediaTileInteraction.accessibilityLabel(for:tapAction)"
            )
        )
        #expect(!tileSource.contains(".onTapGesture"))

        let playerSource = try SourceContract.declaration("MessageVideoAttachmentPlayer")
        let normalizedPlayerSource = playerSource.components(separatedBy: .whitespacesAndNewlines).joined()

        #expect(playerSource.contains("if let player {"))
        #expect(playerSource.contains("VideoPlayer(player: player)"))
        #expect(playerSource.contains("Button(action: activatePlayback)"))
        #expect(normalizedPlayerSource.contains(".buttonStyle(.plain)"))
        #expect(playerSource.contains("MessageVideoAttachmentPlayerAccessibility.label("))
        #expect(!normalizedPlayerSource.contains(".allowsHitTesting(false)"))
        #expect(!normalizedPlayerSource.contains(".accessibilityElement(children:.ignore)"))
        #expect(!playerSource.contains("@State private var isPlaying"))
        #expect(!playerSource.contains("Pause video"))
        #expect(!playerSource.contains(".onTapGesture"))

        let livePlayerBranch = try #require(
            playerSource.range(
                of: "if let player {",
                options: [],
                range: nil,
                locale: nil
            )
        )
        let elseBranch = try #require(
            playerSource.range(
                of: "} else {",
                options: [],
                range: livePlayerBranch.upperBound..<playerSource.endIndex,
                locale: nil
            )
        )
        let livePlayerSource = String(playerSource[livePlayerBranch.upperBound..<elseBranch.lowerBound])
        #expect(livePlayerSource.contains("VideoPlayer(player: player)"))
        #expect(!livePlayerSource.contains("Button(action:"))
    }

    @Test func imageGalleryProvidesDismissalNavigationAndAccessibilityAffordances() throws {
        // MessageImageGalleryOverlay is SwiftUI event wiring, so guard its source contract:
        // pointer and keyboard users can dismiss it, keyboard users can page through images,
        // and VoiceOver receives explicit labels for every icon-only control.
        let overlaySource = try SourceContract.declaration("MessageImageGalleryOverlay")
        let normalizedSource = overlaySource.components(separatedBy: .whitespacesAndNewlines).joined()

        #expect(normalizedSource.contains(".onTapGesture(perform:onClose)"))
        #expect(normalizedSource.contains(".onExitCommand(perform:onClose)"))
        #expect(normalizedSource.contains(".keyboardShortcut(.leftArrow,modifiers:[])"))
        #expect(normalizedSource.contains(".keyboardShortcut(.rightArrow,modifiers:[])"))
        // The labels route through `L10n.string` so VoiceOver announces them in the
        // selected app language rather than the system locale.
        #expect(normalizedSource.contains(".accessibilityLabel(L10n.string(\"Close\"))"))
        #expect(normalizedSource.contains(".accessibilityLabel(accessibilityLabel)"))
        #expect(overlaySource.contains("accessibilityLabel: L10n.string(\"Previous image\")"))
        #expect(overlaySource.contains("accessibilityLabel: L10n.string(\"Next image\")"))
    }

    @Test func automaticMediaDownloadCancelsWhenTileLeavesViewport() throws {
        // AutomaticMediaDownloadModifier is SwiftUI lifecycle wiring, so exercise its source
        // contract directly: the task must be retained and cancelled both on scroll-out and
        // when SwiftUI removes the tile entirely.
        let modifierSource = try SourceContract.declaration("AutomaticMediaDownloadModifier")

        #expect(modifierSource.contains("@State private var automaticDownloadTask: Task<Void, Never>?"))
        #expect(
            modifierSource.contains(
                "} else {\n                            cancelAutomaticDownload()"
            )
        )
        #expect(
            modifierSource.contains(
                ".onDisappear {\n            cancelAutomaticDownload()\n        }"
            )
        )
        #expect(modifierSource.contains("automaticDownloadTask?.cancel()"))
    }

    @Test func videoPlayerReclaimsScratchFileWhenTileLeavesViewport() throws {
        // MessageVideoAttachmentPlayer lives inside the deliberately eager transcript VStack,
        // where scrolling a row away does not trigger onDisappear. Its scroll-visibility hook
        // must cancel any in-flight materialization and run the same teardown that removes the
        // decrypted playback scratch file.
        let playerSource = try SourceContract.declaration("MessageVideoAttachmentPlayer")

        let normalizedSource = playerSource.components(separatedBy: .whitespacesAndNewlines).joined()

        #expect(
            normalizedSource.contains(
                ".onScrollVisibilityChange(threshold:0.01){isVisibleinguard!isVisibleelse{return}tearDownPlayback()}"
            )
        )
        #expect(
            normalizedSource.contains(
                "privatefunctearDownPlayback(){playbackTask?.cancel()playbackTask=nilstopPlayback()}"
            )
        )
        #expect(normalizedSource.contains("MessageMediaPlaybackFileStore.remove(at:url)"))
    }

    @Test func audioPlayerStopsWhenTileLeavesViewport() throws {
        // MessageAudioAttachmentPlayer lives inside the deliberately eager transcript VStack,
        // where scrolling a row away does not trigger onDisappear. Its scroll-visibility hook
        // must stop playback and cancel the progress monitor through the same stopPlayback path.
        let playerSource = try SourceContract.declaration("MessageAudioAttachmentPlayer")

        let normalizedSource = playerSource.components(separatedBy: .whitespacesAndNewlines).joined()

        #expect(
            normalizedSource.contains(
                ".onScrollVisibilityChange(threshold:0.01){isVisibleinguard!isVisibleelse{return}stopPlayback()}"
            )
        )
        #expect(
            normalizedSource.contains(
                "privatefuncstopPlayback(){playbackPreparationID=nil"
            )
        )
        #expect(
            normalizedSource.contains(
                "privatefuncfinishPlayback(){playbackMonitor?.cancel()playbackMonitor=nil"
            )
        )
    }

    @Test func audioRowKeepsItsGeometryAcrossDownloadStatesAndNeverNamesTheFile() throws {
        // A voice message's file name is a generated name the sender never chose, so no audio
        // row shows it — not the player, not the not-yet-downloaded placeholder. The placeholder
        // also has to occupy exactly the player's space so a finished download swaps the control
        // glyph instead of reflowing the bubble, which is only guaranteed while both render
        // through `MessageAudioRow`. Inlining either one's layout would break that silently.

        for typeName in ["MessageAudioAttachmentPlaceholder", "MessageAudioAttachmentPlayer"] {
            let body = try SourceContract.declaration(typeName)

            #expect(body.contains("MessageAudioRow("), "\(typeName) must render through MessageAudioRow")
            #expect(!body.contains("fileName"), "\(typeName) must not show the attachment file name")
            // The speed badge is part of that shared geometry: it sits at the row's trailing edge
            // and takes width from the waveform, so a row that showed it only once the download
            // finished would reflow the bubble on the very swap this test exists to prevent.
            #expect(
                body.contains("MessageAudioSpeedBadge("),
                "\(typeName) must reserve the playback-speed badge"
            )
        }
    }

    @Test func audioRowAlignsItsControlsOnTheWaveformRatherThanOnTheRowBox() throws {
        // The duration label hangs below the bars inside the middle column, so the column's centre
        // — and with it the row box's — sits about half a line below the bars themselves. Aligning
        // on `.center` therefore hangs the play control and the speed badge low against the
        // waveform they belong to. Nothing observable from a unit test reports a stack's alignment,
        // so the guide is pinned against the source, like the player's rate ordering below.
        let normalizedBody = try SourceContract.declaration("MessageAudioRow")
            .components(separatedBy: .whitespacesAndNewlines).joined()

        #expect(normalizedBody.contains("HStack(alignment:.audioRowWaveformCenter"))
        // Half the waveform's own height, not a literal: the guide has to follow the band it names.
        #expect(normalizedBody.contains(".alignmentGuide(.audioRowWaveformCenter){_inSelf.waveformHeight/2}"))
    }

    @Test func aSendingAudioShowsItsWaitInThePlayButtonRatherThanUnderAnOverlay() throws {
        // Same geometry contract as the test above, across the other axis: a voice note is one row
        // from the moment Send is pressed to the moment it is playable, so the wait belongs in the
        // well the play button lands in. Rendering it through the shared placeholder is what makes
        // that a guarantee instead of two hand-matched layouts — and the message-wide dimmer has to
        // stand down for it, or the send announces itself twice and the inline spinner fades along
        // with the row it sits in.
        let source = try SourceContract.source(of: .pendingOutgoingMessage)

        #expect(
            source.contains("MessageAudioAttachmentPlaceholder("),
            "a pending audio row must render through the shared audio placeholder"
        )
        let normalizedSource = source.components(separatedBy: .whitespacesAndNewlines).joined()
        #expect(
            normalizedSource.contains("message.state.isInFlight&&message.inlineLoadingAudioAttachment==nil"),
            "the centered overlay must stand down for a row that carries its own spinner"
        )
    }

    @Test func audioPlayerArmsRateControlBeforePreparingAndReappliesItAroundPlay() throws {
        // Two `AVAudioPlayer` traps, both of which fail silently — the badge would keep cycling and
        // keep reading 2x while playback stayed at 1x, with nothing in the UI to show it:
        //   1. `rate` is ignored unless `enableRate` was set *before* `prepareToPlay()`.
        //   2. `play()` can reset `rate`, so the selected speed has to be applied after it too.
        // Neither is observable from a unit test — nothing reports the audible rate back — so the
        // ordering is pinned against the source, the same way the teardown paths above are.
        let playerSource = try SourceContract.declaration("MessageAudioAttachmentPlayer")

        let enableRate = try #require(playerSource.range(of: "audioPlayer.enableRate = true"))
        let prepareToPlay = try #require(playerSource.range(of: "audioPlayer.prepareToPlay()"))
        #expect(enableRate.upperBound < prepareToPlay.lowerBound)

        let normalizedSource = playerSource.components(separatedBy: .whitespacesAndNewlines).joined()
        #expect(normalizedSource.contains("applyPlaybackSpeed()player?.play()applyPlaybackSpeed()"))
        #expect(normalizedSource.contains("privatefuncapplyPlaybackSpeed(){player?.rate=speed.rate}"))
    }

    @MainActor
    @Test func loadMediaAttachmentRetriesFromFailedState() async throws {
        let account = AccountSummaryFfi(
            label: "Desktop Account",
            accountIdHex: "abcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890",
            localSigning: true,
            externalSigning: false,
            signedOut: false,
            running: false
        )
        let plaintext = Data([0x00, 0x0F, 0xF0, 0xFF])
        let reference = mediaAttachmentReference(
            sourceEpoch: 7,
            mediaType: "video/mp4",
            fileName: "clip.mp4",
            plaintextSha256: hexSHA256(plaintext)
        )
        let download = MediaDownloadResultFfi(
            plaintext: plaintext,
            fileName: "clip.mp4",
            mediaType: "video/mp4",
            sizeBytes: UInt64(plaintext.count)
        )
        let runtime = FakeMarmotRuntime(accounts: [account])
        runtime.installGroup(messageGroup())
        let state = WorkspaceState(clientFactory: { runtime })
        await state.bootstrap()
        state.selection = .chat("group")
        let message = MessageItem(
            id: "failed-video-message",
            groupIdHex: "group",
            senderName: "Alice",
            body: "",
            sentAt: Date(timeIntervalSince1970: 1_700_000_000),
            isOutgoing: false,
            mediaAttachments: [
                MessageMediaAttachment(
                    id: "failed-video-message#0#\(reference.plaintextSha256)",
                    reference: reference
                )
            ]
        )
        let attachment = try #require(message.mediaAttachments.first)
        state.replaceMessages([message], groupIdHex: "group")

        await state.loadMediaAttachment(attachment, for: message)
        guard case .failed = state.mediaDownloadState(for: message, attachment: attachment) else {
            Issue.record("Expected initial video download to fail")
            return
        }
        #expect(runtime.downloadMediaCallCount == 1)

        runtime.installMediaRecord(
            MediaRecordFfi(
                messageIdHex: "failed-video-message",
                attachmentIndex: 0,
                direction: "inbound",
                groupIdHex: "group",
                sender: "alice",
                reference: reference,
                caption: nil,
                recordedAt: 1_700_000_000,
                receivedAt: 1_700_000_000
            ),
            download: download
        )
        await state.loadMediaAttachment(attachment, for: message)

        guard case .loaded(let loaded) = state.mediaDownloadState(for: message, attachment: attachment) else {
            Issue.record("Expected failed video download to retry successfully")
            return
        }
        #expect(loaded.data == plaintext)
        #expect(runtime.downloadMediaCallCount == 2)
    }

    @Test func mediaAttachmentDownloadLimiterCapsConcurrentAcquires() async {
        let limiter = MediaAttachmentDownloadLimiter(maxConcurrent: 2)
        let inFlight = AtomicCounter()
        let maxInFlight = AtomicMax()

        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<8 {
                group.addTask {
                    try? await limiter.acquire()
                    let current = inFlight.increment()
                    maxInFlight.record(current)
                    try? await Task.sleep(nanoseconds: 5_000_000)
                    inFlight.decrement()
                    await limiter.release()
                }
            }
        }

        #expect(maxInFlight.value <= 2)
        #expect(inFlight.value == 0)
    }

    @Test func mediaAttachmentDownloadLimiterDropsCancelledQueuedWaiter() async {
        let limiter = MediaAttachmentDownloadLimiter(maxConcurrent: 1)
        try? await limiter.acquire()

        let cancelled = AtomicCounter()
        let waitingTask = Task {
            do {
                try await limiter.acquire()
                Issue.record("Cancelled queued waiter should not acquire a slot")
            } catch is CancellationError {
                cancelled.increment()
            } catch {
                Issue.record("Expected CancellationError, got \(error)")
            }
        }

        for _ in 0..<100 {
            if await limiter.queuedWaiterCount() == 1 {
                break
            }
            await Task.yield()
        }
        #expect(await limiter.queuedWaiterCount() == 1)

        waitingTask.cancel()
        _ = await waitingTask.result
        #expect(cancelled.value == 1)
        #expect(await limiter.queuedWaiterCount() == 0)

        let acquired = AtomicCounter()
        let nextTask = Task {
            try? await limiter.acquire()
            acquired.increment()
        }
        for _ in 0..<50 where acquired.value == 0 {
            await Task.yield()
        }
        #expect(acquired.value == 0)

        await limiter.release()
        for _ in 0..<50 where acquired.value == 0 {
            await Task.yield()
        }
        #expect(acquired.value == 1)

        await limiter.release()
        _ = await nextTask.result
    }

    @Test func mediaAttachmentDownloadPermitOutlivesTimedOutWaiter() async {
        let limiter = MediaAttachmentDownloadLimiter(maxConcurrent: 1)
        let operationGate = AsyncFfiGate()
        operationGate.isEnabled = true

        let timedOutWaiter = Task {
            do {
                _ = try await withMediaAttachmentDownloadTimeout(nanoseconds: 10_000_000) {
                    try await limiter.withPermit {
                        await operationGate.passIfArmed()
                        return true
                    }
                }
                Issue.record("Expected the first waiter to time out")
            } catch is MediaAttachmentDownloadTimeoutError {
                // Expected: the UI waiter is gone while the simulated blocking work remains.
            } catch {
                Issue.record("Expected a timeout, got \(error)")
            }
        }

        for _ in 0..<100 where !operationGate.didReach {
            await Task.yield()
        }
        #expect(operationGate.didReach)
        _ = await timedOutWaiter.result

        let nextAcquired = AtomicCounter()
        let nextWaiter = Task {
            do {
                try await limiter.acquire()
                nextAcquired.increment()
            } catch {
                Issue.record("Expected the queued waiter to acquire after the operation ended")
            }
        }
        for _ in 0..<100 {
            if await limiter.queuedWaiterCount() == 1 { break }
            await Task.yield()
        }
        #expect(await limiter.queuedWaiterCount() == 1)
        #expect(nextAcquired.value == 0)

        operationGate.release()
        for _ in 0..<100 where nextAcquired.value == 0 {
            await Task.yield()
        }
        #expect(nextAcquired.value == 1)

        await limiter.release()
        _ = await nextWaiter.result
    }

    @MainActor
    @Test func mediaReferenceResolutionDoesNotConsumeDownloadLimiterSlot() async throws {
        let previousActiveAccount = UserDefaults.standard.object(forKey: "whitenoise.mac.activeAccountId")
        defer { restoreDefault(previousActiveAccount, forKey: "whitenoise.mac.activeAccountId") }
        UserDefaults.standard.set("Desktop Account", forKey: "whitenoise.mac.activeAccountId")

        let account = AccountSummaryFfi(
            label: "Desktop Account",
            accountIdHex: "abcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890",
            localSigning: true,
            externalSigning: false,
            signedOut: false,
            running: false
        )
        let plaintext = Data([0x51, 0x52, 0x53])
        let timelineReference = mediaAttachmentReference(
            sourceEpoch: 0,
            mediaType: "image/png",
            fileName: "resolve-before-slot.png",
            plaintextSha256: hexSHA256(plaintext)
        )
        let resolvedReference = mediaAttachmentReference(
            sourceEpoch: 7,
            mediaType: "image/png",
            fileName: "resolve-before-slot.png",
            plaintextSha256: timelineReference.plaintextSha256
        )
        let runtime = FakeMarmotRuntime(accounts: [account])
        runtime.installGroup(messageGroup())
        runtime.installMediaRecord(
            MediaRecordFfi(
                messageIdHex: "resolve-before-slot-message",
                attachmentIndex: 0,
                direction: "inbound",
                groupIdHex: "group",
                sender: "alice",
                reference: resolvedReference,
                caption: nil,
                recordedAt: 1_700_000_000,
                receivedAt: 1_700_000_000
            ),
            download: MediaDownloadResultFfi(
                plaintext: plaintext,
                fileName: "resolve-before-slot.png",
                mediaType: "image/png",
                sizeBytes: UInt64(plaintext.count)
            )
        )
        let state = WorkspaceState(clientFactory: { runtime })
        await state.bootstrap()
        let message = MessageItem(
            id: "resolve-before-slot-message",
            groupIdHex: "group",
            senderName: "Alice",
            body: "",
            sentAt: Date(timeIntervalSince1970: 1_700_000_000),
            isOutgoing: false,
            mediaAttachments: [
                MessageMediaAttachment(
                    id: "resolve-before-slot-message#0#\(timelineReference.plaintextSha256)",
                    reference: timelineReference
                )
            ]
        )
        let attachment = try #require(message.mediaAttachments.first)

        for _ in 0..<MediaAttachmentDownloadConcurrency.maxConcurrentDownloads {
            try await MediaAttachmentDownloadLimiter.shared.acquire()
        }
        runtime.listMediaGateEnabled = true
        let load = Task { await state.loadMediaAttachment(attachment, for: message) }
        for _ in 0..<100 {
            if runtime.didReachListMediaGate {
                break
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }

        #expect(runtime.didReachListMediaGate)

        runtime.releaseListMediaGate()
        for _ in 0..<MediaAttachmentDownloadConcurrency.maxConcurrentDownloads {
            await MediaAttachmentDownloadLimiter.shared.release()
        }
        await load.value

        // `loadMediaAttachment` releases its actor-isolated slot from a deferred task. Reacquiring
        // every slot waits for that deferred release before this serialized test yields the shared
        // limiter to the next test.
        for _ in 0..<MediaAttachmentDownloadConcurrency.maxConcurrentDownloads {
            try await MediaAttachmentDownloadLimiter.shared.acquire()
        }
        for _ in 0..<MediaAttachmentDownloadConcurrency.maxConcurrentDownloads {
            await MediaAttachmentDownloadLimiter.shared.release()
        }

        guard case .loaded(let download) = state.mediaDownloadState(for: message, attachment: attachment) else {
            Issue.record("Expected attachment download to complete after reference resolution")
            return
        }
        #expect(download.data == plaintext)
        #expect(runtime.listMediaCallCount == 1)
        #expect(runtime.downloadMediaCallCount == 1)
    }

    @MainActor
    @Test func cancelledMediaReferenceResolutionAllowsAttachmentRetry() async throws {
        let previousActiveAccount = UserDefaults.standard.object(forKey: "whitenoise.mac.activeAccountId")
        defer { restoreDefault(previousActiveAccount, forKey: "whitenoise.mac.activeAccountId") }
        UserDefaults.standard.set("Desktop Account", forKey: "whitenoise.mac.activeAccountId")

        let account = AccountSummaryFfi(
            label: "Desktop Account",
            accountIdHex: "abcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890",
            localSigning: true,
            externalSigning: false,
            signedOut: false,
            running: false
        )
        let fixtureID = UUID().uuidString
        let plaintext = Data(fixtureID.utf8)
        let timelineReference = mediaAttachmentReference(
            sourceEpoch: 0,
            mediaType: "image/png",
            fileName: "cancelled-resolution-\(fixtureID).png",
            plaintextSha256: hexSHA256(plaintext)
        )
        let resolvedReference = mediaAttachmentReference(
            sourceEpoch: 7,
            mediaType: "image/png",
            fileName: timelineReference.fileName,
            plaintextSha256: timelineReference.plaintextSha256
        )
        let runtime = FakeMarmotRuntime(accounts: [account])
        runtime.installGroup(messageGroup())
        runtime.installMediaRecord(
            MediaRecordFfi(
                messageIdHex: "cancelled-resolution-message",
                attachmentIndex: 0,
                direction: "inbound",
                groupIdHex: "group",
                sender: "alice",
                reference: resolvedReference,
                caption: nil,
                recordedAt: 1_700_000_000,
                receivedAt: 1_700_000_000
            ),
            download: MediaDownloadResultFfi(
                plaintext: plaintext,
                fileName: resolvedReference.fileName,
                mediaType: resolvedReference.mediaType,
                sizeBytes: UInt64(plaintext.count)
            )
        )
        let state = WorkspaceState(clientFactory: { runtime })
        await state.bootstrap()
        let message = MessageItem(
            id: "cancelled-resolution-message",
            groupIdHex: "group",
            senderName: "Alice",
            body: "",
            sentAt: Date(timeIntervalSince1970: 1_700_000_000),
            isOutgoing: false,
            mediaAttachments: [
                MessageMediaAttachment(
                    id: "cancelled-resolution-message#0#\(timelineReference.plaintextSha256)",
                    reference: timelineReference
                )
            ]
        )
        let attachment = try #require(message.mediaAttachments.first)
        let stateStore = state.mediaDownloadStateStore(for: message, attachment: attachment)

        func waitForCompletion(of task: Task<Void, Never>, description: String) async -> Bool {
            do {
                try await withMediaAttachmentDownloadTimeout(nanoseconds: 1_000_000_000) {
                    await task.value
                }
                return true
            } catch {
                Issue.record("Expected \(description) to finish, got \(error)")
                return false
            }
        }

        runtime.listMediaGateEnabled = true
        let firstLoad = Task { await state.loadMediaAttachment(attachment, for: message) }
        var retryLoad: Task<Void, Never>?
        defer {
            firstLoad.cancel()
            retryLoad?.cancel()
            runtime.listMediaGateEnabled = false
            runtime.releaseListMediaGate()
        }

        for _ in 0..<100 {
            if runtime.didReachListMediaGate {
                break
            }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        guard runtime.didReachListMediaGate else {
            firstLoad.cancel()
            runtime.releaseListMediaGate()
            _ = await waitForCompletion(of: firstLoad, description: "the first attachment load")
            Issue.record("Expected media reference resolution to reach the fake listMedia gate")
            return
        }

        firstLoad.cancel()
        for _ in 0..<100 {
            if case .idle = stateStore.state {
                break
            }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        guard case .idle = stateStore.state else {
            runtime.releaseListMediaGate()
            _ = await waitForCompletion(of: firstLoad, description: "the cancelled first attachment load")
            Issue.record("Expected cancellation to clear the attachment loading state")
            return
        }

        let retry = Task { await state.loadMediaAttachment(attachment, for: message) }
        retryLoad = retry
        for _ in 0..<100 {
            if case .loading = stateStore.state {
                break
            }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        guard case .loading = stateStore.state else {
            retry.cancel()
            runtime.releaseListMediaGate()
            _ = await waitForCompletion(of: firstLoad, description: "the cancelled first attachment load")
            _ = await waitForCompletion(of: retry, description: "the retried attachment load")
            Issue.record("Expected a later attachment load to retry reference resolution")
            return
        }

        runtime.releaseListMediaGate()
        let firstLoadFinished = await waitForCompletion(
            of: firstLoad,
            description: "the cancelled first attachment load"
        )
        let retryFinished = await waitForCompletion(of: retry, description: "the retried attachment load")
        guard firstLoadFinished, retryFinished else { return }

        guard case .loaded(let download) = stateStore.state else {
            Issue.record("Expected the retried attachment load to complete")
            return
        }
        #expect(download.data == plaintext)
        #expect(runtime.listMediaCallCount == 1)
        #expect(runtime.downloadMediaCallCount == 1)
    }

    @MainActor
    @Test func mediaAttachmentDownloadTimeoutReleasesLimiterAfterUnderlyingCallReturns() async throws {
        let previousTimeout = MediaAttachmentDownloadConcurrency.ffiDownloadTimeoutNanoseconds
        defer { MediaAttachmentDownloadConcurrency.ffiDownloadTimeoutNanoseconds = previousTimeout }
        MediaAttachmentDownloadConcurrency.ffiDownloadTimeoutNanoseconds = 50_000_000

        let previousActiveAccount = UserDefaults.standard.object(forKey: "whitenoise.mac.activeAccountId")
        defer { restoreDefault(previousActiveAccount, forKey: "whitenoise.mac.activeAccountId") }
        UserDefaults.standard.set("Desktop Account", forKey: "whitenoise.mac.activeAccountId")

        let account = AccountSummaryFfi(
            label: "Desktop Account",
            accountIdHex: "abcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890",
            localSigning: true,
            externalSigning: false,
            signedOut: false,
            running: false
        )
        let stalledPlaintext = Data([0x01, 0x02, 0x03])
        let stalledReference = mediaAttachmentReference(
            sourceEpoch: 7,
            mediaType: "image/png",
            fileName: "stalled.png",
            plaintextSha256: hexSHA256(stalledPlaintext)
        )
        let followUpPlaintext = Data([0x04, 0x05, 0x06])
        let followUpReference = mediaAttachmentReference(
            sourceEpoch: 7,
            mediaType: "image/png",
            fileName: "follow-up.png",
            plaintextSha256: hexSHA256(followUpPlaintext)
        )
        let stalledDownload = MediaDownloadResultFfi(
            plaintext: stalledPlaintext,
            fileName: "stalled.png",
            mediaType: "image/png",
            sizeBytes: UInt64(stalledPlaintext.count)
        )
        let followUpDownload = MediaDownloadResultFfi(
            plaintext: followUpPlaintext,
            fileName: "follow-up.png",
            mediaType: "image/png",
            sizeBytes: UInt64(followUpPlaintext.count)
        )
        let runtime = FakeMarmotRuntime(accounts: [account])
        runtime.installGroup(messageGroup())
        runtime.installMediaRecord(
            MediaRecordFfi(
                messageIdHex: "stalled-media-message",
                attachmentIndex: 0,
                direction: "inbound",
                groupIdHex: "group",
                sender: "alice",
                reference: stalledReference,
                caption: nil,
                recordedAt: 1_700_000_000,
                receivedAt: 1_700_000_000
            ),
            download: stalledDownload
        )
        runtime.installMediaRecord(
            MediaRecordFfi(
                messageIdHex: "follow-up-media-message",
                attachmentIndex: 0,
                direction: "inbound",
                groupIdHex: "group",
                sender: "alice",
                reference: followUpReference,
                caption: nil,
                recordedAt: 1_700_000_001,
                receivedAt: 1_700_000_001
            ),
            download: followUpDownload
        )
        let state = WorkspaceState(clientFactory: { runtime })
        await state.bootstrap()
        let stalledMessage = MessageItem(
            id: "stalled-media-message",
            groupIdHex: "group",
            senderName: "Alice",
            body: "",
            sentAt: Date(timeIntervalSince1970: 1_700_000_000),
            isOutgoing: false,
            mediaAttachments: [
                MessageMediaAttachment(
                    id: "stalled-media-message#0#\(stalledReference.plaintextSha256)",
                    reference: stalledReference
                )
            ]
        )
        let followUpMessage = MessageItem(
            id: "follow-up-media-message",
            groupIdHex: "group",
            senderName: "Alice",
            body: "",
            sentAt: Date(timeIntervalSince1970: 1_700_000_001),
            isOutgoing: false,
            mediaAttachments: [
                MessageMediaAttachment(
                    id: "follow-up-media-message#0#\(followUpReference.plaintextSha256)",
                    reference: followUpReference
                )
            ]
        )
        let stalledAttachment = try #require(stalledMessage.mediaAttachments.first)
        let followUpAttachment = try #require(followUpMessage.mediaAttachments.first)
        let stalledStore = state.mediaDownloadStateStore(for: stalledMessage, attachment: stalledAttachment)
        let heldSlotCount = MediaAttachmentDownloadConcurrency.maxConcurrentDownloads - 1
        for _ in 0..<heldSlotCount {
            try await MediaAttachmentDownloadLimiter.shared.acquire()
        }
        defer {
            Task {
                for _ in 0..<heldSlotCount {
                    await MediaAttachmentDownloadLimiter.shared.release()
                }
            }
        }

        runtime.mediaDownloadGateEnabled = true
        let stalledLoad = Task { await state.loadMediaAttachment(stalledAttachment, for: stalledMessage) }
        for _ in 0..<100 {
            if runtime.didReachMediaDownloadGate {
                break
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        guard runtime.didReachMediaDownloadGate else {
            stalledLoad.cancel()
            runtime.releaseMediaDownloadGate()
            Issue.record("Expected stalled attachment download to reach the fake download gate")
            return
        }
        for _ in 0..<40 {
            if case .failed = stalledStore.state {
                break
            }
            try await Task.sleep(nanoseconds: 25_000_000)
        }

        guard case .failed(let stalledFailure) = stalledStore.state else {
            stalledLoad.cancel()
            runtime.releaseMediaDownloadGate()
            Issue.record("Expected stalled attachment download to fail after timeout")
            return
        }
        _ = await stalledLoad.result
        #expect(stalledFailure == MediaAttachmentDownloadTimeoutError().localizedDescription)

        runtime.releaseMediaDownloadGate()
        runtime.mediaDownloadGateEnabled = false
        for _ in 0..<10 {
            await Task.yield()
        }

        do {
            try await withMediaAttachmentDownloadTimeout(nanoseconds: 500_000_000) {
                await state.loadMediaAttachment(followUpAttachment, for: followUpMessage)
            }
        } catch {
            Issue.record(
                "Expected follow-up attachment download to acquire the completed operation's slot, got \(error)")
            return
        }
        guard
            case .loaded(let loaded) = state.mediaDownloadState(
                for: followUpMessage,
                attachment: followUpAttachment
            )
        else {
            Issue.record("Expected follow-up attachment download to succeed after the stalled call returned")
            return
        }
        #expect(loaded.data == followUpPlaintext)
    }

    @Test func messageAudioMetadataCacheHitPerformanceGuard() async throws {
        let analysisCount = AtomicCounter()
        let expected = MediaWaveformAnalyzer.Metadata(
            durationSeconds: 3,
            samples: Array(repeating: 0.5, count: MediaWaveformAnalyzer.sampleCount)
        )
        let cache = MessageAudioMetadataCache(entryLimit: 4) { _, _ in
            analysisCount.increment()
            return expected
        }
        let payload = DownloadedMediaPayload(id: "audio-cache-hit", data: Data(repeating: 0x41, count: 8 * 1024 * 1024))

        #expect(await cache.metadata(for: payload, mediaType: "audio/mp4") == expected)
        let hitMilliseconds = await measuredMillisecondsAsync {
            for _ in 0..<5_000 {
                _ = await cache.metadata(for: payload, mediaType: "audio/mp4")
            }
        }

        print("PERF audio_metadata_cache_hit_ms=\(formatMilliseconds(hitMilliseconds)) hits=5000")
        #expect(analysisCount.value == 1)
        #expect(hitMilliseconds < 60 * performanceSlack)
    }

    @MainActor
    @Test func mediaDownloadStateStoresDoNotInvalidateWorkspaceObservationForUnrelatedDownloads() async throws {
        let previousActiveAccount = UserDefaults.standard.object(forKey: "whitenoise.mac.activeAccountId")
        defer { restoreDefault(previousActiveAccount, forKey: "whitenoise.mac.activeAccountId") }
        UserDefaults.standard.set("Desktop Account", forKey: "whitenoise.mac.activeAccountId")

        let account = AccountSummaryFfi(
            label: "Desktop Account",
            accountIdHex: "abcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890",
            localSigning: true,
            externalSigning: false,
            signedOut: false,
            running: false
        )
        let firstReference = mediaAttachmentReference(
            sourceEpoch: 0,
            mediaType: "image/png",
            fileName: "first.png",
            ciphertextSha256: String(repeating: "1", count: 64),
            plaintextSha256: String(repeating: "2", count: 64)
        )
        let firstDownloadReference = mediaAttachmentReference(
            sourceEpoch: 7,
            mediaType: "image/png",
            fileName: "first.png",
            ciphertextSha256: firstReference.ciphertextSha256,
            plaintextSha256: firstReference.plaintextSha256
        )
        let secondReference = mediaAttachmentReference(
            sourceEpoch: 0,
            mediaType: "image/png",
            fileName: "second.png",
            ciphertextSha256: String(repeating: "3", count: 64),
            plaintextSha256: String(repeating: "4", count: 64)
        )
        let secondDownloadReference = mediaAttachmentReference(
            sourceEpoch: 7,
            mediaType: "image/png",
            fileName: "second.png",
            ciphertextSha256: secondReference.ciphertextSha256,
            plaintextSha256: secondReference.plaintextSha256
        )
        let secondDownload = MediaDownloadResultFfi(
            plaintext: Data([0x10, 0x20, 0x30, 0x40]),
            fileName: "second.png",
            mediaType: "image/png",
            sizeBytes: 4
        )
        let runtime = FakeMarmotRuntime(accounts: [account])
        func mediaRecord(
            messageId: String,
            reference: MediaAttachmentReferenceFfi,
            recordedAt: UInt64
        ) -> MediaRecordFfi {
            MediaRecordFfi(
                messageIdHex: messageId,
                attachmentIndex: 0,
                direction: "inbound",
                groupIdHex: "group",
                sender: "alice",
                reference: reference,
                caption: nil,
                recordedAt: recordedAt,
                receivedAt: recordedAt
            )
        }
        runtime.installMediaRecord(
            mediaRecord(
                messageId: "first-media-message",
                reference: firstDownloadReference,
                recordedAt: 1_700_000_000
            ),
            download: MediaDownloadResultFfi(
                plaintext: Data([0x01, 0x02, 0x03, 0x04]),
                fileName: "first.png",
                mediaType: "image/png",
                sizeBytes: 4
            )
        )
        runtime.installMediaRecord(
            mediaRecord(
                messageId: "second-media-message",
                reference: secondDownloadReference,
                recordedAt: 1_700_000_001
            ),
            download: secondDownload
        )
        let state = WorkspaceState(clientFactory: { runtime })
        await state.bootstrap()
        let firstMessage = MessageItem(
            id: "first-media-message",
            groupIdHex: "group",
            senderName: "Alice",
            body: "",
            sentAt: Date(timeIntervalSince1970: 1_700_000_000),
            isOutgoing: false,
            mediaAttachments: [
                MessageMediaAttachment(
                    id: "first-media-message#0#\(firstReference.plaintextSha256)",
                    reference: firstReference
                )
            ]
        )
        let secondMessage = MessageItem(
            id: "second-media-message",
            groupIdHex: "group",
            senderName: "Alice",
            body: "",
            sentAt: Date(timeIntervalSince1970: 1_700_000_001),
            isOutgoing: false,
            mediaAttachments: [
                MessageMediaAttachment(
                    id: "second-media-message#0#\(secondReference.plaintextSha256)",
                    reference: secondReference
                )
            ]
        )
        let firstAttachment = try #require(firstMessage.mediaAttachments.first)
        let secondAttachment = try #require(secondMessage.mediaAttachments.first)
        let firstStore = state.mediaDownloadStateStore(for: firstMessage, attachment: firstAttachment)
        let sameFirstStore = state.mediaDownloadStateStore(for: firstMessage, attachment: firstAttachment)
        let secondStore = state.mediaDownloadStateStore(for: secondMessage, attachment: secondAttachment)

        #expect(firstStore === sameFirstStore)
        #expect(firstStore !== secondStore)

        let workspaceInvalidated = ObservationInvalidationFlag()
        withObservationTracking {
            _ = state.mediaDownloadStateStore(for: firstMessage, attachment: firstAttachment)
        } onChange: {
            workspaceInvalidated.markInvalidated()
        }

        let firstStoreInvalidated = ObservationInvalidationFlag()
        withObservationTracking {
            _ = firstStore.state
        } onChange: {
            firstStoreInvalidated.markInvalidated()
        }

        await state.loadMediaAttachment(secondAttachment, for: secondMessage)

        #expect(!workspaceInvalidated.value)
        #expect(!firstStoreInvalidated.value)
        #expect(firstStore.state == .idle)
        #expect(runtime.listMediaCallCount == 1)
        #expect(runtime.downloadMediaCallCount == 1)
        guard case .loaded(let loaded) = secondStore.state else {
            Issue.record("Expected the unrelated download store to receive the loaded state")
            return
        }
        #expect(loaded.data == secondDownload.plaintext)
        await state.deleteAllData()
    }

    @Test func pendingMediaDraftThumbnailDecoderDownsamplesLargeImage() async throws {
        let data = try Self.jpegData(width: 640, height: 480)
        let productionTileMaxPixelSize = 148
        let image = try #require(
            PendingMediaDraftThumbnailDecoder.image(
                from: data,
                maxPixelSize: CGFloat(productionTileMaxPixelSize)
            )
        )
        let representation = try #require(image.representations.first)

        #expect(max(representation.pixelsWide, representation.pixelsHigh) <= productionTileMaxPixelSize)
    }

    @Test func pendingMediaDraftThumbnailDecoderRejectsInvalidImageData() async throws {
        let image = PendingMediaDraftThumbnailDecoder.image(
            from: Data([0x00, 0x01, 0x02, 0x03]),
            maxPixelSize: 74
        )

        #expect(image == nil)
    }

    @Test func pastedImageDraftProcessorEncodesImageAttachment() async throws {
        let attachment = try await OutgoingMediaDraftProcessor.preparedAttachment(
            fromPastedImageData: try Self.testPNGData(width: 48, height: 32),
            typeIdentifier: UTType.png.identifier
        )

        #expect(attachment.kind == .image)
        #expect(attachment.mediaType == "image/jpeg")
        #expect(attachment.dim == "48x32")
        #expect(attachment.fileName.hasPrefix("pasted-image-"))
        #expect(attachment.fileName.hasSuffix(".jpg"))
        #expect(attachment.data.count <= OutgoingMediaDraftProcessor.maxImageAttachmentBytes)
    }

    @Test func remoteImageLoaderCoalescesConcurrentLoadsForSameCacheKey() async throws {
        RemoteImageURLProtocolStub.reset(data: Self.singlePixelPNG, responseDelay: 0.2)
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [RemoteImageURLProtocolStub.self]
        config.urlCache = nil
        let loader = RemoteImageLoader(session: URLSession(configuration: config))
        let url = try #require(URL(string: "https://example.com/avatar.png"))

        async let first = loader.image(for: url, maxPixelSize: 32)
        async let second = loader.image(for: url, maxPixelSize: 32)
        async let third = loader.image(for: url, maxPixelSize: 32)

        let results = await [first, second, third]

        #expect(results.allSatisfy { $0 != nil })
        #expect(RemoteImageURLProtocolStub.requestCount() == 1)
    }

    @Test func remoteImageLoaderCancelsCoalescedDownloadAfterLastWaiterCancels() async throws {
        RemoteImageURLProtocolStub.reset(data: Self.singlePixelPNG, responseDelay: 2)
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [RemoteImageURLProtocolStub.self]
        config.urlCache = nil
        let loader = RemoteImageLoader(session: URLSession(configuration: config))
        let url = try #require(URL(string: "https://example.com/avatar.png"))

        let first = Task { await loader.image(for: url, maxPixelSize: 32) }

        let requestStarted = await waitFor { RemoteImageURLProtocolStub.requestCount() == 1 }
        #expect(requestStarted)

        let second = Task { await loader.image(for: url, maxPixelSize: 32) }

        let secondJoined = await waitFor {
            loader.inFlightWaiterCount(for: url, maxPixelSize: 32) == 2
                && RemoteImageURLProtocolStub.requestCount() == 1
        }
        #expect(secondJoined)

        first.cancel()
        let firstReleased = await waitFor {
            loader.inFlightWaiterCount(for: url, maxPixelSize: 32) == 1
        }
        #expect(firstReleased)
        #expect(RemoteImageURLProtocolStub.stopLoadingCount() == 0)

        second.cancel()

        let requestCancelled = await waitFor {
            RemoteImageURLProtocolStub.stopLoadingCount() == 1
                && loader.inFlightWaiterCount(for: url, maxPixelSize: 32) == 0
        }
        #expect(requestCancelled)

        let results = await [first.value, second.value]
        #expect(results.allSatisfy { $0 == nil })
        #expect(RemoteImageURLProtocolStub.requestCount() == 1)
    }

    @Test func remoteImageLoaderUsesBoundedDecodedCache() async throws {
        let config = URLSessionConfiguration.ephemeral
        let loader = RemoteImageLoader(session: URLSession(configuration: config))

        #expect(loader.decodedCacheCountLimit == RemoteImageLoader.defaultDecodedCacheCountLimit)
        #expect(loader.decodedCacheTotalCostLimit == RemoteImageLoader.defaultDecodedCacheTotalCostLimit)
        #expect(loader.decodedCacheCountLimit > 0)
        #expect(loader.decodedCacheTotalCostLimit > 0)
    }

    @Test func remoteImageLoaderDefaultSessionPinsMemoryOnlyURLCacheInvariant() async throws {
        let config = RemoteImageLoader.makeSessionConfiguration()
        let urlCache = try #require(config.urlCache)

        // Foundation does not expose a stable cross-platform seam for asserting URLCache disk
        // writes directly, so pin the privacy invariant that prevents them for the default loader.
        #expect(urlCache.memoryCapacity > 0)
        #expect(urlCache.diskCapacity == 0)
        #expect(config.timeoutIntervalForRequest == RemoteImageURLPolicy.downloadStallTimeout)
        #expect(config.timeoutIntervalForResource == RemoteImageURLPolicy.downloadResourceTimeout)
        #expect(config.timeoutIntervalForResource > config.timeoutIntervalForRequest)
        #expect(config.requestCachePolicy == .useProtocolCachePolicy)
    }

    @Test func remoteImageLoaderDownsamplesAndCachesLocalAttachmentBytes() async throws {
        let config = URLSessionConfiguration.ephemeral
        let loader = RemoteImageLoader(session: URLSession(configuration: config))
        let imageData = try Self.testPNGData(width: 400, height: 300)

        let small = try #require(
            await loader.image(for: imageData, cacheKey: "attachment-1", maxPixelSize: 64)
        )
        let smallSize = try #require(Self.pixelSize(of: small.nsImage))
        #expect(max(smallSize.width, smallSize.height) <= 64)

        let cached = try #require(
            await loader.image(for: Data([0x00]), cacheKey: "attachment-1", maxPixelSize: 64)
        )
        #expect(cached.nsImage === small.nsImage)

        let large = try #require(
            await loader.image(for: imageData, cacheKey: "attachment-1", maxPixelSize: 128)
        )
        let largeSize = try #require(Self.pixelSize(of: large.nsImage))
        #expect(max(largeSize.width, largeSize.height) <= 128)
        #expect(max(largeSize.width, largeSize.height) > max(smallSize.width, smallSize.height))
    }

    @Test func remoteImageLoaderClearCacheEvictsDecodedImages() async throws {
        let config = URLSessionConfiguration.ephemeral
        let loader = RemoteImageLoader(session: URLSession(configuration: config))
        let imageData = try Self.testPNGData(width: 400, height: 300)

        let decoded = try #require(
            await loader.image(for: imageData, cacheKey: "attachment-1", maxPixelSize: 64)
        )
        let cached = try #require(
            await loader.image(for: Data([0x00]), cacheKey: "attachment-1", maxPixelSize: 64)
        )
        #expect(cached.nsImage === decoded.nsImage)

        loader.clearCache()

        // After a wipe the previously decoded bytes must be gone, so a cache-key-only lookup with
        // bogus bytes can no longer be served and a real re-decode produces a fresh instance.
        #expect(await loader.image(for: Data([0x00]), cacheKey: "attachment-1", maxPixelSize: 64) == nil)
        let reDecoded = try #require(
            await loader.image(for: imageData, cacheKey: "attachment-1", maxPixelSize: 64)
        )
        #expect(reDecoded.nsImage !== decoded.nsImage)
    }

    @Test func remoteImageLoaderClearLocalCachePreservesRemoteImages() async throws {
        RemoteImageURLProtocolStub.reset(data: Self.singlePixelPNG, responseDelay: 0)
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [RemoteImageURLProtocolStub.self]
        config.urlCache = nil
        let loader = RemoteImageLoader(session: URLSession(configuration: config))
        let url = try #require(URL(string: "https://example.com/avatar.png"))
        let localData = try Self.testPNGData(width: 64, height: 64)

        let remote = try #require(await loader.image(for: url, maxPixelSize: 32))
        let local = try #require(
            await loader.image(for: localData, cacheKey: "attachment-1", maxPixelSize: 32)
        )

        loader.clearLocalCache()

        let remoteAfterClear = try #require(await loader.image(for: url, maxPixelSize: 32))
        #expect(remoteAfterClear.nsImage === remote.nsImage)
        #expect(RemoteImageURLProtocolStub.requestCount() == 1)
        #expect(
            await loader.image(for: Data([0x00]), cacheKey: "attachment-1", maxPixelSize: 32) == nil
        )
        let localAfterClear = try #require(
            await loader.image(for: localData, cacheKey: "attachment-1", maxPixelSize: 32)
        )
        #expect(localAfterClear.nsImage !== local.nsImage)
    }

    @Test func remoteImageLoaderClearCacheInvalidatesInFlightLoads() async throws {
        RemoteImageURLProtocolStub.reset(data: Self.singlePixelPNG, responseDelay: 0.2)
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [RemoteImageURLProtocolStub.self]
        config.urlCache = nil
        let loader = RemoteImageLoader(session: URLSession(configuration: config))
        let url = try #require(URL(string: "https://example.com/avatar.png"))

        let pending = Task { await loader.image(for: url, maxPixelSize: 32) }
        let requestStarted = await waitFor {
            RemoteImageURLProtocolStub.requestCount() == 1
                && loader.inFlightWaiterCount(for: url, maxPixelSize: 32) == 1
        }
        #expect(requestStarted)

        loader.clearCache()

        let inFlightCleared = await waitFor {
            loader.inFlightWaiterCount(for: url, maxPixelSize: 32) == 0
        }
        #expect(inFlightCleared)
        let requestCancelled = await waitFor {
            RemoteImageURLProtocolStub.stopLoadingCount() >= 1
        }
        #expect(requestCancelled)
        #expect(await pending.value == nil)

        let reloaded = try #require(await loader.image(for: url, maxPixelSize: 32))
        #expect(reloaded.nsImage.size.width > 0)
        #expect(RemoteImageURLProtocolStub.requestCount() == 2)
    }

    @Test func remoteImageLoaderSeparatesRemoteAndLocalCacheNamespaces() async throws {
        RemoteImageURLProtocolStub.reset(data: Self.singlePixelPNG, responseDelay: 0)
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [RemoteImageURLProtocolStub.self]
        config.urlCache = nil
        let loader = RemoteImageLoader(session: URLSession(configuration: config))
        let url = try #require(URL(string: "https://example.com/avatar.png"))
        let localData = try Self.testPNGData(width: 64, height: 64)

        let remote = try #require(await loader.image(for: url, maxPixelSize: 32))
        let local = try #require(
            await loader.image(for: localData, cacheKey: url.absoluteString, maxPixelSize: 32)
        )
        let localCached = try #require(
            await loader.image(for: Data([0x00]), cacheKey: url.absoluteString, maxPixelSize: 32)
        )

        #expect(remote.nsImage !== local.nsImage)
        #expect(localCached.nsImage === local.nsImage)
        #expect(RemoteImageURLProtocolStub.requestCount() == 1)
    }

    /// The reason the fix exists. Bytes the app already holds for a URL are decoded from memory,
    /// so the avatar that has just been pointed at a freshly uploaded picture draws it instead of
    /// spending a round trip on initials. Primed with a 200x120 image while the network serves a
    /// 1x1, so the decoded size says *which* bytes were used rather than only that nothing was
    /// fetched.
    @Test func remoteImageLoaderServesPrimedSourceBytesWithoutFetching() async throws {
        RemoteImageURLProtocolStub.reset(data: Self.singlePixelPNG, responseDelay: 0)
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [RemoteImageURLProtocolStub.self]
        config.urlCache = nil
        let loader = RemoteImageLoader(session: URLSession(configuration: config))
        let url = try #require(URL(string: "https://blossom.example/just-uploaded.png"))
        let uploaded = try Self.testPNGData(width: 200, height: 120)

        loader.primeRemoteImage(url: url, data: uploaded)

        let small = try #require(await loader.image(for: url, maxPixelSize: 64))
        let smallSize = try #require(Self.pixelSize(of: small.nsImage))
        #expect(smallSize.width == 64)
        #expect(RemoteImageURLProtocolStub.requestCount() == 0)

        // A second size is a second decode of the same primed bytes, not a download: the rail,
        // the form, and the switcher all draw this URL at different sizes.
        let large = try #require(await loader.image(for: url, maxPixelSize: 128))
        let largeSize = try #require(Self.pixelSize(of: large.nsImage))
        #expect(largeSize.width == 128)
        #expect(RemoteImageURLProtocolStub.requestCount() == 0)
    }

    /// A decode that is already in the cache is readable synchronously, which is what lets a view
    /// draw it on its first frame instead of flashing initials for one pass of the async load.
    /// Keyed by size like the async path, so a warm 64px entry does not answer for a 128px view.
    @Test func remoteImageLoaderExposesAnAlreadyDecodedImageSynchronously() async throws {
        RemoteImageURLProtocolStub.reset(data: Self.singlePixelPNG, responseDelay: 0)
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [RemoteImageURLProtocolStub.self]
        config.urlCache = nil
        let loader = RemoteImageLoader(session: URLSession(configuration: config))
        let url = try #require(URL(string: "https://example.com/avatar.png"))

        #expect(loader.decodedImage(for: url, maxPixelSize: 32) == nil)

        let loaded = try #require(await loader.image(for: url, maxPixelSize: 32))

        let peeked = try #require(loader.decodedImage(for: url, maxPixelSize: 32))
        #expect(peeked.nsImage === loaded.nsImage)
        #expect(loader.decodedImage(for: url, maxPixelSize: 64) == nil)
        #expect(RemoteImageURLProtocolStub.requestCount() == 1)
    }

    /// A disallowed URL cannot be primed into being loadable. Priming is a shortcut past the
    /// *network*, never past `RemoteImageURLPolicy`.
    @Test func remoteImageLoaderRefusesToPrimeADisallowedURL() async throws {
        let config = URLSessionConfiguration.ephemeral
        let loader = RemoteImageLoader(session: URLSession(configuration: config))
        let url = try #require(URL(string: "https://192.168.1.10/avatar.png"))
        let uploaded = try Self.testPNGData(width: 64, height: 64)

        loader.primeRemoteImage(url: url, data: uploaded)

        #expect(loader.primedSourceByteCount(for: url) == nil)
        #expect(await loader.image(for: url, maxPixelSize: 32) == nil)
    }

    /// Empty and oversized bodies are rejected, so `primedSourceLimit` bounds bytes held and not
    /// merely a count.
    @Test func remoteImageLoaderRejectsEmptyAndOversizedPrimedBytes() async throws {
        let config = URLSessionConfiguration.ephemeral
        let loader = RemoteImageLoader(session: URLSession(configuration: config))
        let url = try #require(URL(string: "https://blossom.example/just-uploaded.png"))

        loader.primeRemoteImage(url: url, data: Data())
        #expect(loader.primedSourceByteCount(for: url) == nil)

        let oversized = Data(count: Int(RemoteImageURLPolicy.maxResponseBytes) + 1)
        loader.primeRemoteImage(url: url, data: oversized)
        #expect(loader.primedSourceByteCount(for: url) == nil)

        let allowed = try Self.testPNGData(width: 32, height: 32)
        loader.primeRemoteImage(url: url, data: allowed)
        #expect(loader.primedSourceByteCount(for: url) == allowed.count)
    }

    /// Oldest primed entry out first past the limit, and a re-prime of the same URL replaces its
    /// bytes rather than adding a second copy.
    @Test func remoteImageLoaderEvictsThePrimedSourceItHeldLongest() async throws {
        let config = URLSessionConfiguration.ephemeral
        let loader = RemoteImageLoader(session: URLSession(configuration: config))
        let uploaded = try Self.testPNGData(width: 40, height: 40)
        let urls = try (0...RemoteImageLoader.primedSourceLimit).map { index in
            try #require(URL(string: "https://blossom.example/upload-\(index).png"))
        }

        for url in urls {
            loader.primeRemoteImage(url: url, data: uploaded)
        }

        #expect(loader.primedSourceByteCount(for: urls[0]) == nil)
        #expect(urls.dropFirst().allSatisfy { loader.primedSourceByteCount(for: $0) == uploaded.count })

        let replacement = try Self.testPNGData(width: 48, height: 48)
        let newest = try #require(urls.last)
        loader.primeRemoteImage(url: newest, data: replacement)

        #expect(loader.primedSourceByteCount(for: newest) == replacement.count)
        // The re-prime must not have pushed a still-wanted entry out by occupying a second slot.
        #expect(loader.primedSourceByteCount(for: urls[1]) == uploaded.count)
    }

    /// The privacy wipes drop primed bytes too. They are the viewer's own picture, and a primed
    /// URL that outlived its account would keep serving bytes no fetch could have produced.
    @Test func remoteImageLoaderClearCacheDropsPrimedSourceBytes() async throws {
        RemoteImageURLProtocolStub.reset(data: Self.singlePixelPNG, responseDelay: 0)
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [RemoteImageURLProtocolStub.self]
        config.urlCache = nil
        let loader = RemoteImageLoader(session: URLSession(configuration: config))
        let url = try #require(URL(string: "https://blossom.example/just-uploaded.png"))
        let uploaded = try Self.testPNGData(width: 200, height: 120)

        loader.primeRemoteImage(url: url, data: uploaded)
        _ = try #require(await loader.image(for: url, maxPixelSize: 64))
        #expect(RemoteImageURLProtocolStub.requestCount() == 0)

        loader.clearCache()

        #expect(loader.primedSourceByteCount(for: url) == nil)
        let afterClear = try #require(await loader.image(for: url, maxPixelSize: 64))
        let afterClearSize = try #require(Self.pixelSize(of: afterClear.nsImage))
        // Served from the network now, which is the 1x1 the stub answers with rather than the
        // 200-wide upload that decoded to a full 64px above.
        #expect(afterClearSize.width < 64)
        #expect(RemoteImageURLProtocolStub.requestCount() == 1)
    }

    /// `clearLocalCache()` is the media wipe, and it deliberately leaves remote avatars warm — so
    /// it must not throw away the bytes that keep the account's own picture drawing either.
    @Test func remoteImageLoaderClearLocalCachePreservesPrimedSourceBytes() async throws {
        let config = URLSessionConfiguration.ephemeral
        let loader = RemoteImageLoader(session: URLSession(configuration: config))
        let url = try #require(URL(string: "https://blossom.example/just-uploaded.png"))
        let uploaded = try Self.testPNGData(width: 64, height: 64)

        loader.primeRemoteImage(url: url, data: uploaded)
        loader.clearLocalCache()

        #expect(loader.primedSourceByteCount(for: url) == uploaded.count)
    }

    private static let singlePixelPNG = Data([
        0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A,
        0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52,
        0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
        0x08, 0x06, 0x00, 0x00, 0x00, 0x1F, 0x15, 0xC4,
        0x89, 0x00, 0x00, 0x00, 0x0D, 0x49, 0x44, 0x41,
        0x54, 0x78, 0x9C, 0x63, 0xF8, 0xCF, 0xC0, 0xF0,
        0x1F, 0x00, 0x05, 0x00, 0x01, 0xFF, 0x89, 0x99,
        0x3D, 0x1D, 0x00, 0x00, 0x00, 0x00, 0x49, 0x45,
        0x4E, 0x44, 0xAE, 0x42, 0x60, 0x82,
    ])

    private static func jpegData(width: Int, height: Int) throws -> Data {
        let bytesPerPixel = 4
        let bytesPerRow = width * bytesPerPixel
        var pixels = [UInt8](repeating: 0, count: height * bytesPerRow)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue
        let cgImage = pixels.withUnsafeMutableBytes { bytes -> CGImage? in
            guard
                let context = CGContext(
                    data: bytes.baseAddress,
                    width: width,
                    height: height,
                    bitsPerComponent: 8,
                    bytesPerRow: bytesPerRow,
                    space: colorSpace,
                    bitmapInfo: bitmapInfo
                )
            else {
                return nil
            }
            context.setFillColor(NSColor.systemBlue.cgColor)
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            return context.makeImage()
        }
        let image = try #require(cgImage)
        let data = NSMutableData()
        let destination = try #require(
            CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil)
        )
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
        return data as Data
    }

    private static func pixelSize(of image: NSImage) -> (width: Int, height: Int)? {
        guard let representation = image.representations.first else { return nil }
        return (representation.pixelsWide, representation.pixelsHigh)
    }
}
