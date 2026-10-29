//
//  ForwardingTests.swift
//  whitenoise-macTests
//
//  Forwarding messages that carry attachments: what is fetched, what is re-sent through the
//  destination's attachment send, and how unavailable files are reported before anything goes out.
//

import Foundation
import MarmotKit
import Testing

@testable import whitenoise_mac

@MainActor
struct ForwardingTests {
    private let target = ChatItem.samples[1]

    /// Opens a forward of the fixture's message and returns the sheet's model.
    private func openForward(
        attachments: [(fileName: String, mediaType: String, data: Data, isAvailable: Bool)],
        body: String = ""
    ) async throws -> (model: MessageForwardViewModel, state: WorkspaceState, runtime: FakeMarmotRuntime) {
        let fixture = await mediaDownloadFixture(
            attachments: attachments,
            body: body,
            destination: FakeMediaDownloadDestination(storedURL: nil)
        )
        fixture.state.startForwarding([fixture.message])
        let model = try #require(MessageForwardViewModel.live(workspace: fixture.state))
        return (model, fixture.state, fixture.runtime)
    }

    @Test func attachmentOnlyAndCaptionedMessagesCanBeForwarded() {
        let attachment = MessageMediaAttachment(
            id: "a#0",
            reference: mediaAttachmentReference(
                sourceEpoch: 1,
                mediaType: "image/jpeg",
                fileName: "photo.jpg",
                ciphertextSha256: String(repeating: "a", count: 64),
                plaintextSha256: String(repeating: "b", count: 64)
            )
        )
        let attachmentOnly = MessageItem(
            id: "media",
            senderName: "Alice",
            body: "",
            sentAt: Date(timeIntervalSince1970: 1),
            isOutgoing: false,
            mediaAttachments: [attachment]
        )
        let captioned = MessageItem(
            id: "captioned",
            senderName: "Alice",
            body: "Look",
            sentAt: Date(timeIntervalSince1970: 1),
            isOutgoing: false,
            mediaAttachments: [attachment]
        )
        #expect(attachmentOnly.canForward)
        #expect(captioned.canForward)
    }

    @Test func forwardingAnAttachmentOnlyMessageSendsEveryFileThroughTheAttachmentSend() async throws {
        let photo = Data([0x01, 0x02, 0x03])
        let document = Data([0x04, 0x05])
        let (model, state, runtime) = try await openForward(attachments: [
            (fileName: "photo.jpg", mediaType: "image/jpeg", data: photo, isAvailable: true),
            (fileName: "notes.pdf", mediaType: "application/pdf", data: document, isAvailable: true),
        ])

        model.forward(to: target)
        await model.waitUntilIdle()

        let submission = try #require(runtime.tokenizedMediaSubmissions.only)
        #expect(submission.groupIdHex == target.id)
        #expect(submission.request.send)
        #expect(submission.request.caption == nil)
        #expect(submission.request.attachments.map(\.fileName) == ["photo.jpg", "notes.pdf"])
        #expect(submission.request.attachments.map(\.mediaType) == ["image/jpeg", "application/pdf"])
        #expect(submission.request.attachments.map(\.plaintext) == [photo, document])
        // An attachment-only message has no text to send on its own.
        #expect(runtime.sentTextClientTokens.isEmpty)
        #expect(!state.isForwardPickerPresented)
        #expect(state.forwardingMessageIds.isEmpty)
        #expect(state.lastError == nil)
        #expect(model.phase == .choosing)
    }

    @Test func forwardingACaptionedAttachmentKeepsTheCaptionWithTheFile() async throws {
        let audio = Data([0x0A, 0x0B, 0x0C])
        let (model, _, runtime) = try await openForward(
            attachments: [(fileName: "memo.m4a", mediaType: "audio/mp4", data: audio, isAvailable: true)],
            body: "Listen to this"
        )

        model.forward(to: target)
        await model.waitUntilIdle()

        let submission = try #require(runtime.tokenizedMediaSubmissions.only)
        #expect(submission.request.caption == "Listen to this")
        #expect(submission.request.attachments.map(\.fileName) == ["memo.m4a"])
        #expect(submission.request.attachments.map(\.plaintext) == [audio])
        // The caption travels with the file, not as a second message.
        #expect(runtime.sentTextClientTokens.isEmpty)
    }

    @Test func unavailableFilesAreReportedBeforeAnythingIsSent() async throws {
        let video = Data([0x10, 0x11])
        let (model, state, runtime) = try await openForward(
            attachments: [
                (fileName: "clip.mov", mediaType: "video/quicktime", data: video, isAvailable: true),
                (fileName: "missing.pdf", mediaType: "application/pdf", data: Data([0x20]), isAvailable: false),
            ],
            body: "Both files"
        )

        model.forward(to: target)
        await model.waitUntilIdle()

        let files = try #require(model.unavailableFiles)
        #expect(files.plan.unavailableFileNames == ["missing.pdf"])
        #expect(files.canForwardRemainder)
        #expect(files.message.contains("missing.pdf"))
        #expect(runtime.tokenizedMediaSubmissions.isEmpty)
        #expect(runtime.sentTextClientTokens.isEmpty)
        #expect(state.isForwardPickerPresented)

        model.forwardAvailableFiles()
        await model.waitUntilIdle()

        let submission = try #require(runtime.tokenizedMediaSubmissions.only)
        #expect(submission.groupIdHex == target.id)
        #expect(submission.request.caption == "Both files")
        #expect(submission.request.attachments.map(\.fileName) == ["clip.mov"])
        #expect(submission.request.attachments.map(\.plaintext) == [video])
        #expect(!state.isForwardPickerPresented)
    }

    @Test func decliningTheUnavailableFilesPromptSendsNothing() async throws {
        let (model, state, runtime) = try await openForward(attachments: [
            (fileName: "photo.jpg", mediaType: "image/jpeg", data: Data([0x01]), isAvailable: true),
            (fileName: "gone.png", mediaType: "image/png", data: Data([0x02]), isAvailable: false),
        ])

        model.forward(to: target)
        await model.waitUntilIdle()
        #expect(model.unavailableFiles != nil)

        model.dismissUnavailableFiles()

        #expect(model.phase == .choosing)
        #expect(runtime.tokenizedMediaSubmissions.isEmpty)
        #expect(state.isForwardPickerPresented)
    }

    @Test func aMessageWhoseOnlyFileIsUnavailableHasNothingLeftToForward() async throws {
        let (model, _, runtime) = try await openForward(attachments: [
            (fileName: "gone.pdf", mediaType: "application/pdf", data: Data([0x01]), isAvailable: false)
        ])

        model.forward(to: target)
        await model.waitUntilIdle()

        let files = try #require(model.unavailableFiles)
        #expect(!files.canForwardRemainder)
        #expect(files.message.contains("gone.pdf"))

        // Offered only OK; accepting cannot send anything.
        model.forwardAvailableFiles()
        await model.waitUntilIdle()
        #expect(model.phase == .choosing)
        #expect(runtime.tokenizedMediaSubmissions.isEmpty)
        #expect(runtime.sentTextClientTokens.isEmpty)
    }

    @Test func aCaptionWhoseFilesAreAllUnavailableStillForwardsAsText() async throws {
        let attachment = MessageMediaAttachment(
            id: "m#0",
            reference: mediaAttachmentReference(
                sourceEpoch: 1,
                mediaType: "image/jpeg",
                fileName: "photo.jpg",
                ciphertextSha256: String(repeating: "a", count: 64),
                plaintextSha256: String(repeating: "b", count: 64)
            )
        )
        let message = MessageItem(
            id: "m",
            senderName: "Alice",
            body: "  Caption  ",
            sentAt: Date(timeIntervalSince1970: 1),
            isOutgoing: false,
            mediaAttachments: [attachment]
        )

        let plan = await MessageForwardPlan.make(messages: [message]) { _, _ in nil }

        #expect(plan.messages == [ForwardedMessage(text: "Caption", attachments: [])])
        #expect(plan.unavailableFileNames == ["photo.jpg"])
        #expect(plan.hasContent)
        #expect(!plan.isComplete)
    }

    @Test func forwardedAttachmentPrefersTheCoreNameAndKeepsTheReferenceLayoutHints() {
        let reference = MediaAttachmentReferenceFfi(
            locators: [],
            ciphertextSha256: String(repeating: "a", count: 64),
            plaintextSha256: String(repeating: "b", count: 64),
            nonceHex: String(repeating: "0", count: 24),
            fileName: "timeline-name.jpg",
            mediaType: "image/jpeg",
            version: .v2,
            sourceEpoch: 1,
            dim: "640x480",
            thumbhash: "thumb"
        )
        let attachment = MessageMediaAttachment(id: "a", reference: reference)
        let data = Data([0x01, 0x02])
        let download = MessageMediaDownload(
            payload: DownloadedMediaPayload(data: data),
            fileName: "core-name.jpg",
            mediaType: "image/png",
            sizeBytes: UInt64(data.count)
        )

        let forwarded = MessageForwardPlan.forwardedAttachment(attachment, download: download)

        #expect(forwarded.fileName == "core-name.jpg")
        #expect(forwarded.mediaType == "image/png")
        #expect(forwarded.data == data)
        #expect(forwarded.dim == "640x480")
        #expect(forwarded.thumbhash == "thumb")
        #expect(!forwarded.isVoiceMessage)
    }
}

extension Array {
    fileprivate var only: Element? {
        count == 1 ? first : nil
    }
}
