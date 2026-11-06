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
        for mediaType in [
            "text/markdown", "application/zip", "application/yaml", "application/xml", "text/xml", "text/html",
        ] {
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
        #expect(
            OutgoingMediaAttachmentPolicy.isSupported(mediaType: "application/octet-stream", fileName: "index.HTM"))
        #expect(
            OutgoingMediaAttachmentPolicy.mediaType(typeIdentifier: nil, fileName: "page.html", fallbackKind: nil)
                == "text/html")
        // `.xhtml` is XML first (`public.xhtml` is not a `public.html`), so it stays off the list.
        #expect(!OutgoingMediaAttachmentPolicy.isSupported(mediaType: "application/xhtml+xml", fileName: "page.xhtml"))
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
        for ext in ["md", "zip", "yaml", "yml", "xml", "html", "htm"] {
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
            "Landing Page.html",
            "index.htm",
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

    /// The picker matches by conformance, and `public.xml` / `public.zip-archive` are the
    /// concrete types for `.xml` / `.zip` — there is no exact-match mode — so every subtype of
    /// them is selectable and then refused as unsupported. That is a deliberate trade, pinned here
    /// so the next widening of the list is one too. Only system-declared types are listed;
    /// Xcode's `.xib`, `.storyboard` and `.entitlements` behave the same where Xcode is installed.
    @Test(arguments: ["app.jar", "feed.rss", "strings.xliff", "page.xhtml", "wifi.mobileconfig"])
    func xmlAndZipSubtypesArePickableButRefused(fileName: String) async throws {
        let type = try #require(UTType(filenameExtension: (fileName as NSString).pathExtension))
        #expect(OutgoingMediaAttachmentPolicy.fileImporterAllowedTypes.contains { type.conforms(to: $0) })

        let directory = try Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent(fileName)
        try Data("pickable, not sendable".utf8).write(to: url)

        await #expect(throws: OutgoingMediaDraftProcessor.Failure.self) {
            _ = try await OutgoingMediaDraftProcessor.preparedAttachment(fromFileURL: url)
        }
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
    /// land in the processor the file picker uses. This checks the two halves — the reader
    /// resolves a Markdown file URL, the processor attaches it — not the composer's paste handler.
    @MainActor
    @Test func pasteboardFileURLForMarkdownResolvesAndAttaches() async throws {
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
        // Bidi overrides go — they make `fdp.exe` read as `exe.pdf` — but the joiners stay.
        #expect(name("\u{202E}fdp.exe") == "fdp.exe")
        #expect(name("a\u{2067}b\u{2069}\u{200F}.txt") == "ab.txt")
        #expect(name("نامه\u{200C}ها.pdf") == "نامه\u{200C}ها.pdf")
        #expect(name("👨\u{200D}👩\u{200D}👧.png") == "👨\u{200D}👩\u{200D}👧.png")
        #expect(name("Makefile") == "Makefile")
        #expect(name("song", fallbackExtension: "mp3") == "song")
        #expect(name(nil) == "attachment-1.bin")
        #expect(name("  ") == "attachment-1.bin")
        #expect(name("/..") == "attachment-1.bin")
        #expect(name("attachment") == "attachment")
        #expect(name("attachment/..") == "attachment-1.bin")
    }

    @Test func fileExtensionIgnoresANameWithoutOne() {
        #expect(
            OutgoingMediaAttachmentPolicy.fileExtension(for: "application/octet-stream", fileName: "README") == "bin")
        #expect(OutgoingMediaAttachmentPolicy.fileExtension(for: "text/plain", fileName: "README") == "txt")
        // A bare name that happens to spell an extension is still a name, not a type.
        #expect(
            OutgoingMediaAttachmentPolicy.mediaType(typeIdentifier: nil, fileName: "mov", fallbackKind: nil) == nil)
        #expect(OutgoingMediaAttachmentPolicy.kind(mediaType: "application/octet-stream", fileName: "mp4") == .file)
        #expect(
            OutgoingMediaAttachmentPolicy.scratchFileExtension(for: "application/octet-stream", fileName: "zip")
                == "bin")
    }

    @Test func scratchFileExtensionKeepsSupportedDocumentSuffixesForGenericTypes() {
        func suffix(_ mediaType: String, _ fileName: String?) -> String {
            OutgoingMediaAttachmentPolicy.scratchFileExtension(for: mediaType, fileName: fileName)
        }
        // Supported document suffixes with no MIME mapping survive a generic type.
        #expect(suffix("application/octet-stream", "notes.MD") == "md")
        #expect(suffix("application/octet-stream", "notes.markdown") == "markdown")
        #expect(suffix("", "archive.zip") == "zip")
        #expect(suffix("application/octet-stream", "config.yaml") == "yaml")
        #expect(suffix("application/octet-stream", "config.yml") == "yml")
        #expect(suffix("application/octet-stream", "feed.xml") == "xml")
        #expect(suffix("application/octet-stream", "index.HTM") == "htm")
        // Allowlisted extensions still resolve through their media type.
        #expect(suffix("application/octet-stream", "photo.JPEG") == "jpg")
        #expect(suffix("application/octet-stream", "report.pdf") == "pdf")
        // Unsupported suffixes still fall back, and a concrete type stays authoritative.
        #expect(suffix("application/octet-stream", "setup.exe") == "bin")
        #expect(suffix("application/octet-stream", nil) == "bin")
        #expect(suffix("application/pdf", "notes.md") == "pdf")
    }

    @Test func scratchFileExtensionMapsConcreteDocumentTypes() {
        func suffix(_ mediaType: String, _ fileName: String?) -> String {
            OutgoingMediaAttachmentPolicy.scratchFileExtension(for: mediaType, fileName: fileName)
        }
        // Own sends carry the concrete type `UTType.preferredMIMEType` reports.
        #expect(suffix("text/markdown", "notes.md") == "md")
        #expect(suffix("text/x-markdown", nil) == "md")
        #expect(suffix("application/zip", nil) == "zip")
        #expect(suffix("application/x-zip-compressed", "archive.zip") == "zip")
        #expect(suffix("application/x-yaml", "c.yml") == "yaml")
        #expect(suffix("application/yaml", nil) == "yaml")
        #expect(suffix("text/yaml", nil) == "yaml")
        #expect(suffix("text/x-yaml", nil) == "yaml")
        #expect(suffix("application/xml", nil) == "xml")
        #expect(suffix("text/xml", nil) == "xml")
        #expect(suffix("text/html", nil) == "html")
    }

    @Test func everySupportedDocumentMediaTypeHasASuffix() {
        for mediaType in OutgoingMediaAttachmentPolicy.supportedDocumentMediaTypes.sorted() {
            #expect(
                OutgoingMediaAttachmentPolicy.fileExtension(for: mediaType) != "bin",
                "\(mediaType) has no suffix mapping"
            )
        }
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
