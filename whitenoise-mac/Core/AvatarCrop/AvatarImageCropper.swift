//
//  AvatarImageCropper.swift
//  whitenoise-mac
//
//  The arithmetic and the rendering behind the circular avatar crop.
//

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Everything about a square avatar crop that is not a view: decoding the picked bytes into
/// something the editor can draw, keeping the image covering the crop circle while it is dragged
/// and zoomed, and rendering the visible square out as JPEG.
///
/// Ported from `whitenoise-ios`'s `AvatarImageCropper`, with `CGImage` in place of `UIImage` and
/// ImageIO in place of `UIGraphicsImageRenderer`. The geometry is the same on purpose, so a
/// profile picture cropped on either client frames the same way.
///
/// The model is one the editor draws literally: the image is scaled to *cover* a `cropSide`
/// square (`baseScale`), multiplied by `zoom`, and shifted by `offset` in points from centred.
/// Offsets are in the same top-left-origin space as SwiftUI's, which is also `CGImage.cropping`'s.
nonisolated enum AvatarImageCropper {
    /// Why a destination turned a finished crop away before it started saving.
    ///
    /// A commit that returns closes the editor as if it had saved, so a refusal the user can retry
    /// past — another change to the same group or profile still in flight — has to throw, or the
    /// picture they just framed is thrown away with nothing saved. A destination that has gone
    /// (the account switched, the group deselected) still returns quietly: there is nothing left
    /// to retry against.
    enum CommitError: LocalizedError, Equatable {
        case busy

        var errorDescription: String? {
            switch self {
            case .busy:
                L10n.string("Another change is still saving. Try again in a moment.")
            }
        }
    }

    static let maximumZoom: CGFloat = 6
    /// The cap on picked bytes, before decoding: the same one any attachment gets, which is what a
    /// picture could be before the editor existed. iOS stops at 25 MB, but memory is bounded by
    /// `maximumSourcePixelCount` and `maximumEditorPixelSize`, not by this, so halving it here would
    /// only refuse large photos that used to work.
    static let maximumEncodedBytes = OutgoingMediaDraftProcessor.maxAttachmentBytes
    /// The cap on decoded source pixels, checked from the header before anything is decoded.
    static let maximumSourcePixelCount = 80_000_000
    /// The longest edge the editor works on. The output is 1024 square, so anything sharper than
    /// twice that is memory spent on detail nobody will see.
    static let maximumEditorPixelSize = 2_048
    static let outputPixelSize = 1_024
    static let outputTypeIdentifier = UTType.jpeg.identifier
    static let outputCompressionQuality: CGFloat = 0.92

    static func encodedByteCountIsAllowed(_ count: Int) -> Bool {
        count > 0 && count <= maximumEncodedBytes
    }

    static func sourceDimensionsAreAllowed(width: Int, height: Int) -> Bool {
        width > 0 && height > 0 && width <= maximumSourcePixelCount / height
    }

    /// Decodes `data` upright (EXIF orientation applied) and no larger than
    /// `maximumEditorPixelSize`, or `nil` when it is not an image this editor will take.
    static func normalizedImage(from data: Data) -> CGImage? {
        guard encodedByteCountIsAllowed(data.count),
            let source = CGImageSourceCreateWithData(
                data as CFData,
                [kCGImageSourceShouldCache: false] as CFDictionary
            ),
            let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
            let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
            let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue,
            sourceDimensionsAreAllowed(width: width, height: height)
        else { return nil }

        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maximumEditorPixelSize,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    /// The scale at which the image exactly covers the crop square, before any zoom.
    static func baseScale(imageSize: CGSize, cropSide: CGFloat) -> CGFloat {
        guard imageSize.width > 0, imageSize.height > 0 else { return 1 }
        return max(cropSide / imageSize.width, cropSide / imageSize.height)
    }

    /// The image's on-screen size at `zoom`.
    static func displayedSize(imageSize: CGSize, cropSide: CGFloat, zoom: CGFloat) -> CGSize {
        let scale = baseScale(imageSize: imageSize, cropSide: cropSide) * zoom
        return CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
    }

    static func clampedZoom(_ zoom: CGFloat) -> CGFloat {
        guard zoom.isFinite else { return 1 }
        return min(max(zoom, 1), maximumZoom)
    }

    /// `offset`, pulled back far enough that the image still covers the whole crop square.
    static func clampedOffset(
        _ offset: CGSize,
        imageSize: CGSize,
        cropSide: CGFloat,
        zoom: CGFloat
    ) -> CGSize {
        let displayed = displayedSize(imageSize: imageSize, cropSide: cropSide, zoom: zoom)
        let maximumX = max(0, (displayed.width - cropSide) / 2)
        let maximumY = max(0, (displayed.height - cropSide) / 2)
        return CGSize(
            width: min(max(offset.width, -maximumX), maximumX),
            height: min(max(offset.height, -maximumY), maximumY)
        )
    }

    /// The offset that keeps the point under the crop's centre where it is when zoom moves from
    /// `oldZoom` to `newZoom`, clamped for the new zoom.
    ///
    /// iOS only clamps, which is right for a pinch — the fingers carry the image along — but a
    /// slider has no fingers, and zooming out of a dragged-aside face should not slide it away.
    static func rezoomedOffset(
        _ offset: CGSize,
        imageSize: CGSize,
        cropSide: CGFloat,
        from oldZoom: CGFloat,
        to newZoom: CGFloat
    ) -> CGSize {
        let ratio = oldZoom > 0 ? newZoom / oldZoom : 1
        return clampedOffset(
            CGSize(width: offset.width * ratio, height: offset.height * ratio),
            imageSize: imageSize,
            cropSide: cropSide,
            zoom: newZoom
        )
    }

    /// The square of source pixels visible inside the crop, in the image's own top-left space.
    static func cropRect(
        imageSize: CGSize,
        cropSide: CGFloat,
        zoom: CGFloat,
        offset: CGSize
    ) -> CGRect {
        guard imageSize.width >= 1, imageSize.height >= 1 else { return .zero }
        let displayScale = baseScale(imageSize: imageSize, cropSide: cropSide) * zoom
        // One rounded side for both axes, and an origin clamped rather than an edge intersected:
        // `.integral` rounds each edge outward on its own, so a fractional square could come back
        // a pixel wider than tall and be stretched into the square output.
        let side = min(
            max(1, (cropSide / displayScale).rounded()),
            imageSize.width.rounded(.down),
            imageSize.height.rounded(.down)
        )
        let centre = CGPoint(
            x: imageSize.width / 2 - offset.width / displayScale,
            y: imageSize.height / 2 - offset.height / displayScale
        )
        let origin = CGPoint(
            x: min(max((centre.x - side / 2).rounded(), 0), imageSize.width - side),
            y: min(max((centre.y - side / 2).rounded(), 0), imageSize.height - side)
        )
        return CGRect(origin: origin, size: CGSize(width: side, height: side))
    }

    /// The attachment a profile or group picture is uploaded or staged as.
    ///
    /// What `croppedJPEG` rendered is already a small, upright, metadata-free JPEG, so it is
    /// wrapped as it is: running it back through `OutgoingMediaDraftProcessor` would decode it and
    /// encode it again at a lower quality for nothing. Anything else — bytes that did not come
    /// from the editor — still takes that path.
    static func attachment(fromCroppedImageData data: Data) async throws -> PendingMediaAttachment {
        if let size = editorJPEGPixelSize(data) {
            return PendingMediaAttachment(
                fileName: "avatar.jpg",
                mediaType: "image/jpeg",
                data: data,
                dim: "\(size.width)x\(size.height)"
            )
        }
        return try await OutgoingMediaDraftProcessor.preparedAttachment(
            fromPastedImageData: data,
            typeIdentifier: nil
        )
    }

    /// The header properties `croppedJPEG`'s ImageIO output carries. A JPEG with anything more —
    /// an orientation, GPS, a camera's EXIF — did not come from the editor, and is re-encoded so
    /// none of it is uploaded.
    private static let editorJPEGPropertyKeys: Set<CFString> = [
        kCGImagePropertyColorModel, kCGImagePropertyDepth, kCGImagePropertyPixelWidth,
        kCGImagePropertyPixelHeight, kCGImagePropertyProfileName, kCGImagePropertyExifDictionary,
        kCGImagePropertyJFIFDictionary,
    ]
    private static let editorJPEGExifKeys: Set<CFString> = [
        kCGImagePropertyExifColorSpace, kCGImagePropertyExifPixelXDimension, kCGImagePropertyExifPixelYDimension,
    ]

    /// The pixel size of `data` when it is a JPEG the editor could have produced: no metadata
    /// beyond what it writes, and no larger than an attachment may be. Read from the header only.
    private static func editorJPEGPixelSize(_ data: Data) -> (width: Int, height: Int)? {
        guard data.count <= OutgoingMediaDraftProcessor.maxImageAttachmentBytes,
            let source = CGImageSourceCreateWithData(
                data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
            CGImageSourceGetType(source) as String? == outputTypeIdentifier,
            CGImageSourceGetCount(source) == 1,
            let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
            Set(properties.keys).isSubset(of: editorJPEGPropertyKeys),
            Set((properties[kCGImagePropertyExifDictionary] as? [CFString: Any] ?? [:]).keys)
                .isSubset(of: editorJPEGExifKeys),
            let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
            let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue,
            width > 0, height > 0,
            CGFloat(max(width, height)) <= OutgoingMediaDraftProcessor.maxLongEdge
        else { return nil }
        return (width, height)
    }

    /// The visible square, scaled to `outputPixelSide` and encoded as JPEG.
    ///
    /// Drawn onto white first: JPEG has no alpha, and a transparent PNG otherwise comes out with a
    /// black ground.
    static func croppedJPEG(
        image: CGImage,
        cropSide: CGFloat,
        zoom: CGFloat,
        offset: CGSize,
        outputPixelSide: Int = outputPixelSize
    ) -> Data? {
        guard outputPixelSide > 0 else { return nil }
        let imageSize = CGSize(width: image.width, height: image.height)
        let rect = cropRect(imageSize: imageSize, cropSide: cropSide, zoom: zoom, offset: offset)
        guard rect.width > 0, rect.height > 0,
            let cropped = image.cropping(to: rect),
            let context = CGContext(
                data: nil,
                width: outputPixelSide,
                height: outputPixelSide,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
            )
        else { return nil }

        let bounds = CGRect(x: 0, y: 0, width: outputPixelSide, height: outputPixelSide)
        context.interpolationQuality = .high
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(bounds)
        context.draw(cropped, in: bounds)
        guard let output = context.makeImage() else { return nil }

        let data = NSMutableData()
        guard
            let destination = CGImageDestinationCreateWithData(
                data as CFMutableData,
                outputTypeIdentifier as CFString,
                1,
                nil
            )
        else { return nil }
        CGImageDestinationAddImage(
            destination,
            output,
            [kCGImageDestinationLossyCompressionQuality: outputCompressionQuality] as CFDictionary
        )
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }
}
