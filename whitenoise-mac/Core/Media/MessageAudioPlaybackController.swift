//
//  MessageAudioPlaybackController.swift
//  whitenoise-mac
//

import AVFoundation
import Foundation
import Observation
import SwiftUI

struct PreparedMessageAudioPlayer: @unchecked Sendable {
    let player: AVAudioPlayer
}

@MainActor
final class MessageAudioPlayerDelegate: NSObject, AVAudioPlayerDelegate {
    var onDidFinishPlaying: (() -> Void)?

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        player.currentTime = 0
        onDidFinishPlaying?()
    }
}

/// Playing one voice note: the `AVAudioPlayer`, the speed the listener picked for it, and the
/// progress monitor that follows it.
///
/// Lifted out of `MessageAudioAttachmentPlayer` so the two `AVAudioPlayer` traps below are
/// observable. Both fail silently in the view — the badge keeps reading `2x` while playback stays
/// at 1x, and nothing on screen says otherwise:
///
///  1. `rate` is ignored unless `enableRate` was set **before** `prepareToPlay()`.
///  2. `play()` can reset `rate`, so the selected speed has to be applied after it as well.
///
/// A test drives this object with real audio bytes and reads the rate back off the player, which is
/// the only place the truth was ever written down.
@MainActor
@Observable
final class MessageAudioPlaybackController {
    private(set) var isPlaying = false
    private(set) var progress: CGFloat = 0
    /// Per-row, like the iOS client's bubble: the speed a listener picked for one voice note is
    /// their reading of that note, not a preference to carry across the transcript.
    private(set) var speed = AudioPlaybackSpeed.initial

    /// The prepared player, exposed so a test can read the rate control the view cannot show.
    private(set) var player: AVAudioPlayer?

    private var preparationID: UUID?
    private var playbackMonitor: Task<Void, Never>?
    private let delegate = MessageAudioPlayerDelegate()

    var isPreparingPlayback: Bool {
        preparationID != nil
    }

    /// Whether the progress monitor is still running. `isPlaying` going false without this going
    /// with it is the leak that kept a stopped row waking the main actor five times a second.
    var isMonitoringProgress: Bool {
        guard let playbackMonitor else { return false }
        return !playbackMonitor.isCancelled
    }

    func toggle(payload: Data) async {
        if isPlaying || isPreparingPlayback {
            stop()
        } else {
            await start(payload: payload)
        }
    }

    func start(payload: Data) async {
        var startedPreparationID: UUID?
        do {
            if player == nil {
                let nextPreparationID = UUID()
                startedPreparationID = nextPreparationID
                preparationID = nextPreparationID
                let preparedPlayer = try await Task.detached(priority: .userInitiated) {
                    let audioPlayer = try AVAudioPlayer(data: payload)
                    // `rate` is only honoured when rate control is armed before the player prepares
                    // its buffers, so it is enabled here — arming it on the first click of the
                    // speed badge is too late and leaves playback at 1x for the whole note.
                    audioPlayer.enableRate = true
                    audioPlayer.prepareToPlay()
                    return PreparedMessageAudioPlayer(player: audioPlayer)
                }.value.player
                guard preparationID == nextPreparationID else { return }
                preparationID = nil
                player = preparedPlayer
                preparedPlayer.delegate = delegate
            }
            delegate.onDidFinishPlaying = { [weak self] in self?.finishPlayback() }
            applyPlaybackSpeed()
            player?.play()
            applyPlaybackSpeed()
            isPlaying = true
            updateProgress()
            monitorProgress()
        } catch {
            if startedPreparationID == nil || preparationID == startedPreparationID {
                preparationID = nil
                isPlaying = false
            }
        }
    }

    /// Advance the badge one step, wrapping 2x back to 1x, and make the new rate audible at once.
    ///
    /// Nothing is loaded on the first click of a row that has never played, and that is fine: the
    /// selection is remembered in `speed` and `start` applies it to the player it prepares.
    func cycleSpeed() {
        speed = speed.next
        applyPlaybackSpeed()
        guard isPlaying else { return }
        // A rate assigned to an already-playing `AVAudioPlayer` does not always take until the
        // player is told to play again, and `play()` in turn can reset the rate to 1 — so the new
        // speed is applied on both sides of the call. Without this the change is inaudible until
        // the listener stops and restarts the note.
        player?.play()
        applyPlaybackSpeed()
    }

    /// Transcript rows are eager, so scrolling one out of the viewport does not take it away.
    /// A row that has left the screen stops rather than playing on behind the reader.
    func scrollVisibilityChanged(to isVisible: Bool) {
        guard !isVisible else { return }
        stop()
    }

    func disappeared() {
        stop()
    }

    /// The prepared player is built from one payload's bytes. If the view's identity outlives a
    /// change of payload — an edited or progressively updated attachment — the stale player is
    /// dropped so the next play rebuilds it instead of replaying the previous one. See #339.
    func payloadChanged() {
        stop()
        player = nil
    }

    func stop() {
        preparationID = nil
        delegate.onDidFinishPlaying = nil
        player?.stop()
        player?.currentTime = 0
        finishPlayback()
    }

    private func applyPlaybackSpeed() {
        player?.rate = speed.rate
    }

    private func finishPlayback() {
        playbackMonitor?.cancel()
        playbackMonitor = nil
        isPlaying = false
        progress = 0
    }

    private func monitorProgress() {
        playbackMonitor?.cancel()
        playbackMonitor = Task { @MainActor in
            while !Task.isCancelled, isPlaying {
                updateProgress()
                try? await Task.sleep(for: .milliseconds(200))
            }
        }
    }

    private func updateProgress() {
        guard let player, player.duration > 0 else {
            progress = 0
            return
        }
        progress = min(1, max(0, CGFloat(player.currentTime / player.duration)))
    }
}
