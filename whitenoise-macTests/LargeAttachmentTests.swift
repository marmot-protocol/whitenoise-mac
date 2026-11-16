//
//  LargeAttachmentTests.swift
//  whitenoise-macTests
//
//  Attachments up to MDK's 512 MiB blob limit: images keep their decode limit, a message never
//  passes MDK's per-send bound, attachments over the draft cap stay out of saved drafts and are not
//  uploaded ahead of Send, and their message streams to MDK from files.
//

import Foundation
import MarmotKit
import Testing

@testable import whitenoise_mac

struct LargeAttachmentTests: WorkspaceTestSupport {
    private static let accountRef = "Desktop Account"

    @MainActor
    private static func bootstrappedState() async -> (WorkspaceState, FakeMarmotRuntime) {
        let account = AccountSummaryFfi(
            label: accountRef,
            accountIdHex: "abcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890",
            localSigning: true,
            externalSigning: false,
            signedOut: false,
            running: true,
            unlinked: false
        )
        let runtime = FakeMarmotRuntime(accounts: [account])
        runtime.installDirectGroup(
            directGroup(),
            selfAccountIdHex: account.accountIdHex,
            otherAccountIdHex: "alice1234567890alice1234567890alice1234567890alice1234567890",
            otherDisplayName: "Alice",
            otherProfile: UserProfileMetadataFfi(
                name: "alice", displayName: "Alice", about: nil, picture: nil, nip05: nil, lud16: nil
            )
        )
        let state = WorkspaceState(clientFactory: { runtime })
        await state.bootstrap()
        return (state, runtime)
    }

    private static func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    /// A file whose reported size is past a cap without writing its bytes to disk.
    private static func sparseFile(at url: URL, byteCount: Int) throws {
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.truncate(atOffset: UInt64(byteCount))
    }

    private static func video(byteCount: Int, name: String = "holiday.mov") -> PendingMediaAttachment {
        var data = Data(count: byteCount)
        data[0] = 0x01
        return PendingMediaAttachment(fileName: name, mediaType: "video/quicktime", data: data, dim: nil)
    }

    // MARK: - Limits

    @Test func theAttachmentCapIsMDKsBlobLimitLessTheTag() {
        #expect(OutgoingMediaDraftProcessor.maxAttachmentBytes == 512 * 1024 * 1024 - 16)
        #expect(OutgoingMediaDraftProcessor.maxImageSourceBytes == 50 * 1024 * 1024)
        #expect(OutgoingMediaDraftProcessor.maxDraftAttachmentBytes == 50 * 1024 * 1024)
        // One attachment at the cap always fits a send on its own.
        #expect(MediaFileUploadLimit.fits(OutgoingMediaDraftProcessor.maxAttachmentBytes, alongside: []))
    }

    @Test func imagesAreBoundByTheirDecodeLimitAndEverythingElseByTheCap() {
        #expect(OutgoingMediaDraftProcessor.maxSourceBytes(for: .image) == 50 * 1024 * 1024)
        #expect(
            OutgoingMediaDraftProcessor.maxSourceBytes(for: .video) == OutgoingMediaDraftProcessor.maxAttachmentBytes)
        #expect(
            OutgoingMediaDraftProcessor.maxSourceBytes(for: .file) == OutgoingMediaDraftProcessor.maxAttachmentBytes)
        #expect(
            OutgoingMediaDraftProcessor.maxSourceBytes(for: .audio) == OutgoingMediaDraftProcessor.maxAttachmentBytes)
    }

    @Test func ciphertextCountsEachAttachmentsTagAndRefusesOverflow() {
        #expect(MediaFileUploadLimit.ciphertextBytes(plaintextByteCounts: []) == 0)
        #expect(MediaFileUploadLimit.ciphertextBytes(plaintextByteCounts: [10, 20]) == 62)
        #expect(MediaFileUploadLimit.ciphertextBytes(plaintextByteCounts: [Int.max, Int.max, Int.max]) == nil)
        #expect(MediaFileUploadLimit.fits(84, alongside: [100], limit: 216))
        #expect(!MediaFileUploadLimit.fits(85, alongside: [100], limit: 216))
    }

    @Test func aNewAudioIsMeasuredAgainstTheAttachmentsLeftAfterItReplacesTheOld() {
        let oldAudio = PendingMediaAttachment(
            fileName: "a.m4a", mediaType: "audio/mp4", data: Data(count: 100), dim: nil)
        let photo = PendingMediaAttachment(fileName: "p.jpg", mediaType: "image/jpeg", data: Data(count: 10), dim: nil)
        let newAudio = PendingMediaAttachment(
            fileName: "b.m4a", mediaType: "audio/mp4", data: Data(count: 150), dim: nil)

        let kept = OutgoingMediaDraftProcessor.attachmentsKept([oldAudio, photo], adding: newAudio)

        #expect(kept.map(\.id) == [photo.id])
        // 10 + 150 plus two tags fits 200; counting the audio it replaces would not.
        #expect(OutgoingMediaDraftProcessor.fitsInOneSend(newAudio, alongside: kept, limit: 200))
        #expect(!OutgoingMediaDraftProcessor.fitsInOneSend(newAudio, alongside: [oldAudio, photo], limit: 200))
    }

    @Test func onlyABatchCarryingSomethingOverTheOldCapStreamsFromFiles() {
        let cap = OutgoingMediaDraftProcessor.maxDraftAttachmentBytes
        #expect(MediaUploadRoute.route(byteCounts: [cap, cap]) == .bytes)
        #expect(MediaUploadRoute.route(byteCounts: [10, cap + 1]) == .files)
    }

    @Test func batchRefusalSaysTheAttachmentsDoNotFitTogether() {
        let english = Locale(identifier: "en")
        let rejection = AttachmentRejection(source: .file(name: "second.mov"), reason: .exceedsBatchLimit)
        #expect(
            rejection.reasonDescription(locale: english)
                == L10n.string("These attachments are too large to send together.", locale: english))
    }

    // MARK: - Reading picked files

    @Test func aPickedFileIsReadThroughAnUnlinkedClone() throws {
        let directory = try Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let scratch = directory.appendingPathComponent("scratch", isDirectory: true)
        let source = directory.appendingPathComponent("clip.mov")
        try Data("movie bytes".utf8).write(to: source)

        let data = try PickedMediaFile.mappedData(from: source, in: scratch)
        // Changing the picked file afterwards leaves the read bytes alone.
        try Data("rewritten!!".utf8).write(to: source)

        #expect(data == Data("movie bytes".utf8))
        #expect(try FileManager.default.contentsOfDirectory(atPath: scratch.path).isEmpty)
    }

    @Test func aCloneOfAnOldFileSurvivesAConcurrentPicksSweep() throws {
        let directory = try Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let scratch = directory.appendingPathComponent("scratch", isDirectory: true)
        let source = directory.appendingPathComponent("old.mov")
        try Data("old movie".utf8).write(to: source)
        let now = Date()
        try FileManager.default.setAttributes(
            [.modificationDate: now.addingTimeInterval(-2 * 60 * 60)], ofItemAtPath: source.path)

        let clone = try PickedMediaFile.makeClone(of: source, in: scratch, now: now)
        defer { try? FileManager.default.removeItem(at: clone) }
        // Another pick's sweep runs between this pick's copy and its read.
        MediaUploadSourceFiles.removeStale(in: scratch, olderThan: PickedMediaFile.staleAge, now: now)

        #expect(FileManager.default.fileExists(atPath: clone.path))
        let modified = try #require(
            try clone.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
        #expect(modified >= now.addingTimeInterval(-1))
    }

    @Test func aSymlinkedFileAttachesItsTargetsBytes() async throws {
        let directory = try Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let notes = directory.appendingPathComponent("notes.txt")
        let contents = Data("the notes".utf8)
        try contents.write(to: notes)
        let link = directory.appendingPathComponent("link.txt")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: notes)

        let attachment = try await OutgoingMediaDraftProcessor.preparedAttachment(fromFileURL: link)

        #expect(attachment.data == contents)
        #expect(attachment.mediaType == "text/plain")
    }

    @Test func aSymlinkIsMeasuredByItsTarget() async throws {
        let directory = try Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let movie = directory.appendingPathComponent("huge.mov")
        try Self.sparseFile(at: movie, byteCount: OutgoingMediaDraftProcessor.maxAttachmentBytes + 1)
        let link = directory.appendingPathComponent("link.mov")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: movie)

        await #expect(throws: OutgoingMediaDraftProcessor.Failure.self) {
            _ = try await OutgoingMediaDraftProcessor.preparedAttachment(fromFileURL: link)
        }
    }

    @MainActor
    @Test func anImageOverItsDecodeLimitIsRefusedBeforeItIsRead() async throws {
        let (state, runtime) = await Self.bootstrappedState()
        let directory = try Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let photo = directory.appendingPathComponent("panorama.png")
        try Self.sparseFile(at: photo, byteCount: OutgoingMediaDraftProcessor.maxImageSourceBytes + 1)

        let rejections = await state.addMediaAttachments(from: [photo])

        #expect(
            rejections == [
                AttachmentRejection(
                    source: .file(name: "panorama.png"),
                    reason: .tooLarge(limitBytes: OutgoingMediaDraftProcessor.maxImageSourceBytes)
                )
            ])
        #expect(state.pendingMediaAttachments.isEmpty)
        #expect(runtime.uploadMediaCallCount == 0)
    }

    @MainActor
    @Test func aVideoOverTheOldCapIsStaged() async throws {
        let (state, _) = await Self.bootstrappedState()
        let directory = try Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let movie = directory.appendingPathComponent("holiday.mov")
        try Self.sparseFile(at: movie, byteCount: OutgoingMediaDraftProcessor.maxDraftAttachmentBytes + 1)

        let rejections = await state.addMediaAttachments(from: [movie])

        #expect(rejections.isEmpty)
        #expect(state.pendingMediaAttachments.map(\.fileName) == ["holiday.mov"])
        #expect(
            state.pendingMediaAttachments.first?.data.count == OutgoingMediaDraftProcessor.maxDraftAttachmentBytes + 1)
    }

    // MARK: - Drafts and sending

    @MainActor
    @Test func anAttachmentOverTheDraftCapIsNeitherSavedNorUploadedAhead() async throws {
        let (state, runtime) = await Self.bootstrappedState()
        let draftKey = try #require(state.selectedComposerDraftKey)
        let small = PendingMediaAttachment(
            fileName: "notes.txt", mediaType: "text/plain", data: Data("notes".utf8), dim: nil)
        let large = Self.video(byteCount: OutgoingMediaDraftProcessor.maxDraftAttachmentBytes + 1)

        #expect(state.appendPendingMediaAttachment(small, for: draftKey))
        #expect(state.appendPendingMediaAttachment(large, for: draftKey))
        await Self.settleComposerMediaUploads(state)
        await state.flushComposerDraftPersistence()

        #expect(state.pendingMediaAttachments.map(\.id) == [small.id, large.id])
        #expect(runtime.uploadedMediaRequests.flatMap(\.request.attachments).map(\.fileName) == ["notes.txt"])
        let stored = try #require(runtime.storedMessageDraft(accountRef: Self.accountRef, groupIdHex: draftKey.chatId))
        #expect(stored.mediaAttachments.map(\.fileName) == ["notes.txt"])
    }

    @MainActor
    @Test func aComposerHoldingOnlyAnUnsavedAttachmentIsNotOverwrittenByARestore() async throws {
        let (state, _) = await Self.bootstrappedState()
        let draftKey = try #require(state.selectedComposerDraftKey)
        let large = Self.video(byteCount: OutgoingMediaDraftProcessor.maxDraftAttachmentBytes + 1)
        #expect(state.appendPendingMediaAttachment(large, for: draftKey))
        state.composerDraftRestores[draftKey] = nil

        await state.restoreComposerDraftIfNeeded(accountId: draftKey.accountId, groupIdHex: draftKey.chatId)

        #expect(state.pendingMediaAttachments.map(\.id) == [large.id])
    }

    @MainActor
    @Test func aMessageCarryingALargeAttachmentStreamsFromFiles() async throws {
        let (state, runtime) = await Self.bootstrappedState()
        let draftKey = try #require(state.selectedComposerDraftKey)
        let large = Self.video(byteCount: OutgoingMediaDraftProcessor.maxDraftAttachmentBytes + 1)
        #expect(state.appendPendingMediaAttachment(large, for: draftKey))
        state.draftText = "Look at this"

        await state.sendDraft()
        await Self.settlePendingOutgoingMediaSends(state)

        #expect(runtime.fileBackedMediaSubmissions.count == 1)
        let submission = try #require(runtime.fileBackedMediaSubmissions.first)
        #expect(submission.groupIdHex == draftKey.chatId)
        #expect(submission.request.send)
        #expect(submission.request.caption == "Look at this")
        #expect(submission.request.attachments.map(\.fileName) == ["holiday.mov"])
        #expect(submission.request.attachments.map(\.expectedSize) == [UInt64(large.data.count)])
        #expect(submission.plaintexts == [large.data])
        // The source files are gone once MDK has returned.
        for attachment in submission.request.attachments {
            #expect(!FileManager.default.fileExists(atPath: attachment.sourcePath))
        }
        #expect(state.lastError == nil)
    }

    @Test func aFailedStagingRemovesWhatItWroteAndLeavesWhatWasThere() throws {
        let directory = try Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let existing = directory.appendingPathComponent("second")
        try Data("not ours".utf8).write(to: existing)
        var names = ["first", "second"].makeIterator()

        #expect(throws: MediaFileUploadFailure.sourceUnavailable) {
            _ = try MediaUploadSourceFiles.stageSynchronously(
                [Self.video(byteCount: 8, name: "a.mov"), Self.video(byteCount: 8, name: "b.mov")],
                in: directory,
                now: Date(),
                fileName: { names.next()! }
            )
        }

        #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("first").path))
        #expect(try Data(contentsOf: existing) == Data("not ours".utf8))
    }

    @MainActor
    @Test func aMessageWithinTheOldCapKeepsTheByteUpload() async throws {
        let (state, runtime) = await Self.bootstrappedState()
        let draftKey = try #require(state.selectedComposerDraftKey)
        let clip = Self.video(byteCount: 1024)
        #expect(state.appendPendingMediaAttachment(clip, for: draftKey))

        await state.sendDraft()
        await Self.settlePendingOutgoingMediaSends(state)

        #expect(runtime.fileBackedMediaSubmissions.isEmpty)
        #expect(runtime.tokenizedMediaSubmissions.count == 1)
        let submission = try #require(runtime.tokenizedMediaSubmissions.first)
        #expect(submission.request.attachments.map(\.plaintext) == [clip.data])
    }
}
