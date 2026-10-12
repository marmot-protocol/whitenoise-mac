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
    static let maximumZoom: CGFloat = 6
    /// The cap on picked bytes, before decoding. Matches iOS.
    static let maximumEncodedBytes = 25 * 1024 * 1024
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
        let displayScale = baseScale(imageSize: imageSize, cropSide: cropSide) * zoom
        let length = cropSide / displayScale
        let origin = CGPoint(
            x: (imageSize.width - length) / 2 - offset.width / displayScale,
            y: (imageSize.height - length) / 2 - offset.height / displayScale
        )
        return CGRect(origin: origin, size: CGSize(width: length, height: length))
            .integral
            .intersection(CGRect(origin: .zero, size: imageSize))
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
