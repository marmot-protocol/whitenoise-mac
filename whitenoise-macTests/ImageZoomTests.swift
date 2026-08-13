//
//  ImageZoomTests.swift
//  whitenoise-macTests
//
//  The zoom/pan contract for the full-screen image viewers. These mirror the
//  Flutter client's `InteractiveViewer` tests, which likewise assert against the
//  transformation state rather than rendered pixels.
//

import CoreGraphics
import Foundation
import Testing

@testable import whitenoise_mac

@Suite(.serialized)
struct ImageZoomTests {
    /// A landscape image letterboxed into a taller viewport: fitted is narrower than
    /// the viewport is tall, so the two pan axes bottom out at different scales.
    private let viewport = CGSize(width: 1000, height: 800)
    private let fitted = CGSize(width: 1000, height: 500)

    @Test func startsFittedAndUnzoomed() {
        let zoom = ImageZoomState()

        #expect(zoom.scale == 1)
        #expect(zoom.offset == .zero)
        #expect(!zoom.isZoomed)
    }

    @Test func doubleClickZoomsInToTheDoubleClickScale() {
        var zoom = ImageZoomState()

        zoom.toggleZoom(at: .zero, viewport: viewport, fitted: fitted)

        #expect(zoom.scale == ImageZoomState.doubleClickScale)
        #expect(zoom.isZoomed)
    }

    @Test func doubleClickWhileZoomedReturnsToFit() {
        var zoom = ImageZoomState()

        zoom.toggleZoom(at: CGPoint(x: 200, y: 100), viewport: viewport, fitted: fitted)
        #expect(zoom.isZoomed)

        // A second double-click resets regardless of where it lands, matching Flutter's
        // "double-tap when zoomed resets to identity".
        zoom.toggleZoom(at: CGPoint(x: -300, y: 50), viewport: viewport, fitted: fitted)

        #expect(zoom.scale == 1)
        #expect(zoom.offset == .zero)
        #expect(!zoom.isZoomed)
    }

    @Test func doubleClickKeepsThePointUnderTheCursorInPlace() {
        var zoom = ImageZoomState()
        // Left of centre, and within the fitted image so the anchor is not clamped away.
        let focus = CGPoint(x: -200, y: 0)

        zoom.toggleZoom(at: focus, viewport: viewport, fitted: fitted)

        // Screen position of a content point u is `offset + scale * u`. The content point
        // that sat under the cursor before the zoom must still sit under it after.
        let contentUnderCursor = CGPoint(x: focus.x, y: focus.y)
        let screenX = zoom.offset.width + zoom.scale * contentUnderCursor.x
        let screenY = zoom.offset.height + zoom.scale * contentUnderCursor.y

        #expect(abs(screenX - focus.x) < 0.001)
        #expect(abs(screenY - focus.y) < 0.001)
    }

    @Test func zoomClampsToTheAllowedRange() {
        var zoom = ImageZoomState()

        zoom.zoom(to: 99, focus: .zero, viewport: viewport, fitted: fitted)
        #expect(zoom.scale == ImageZoomState.maximumScale)

        zoom.zoom(to: 0.1, focus: .zero, viewport: viewport, fitted: fitted)
        #expect(zoom.scale == ImageZoomState.minimumScale)
    }

    @Test func pinchingBackToFitRecentresTheImage() {
        var zoom = ImageZoomState()

        zoom.zoom(to: 4, focus: CGPoint(x: -400, y: -200), viewport: viewport, fitted: fitted)
        #expect(zoom.offset != .zero)

        // Returning to fit must leave no residual offset, or the image would sit
        // off-centre in its own letterbox with no way to nudge it back.
        zoom.zoom(to: 1, focus: CGPoint(x: -400, y: -200), viewport: viewport, fitted: fitted)
        #expect(zoom.offset == .zero)
    }

    @Test func panningIsRefusedWhileTheImageStillFits() {
        var zoom = ImageZoomState()

        zoom.pan(to: CGSize(width: 250, height: 250), viewport: viewport, fitted: fitted)

        #expect(zoom.offset == .zero)
    }

    @Test func panningStopsAtTheImageEdge() {
        var zoom = ImageZoomState()
        zoom.zoom(to: 2, focus: .zero, viewport: viewport, fitted: fitted)

        zoom.pan(to: CGSize(width: 10_000, height: 10_000), viewport: viewport, fitted: fitted)

        // Scaled image is 2000x1000 inside a 1000x800 viewport, so the image may travel
        // (2000-1000)/2 = 500 horizontally and (1000-800)/2 = 100 vertically.
        #expect(zoom.offset.width == 500)
        #expect(zoom.offset.height == 100)

        zoom.pan(to: CGSize(width: -10_000, height: -10_000), viewport: viewport, fitted: fitted)
        #expect(zoom.offset.width == -500)
        #expect(zoom.offset.height == -100)
    }

    @Test func theLetterboxedAxisNeverPansWhileTheImageFitsIt() {
        var zoom = ImageZoomState()
        // At 1.5x the 500pt-tall fitted image is 750pt — still inside the 800pt viewport,
        // so vertical panning would only expose backdrop.
        zoom.zoom(to: 1.5, focus: .zero, viewport: viewport, fitted: fitted)

        zoom.pan(to: CGSize(width: 10_000, height: 10_000), viewport: viewport, fitted: fitted)

        #expect(zoom.offset.height == 0)
        #expect(zoom.offset.width == 250)
    }

    @Test func zoomingOutPullsTheImageBackInsideItsBounds() {
        var zoom = ImageZoomState()
        zoom.zoom(to: 4, focus: .zero, viewport: viewport, fitted: fitted)
        zoom.pan(to: CGSize(width: 10_000, height: 10_000), viewport: viewport, fitted: fitted)
        #expect(zoom.offset.width == 1500)

        // Shrinking the image must re-clamp the offset it was already holding, otherwise
        // the previous pan would leave a gap at the trailing edge.
        zoom.zoom(to: 2, focus: .zero, viewport: viewport, fitted: fitted)

        #expect(zoom.offset.width <= 500)
        #expect(zoom.offset.height <= 100)
    }

    @Test func reClampingAfterTheImageFitsSmallerPullsItBackInside() {
        var zoom = ImageZoomState()
        zoom.zoom(to: 4, focus: .zero, viewport: viewport, fitted: fitted)
        zoom.pan(to: CGSize(width: 10_000, height: 10_000), viewport: viewport, fitted: fitted)
        #expect(zoom.offset.width == 1500)

        // A window resize re-fits the image, which moves the pan limits under an offset that
        // was legal a moment ago. Re-panning to the current offset is how the viewer re-clamps.
        let smallerFit = CGSize(width: 600, height: 300)
        zoom.pan(to: zoom.offset, viewport: viewport, fitted: smallerFit)

        // 600*4 = 2400 wide in a 1000pt viewport leaves (2400-1000)/2 = 700 of travel.
        #expect(zoom.offset.width == 700)
    }

    @Test func reClampingIsIdempotentForAnOffsetThatIsAlreadyLegal() {
        var zoom = ImageZoomState()
        zoom.zoom(to: 2, focus: .zero, viewport: viewport, fitted: fitted)
        zoom.pan(to: CGSize(width: 120, height: 40), viewport: viewport, fitted: fitted)
        let settled = zoom

        // The viewer re-clamps on every geometry change, most of which move nothing.
        zoom.pan(to: zoom.offset, viewport: viewport, fitted: fitted)

        #expect(zoom == settled)
    }

    @Test func isZoomedIgnoresFloatingPointDust() {
        var zoom = ImageZoomState()

        zoom.zoom(to: 1.005, focus: .zero, viewport: viewport, fitted: fitted)

        // Flutter treats anything at or below a 1% overshoot as "not zoomed" so that a
        // stray trackpad twitch does not silently disable paging.
        #expect(!zoom.isZoomed)
    }

    @Test func resetReturnsToTheInitialState() {
        var zoom = ImageZoomState()
        zoom.zoom(to: 3, focus: CGPoint(x: 100, y: 100), viewport: viewport, fitted: fitted)

        zoom.reset()

        #expect(zoom == ImageZoomState())
    }

    @Test func degenerateGeometryIsIgnoredRatherThanProducingNaN() {
        var zoom = ImageZoomState()

        zoom.zoom(to: 2, focus: .zero, viewport: .zero, fitted: .zero)
        #expect(zoom.offset.width.isFinite)
        #expect(zoom.offset.height.isFinite)

        zoom.zoom(to: .nan, focus: .zero, viewport: viewport, fitted: fitted)
        #expect(zoom.scale.isFinite)
    }

    // MARK: - Pixel budget

    @Test func zoomBucketsThePixelBudgetSoAPinchDoesNotRedecodeContinuously() {
        // Fit and anything near it keeps the fitted-resolution decode.
        #expect(DownsampledImageSizing.zoomPixelMultiplier(for: 1) == 1)
        #expect(DownsampledImageSizing.zoomPixelMultiplier(for: 1.4) == 1)
        // Then at most two refinements across the whole 1x-4x range.
        #expect(DownsampledImageSizing.zoomPixelMultiplier(for: 2) == 2)
        #expect(DownsampledImageSizing.zoomPixelMultiplier(for: 4) == 4)
    }

    @Test func zoomedGalleryAsksForMorePixelsThanTheFittedDecode() {
        let size = CGSize(width: 800, height: 600)
        let fittedBudget = DownsampledImageSizing.galleryPixelSize(for: size, displayScale: 2)
        let zoomedBudget = DownsampledImageSizing.galleryPixelSize(for: size, displayScale: 2, zoomScale: 4)

        // Without this the viewer would simply magnify the fit-sized bitmap and go soft.
        #expect(zoomedBudget > fittedBudget)
        #expect(zoomedBudget == fittedBudget * 4)
    }

    @Test func theZoomedPixelBudgetStaysBounded() {
        let large = CGSize(width: 1600, height: 1200)
        let budget = DownsampledImageSizing.galleryPixelSize(for: large, displayScale: 2, zoomScale: 4)

        // 3200 fitted pixels would otherwise ask ImageIO for a 12800px decode at 4x.
        #expect(budget == DownsampledImageSizing.maximumGalleryPixelSize)
    }

    @Test func theBoundNeverShrinksABudgetThatIsAlreadyThatLarge() {
        // On a display whose fitted decode already exceeds the cap, zooming must not
        // *reduce* resolution — the cap bounds zoom-driven growth, nothing else.
        let enormous = CGSize(width: 6000, height: 6000)
        let fittedBudget = DownsampledImageSizing.galleryPixelSize(for: enormous, displayScale: 2)
        let zoomedBudget = DownsampledImageSizing.galleryPixelSize(for: enormous, displayScale: 2, zoomScale: 4)

        #expect(fittedBudget > DownsampledImageSizing.maximumGalleryPixelSize)
        #expect(zoomedBudget == fittedBudget)
    }

    @Test func anUnzoomedGalleryBudgetIsUnchangedFromBefore() {
        let size = CGSize(width: 800, height: 600)

        // The default argument must keep every existing call site byte-identical in behaviour.
        #expect(
            DownsampledImageSizing.galleryPixelSize(for: size, displayScale: 2)
                == DownsampledImageSizing.galleryPixelSize(for: size, displayScale: 2, zoomScale: 1)
        )
    }
}
