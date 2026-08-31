//
//  ImageZoomState.swift
//  whitenoise-mac
//
//  The zoom and pan transform for the full-screen image viewers, kept as a value
//  type so the gesture wiring in the views holds no rules of its own.
//

import CoreGraphics
import Foundation

/// How far a full-screen image may be magnified, and where it is allowed to sit
/// once it is.

/// Positions are held as a *centred* transform — the rendered position of a content
/// point `u` is `offset + scale * u`, with the origin at the middle of the viewport.
/// That is exactly what `.scaleEffect(scale).offset(offset)` produces in SwiftUI, so
/// the view applies this state without doing any arithmetic of its own.
///
/// Two sizes are needed for every operation and they are not interchangeable:
/// `viewport` is the space the viewer occupies, `fitted` is the size the image is
/// actually drawn at inside it after `.scaledToFit()`. A letterboxed image has a
/// `fitted` smaller than the `viewport` on one axis, and panning that axis before the
/// scaled image outgrows the viewport would only drag backdrop into view.
nonisolated struct ImageZoomState: Equatable {
    static let minimumScale: CGFloat = 1
    static let maximumScale: CGFloat = 4
    static let doubleClickScale: CGFloat = 2.5

    /// Anything within 1% of fit counts as unzoomed. Without the tolerance a trackpad
    /// twitch that leaves the scale at 1.0000001 would latch the viewer into its zoomed
    /// mode — which suppresses paging — with nothing on screen to explain why.
    private static let zoomedTolerance: CGFloat = 0.01

    private(set) var scale: CGFloat = minimumScale
    private(set) var offset: CGSize = .zero

    var isZoomed: Bool { scale > Self.minimumScale + Self.zoomedTolerance }

    /// Magnifies about `focus`, a point relative to the centre of the viewport.
    ///
    /// The content under `focus` stays under it, so a pinch grows the detail being
    /// pointed at rather than the middle of the picture.
    mutating func zoom(to proposedScale: CGFloat, focus: CGPoint, viewport: CGSize, fitted: CGSize) {
        guard proposedScale.isFinite, focus.x.isFinite, focus.y.isFinite else { return }
        let newScale = min(max(proposedScale, Self.minimumScale), Self.maximumScale)
        let previousScale = scale
        guard previousScale > 0 else { return }

        // Solve `focus == newOffset + newScale * u` for the content point `u` that the
        // old transform placed under the cursor.
        let ratio = newScale / previousScale
        let proposedOffset = CGSize(
            width: focus.x - ratio * (focus.x - offset.width),
            height: focus.y - ratio * (focus.y - offset.height)
        )

        scale = newScale
        offset = Self.clamped(proposedOffset, scale: newScale, viewport: viewport, fitted: fitted)
    }

    /// Double-click: out to `doubleClickScale` anchored at the pointer, or straight back
    /// to fit if the image is already magnified. Zooming out ignores `focus` deliberately —
    /// the gesture that leaves a zoom should always land on the same, centred image.
    mutating func toggleZoom(at focus: CGPoint, viewport: CGSize, fitted: CGSize) {
        if isZoomed {
            reset()
        } else {
            zoom(to: Self.doubleClickScale, focus: focus, viewport: viewport, fitted: fitted)
        }
    }

    /// Moves the image to `proposedOffset`, stopping at whichever edge it reaches first.
    mutating func pan(to proposedOffset: CGSize, viewport: CGSize, fitted: CGSize) {
        offset = Self.clamped(proposedOffset, scale: scale, viewport: viewport, fitted: fitted)
    }

    mutating func reset() {
        self = ImageZoomState()
    }

    /// How far the image may travel from centre before its own edge would come inside the
    /// viewport. Zero on an axis the scaled image does not yet overflow.
    private static func clamped(
        _ proposed: CGSize,
        scale: CGFloat,
        viewport: CGSize,
        fitted: CGSize
    ) -> CGSize {
        guard proposed.width.isFinite, proposed.height.isFinite else { return .zero }
        let limitX = max(0, (fitted.width * scale - viewport.width) / 2)
        let limitY = max(0, (fitted.height * scale - viewport.height) / 2)
        guard limitX.isFinite, limitY.isFinite else { return .zero }
        return CGSize(
            width: min(max(proposed.width, -limitX), limitX),
            height: min(max(proposed.height, -limitY), limitY)
        )
    }
}
