//
//  AttachmentGIF.swift
//  whitenoise-mac
//
//  GIF attachments, ported from whitenoise-ios (#1064): an attached GIF keeps its frames instead
//  of being flattened to a JPEG, and a received one is checked against hard bounds before
//  anything decodes it. GIPHY envelopes are a separate path — see `RemoteGiphyMedia`.
//

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

nonisolated enum AttachmentGIF {
    static let mediaType = "image/gif"
    static let maxPixelEdge = 4096
    /// Frame and pixel budgets for bytes a peer controls. A GIF is a few kilobytes of LZW that
    /// can expand to gigabytes of frames, so the header alone is not allowed to decide.
    static let maxFrames = 1000
    static let maxTotalPixels = 32 * 1024 * 1024

    static func isGIF(mediaType: String) -> Bool {
        OutgoingMediaAttachmentPolicy.canonicalMediaType(mediaType) == Self.mediaType
    }

    static func hasSignature(_ data: Data) -> Bool {
        let signature = data.prefix(6)
        return signature == Data("GIF87a".utf8) || signature == Data("GIF89a".utf8)
    }

    /// An image source for `data` when it is a complete GIF inside every bound, otherwise nil.
    /// Validates both the logical screen in the header and every frame, since a frame may be
    /// declared larger than the canvas it is drawn on.
    static func validatedSource(from data: Data, maxBytes: Int = OutgoingMediaDraftProcessor.maxImageAttachmentBytes)
        -> CGImageSource?
    {
        guard hasSignature(data), data.count <= maxBytes,
            let source = CGImageSourceCreateWithData(
                data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
            CGImageSourceGetType(source) as String? == UTType.gif.identifier,
            CGImageSourceGetStatus(source) == .statusComplete
        else { return nil }
        let count = CGImageSourceGetCount(source)
        guard (1...maxFrames).contains(count) else { return nil }
        let header = Array(data.dropFirst(6).prefix(4))
        guard header.count == 4 else { return nil }
        let width = Int(header[0]) | (Int(header[1]) << 8)
        let height = Int(header[2]) | (Int(header[3]) << 8)
        guard (1...maxPixelEdge).contains(width), (1...maxPixelEdge).contains(height),
            width * height <= maxTotalPixels / count
        else { return nil }
        var remainingPixels = maxTotalPixels
        for index in 0..<count {
            guard let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any],
                let frameWidth = properties[kCGImagePropertyPixelWidth] as? Int,
                let frameHeight = properties[kCGImagePropertyPixelHeight] as? Int,
                (1...maxPixelEdge).contains(frameWidth), (1...maxPixelEdge).contains(frameHeight),
                frameWidth * frameHeight <= remainingPixels
            else { return nil }
            remainingPixels -= frameWidth * frameHeight
        }
        return source
    }

    /// What the player needs to know before it starts: nil when the data is not a playable
    /// animation, which leaves the still image on screen.
    struct Animation: Equatable, Sendable {
        let frameCount: Int
        /// How many times the whole animation plays; nil plays forever. A GIF without a
        /// NETSCAPE loop extension plays once, which is what every browser does with it.
        let loopCount: Int?

        var totalFrames: Int? { loopCount.map { $0 * frameCount } }
    }

    static func animation(from data: Data) -> Animation? {
        guard let source = validatedSource(from: data) else { return nil }
        let count = CGImageSourceGetCount(source)
        guard count > 1 else { return nil }
        let properties = CGImageSourceCopyProperties(source, nil) as? [CFString: Any]
        let gif = properties?[kCGImagePropertyGIFDictionary] as? [CFString: Any]
        let loops = gif?[kCGImagePropertyGIFLoopCount] as? Int ?? 1
        return Animation(frameCount: count, loopCount: loops > 0 ? loops : nil)
    }

    struct Encoded: Equatable, Sendable {
        let data: Data
        let width: Int
        let height: Int
    }

    /// Re-encodes a GIF frame by frame, downscaled to `maxPixelEdge`, carrying only what the
    /// animation needs — frame delays and the loop count. Every other property of the source
    /// (comments, application extensions, XMP) is dropped, the same way a photo's EXIF is.
    static func reencoded(_ data: Data, maxPixelEdge: Int) -> Encoded? {
        guard let source = validatedSource(from: data) else { return nil }
        let count = CGImageSourceGetCount(source)
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.gif.identifier as CFString, count, nil)
        else { return nil }
        let properties = CGImageSourceCopyProperties(source, nil) as? [CFString: Any]
        let gif = properties?[kCGImagePropertyGIFDictionary] as? [CFString: Any]
        if let loopCount = gif?[kCGImagePropertyGIFLoopCount] {
            CGImageDestinationSetProperties(
                destination,
                [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: loopCount]] as CFDictionary
            )
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: min(maxPixelEdge, Self.maxPixelEdge),
            kCGImageSourceShouldCache: false,
        ]
        var size: (width: Int, height: Int)?
        for index in 0..<count {
            let added: Bool = autoreleasepool {
                guard let frame = CGImageSourceCreateThumbnailAtIndex(source, index, options as CFDictionary) else {
                    return false
                }
                let frameProperties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any]
                let frameGIF = frameProperties?[kCGImagePropertyGIFDictionary] as? [CFString: Any] ?? [:]
                let timing = frameGIF.filter {
                    $0.key == kCGImagePropertyGIFDelayTime || $0.key == kCGImagePropertyGIFUnclampedDelayTime
                }
                CGImageDestinationAddImage(destination, frame, [kCGImagePropertyGIFDictionary: timing] as CFDictionary)
                if index == 0 { size = (frame.width, frame.height) }
                return true
            }
            guard added else { return nil }
        }
        guard let size, CGImageDestinationFinalize(destination) else { return nil }
        return Encoded(data: output as Data, width: size.width, height: size.height)
    }
}
