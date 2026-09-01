//
//  WorkspaceTestSupport.swift
//  whitenoise-macTests
//
//  Helpers the split suites reach for through `Self.` — settling detached send and upload
//  tasks, waiting on real async work, and building image bytes. They were `private static`
//  members of the one big suite; a protocol extension keeps every call site exactly as it
//  was written (`Self.settleOutgoingTextSends(state)`) while letting each suite conform.
//
//  Not free functions: several of these names are also file-private helpers in other test
//  files, and a module-scope twin of one of those is a redeclaration error.
//

import AppKit
import Combine
import CryptoKit
import Darwin
import Foundation
import ImageIO
import MarmotKit
import Observation
import SwiftUI
import Testing
import UniformTypeIdentifiers
import UserNotifications

@testable import whitenoise_mac

enum ImageFixtureError: Error {
    case failedToCreateContext
    case failedToCreateImage
    case failedToCreateDestination
    case failedToFinalize
}

protocol WorkspaceTestSupport {}

extension WorkspaceTestSupport {
    /// Attachments upload in a detached task as soon as they are staged, so tests that want every
    /// staged blob on Blossom before pressing Send have to let those tasks run. Yields until no
    /// attachment is still `.uploading` or the budget runs out, so a hang fails the assertion that
    /// follows rather than the whole suite.
    @MainActor
    static func settleComposerMediaUploads(_ state: WorkspaceState, yields: Int = 1_000) async {
        await yieldUntil(yields: yields) {
            state.pendingMediaUploadStatesByConversation.values.allSatisfy { states in
                states.values.allSatisfy { $0 != .uploading }
            }
        }
    }

    /// Send never waits for media: it hands the message to a detached upload-then-publish task and
    /// returns. Anything asserting on the runtime, the transcript, or the disk cache therefore has
    /// to let that task finish. A failed message stays parked as a `.failed` bubble, which counts
    /// as settled.
    ///
    /// Awaits the tasks themselves rather than yield-polling: the publish path does real async work
    /// (a disk-cache store, and the Keychain read behind it) that no number of cooperative yields
    /// will advance. `rounds` bounds a retry chain so a bug cannot hang the suite.
    @MainActor
    static func settlePendingOutgoingMediaSends(_ state: WorkspaceState, rounds: Int = 20) async {
        for _ in 0..<rounds {
            let inFlight = state.pendingOutgoingMediaMessagesByConversation.values
                .flatMap { $0 }
                .filter(\.state.isInFlight)
            guard !inFlight.isEmpty else { return }
            for message in inFlight {
                await state.pendingOutgoingMediaSendTasks[message.id]?.value
            }
        }
    }

    /// Text sends hand off the same way media ones do — Send empties the composer, returns, and
    /// leaves a detached task to publish — so anything asserting on the runtime, `lastError` or the
    /// transcript has to let that task finish. Awaiting the tasks beats yield-polling for the same
    /// reason it does above: the publish path does real async work no cooperative hop can advance.
    ///
    /// One entry per conversation, each chained behind its predecessor, so awaiting the snapshot
    /// drains every text send made from that composer.
    @MainActor
    static func settleOutgoingTextSends(_ state: WorkspaceState) async {
        for task in state.outgoingTextSendTasks.values {
            await task.value
        }
    }

    /// Retries do not join the conversation's send chain — the messages in it are the ones sent
    /// *since* the failure — so they are awaited through their own handles.
    @MainActor
    static func settlePendingOutgoingTextSends(_ state: WorkspaceState) async {
        for task in state.pendingOutgoingTextSendTasks.values {
            await task.value
        }
    }

    /// Real-time counterpart of `yieldUntil`, for conditions a detached task only reaches after
    /// actual async work rather than after a cooperative hop.
    @MainActor
    static func waitUntil(timeout: Duration = .seconds(10), _ condition: () -> Bool) async {
        let deadline = ContinuousClock.now + timeout
        while !condition() && ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(2))
        }
    }

    /// `beginPendingMediaUpload` marks the attachment `.uploading` synchronously but reaches the
    /// FFI inside a `Task`, so anything asserting on the runtime has to let that task start.
    @MainActor
    static func yieldUntil(yields: Int = 1_000, _ condition: () -> Bool) async {
        for _ in 0..<yields where !condition() {
            await Task.yield()
        }
    }

    static func testPNGData(width: Int, height: Int) throws -> Data {
        let bytesPerPixel = 4
        let bytesPerRow = width * bytesPerPixel
        var pixels = [UInt8](repeating: 0xFF, count: height * bytesPerRow)

        return try pixels.withUnsafeMutableBytes { buffer in
            guard
                let context = CGContext(
                    data: buffer.baseAddress,
                    width: width,
                    height: height,
                    bitsPerComponent: 8,
                    bytesPerRow: bytesPerRow,
                    space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                )
            else {
                throw ImageFixtureError.failedToCreateContext
            }
            guard let image = context.makeImage() else {
                throw ImageFixtureError.failedToCreateImage
            }

            let data = NSMutableData()
            guard
                let destination = CGImageDestinationCreateWithData(
                    data,
                    UTType.png.identifier as CFString,
                    1,
                    nil
                )
            else {
                throw ImageFixtureError.failedToCreateDestination
            }
            CGImageDestinationAddImage(destination, image, nil)
            guard CGImageDestinationFinalize(destination) else {
                throw ImageFixtureError.failedToFinalize
            }
            return data as Data
        }
    }

    /// Puts `state` into an in-progress voice-recording state (mic "hot", metering task running,
    /// plaintext temp file on disk) without needing real mic hardware, mirroring what
    /// `startVoiceRecording()` sets up. Returns the temp file URL so tests can assert the
    /// recording was torn down and the plaintext audio purged. See #311.
    @MainActor
    func armInProgressVoiceRecording(on state: WorkspaceState) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("whitenoise-recording-teardown-\(UUID().uuidString).m4a")
        try Data("plaintext audio".utf8).write(to: url)

        state.voiceRecordingURL = url
        state.isRecordingVoiceMessage = true
        state.voiceRecordingSamples = [0.4, 0.6]
        state.voiceRecordingDurationSeconds = 1.5
        state.startVoiceRecordingMetering()
        #expect(state.voiceRecordingMeterTask != nil)
        return url
    }
}
