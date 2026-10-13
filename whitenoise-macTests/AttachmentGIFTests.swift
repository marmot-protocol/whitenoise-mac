//
//  AttachmentGIFTests.swift
//  whitenoise-macTests
//
//  GIF *attachments* (not GIPHY envelopes): an attached GIF keeps its frames, timing and loop
//  count; peer bytes are bounded before decoding; and the player honours the GIF's loop count.
//

import AppKit
import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers

@testable import whitenoise_mac

struct AttachmentGIFTests {
    // MARK: Import

    @Test func pastedGIFStaysAnAnimatedGIFInsteadOfBecomingAJPEG() async throws {
        let gif = try Self.gif(width: 40, height: 30, frames: 3, loopCount: 2, delay: 0.2)

        let attachment = try await OutgoingMediaDraftProcessor.preparedAttachment(
            fromPastedImageData: gif,
            typeIdentifier: UTType.gif.identifier
        )

        #expect(attachment.mediaType == "image/gif")
        #expect(attachment.fileName.hasSuffix(".gif"))
        #expect(attachment.dim == "40x30")
        let source = try #require(CGImageSourceCreateWithData(attachment.data as CFData, nil))
        #expect(CGImageSourceGetType(source) as String? == UTType.gif.identifier)
        #expect(CGImageSourceGetCount(source) == 3)
        #expect(AttachmentGIF.animation(from: attachment.data) == .init(frameCount: 3, loopCount: 2))
        let frame = try #require(
            CGImageSourceCopyPropertiesAtIndex(source, 1, nil) as? [CFString: Any])
        let frameGIF = try #require(frame[kCGImagePropertyGIFDictionary] as? [CFString: Any])
        #expect((frameGIF[kCGImagePropertyGIFDelayTime] as? Double).map { abs($0 - 0.2) < 0.01 } == true)
    }

    @Test func gifFileImportKeepsAnimationAndRenamesToGIF() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AttachmentGIFTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("dancing cat.gif")
        try Self.gif(width: 20, height: 20, frames: 2, loopCount: 0).write(to: url)

        let attachment = try await OutgoingMediaDraftProcessor.preparedAttachment(fromFileURL: url)

        #expect(attachment.mediaType == "image/gif")
        #expect(attachment.fileName == "dancing-cat.gif")
        #expect(AttachmentGIF.animation(from: attachment.data) == .init(frameCount: 2, loopCount: nil))
    }

    @Test func reencodingDownscalesToTheLongEdgeCap() throws {
        let gif = try Self.gif(width: 300, height: 150, frames: 2, loopCount: 0)

        let encoded = try #require(AttachmentGIF.reencoded(gif, maxPixelEdge: 100))

        #expect(encoded.width == 100)
        #expect(encoded.height == 50)
        let source = try #require(CGImageSourceCreateWithData(encoded.data as CFData, nil))
        #expect(CGImageSourceGetCount(source) == 2)
    }

    @Test func reencodingDropsSourceCommentsButKeepsTheLoopCount() throws {
        // A GIF Comment Extension (0x21 0xFE) slipped in before the trailer — the kind of
        // metadata an editor leaves behind, which ImageIO itself never writes.
        var gif = try Self.gif(width: 10, height: 10, frames: 2, loopCount: 3)
        let comment = Data("Secret Name".utf8)
        #expect(gif.last == 0x3B)
        gif.insert(contentsOf: [0x21, 0xFE, UInt8(comment.count)] + comment + [0x00], at: gif.count - 1)
        #expect(gif.range(of: comment) != nil)
        #expect(AttachmentGIF.validatedSource(from: gif) != nil)

        let encoded = try #require(AttachmentGIF.reencoded(gif, maxPixelEdge: 2048))

        #expect(encoded.data.range(of: comment) == nil)
        #expect(AttachmentGIF.animation(from: encoded.data)?.loopCount == 3)
    }

    @MainActor
    @Test func pasteboardPrefersTheGIFRepresentationOverItsStillFrame() throws {
        let gif = try Self.gif(width: 8, height: 8, frames: 2, loopCount: 0)
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("AttachmentGIFTests-\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        pasteboard.clearContents()
        let item = NSPasteboardItem()
        item.setData(Data([0x89, 0x50, 0x4E, 0x47]), forType: NSPasteboard.PasteboardType(UTType.png.identifier))
        item.setData(gif, forType: NSPasteboard.PasteboardType(UTType.gif.identifier))
        pasteboard.writeObjects([item])

        let attachments = OutgoingMediaPasteboardReader.attachments(from: pasteboard)

        #expect(attachments == [.init(payload: .imageData(gif, typeIdentifier: UTType.gif.identifier))])
    }

    // MARK: Validation

    @Test func validationRejectsNonGIFTruncatedAndOversizedInputs() throws {
        let gif = try Self.gif(width: 10, height: 10, frames: 2, loopCount: 0)
        #expect(AttachmentGIF.validatedSource(from: gif) != nil)

        #expect(AttachmentGIF.validatedSource(from: Data("not a gif".utf8)) == nil)
        #expect(AttachmentGIF.validatedSource(from: gif.prefix(gif.count / 2)) == nil)
        #expect(AttachmentGIF.validatedSource(from: gif, maxBytes: gif.count - 1) == nil)

        // A logical screen wider than the per-edge cap, declared in the header.
        var wide = gif
        let width = AttachmentGIF.maxPixelEdge + 1
        wide[6] = UInt8(width & 0xFF)
        wide[7] = UInt8(width >> 8)
        #expect(AttachmentGIF.validatedSource(from: wide) == nil)
    }

    @Test func aStillGIFHasNoAnimationAndAMissingLoopExtensionPlaysOnce() throws {
        #expect(AttachmentGIF.animation(from: try Self.gif(width: 4, height: 4, frames: 1, loopCount: 0)) == nil)
        #expect(
            AttachmentGIF.animation(from: try Self.gif(width: 4, height: 4, frames: 2, loopCount: nil))
                == .init(frameCount: 2, loopCount: 1))
    }

    @Test func gifDetectionUsesTheCanonicalMediaType() {
        #expect(AttachmentGIF.isGIF(mediaType: "IMAGE/GIF; charset=binary"))
        #expect(!AttachmentGIF.isGIF(mediaType: "image/png"))
    }

    // MARK: Playback

    @MainActor
    @Test func playerStopsOnTheLastFrameOnceTheLoopCountIsSpent() async throws {
        let gif = try Self.gif(width: 4, height: 4, frames: 2, loopCount: 1, delay: 0.02)
        let animation = try #require(AttachmentGIF.animation(from: gif))
        let player = AttachmentGIFPlayer()

        player.play(contentID: "a", data: gif, animation: animation)
        let deadline = ContinuousClock.now + .seconds(10)
        while !player.didFinish, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }

        #expect(player.didFinish)
        #expect(!player.isPlaying)
        #expect(player.frame != nil)
        // A finished animation does not restart when asked to play again.
        player.play(contentID: "a", data: gif, animation: animation)
        #expect(!player.isPlaying)
    }

    @MainActor
    @Test func pausingKeepsTheFrameOnScreen() async throws {
        let gif = try Self.gif(width: 4, height: 4, frames: 2, loopCount: 0, delay: 0.02)
        let animation = try #require(AttachmentGIF.animation(from: gif))
        let player = AttachmentGIFPlayer()

        player.play(contentID: "a", data: gif, animation: animation)
        let deadline = ContinuousClock.now + .seconds(10)
        while player.frame == nil, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        player.pause()

        #expect(!player.isPlaying)
        #expect(player.frame != nil)
        #expect(!player.didFinish)
    }

    // MARK: Fixtures

    private static func gif(
        width: Int,
        height: Int,
        frames: Int,
        loopCount: Int?,
        delay: Double = 0.1
    ) throws -> Data {
        let data = NSMutableData()
        let destination = try #require(
            CGImageDestinationCreateWithData(data, UTType.gif.identifier as CFString, frames, nil))
        if let loopCount {
            CGImageDestinationSetProperties(
                destination,
                [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: loopCount]] as CFDictionary
            )
        }
        let context = try #require(
            CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ))
        let frameProperties = [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: delay]] as CFDictionary
        for index in 0..<frames {
            context.setFillColor(CGColor(red: CGFloat(index % 2), green: 0, blue: 1, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            CGImageDestinationAddImage(destination, try #require(context.makeImage()), frameProperties)
        }
        #expect(CGImageDestinationFinalize(destination))
        return data as Data
    }
}
