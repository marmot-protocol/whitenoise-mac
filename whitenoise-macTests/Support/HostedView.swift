//
//  HostedView.swift
//  whitenoise-macTests
//
//  Building a SwiftUI view for real and measuring what came out.
//

import AppKit
import SwiftUI

/// A SwiftUI view built by SwiftUI, in a real window, so a test can measure it.
///
/// This is the replacement for the "does the source say `MessageAudioRow(`" family of assertions.
/// Two rows that must not reflow into each other are checked by *rendering both and comparing the
/// sizes*, which is the property the reader actually has — a shared sub-view is only one of the
/// ways to hold it, and naming that way in a test froze the implementation instead of the promise.
///
/// SwiftUI does not build an accessibility tree unless an assistive client is attached, so nothing
/// here reads labels or presses buttons: what a hosted view can report is its geometry and its
/// pixels. Everything a test wants to know about *wiring* belongs in a value type the view calls,
/// not in a probe of the view.
@MainActor
enum HostedView {

    /// The size SwiftUI lays `view` out at when nothing constrains it — the row's own footprint.
    ///
    /// The window is real (`NSHostingView` off-window resolves some layouts to zero) but never
    /// ordered in, so a suite running this does not steal focus from the machine it runs on.
    static func fittingSize(
        of view: some View,
        proposedWidth: CGFloat? = nil
    ) -> CGSize {
        let hosting = NSHostingView(rootView: AnyView(view))
        hosting.sizingOptions = [.intrinsicContentSize]
        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 1_000, height: 1_000),
            styleMask: [.titled],
            backing: .buffered,
            defer: true
        )
        window.contentView = NSView(frame: CGRect(x: 0, y: 0, width: 1_000, height: 1_000))
        window.contentView?.addSubview(hosting)
        if let proposedWidth {
            hosting.frame = CGRect(x: 0, y: 0, width: proposedWidth, height: 1_000)
        }
        hosting.layoutSubtreeIfNeeded()
        let size = hosting.intrinsicContentSize
        hosting.removeFromSuperview()
        window.contentView = nil
        return size
    }

    /// The view, rasterized, so a test can ask where something actually landed.
    ///
    /// `ImageRenderer` needs the colour scheme as well as the `NSAppearance`: with only the
    /// appearance set it resolves the whole palette light, and a measurement taken from that is a
    /// measurement of the harness.
    static func render(
        _ view: some View,
        appearance: NSAppearance.Name = .aqua,
        scale: CGFloat = 2
    ) -> NSBitmapImageRep? {
        var rep: NSBitmapImageRep?
        let nsAppearance = NSAppearance(named: appearance)
        nsAppearance?.performAsCurrentDrawingAppearance {
            let renderer = ImageRenderer(
                content:
                    view
                    .environment(\.colorScheme, appearance == .darkAqua ? .dark : .light)
            )
            renderer.scale = scale
            guard let cgImage = renderer.cgImage else { return }
            rep = NSBitmapImageRep(cgImage: cgImage)
        }
        return rep
    }

    /// The vertical span, in points, of the tallest solid dark block in the leading `searchWidth`
    /// points of `rep`.
    ///
    /// Used to find a control drawn as a solid black block and report where it landed, which is the
    /// only way to see an `.alignmentGuide` from outside the view that declares one. The tallest run
    /// wins rather than a named column, so the row's own chrome can inset the control without the
    /// measurement having to know by how much.
    static func tallestDarkSpan(
        in rep: NSBitmapImageRep,
        searchWidth: CGFloat,
        scale: CGFloat = 2
    ) -> ClosedRange<CGFloat>? {
        var best: ClosedRange<Int>?
        for column in 0..<min(rep.pixelsWide, Int(searchWidth * scale)) {
            var runStart: Int?
            for row in 0...rep.pixelsHigh {
                let isDark: Bool
                if row == rep.pixelsHigh {
                    isDark = false
                } else if let color = rep.colorAt(x: column, y: row)?.usingColorSpace(.sRGB) {
                    isDark = color.alphaComponent > 0.5 && color.brightnessComponent < 0.2
                } else {
                    isDark = false
                }
                if isDark {
                    if runStart == nil { runStart = row }
                } else if let start = runStart {
                    let run = start...(row - 1)
                    if best.map({ run.count > $0.count }) ?? true { best = run }
                    runStart = nil
                }
            }
        }
        guard let best else { return nil }
        return (CGFloat(best.lowerBound) / scale)...(CGFloat(best.upperBound) / scale)
    }
}
