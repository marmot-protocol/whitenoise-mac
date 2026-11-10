import AppKit
import SwiftUI
import Vision

@testable import whitenoise_mac

/// A SwiftUI view hosted in a real window placed far offscreen. Unlike `ImageRenderer`, hosting
/// runs the view's `.task`s, draws `ScrollView` content and images, and takes clicks, so a page
/// that loads its own data can be driven and drawn in the state those loads leave it in.
///
/// Main-actor only, like every AppKit drawing call.
@MainActor
final class HostedViewWindow {
    let window: NSWindow
    /// Snapshot pixels per point.
    static let scale: CGFloat = 2

    init(_ view: some View, size: CGSize) {
        window = NSWindow(
            contentRect: CGRect(origin: CGPoint(x: -10_000, y: -10_000), size: size), styleMask: [.borderless],
            backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .aqua)
        window.contentView = NSHostingView(
            rootView: view.background(WNColor.backgroundPrimary).environment(\.colorScheme, .light))
        // Ordered in, though offscreen: a window that was never ordered in delivers no clicks.
        window.orderFrontRegardless()
        window.contentView?.layoutSubtreeIfNeeded()
    }

    func close() {
        window.close()
    }

    /// Lays the view out until `predicate` holds or `timeout` passes. The views under test start
    /// their reads in their own `.task`s, which hand back no handle to await.
    func settle(timeout: Duration = .seconds(5), until predicate: () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            window.contentView?.layoutSubtreeIfNeeded()
            if predicate() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        window.contentView?.layoutSubtreeIfNeeded()
        return predicate()
    }

    /// Settles until what the window draws satisfies `predicate`, and returns that drawing.
    func settleDrawing(
        timeout: Duration = .seconds(5), until predicate: (NSBitmapImageRep) -> Bool
    ) async -> NSBitmapImageRep? {
        var latest: NSBitmapImageRep?
        let matched = await settle(timeout: timeout) {
            latest = snapshot()
            return latest.map(predicate) ?? false
        }
        return matched ? latest : nil
    }

    /// The drawing once it has stopped changing: the same inked rows and fixture pixels in five
    /// layouts in a row. For a state with no other signal, such as a list that has finished
    /// loading and now draws nothing new.
    func steadyDrawing(timeout: Duration = .seconds(5)) async -> NSBitmapImageRep? {
        var previous: (rows: Int, pixels: Int)?
        var unchanged = 0
        return await settleDrawing(timeout: timeout) { drawing in
            let current = (rows: DrawnPixels.inkedRows(drawing), pixels: DrawnPixels.fixturePixels(in: drawing))
            unchanged = previous.map { $0 == current } == true ? unchanged + 1 : 0
            previous = current
            return unchanged >= 4
        }
    }

    /// What the window draws now, read from its layer tree. `cacheDisplay` leaves SwiftUI's images
    /// out.
    func snapshot() -> NSBitmapImageRep? {
        guard let view = window.contentView, let layer = view.layer else { return nil }
        view.layoutSubtreeIfNeeded()
        view.displayIfNeeded()
        guard
            let rep = NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: Int(view.bounds.width * Self.scale),
                pixelsHigh: Int(view.bounds.height * Self.scale), bitsPerSample: 8, samplesPerPixel: 4,
                hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
            let context = NSGraphicsContext(bitmapImageRep: rep)
        else { return nil }
        // Flipped, so row 0 of the bitmap is the top of the view, as `colorAt` reads it.
        context.cgContext.translateBy(x: 0, y: CGFloat(rep.pixelsHigh))
        context.cgContext.scaleBy(x: Self.scale, y: -Self.scale)
        layer.render(in: context.cgContext)
        return rep
    }

    /// A left click at `point`, in points from the window's top-left corner.
    func click(at point: CGPoint) {
        guard let height = window.contentView?.bounds.height else { return }
        let location = NSPoint(x: point.x, y: height - point.y)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            guard
                let event = NSEvent.mouseEvent(
                    with: type, location: location, modifierFlags: [],
                    timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
                    eventNumber: 0, clickCount: 1, pressure: 1)
            else { continue }
            window.sendEvent(event)
        }
    }

    /// A click on the trailing control of a page header (`StickerPageHeader`): 14pt in from the
    /// trailing edge, centred in the header's 10pt-padded row.
    func clickHeaderTrailingControl() {
        click(at: CGPoint(x: window.frame.width - 14 - 12, y: 21))
    }

    /// A click on a page header's Back button, the leading control.
    func clickHeaderBack() {
        click(at: CGPoint(x: 14 + 11, y: 21))
    }
}

/// Pixel measures of a `HostedViewWindow` snapshot.
enum DrawnPixels {
    /// The pure magenta the render fixtures paint their images with: no chrome, text or system
    /// tint in the app draws it, so finding it means a fixture image was drawn.
    static let fixtureColor = NSColor(srgbRed: 1, green: 0, blue: 1, alpha: 1)

    /// An opaque PNG filled with `fixtureColor`.
    static func fixturePNG(side: Int = 16) -> Data? {
        guard
            let bitmap = NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side, bitsPerSample: 8, samplesPerPixel: 4,
                hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
        else { return nil }
        // `setColor(_:atX:y:)` silently writes nothing across colour spaces, so paint it.
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        fixtureColor.setFill()
        NSRect(x: 0, y: 0, width: side, height: side).fill()
        NSGraphicsContext.restoreGraphicsState()
        return bitmap.representation(using: .png, properties: [:])
    }

    /// One pixel's 8-bit RGBA, read straight from a snapshot's bytes: `colorAt` with a colour
    /// space conversion is slow enough over a whole page to stretch a test by seconds. Snapshots
    /// are meshed 8-bit RGBA, so this is exact for them.
    private struct Pixel: Equatable {
        let red: UInt8
        let green: UInt8
        let blue: UInt8
        let alpha: UInt8

        init(_ rep: NSBitmapImageRep, x: Int, y: Int) {
            guard let data = rep.bitmapData, rep.samplesPerPixel == 4, !rep.isPlanar else {
                self.init(red: 0, green: 0, blue: 0, alpha: 0)
                return
            }
            let offset = y * rep.bytesPerRow + x * 4
            self.init(red: data[offset], green: data[offset + 1], blue: data[offset + 2], alpha: data[offset + 3])
        }

        init(red: UInt8, green: UInt8, blue: UInt8, alpha: UInt8) {
            self.red = red
            self.green = green
            self.blue = blue
            self.alpha = alpha
        }

        /// The fixture's magenta at full strength. A faded (disabled) image's blend with the
        /// ground does not count.
        var isFixture: Bool { red > 216 && green < 51 && blue > 216 && alpha > 216 }

        var brightness: Int { Int(max(red, green, blue)) }

        /// Visibly different from `ground`: brighter or darker, or more or less opaque.
        func isInk(on ground: Pixel) -> Bool {
            abs(brightness - ground.brightness) > 20 || abs(Int(alpha) - Int(ground.alpha)) > 20
        }
    }

    /// How many pixels, sampling every other column and row, are the fixture's magenta.
    static func fixturePixels(in rep: NSBitmapImageRep) -> Int {
        var count = 0
        for y in stride(from: 0, to: rep.pixelsHigh, by: 2) {
            for x in stride(from: 0, to: rep.pixelsWide, by: 2) where Pixel(rep, x: x, y: y).isFixture { count += 1 }
        }
        return count
    }

    /// Where the topmost, then leftmost, fixture image at or below `top` (in points) was drawn,
    /// as a point from the top-left corner a few pixels inside the image, so a click there lands
    /// on it.
    static func firstFixturePoint(in rep: NSBitmapImageRep, below top: CGFloat = 0) -> CGPoint? {
        for y in stride(from: Int(top * HostedViewWindow.scale), to: rep.pixelsHigh, by: 2) {
            for x in stride(from: 0, to: rep.pixelsWide, by: 2) where Pixel(rep, x: x, y: y).isFixture {
                return CGPoint(
                    x: CGFloat(x + 8) / HostedViewWindow.scale, y: CGFloat(y + 8) / HostedViewWindow.scale)
            }
        }
        return nil
    }

    /// Whether `count` is `expected` give or take 10%, for fixture pixels lost to an image's
    /// anti-aliased edges.
    static func isAbout(_ count: Int, _ expected: Int) -> Bool {
        abs(count - expected) <= expected / 10
    }

    /// Whether row `y` carries anything besides the ground, read at the bottom-left corner.
    private static func isInked(_ rep: NSBitmapImageRep, row y: Int) -> Bool {
        let ground = Pixel(rep, x: 1, y: rep.pixelsHigh - 2)
        return stride(from: 0, to: rep.pixelsWide, by: 3).contains { Pixel(rep, x: $0, y: y).isInk(on: ground) }
    }

    /// The lowest pixel row carrying anything besides the ground: where a page's content ends.
    static func lastInkedRow(_ rep: NSBitmapImageRep) -> Int {
        (0..<rep.pixelsHigh).last { isInked(rep, row: $0) } ?? 0
    }

    /// Pixel rows carrying anything besides the ground, a measure of how much a view drew.
    static func inkedRows(_ rep: NSBitmapImageRep) -> Int {
        (0..<rep.pixelsHigh).count { isInked(rep, row: $0) }
    }
}

/// Text read back out of a `HostedViewWindow` snapshot. For copy that must be on screen, such as a
/// privacy disclosure, where how much a view drew cannot tell one sentence from another.
enum DrawnText {
    /// Whether `phrase` was drawn, ignoring case, line breaks, how the text wrapped, and whether
    /// its apostrophes are typographic.
    static func contains(_ phrase: String, in rep: NSBitmapImageRep) -> Bool {
        normalized(recognized(in: rep)).contains(normalized(phrase))
    }

    /// Every line Vision recognizes, top to bottom, joined by spaces.
    static func recognized(in rep: NSBitmapImageRep) -> String {
        guard let image = rep.cgImage else { return "" }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        try? VNImageRequestHandler(cgImage: image).perform([request])
        return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: " ")
    }

    private static func normalized(_ text: String) -> String {
        text.lowercased().replacingOccurrences(of: "\u{2019}", with: "'")
            .replacingOccurrences(of: "\u{2018}", with: "'")
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}
