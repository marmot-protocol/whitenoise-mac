//
//  AttachmentGIFPlayback.swift
//  whitenoise-mac
//
//  Plays a GIF *attachment* — bytes that came through Blossom, not a GIPHY envelope — wherever the
//  app otherwise draws the attachment's still: the transcript tile, the gallery, and the composer.
//

import CoreGraphics
import Foundation
import ImageIO
import OSLog
import Observation
import SwiftUI

/// Runs ImageIO's animator over one GIF and publishes the frame on screen.
///
/// Frames go through SwiftUI as an `Image` rather than into a hosted `NSView`'s layer (what
/// `GiphyAnimatedNSView` does) so that a frame takes exactly the transforms the still did: the
/// gallery's zoom is a `scaleEffect` + `offset`, which a hosted AppKit view does not follow.
@MainActor
@Observable
final class AttachmentGIFPlayer {
    /// One run of the animator. ImageIO keeps calling a run's block until the block asks it to
    /// stop, so pausing marks the run and its next frame ends it.
    private final class Run {
        var isStopped = false
    }

    private(set) var frame: CGImage?
    private(set) var contentID: String?
    private(set) var didFinish = false

    @ObservationIgnored private var run: Run?
    @ObservationIgnored private var nextFrameIndex = 0
    /// Frames left before the GIF's own loop count is spent; nil loops forever. ImageIO is always
    /// asked to loop forever and the player counts, so a paused run resumes mid-loop without
    /// restarting the count.
    @ObservationIgnored private var remainingFrames: Int?

    var isPlaying: Bool { run != nil }

    func play(contentID: String, data: Data, animation: AttachmentGIF.Animation) {
        if self.contentID != contentID {
            pause()
            self.contentID = contentID
            frame = nil
            didFinish = false
            nextFrameIndex = 0
            remainingFrames = animation.totalFrames
        }
        guard run == nil, !didFinish else { return }
        let run = Run()
        self.run = run
        let frameCount = animation.frameCount
        let options: [CFString: Any] = [
            kCGImageAnimationLoopCount: Double.infinity,
            kCGImageAnimationStartIndex: nextFrameIndex,
        ]
        let status = CGAnimateImageDataWithBlock(data as CFData, options as CFDictionary) {
            [weak self] index, image, stop in
            guard let self, !run.isStopped else {
                stop.pointee = true
                return
            }
            frame = image
            nextFrameIndex = (index + 1) % frameCount
            if let remaining = remainingFrames {
                remainingFrames = remaining - 1
                if remaining <= 1 {
                    // The last frame of the last loop stays on screen, as in a browser.
                    stop.pointee = true
                    run.isStopped = true
                    self.run = nil
                    didFinish = true
                }
            }
        }
        if status != noErr {
            Self.log.error("animation_start_failed status=\(status, privacy: .public)")
            run.isStopped = true
            self.run = nil
            frame = nil
            didFinish = true
        }
    }

    /// Stops the animator; the frame on screen stays, and `play` picks up after it.
    func pause() {
        run?.isStopped = true
        run = nil
    }

    private static let log = Logger(subsystem: "dev.ipf.whitenoise.mac", category: "gif-attachment")
}

/// Hands `content` the GIF's current frame while it should animate, and nil otherwise — before the
/// animation is ready, for a still or malformed GIF, and under Reduce Motion — so the caller keeps
/// drawing its downsampled still. `content` must lay the frame out exactly as it lays out the
/// still; they share an aspect ratio, so swapping one for the other never moves anything.
///
/// It animates only while `isActive` (on screen, or the selected gallery page) and while the
/// window's scene is active. Bytes that are not a GIF pass straight through to the still.
struct AttachmentGIFPlayback<Content: View>: View {
    let contentID: String
    let data: Data?
    let isActive: Bool
    @ViewBuilder let content: (Image?) -> Content

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @State private var player = AttachmentGIFPlayer()
    @State private var prepared: Prepared?

    private struct Prepared: Equatable {
        let contentID: String
        let animation: AttachmentGIF.Animation
    }

    private struct PlaybackTaskID: Equatable {
        let contentID: String
        let isPrepared: Bool
        let isEligible: Bool
    }

    private var gifData: Data? {
        guard let data, AttachmentGIF.hasSignature(data) else { return nil }
        return data
    }

    var body: some View {
        content(currentFrame.map { Image(decorative: $0, scale: 1) })
            .task(id: gifData == nil ? nil : contentID) {
                guard prepared?.contentID != contentID else { return }
                prepared = nil
                guard let data = gifData else { return }
                let validation = Task.detached(priority: .utility) {
                    AttachmentGIF.animation(from: data)
                }
                // A detached task does not inherit this one's cancellation; forward it, so a tile
                // scrolled past stops validating its GIF.
                let animation = await withTaskCancellationHandler {
                    await validation.value
                } onCancel: {
                    validation.cancel()
                }
                guard !Task.isCancelled, let animation else { return }
                prepared = Prepared(contentID: contentID, animation: animation)
            }
            .task(id: playbackTaskID) {
                guard playbackTaskID.isEligible, let prepared, prepared.contentID == contentID, let data = gifData
                else {
                    player.pause()
                    return
                }
                player.play(contentID: contentID, data: data, animation: prepared.animation)
            }
            .onDisappear { player.pause() }
    }

    private var playbackTaskID: PlaybackTaskID {
        PlaybackTaskID(
            contentID: contentID,
            isPrepared: prepared?.contentID == contentID,
            isEligible: isActive && scenePhase == .active && !reduceMotion
        )
    }

    private var currentFrame: CGImage? {
        guard !reduceMotion, prepared?.contentID == contentID, player.contentID == contentID else { return nil }
        return player.frame
    }
}

#if DEBUG
    enum AttachmentGIFPreviewData {
        /// A 4-frame 64×64 GIF cycling through four colors, looping forever.
        static let cyclingColors: Data = {
            let output = NSMutableData()
            let colors: [CGColor] = [
                CGColor(red: 0.9, green: 0.2, blue: 0.2, alpha: 1),
                CGColor(red: 0.2, green: 0.7, blue: 0.3, alpha: 1),
                CGColor(red: 0.2, green: 0.4, blue: 0.9, alpha: 1),
                CGColor(red: 0.9, green: 0.8, blue: 0.2, alpha: 1),
            ]
            guard
                let destination = CGImageDestinationCreateWithData(
                    output, "com.compuserve.gif" as CFString, colors.count, nil)
            else { return Data() }
            CGImageDestinationSetProperties(
                destination,
                [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary
            )
            for color in colors {
                guard
                    let context = CGContext(
                        data: nil, width: 64, height: 64, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpaceCreateDeviceRGB(),
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                    )
                else { continue }
                context.setFillColor(color)
                context.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
                guard let image = context.makeImage() else { continue }
                CGImageDestinationAddImage(
                    destination, image,
                    [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 0.25]] as CFDictionary
                )
            }
            CGImageDestinationFinalize(destination)
            return output as Data
        }()
    }

    #Preview {
        AttachmentGIFPlayback(contentID: "preview", data: AttachmentGIFPreviewData.cyclingColors, isActive: true) {
            frame in
            if let frame {
                frame.resizable().scaledToFit()
            } else {
                Color.gray
            }
        }
        .frame(width: 160, height: 160)
        .padding()
    }
#endif
