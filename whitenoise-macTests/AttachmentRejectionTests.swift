//
//  AttachmentRejectionTests.swift
//  whitenoise-macTests
//
//  A multi-file selection stages what it can and names every file it could not, each with its
//  own reason and, for size, the limit it broke.
//

import Foundation
import MarmotKit
import Testing

@testable import whitenoise_mac

struct AttachmentRejectionTests: WorkspaceTestSupport {
    @MainActor
    private static func bootstrappedState() async -> (WorkspaceState, FakeMarmotRuntime) {
        let account = AccountSummaryFfi(
            label: "Desktop Account",
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

    /// A file whose reported size is past the cap without writing 50 MB to disk.
    private static func sparseFile(at url: URL, byteCount: Int) throws {
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.truncate(atOffset: UInt64(byteCount))
    }

    @MainActor
    @Test func mixedSelectionKeepsValidFilesAndNamesEachRejectedOne() async throws {
        let (state, runtime) = await Self.bootstrappedState()
        let directory = try Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let notes = directory.appendingPathComponent("notes.txt")
        try Data("hello".utf8).write(to: notes)
        let huge = directory.appendingPathComponent("holiday-video.mov")
        try Self.sparseFile(at: huge, byteCount: OutgoingMediaDraftProcessor.maxAttachmentBytes + 1)
        let photo = directory.appendingPathComponent("photo.png")
        try Self.testPNGData(width: 20, height: 20).write(to: photo)
        let broken = directory.appendingPathComponent("broken.png")
        try Data("not an image".utf8).write(to: broken)

        let rejections = await state.addMediaAttachments(from: [notes, huge, photo, broken])

        #expect(state.pendingMediaAttachments.count == 2)
        #expect(state.pendingMediaAttachments.first?.fileName == "notes.txt")
        #expect(
            rejections == [
                AttachmentRejection(
                    source: .file(name: "holiday-video.mov"),
                    reason: .tooLarge(limitBytes: OutgoingMediaDraftProcessor.maxAttachmentBytes)
                ),
                AttachmentRejection(source: .file(name: "broken.png"), reason: .unreadableImage),
            ])
        // Failures are the notice's to show; they no longer collapse into the global error.
        #expect(state.lastError == nil)
        await Self.settleComposerMediaUploads(state)
        #expect(runtime.uploadMediaCallCount == 2)
    }

    @MainActor
    @Test func selectionPastTheCapNamesEveryFileThatGotNoSlot() async throws {
        let (state, _) = await Self.bootstrappedState()
        let directory = try Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let max = OutgoingMediaDraftProcessor.maxAttachmentCount
        let urls = try (0..<(max + 2)).map { index in
            let url = directory.appendingPathComponent("file-\(index).txt")
            try Data("file \(index)".utf8).write(to: url)
            return url
        }

        let rejections = await state.addMediaAttachments(from: urls)

        #expect(state.pendingMediaAttachments.count == max)
        let capped = AttachmentRejection.Reason.attachmentLimitReached(maxCount: max)
        #expect(
            rejections == [
                AttachmentRejection(source: .file(name: "file-\(max).txt"), reason: capped),
                AttachmentRejection(source: .file(name: "file-\(max + 1).txt"), reason: capped),
            ])
        await Self.settleComposerMediaUploads(state)
    }

    @MainActor
    @Test func fullComposerNamesEveryPickedFileAndStagesNone() async throws {
        let (state, _) = await Self.bootstrappedState()
        let directory = try Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let max = OutgoingMediaDraftProcessor.maxAttachmentCount
        let filling = try (0..<max).map { index in
            let url = directory.appendingPathComponent("file-\(index).txt")
            try Data("file \(index)".utf8).write(to: url)
            return url
        }
        #expect(await state.addMediaAttachments(from: filling).isEmpty)
        #expect(state.pendingMediaAttachments.count == max)

        let extra = directory.appendingPathComponent("extra.txt")
        try Data("extra".utf8).write(to: extra)
        let another = directory.appendingPathComponent("another.txt")
        try Data("another".utf8).write(to: another)
        let capped = AttachmentRejection.Reason.attachmentLimitReached(maxCount: max)

        let fileRejections = await state.addMediaAttachments(from: [extra, another])
        let pasteRejections = await state.addPastedMediaAttachments([
            OutgoingMediaPasteboardAttachment(payload: .fileURL(extra)),
            OutgoingMediaPasteboardAttachment(
                payload: .imageData(try Self.testPNGData(width: 4, height: 4), typeIdentifier: nil)),
        ])

        #expect(
            fileRejections == [
                AttachmentRejection(source: .file(name: "extra.txt"), reason: capped),
                AttachmentRejection(source: .file(name: "another.txt"), reason: capped),
            ])
        #expect(
            pasteRejections == [
                AttachmentRejection(source: .file(name: "extra.txt"), reason: capped),
                AttachmentRejection(source: .pastedImage, reason: capped),
            ])
        #expect(state.pendingMediaAttachments.count == max)
        // The notice names them; the global warning would only say the same thing again.
        #expect(state.lastError == nil)
        await Self.settleComposerMediaUploads(state)
    }

    @MainActor
    @Test func failedPreparationHandsItsSlotToTheNextPickedFile() async throws {
        let (state, _) = await Self.bootstrappedState()
        let directory = try Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let max = OutgoingMediaDraftProcessor.maxAttachmentCount
        let filling = try (0..<(max - 1)).map { index in
            let url = directory.appendingPathComponent("file-\(index).txt")
            try Data("file \(index)".utf8).write(to: url)
            return url
        }
        #expect(await state.addMediaAttachments(from: filling).isEmpty)

        let broken = directory.appendingPathComponent("broken.png")
        try Data("not an image".utf8).write(to: broken)
        let notes = directory.appendingPathComponent("notes.txt")
        try Data("notes".utf8).write(to: notes)
        let later = directory.appendingPathComponent("later.txt")
        try Data("later".utf8).write(to: later)

        let rejections = await state.addMediaAttachments(from: [broken, notes, later])

        #expect(state.pendingMediaAttachments.count == max)
        #expect(state.pendingMediaAttachments.last?.fileName == "notes.txt")
        #expect(
            rejections == [
                AttachmentRejection(source: .file(name: "broken.png"), reason: .unreadableImage),
                AttachmentRejection(
                    source: .file(name: "later.txt"),
                    reason: .attachmentLimitReached(maxCount: max)
                ),
            ])
        await Self.settleComposerMediaUploads(state)
    }

    @MainActor
    @Test func capReachedWhilePreparingIsReportedOnlyInTheNotice() async throws {
        let (state, _) = await Self.bootstrappedState()
        let draftKey = try #require(state.selectedComposerDraftKey)
        let directory = try Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let late = directory.appendingPathComponent("late.txt")
        try Data("late".utf8).write(to: late)

        let staging = Task { await state.addMediaAttachments(from: [late]) }
        // The batch passes the gate with every slot open and suspends in preparation; the
        // composer fills before it gets back to the main actor to stage.
        await Task.yield()
        for index in 0..<OutgoingMediaDraftProcessor.maxAttachmentCount {
            state.appendPendingMediaAttachment(
                PendingMediaAttachment(
                    fileName: "filler-\(index).txt",
                    mediaType: "text/plain",
                    data: Data("filler \(index)".utf8),
                    dim: nil
                ),
                for: draftKey
            )
        }
        let rejections = await staging.value

        #expect(
            rejections == [
                AttachmentRejection(
                    source: .file(name: "late.txt"),
                    reason: .attachmentLimitReached(maxCount: OutgoingMediaDraftProcessor.maxAttachmentCount)
                )
            ])
        #expect(!state.pendingMediaAttachments.contains { $0.fileName == "late.txt" })
        #expect(state.lastError == nil)
        await Self.settleComposerMediaUploads(state)
    }

    @MainActor
    @Test func batchThatOnlyFailedNamesNothingAfterAChatSwitch() async throws {
        let (state, _) = await Self.bootstrappedState()
        let directory = try Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let broken = try ["broken-1.png", "broken-2.png"].map { name in
            let url = directory.appendingPathComponent(name)
            try Data("not an image".utf8).write(to: url)
            return url
        }

        let staging = Task { await state.addMediaAttachments(from: broken) }
        // The batch suspends in preparation for the chat it started in; by the time its failures
        // come back the user is somewhere else, and they belong to a composer no longer on screen.
        await Task.yield()
        state.selection = .settings(.profile)

        #expect(await staging.value.isEmpty)
    }

    @Test func tooLargeReasonStatesTheLimit() {
        let english = Locale(identifier: "en")
        let rejection = AttachmentRejection(
            source: .file(name: "holiday-video.mov"),
            reason: .tooLarge(limitBytes: OutgoingMediaDraftProcessor.maxAttachmentBytes)
        )

        let limit = AttachmentRejection.formattedLimit(OutgoingMediaDraftProcessor.maxAttachmentBytes, locale: english)
        #expect(limit == "50 MB")
        #expect(rejection.displayName(locale: english) == "holiday-video.mov")
        #expect(
            rejection.reasonDescription(locale: english)
                == String(
                    format: L10n.string("That attachment is too large to send. The limit is %@.", locale: english),
                    limit
                ))
        #expect(rejection.reasonDescription(locale: english).contains(limit))
    }

    @Test func processorFailuresMapToTheirReasons() {
        typealias Failure = OutgoingMediaDraftProcessor.Failure
        #expect(
            AttachmentRejection.Reason(Failure.attachmentTooLarge(1))
                == .tooLarge(limitBytes: OutgoingMediaDraftProcessor.maxAttachmentBytes))
        #expect(
            AttachmentRejection.Reason(
                Failure.attachmentTooLarge(1, limit: OutgoingMediaDraftProcessor.maxImageAttachmentBytes))
                == .tooLarge(limitBytes: OutgoingMediaDraftProcessor.maxImageAttachmentBytes))
        #expect(AttachmentRejection.Reason(Failure.unsupportedAttachment) == .unsupportedType)
        #expect(AttachmentRejection.Reason(Failure.unsupportedImage) == .unreadableImage)
        #expect(AttachmentRejection.Reason(Failure.encodingFailed) == .preparationFailed)
        let ioError = CocoaError(.fileReadNoPermission)
        #expect(AttachmentRejection.Reason(ioError) == .other(ioError.localizedDescription))
    }

    /// A refused file's tile draws the glyph a staged file of the same kind would, read from the
    /// name alone because its bytes were never taken.
    @Test func rejectedTilesTakeTheirGlyphFromTheFileName() {
        func kind(_ source: AttachmentRejection.Source) -> MessageMediaKind {
            AttachmentRejection(source: source, reason: .unsupportedType).mediaKind
        }
        #expect(kind(.file(name: "holiday-video.mov")) == .video)
        #expect(kind(.file(name: "photo.jpg")) == .image)
        #expect(kind(.file(name: "memo.m4a")) == .audio)
        #expect(kind(.file(name: "installer.exe")) == .file)
        #expect(kind(.file(name: "no-extension")) == .file)
        #expect(kind(.pastedImage) == .image)
    }

    /// Dismissing one failed tile leaves its neighbors, in order.
    @Test func dismissingOneRejectionKeepsTheOthers() {
        var rejections = ComposerAttachmentRejections(
            chatId: "chat",
            rejections: [
                AttachmentRejection(source: .file(name: "a.exe"), reason: .unsupportedType),
                AttachmentRejection(source: .file(name: "b.exe"), reason: .unsupportedType),
                AttachmentRejection(source: .file(name: "c.exe"), reason: .unsupportedType),
            ]
        )
        rejections.remove(rejections.items[1].id)
        #expect(rejections.items.map(\.rejection.source) == [.file(name: "a.exe"), .file(name: "c.exe")])
    }
}
