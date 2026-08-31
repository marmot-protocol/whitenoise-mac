//
//  ZoomableImageView.swift
//  whitenoise-mac
//
//  The magnifiable image used by both full-screen viewers: the chat gallery overlay
//  and the shared-media preview sheet.
//

import SwiftUI

/// A decrypted attachment rendered to fit, that the pointer can magnify.
///
/// Three gestures: pinch to scale, double-click to jump to
/// `ImageZoomState.doubleClickScale` at the pointer (and again to return to fit), and drag
/// to pan once the image is larger than the space it sits in.
///
/// The gestures hang off the drawn image rather than the surrounding frame on purpose. A
/// letterboxed photo leaves backdrop either side of it, and both viewers close when that
/// backdrop is clicked — giving the whole frame a hit shape would quietly take that away.
struct ZoomableMediaImage<Placeholder: View>: View {
    let payload: DownloadedMediaPayload
    @Binding var zoom: ImageZoomState
    var accessibilityLabel: String?
    @ViewBuilder var placeholder: () -> Placeholder

    @Environment(\.displayScale) private var displayScale

    /// The size the image is actually drawn at, which is what decides how far it may pan.
    /// It is not the frame size: `.scaledToFit()` letterboxes anything that does not share
    /// the frame's aspect ratio.
    @State private var fittedSize: CGSize = .zero
    @State private var pointerLocation: CGPoint?
    @State private var panOrigin: CGSize?
    @State private var magnifyBaseScale: CGFloat?

    /// Flutter animates zoom over 250ms of `Curves.easeOutCubic`; this is the same curve
    /// expressed as its bezier, so a double-click settles identically on both clients.
    private static var zoomAnimation: Animation {
        .timingCurve(0.215, 0.61, 0.355, 1, duration: 0.25)
    }

    /// Computed rather than stored because `ZoomableMediaImage` is generic over its
    /// placeholder, and generic types cannot hold static stored properties.
    private static var coordinateSpace: String { "zoomableMediaImage" }

    var body: some View {
        GeometryReader { proxy in
            let viewport = proxy.size

            DownsampledDataImage(
                payload: payload,
                maxPixelSize: DownsampledImageSizing.galleryPixelSize(
                    for: viewport,
                    displayScale: displayScale,
                    zoomScale: zoom.scale
                )
            ) { image in
                labelled(
                    image
                        .resizable()
                        .scaledToFit()
                        .onGeometryChange(for: CGSize.self) {
                            $0.size
                        } action: {
                            fittedSize = $0
                        }
                        .scaleEffect(zoom.scale)
                        .offset(zoom.offset)
                )
                .pointerStyle(zoom.isZoomed ? .grabIdle : .zoomIn)
                // Pinch runs alongside the click/drag pair rather than competing with it:
                // a trackpad magnify and a pointer drag are separate inputs and either may
                // arrive first.
                .simultaneousGesture(magnifyGesture(viewport: viewport))
                .gesture(
                    doubleClickGesture(viewport: viewport)
                        .exclusively(before: panGesture(viewport: viewport))
                )
            } placeholder: {
                placeholder()
            }
            .frame(width: viewport.width, height: viewport.height)
            .coordinateSpace(.named(Self.coordinateSpace))
            .onContinuousHover(coordinateSpace: .named(Self.coordinateSpace)) { phase in
                switch phase {
                case .active(let location): pointerLocation = location
                case .ended: pointerLocation = nil
                }
            }
            // A resize moves the pan limits under an offset that was legal a moment ago, so
            // re-clamp rather than leaving the image parked past its own edge. Both inputs
            // matter: `viewport` appears in the limits directly, and it also changes the size
            // the image fits to. Watching only `viewport` would always run a step early —
            // SwiftUI measures the child after the parent, so `fittedSize` is still the old
            // one at that point.
            .onChange(of: viewport) { reclampOffset(viewport: viewport) }
            .onChange(of: fittedSize) { reclampOffset(viewport: viewport) }
        }
    }

    /// Trackpad pinch. `MagnifyGesture.magnification` is cumulative from the start of the
    /// gesture, so it is applied to the scale captured when the fingers went down instead of
    /// compounding against a scale this same gesture already changed.
    private func magnifyGesture(viewport: CGSize) -> some Gesture {
        MagnifyGesture()
            .onChanged { value in
                let base = magnifyBaseScale ?? zoom.scale
                magnifyBaseScale = base
                zoom.zoom(
                    to: base * value.magnification,
                    focus: focus(at: pointerLocation, viewport: viewport),
                    viewport: viewport,
                    fitted: fittedSize
                )
            }
            .onEnded { _ in magnifyBaseScale = nil }
    }

    private func doubleClickGesture(viewport: CGSize) -> some Gesture {
        SpatialTapGesture(count: 2, coordinateSpace: .named(Self.coordinateSpace))
            .onEnded { value in
                withAnimation(Self.zoomAnimation) {
                    zoom.toggleZoom(
                        at: focus(at: value.location, viewport: viewport),
                        viewport: viewport,
                        fitted: fittedSize
                    )
                }
            }
    }

    /// Drag to pan, but only once there is something to pan to — otherwise a stray drag on a
    /// fitted image would be swallowed here instead of reaching the viewer behind it.
    private func panGesture(viewport: CGSize) -> some Gesture {
        DragGesture(coordinateSpace: .named(Self.coordinateSpace))
            .onChanged { value in
                guard zoom.isZoomed else { return }
                let origin = panOrigin ?? zoom.offset
                panOrigin = origin
                zoom.pan(
                    to: CGSize(
                        width: origin.width + value.translation.width,
                        height: origin.height + value.translation.height
                    ),
                    viewport: viewport,
                    fitted: fittedSize
                )
            }
            .onEnded { _ in panOrigin = nil }
    }

    /// Pulls the current offset back inside whatever the limits have just become. A no-op for
    /// an offset that is still legal, which is most geometry changes.
    private func reclampOffset(viewport: CGSize) {
        zoom.pan(to: zoom.offset, viewport: viewport, fitted: fittedSize)
    }

    /// Labels the image only when the caller has a name for it. The shared-media sheet does
    /// not, and an empty label reads worse to VoiceOver than an unlabelled decorative image.
    @ViewBuilder
    private func labelled(_ image: some View) -> some View {
        if let accessibilityLabel {
            image.accessibilityLabel(accessibilityLabel)
        } else {
            image
        }
    }

    /// Converts a point in the viewer's coordinate space to the centre-relative one
    /// `ImageZoomState` works in. A pinch with the pointer outside the view (or off-screen)
    /// falls back to the centre.
    private func focus(at location: CGPoint?, viewport: CGSize) -> CGPoint {
        guard let location else { return .zero }
        return CGPoint(x: location.x - viewport.width / 2, y: location.y - viewport.height / 2)
    }
}
