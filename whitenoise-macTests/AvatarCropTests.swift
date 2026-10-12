//
//  AvatarCropTests.swift
//  whitenoise-macTests
//

import CoreGraphics
import Foundation
import ImageIO
import Testing

@testable import whitenoise_mac

/// Guards the circular crop every profile and group picture passes through: the geometry that
/// keeps the picture covering the circle, the render that turns the visible square into the
/// stored JPEG, and the model the sheet drives.
@MainActor
struct AvatarCropTests: WorkspaceTestSupport {
    // MARK: - Geometry

    @Test func aLandscapeImageAtRestCropsItsCentredSquare() {
        let rect = AvatarImageCropper.cropRect(
            imageSize: CGSize(width: 1_200, height: 800),
            cropSide: 280,
            zoom: 1,
            offset: .zero
        )

        #expect(rect == CGRect(x: 200, y: 0, width: 800, height: 800))
    }

    /// Dragged as far right as it goes, the picture's left edge meets the circle's: the crop is
    /// the leftmost square, not one hanging past the image.
    @Test func offsetIsClampedSoThePictureStillCoversTheCircle() {
        let imageSize = CGSize(width: 1_200, height: 800)
        let clamped = AvatarImageCropper.clampedOffset(
            CGSize(width: 10_000, height: 10_000),
            imageSize: imageSize,
            cropSide: 280,
            zoom: 1
        )

        #expect(clamped == CGSize(width: 70, height: 0))
        let rect = AvatarImageCropper.cropRect(imageSize: imageSize, cropSide: 280, zoom: 1, offset: clamped)
        #expect(rect.minX == 0)
        #expect(rect.width == 800)
    }

    @Test func zoomIsClampedBetweenOneAndTheMaximum() {
        #expect(AvatarImageCropper.clampedZoom(0.2) == 1)
        #expect(AvatarImageCropper.clampedZoom(99) == AvatarImageCropper.maximumZoom)
        #expect(AvatarImageCropper.clampedZoom(.nan) == 1)
    }

    /// Zooming in keeps whatever is under the circle's centre there, so a face dragged into frame
    /// does not slide away when the slider moves.
    @Test func rezoomingKeepsTheCentredPointInPlace() {
        let imageSize = CGSize(width: 1_000, height: 1_000)
        let before = AvatarImageCropper.cropRect(
            imageSize: imageSize, cropSide: 280, zoom: 2, offset: CGSize(width: 40, height: -20))
        let offset = AvatarImageCropper.rezoomedOffset(
            CGSize(width: 40, height: -20), imageSize: imageSize, cropSide: 280, from: 2, to: 4)
        let after = AvatarImageCropper.cropRect(imageSize: imageSize, cropSide: 280, zoom: 4, offset: offset)

        #expect(abs(before.midX - after.midX) <= 1)
        #expect(abs(before.midY - after.midY) <= 1)
        #expect(after.width < before.width)
    }

    @Test func croppedJPEGIsASquareJPEGAtTheOutputSize() throws {
        let source = try #require(AvatarImageCropper.normalizedImage(from: Self.testPNGData(width: 300, height: 200)))

        let data = try #require(
            AvatarImageCropper.croppedJPEG(image: source, cropSide: 280, zoom: 2, offset: CGSize(width: 15, height: 5))
        )

        let decoded = try #require(CGImageSourceCreateWithData(data as CFData, nil))
        #expect(CGImageSourceGetType(decoded) as String? == AvatarImageCropper.outputTypeIdentifier)
        let image = try #require(CGImageSourceCreateImageAtIndex(decoded, 0, nil))
        #expect(image.width == AvatarImageCropper.outputPixelSize)
        #expect(image.height == AvatarImageCropper.outputPixelSize)
    }

    @Test func theEditorWorksOnABoundedCopyOfAHugeImage() throws {
        let image = try #require(
            AvatarImageCropper.normalizedImage(from: Self.testPNGData(width: 4_000, height: 1_000)))

        #expect(image.width == AvatarImageCropper.maximumEditorPixelSize)
        #expect(image.height == AvatarImageCropper.maximumEditorPixelSize / 4)
    }

    @Test func bytesThatAreNotAnImageDoNotDecode() {
        #expect(AvatarImageCropper.normalizedImage(from: Data("not an image".utf8)) == nil)
        #expect(AvatarImageCropper.normalizedImage(from: Data()) == nil)
    }

    // MARK: - Sources

    @Test func aWebResultWithAnUnsafeURLIsRefusedBeforeAnyDownload() async throws {
        let loader = FakeGroupImageSourceLoader(response: Data([1]))

        await #expect(throws: AvatarImageCropSource.Failure.invalidWebImage) {
            try await AvatarImageCropSource.data(for: Self.result(imageURL: "ftp://example.com/a.png"), using: loader)
        }
        #expect(await loader.requestedURLs.isEmpty)
    }

    @Test func aWebResultThatFailsToDownloadSaysSo() async throws {
        let loader = FakeGroupImageSourceLoader(response: nil)

        await #expect(throws: AvatarImageCropSource.Failure.downloadFailed) {
            try await AvatarImageCropSource.data(for: Self.result(imageURL: "https://example.com/a.png"), using: loader)
        }
    }

    @Test func aFileOverTheCapIsRefusedWithoutBeingReadWhole() async throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "avatar-crop-\(UUID().uuidString).png")
        try Data(repeating: 0xAB, count: 64).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        await #expect(throws: OutgoingMediaDraftProcessor.Failure.self) {
            try await AvatarImageCropSource.data(fromFileURL: url, maximumBytes: 32)
        }
        #expect(try await AvatarImageCropSource.data(fromFileURL: url, maximumBytes: 64).count == 64)
    }

    // MARK: - Model

    @Test func loadingDecodesThePictureAndCentresIt() async throws {
        let model = AvatarCropViewModel(loadData: { try Self.testPNGData(width: 300, height: 200) }, commit: { _ in })

        await model.load()

        #expect(model.phase == .ready)
        #expect(model.imageSize == CGSize(width: 300, height: 200))
        #expect(model.zoom == 1)
        #expect(model.offset == .zero)
        #expect(model.displayedSize.height == model.cropSide)
    }

    @Test func aSourceThatFailsLeavesTheEditorShowingWhy() async {
        let model = AvatarCropViewModel(
            loadData: { throw AvatarImageCropSource.Failure.downloadFailed },
            commit: { _ in Issue.record("Nothing should be committed") }
        )

        await model.load()

        #expect(model.phase == .failed(AvatarImageCropSource.Failure.downloadFailed.localizedDescription))
        #expect(!model.canSave)
        #expect(await model.save() == false)
    }

    /// A drag reports its total translation each time; applying it to the offset the drag started
    /// from — not to the last one — is what stops the picture from running away under the cursor.
    @Test func aDragMovesFromWhereItStartedAndStopsAtTheEdge() async throws {
        let model = AvatarCropViewModel(loadData: { try Self.testPNGData(width: 300, height: 200) }, commit: { _ in })
        await model.load()

        model.drag(by: CGSize(width: 20, height: 0))
        model.drag(by: CGSize(width: 30, height: 0))
        #expect(model.offset == CGSize(width: 30, height: 0))
        model.endDrag()

        model.drag(by: CGSize(width: 10_000, height: 10_000))
        #expect(model.offset == CGSize(width: 70, height: 0))
    }

    @Test func aPinchScalesFromTheZoomItStartedAt() async throws {
        let model = AvatarCropViewModel(loadData: { try Self.testPNGData(width: 200, height: 200) }, commit: { _ in })
        await model.load()

        model.pinch(by: 2)
        model.pinch(by: 3)
        #expect(model.zoom == 3)
        model.endPinch()
        model.pinch(by: 10)
        #expect(model.zoom == AvatarImageCropper.maximumZoom)
    }

    @Test func savingHandsTheCroppedJPEGToTheCommit() async throws {
        var committed: Data?
        let model = AvatarCropViewModel(
            loadData: { try Self.testPNGData(width: 300, height: 200) },
            commit: { committed = $0 }
        )
        await model.load()

        #expect(await model.save())

        let data = try #require(committed)
        let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
        #expect(CGImageSourceGetType(source) as String? == AvatarImageCropper.outputTypeIdentifier)
        #expect(!model.isSaving)
        #expect(model.saveError == nil)
    }

    /// The destination's failure stays in the editor, beside the picture the user framed, rather
    /// than closing it and losing the crop.
    @Test func aFailedCommitKeepsTheEditorOpenWithTheError() async throws {
        let model = AvatarCropViewModel(
            loadData: { try Self.testPNGData(width: 300, height: 200) },
            commit: { _ in throw AvatarImageCropSource.Failure.downloadFailed }
        )
        await model.load()

        #expect(await model.save() == false)
        #expect(model.saveError == AvatarImageCropSource.Failure.downloadFailed.localizedDescription)
        #expect(model.canSave)
    }

    private static func result(imageURL: String) -> GroupImageSearchResult {
        GroupImageSearchResult(
            id: "crop",
            title: "Crop",
            imageURL: imageURL,
            thumbnailURL: nil,
            creator: nil,
            license: nil,
            attribution: nil,
            sourceURL: nil,
            width: 64,
            height: 64
        )
    }
}
