//
//  OutgoingMediaAttachmentPolicyTests.swift
//  whitenoise-macTests
//

import AVFoundation
import AppKit
import Foundation
import MarmotKit
import Testing
import UniformTypeIdentifiers

@testable import whitenoise_mac

struct OutgoingMediaAttachmentPolicyTests {
    /// Every extension the app maps itself, and the MIME type it must map to.
    private static let allowlist: [(ext: String, mediaType: String)] = [
        ("gif", "image/gif"),
        ("heic", "image/heic"),
        ("jpeg", "image/jpeg"),
        ("jpg", "image/jpeg"),
        ("png", "image/png"),
        ("webp", "image/webp"),
        ("aac", "audio/aac"),
        ("m4a", "audio/mp4"),
        ("mp3", "audio/mpeg"),
        ("wav", "audio/wav"),
        ("mov", "video/quicktime"),
        ("mp4", "video/mp4"),
        ("m4v", "video/mp4"),
        ("txt", "text/plain"),
        ("csv", "text/csv"),
        ("json", "application/json"),
        ("rtf", "application/rtf"),
        ("pdf", "application/pdf"),
        ("doc", "application/msword"),
        ("docx", "application/vnd.openxmlformats-officedocument.wordprocessingml.document"),
        ("xls", "application/vnd.ms-excel"),
        ("xlsx", "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"),
        ("ppt", "application/vnd.ms-powerpoint"),
        ("pptx", "application/vnd.openxmlformats-officedocument.presentationml.presentation"),
    ]

    @Test func allowlistedExtensionsMapToTheirMediaTypeCaseInsensitively() {
        for entry in Self.allowlist {
            #expect(OutgoingMediaAttachmentPolicy.mediaType(forFileExtension: entry.ext) == entry.mediaType)
            #expect(
                OutgoingMediaAttachmentPolicy.mediaType(forFileExtension: entry.ext.uppercased()) == entry.mediaType
            )
        }
    }

    @Test func mediaTypeAndExtensionRoundTripThroughTheCanonicalSuffix() {
        // Two extensions share a MIME type with a more common spelling; the canonical suffix is
        // the one the app writes scratch files under, so the round trip lands there instead.
        let canonicalSuffix = ["jpeg": "jpg", "m4v": "mp4", "aac": "m4a"]
        for entry in Self.allowlist {
            let mediaType = OutgoingMediaAttachmentPolicy.mediaType(forFileExtension: entry.ext) ?? ""
            #expect(
                OutgoingMediaAttachmentPolicy.fileExtension(for: mediaType)
                    == canonicalSuffix[entry.ext, default: entry.ext]
            )
        }
    }

    @Test func fileExtensionPrefersTheFileNameAndKnowsLegacyAliases() {
        #expect(OutgoingMediaAttachmentPolicy.fileExtension(for: "image/png", fileName: "Photo.JPEG") == "jpeg")
        #expect(OutgoingMediaAttachmentPolicy.fileExtension(for: "image/jpg") == "jpg")
        #expect(OutgoingMediaAttachmentPolicy.fileExtension(for: "audio/x-m4a") == "m4a")
        #expect(OutgoingMediaAttachmentPolicy.fileExtension(for: "audio/x-wav") == "wav")
        #expect(OutgoingMediaAttachmentPolicy.fileExtension(for: "text/json") == "json")
        #expect(OutgoingMediaAttachmentPolicy.fileExtension(for: "text/rtf") == "rtf")
        #expect(OutgoingMediaAttachmentPolicy.fileExtension(for: "IMAGE/PNG; charset=binary") == "png")
        #expect(OutgoingMediaAttachmentPolicy.fileExtension(for: "application/octet-stream") == "bin")
    }

    @Test func mediaTypePrefersTheTypeIdentifierThenTheFileNameThenTheKind() {
        #expect(
            OutgoingMediaAttachmentPolicy.mediaType(
                typeIdentifier: UTType.png.identifier, fileName: "clip.mov", fallbackKind: .video
            ) == "image/png"
        )
        #expect(
            OutgoingMediaAttachmentPolicy.mediaType(typeIdentifier: nil, fileName: "clip.MOV", fallbackKind: .image)
                == "video/quicktime"
        )

        let unknownName = "capture.zzqunknown"
        let fallbacks: [(MessageMediaKind?, String?)] = [
            (.video, "video/mp4"),
            (.audio, "audio/mp4"),
            (.image, "image/jpeg"),
            (.file, nil),
            (nil, nil),
        ]
        for (kind, expected) in fallbacks {
            #expect(
                OutgoingMediaAttachmentPolicy.mediaType(
                    typeIdentifier: nil, fileName: unknownName, fallbackKind: kind
                ) == expected
            )
        }
    }

    @Test func supportCoversDecodableMediaAndAllowlistedDocumentsOnly() {
        #expect(OutgoingMediaAttachmentPolicy.isSupported(mediaType: "image/png; charset=binary"))
        #expect(OutgoingMediaAttachmentPolicy.isSupported(mediaType: "video/mp4"))
        #expect(OutgoingMediaAttachmentPolicy.isSupported(mediaType: "audio/mpeg"))
        #expect(OutgoingMediaAttachmentPolicy.isSupported(mediaType: "application/pdf"))
        for mediaType in ["text/markdown", "application/zip", "application/yaml", "application/xml", "text/xml"] {
            #expect(OutgoingMediaAttachmentPolicy.isSupported(mediaType: mediaType), "\(mediaType)")
        }
        // SVG is an image type the app cannot decode safely, so it is never offered as one.
        #expect(!OutgoingMediaAttachmentPolicy.isSupported(mediaType: "image/svg+xml"))
        #expect(!OutgoingMediaAttachmentPolicy.isSupported(mediaType: "application/x-sqlite3"))
        #expect(!OutgoingMediaAttachmentPolicy.isSupported(mediaType: "application/octet-stream", fileName: "README"))
        #expect(
            OutgoingMediaAttachmentPolicy.isSupported(mediaType: "application/octet-stream", fileName: "Report.PDF")
        )
        #expect(OutgoingMediaAttachmentPolicy.isSupported(mediaType: "application/octet-stream", fileName: "ci.yml"))
    }

    @Test func fileImporterOffersEveryDocumentExtensionWithoutDuplicates() {
        let types = OutgoingMediaAttachmentPolicy.fileImporterAllowedTypes
        #expect(Set(types).count == types.count)
        for type in [UTType.image, .movie, .audio, .pdf] {
            #expect(types.contains(type))
        }
        for ext in OutgoingMediaAttachmentPolicy.supportedDocumentExtensions {
            let type = UTType(filenameExtension: ext)
            #expect(type.map { resolved in types.contains { resolved.conforms(to: $0) } } ?? true)
        }
        for ext in ["md", "zip", "yaml", "yml", "xml"] {
            let type = UTType(filenameExtension: ext)
            #expect(type.map { resolved in types.contains { resolved.conforms(to: $0) } } == true, "\(ext)")
        }
    }

    /// The formats the old allowlist refused. Each goes out as a file card under the name and
    /// bytes it had on disk.
    @Test(
        arguments: [
            "Release Notes.md",
            "archive.zip",
            "config.yaml",
            "workflow.yml",
            "feed.xml",
        ])
    func addedDocumentFormatsAttachUnchangedFromTheFilePicker(fileName: String) async throws {
        let directory = try Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent(fileName)
        let contents = Data("contents of \(fileName)\n\u{0}\u{1}binary tail".utf8)
        try contents.write(to: url)

        let attachment = try await OutgoingMediaDraftProcessor.preparedAttachment(fromFileURL: url)

        #expect(attachment.fileName == fileName)
        #expect(attachment.data == contents)
        #expect(attachment.kind == .file)
        #expect(OutgoingMediaAttachmentPolicy.isSupported(mediaType: attachment.mediaType, fileName: fileName))
        #expect(attachment.uploadRequest.fileName == fileName)
        #expect(attachment.uploadRequest.plaintext == contents)
    }

    @Test(arguments: ["data.sqlite", "diagram.svg"])
    func formatsOutsideTheAllowlistAreStillRefused(fileName: String) async throws {
        let directory = try Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent(fileName)
        try Data("not on the list".utf8).write(to: url)

        await #expect(throws: OutgoingMediaDraftProcessor.Failure.self) {
            _ = try await OutgoingMediaDraftProcessor.preparedAttachment(fromFileURL: url)
        }
    }

    /// Paste reads file URLs off the pasteboard and drag-and-drop hands over the same URLs; both
    /// land in the processor the file picker uses, so a pasted Markdown file is attached too.
    @MainActor
    @Test func pastedMarkdownFileAttachesLikeAPickedOne() async throws {
        let directory = try Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("Meeting notes.md")
        let contents = Data("# Agenda\n\n- ship it\n".utf8)
        try contents.write(to: url)
        let pasteboard = NSPasteboard(
            name: NSPasteboard.Name("OutgoingMediaAttachmentPolicyTests-\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        pasteboard.clearContents()
        let item = NSPasteboardItem()
        #expect(item.setString(url.absoluteString, forType: .fileURL))
        #expect(pasteboard.writeObjects([item]))

        let pasted = OutgoingMediaPasteboardReader.attachments(from: pasteboard)
        #expect(pasted == [.init(payload: .fileURL(url))])

        let attachment = try await OutgoingMediaDraftProcessor.preparedAttachment(fromFileURL: url)
        #expect(attachment.fileName == "Meeting notes.md")
        #expect(attachment.mediaType == "text/markdown")
        #expect(attachment.data == contents)
    }

    @Test func directoriesAreStillRefused() async throws {
        let directory = try Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        await #expect(throws: OutgoingMediaDraftProcessor.Failure.self) {
            _ = try await OutgoingMediaDraftProcessor.preparedAttachment(fromFileURL: directory)
        }
    }

    @Test func attachmentNamesKeepWhatTheUserSeesAndDropOnlyWhatMisleads() {
        func name(_ fileName: String?, fallbackExtension: String = "bin") -> String {
            OutgoingMediaDraftProcessor.sanitizedFileName(
                fileName, fallbackStem: "attachment-1", fallbackExtension: fallbackExtension
            )
        }
        #expect(name("Résumé – final (2).pdf") == "Résumé – final (2).pdf")
        #expect(name("报告.docx") == "报告.docx")
        #expect(name("../../etc/passwd") == "passwd")
        #expect(name(".env") == "env")
        #expect(name("Q3:report.pdf") == "Q3-report.pdf")
        #expect(name("tab\tand\nnewline.txt") == "tabandnewline.txt")
        #expect(name("Makefile") == "Makefile")
        #expect(name("song", fallbackExtension: "mp3") == "song")
        #expect(name(nil) == "attachment-1.bin")
        #expect(name("  ") == "attachment-1.bin")
        #expect(name("/..") == "attachment-1.bin")
        #expect(name("attachment") == "attachment")
    }

    @Test func fileExtensionIgnoresANameWithoutOne() {
        #expect(
            OutgoingMediaAttachmentPolicy.fileExtension(for: "application/octet-stream", fileName: "README") == "bin")
        #expect(OutgoingMediaAttachmentPolicy.fileExtension(for: "text/plain", fileName: "README") == "txt")
    }

    private static func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("OutgoingMediaAttachmentPolicyTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    @Test func waveformChunksStayInsideTheByteBudgetAndFrameCeiling() {
        let ceiling = MediaWaveformAnalyzer.chunkFrameCapacityCeiling
        #expect(MediaWaveformAnalyzer.chunkFrameCapacity(channelCount: 2, bytesPerSample: 4) == ceiling)
        // A degenerate format still reads at least one sample per frame.
        #expect(MediaWaveformAnalyzer.chunkFrameCapacity(channelCount: 0, bytesPerSample: 0) == ceiling)
        // An enormous frame is bounded by the byte budget rather than the ceiling.
        let perFrameBytes = 64 * 8192
        #expect(
            MediaWaveformAnalyzer.chunkFrameCapacity(channelCount: 64, bytesPerSample: 8192)
                == AVAudioFrameCount(MediaWaveformAnalyzer.maxChunkBytes / perFrameBytes)
        )
    }

    @Test func waveformAnalysisIsCappedAndChunksNeverOverrunTheRemainder() {
        let cap = MediaWaveformAnalyzer.maxAnalyzedFrames
        #expect(MediaWaveformAnalyzer.analyzedFrameCount(totalFrames: 0) == 0)
        #expect(MediaWaveformAnalyzer.analyzedFrameCount(totalFrames: -5) == 0)
        #expect(MediaWaveformAnalyzer.analyzedFrameCount(totalFrames: 1_000) == 1_000)
        #expect(MediaWaveformAnalyzer.analyzedFrameCount(totalFrames: cap + 1) == cap)

        #expect(
            MediaWaveformAnalyzer.nextChunkFrameCount(analyzedFrames: 1_000, framesProcessed: 0, chunkCapacity: 64)
                == 64)
        #expect(
            MediaWaveformAnalyzer.nextChunkFrameCount(analyzedFrames: 100, framesProcessed: 90, chunkCapacity: 64)
                == 10)
        #expect(
            MediaWaveformAnalyzer.nextChunkFrameCount(analyzedFrames: 100, framesProcessed: 100, chunkCapacity: 64)
                == 0)
    }

    @Test func waveformBucketsClampToTheirRange() {
        #expect(MediaWaveformAnalyzer.bucketIndex(forFrame: 0, analyzedFrames: 100, bucketCount: 36) == 0)
        #expect(MediaWaveformAnalyzer.bucketIndex(forFrame: 50, analyzedFrames: 100, bucketCount: 36) == 18)
        #expect(MediaWaveformAnalyzer.bucketIndex(forFrame: 99, analyzedFrames: 100, bucketCount: 36) == 35)
        #expect(MediaWaveformAnalyzer.bucketIndex(forFrame: 100, analyzedFrames: 100, bucketCount: 36) == 35)
        #expect(MediaWaveformAnalyzer.bucketIndex(forFrame: -1, analyzedFrames: 100, bucketCount: 36) == 0)
        #expect(MediaWaveformAnalyzer.bucketIndex(forFrame: 5, analyzedFrames: 0, bucketCount: 36) == 0)
        #expect(MediaWaveformAnalyzer.bucketIndex(forFrame: 5, analyzedFrames: 100, bucketCount: 0) == 0)
        #expect(
            MediaWaveformAnalyzer.bucketIndex(forFrame: 99, analyzedFrames: 100)
                == MediaWaveformAnalyzer.sampleCount - 1
        )
    }
}
