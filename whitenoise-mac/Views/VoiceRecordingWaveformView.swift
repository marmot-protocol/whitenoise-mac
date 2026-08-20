//
//  VoiceRecordingWaveformView.swift
//  whitenoise-mac
//

import SwiftUI

/// The recording's own strip, hot or stopped: narrow bars whose height is the volume recorded,
/// filling in from the left and then travelling left at one bar per 40 ms of sound. Stopping the
/// mic freezes it — same bar width, same pitch, same length — and adds only a played/unplayed
/// split for listening back.
///
/// This is a separate view from the playback `ComposerAudioWaveformView` rather than another mode
/// of it, because the two are drawn on opposite terms. Playback divides its width between a fixed
/// number of samples, which in a composer-wide bar makes every bar about as wide as a finger; the
/// recording strip keeps the bar width fixed and takes as many bars as fit. That is why the staged
/// recording draws through this view and the transcript bubble — narrow enough that a fixed count
/// still lands thin — draws through the other one.
struct VoiceRecordingWaveformView: View {
    /// Which of the take's levels the bars are filled from, once the width is known.
    enum Window: Equatable {
        /// The newest levels that fit. The strip travels leftwards as the mic keeps running.
        case liveTail
        /// The whole take, at the length it had reached when the mic went off.
        case stopped(recordedSeconds: Double?)
    }

    /// How far playback has run through a stopped take, and the colour its bars take once passed.
    struct PlaybackTint: Equatable {
        let progress: CGFloat
        let playedColor: Color
    }

    /// The recording's levels, oldest first. Sliced or condensed to what fits once the width is
    /// known, according to `window`.
    let levels: [CGFloat]
    let window: Window
    let barColor: Color
    /// `nil` while the mic is hot: every bar of a live recording is at full strength.
    var playback: PlaybackTint?

    private static let restingBarHeight: CGFloat = 3

    var body: some View {
        GeometryReader { geometry in
            let visible = visibleLevels(forWidth: geometry.size.width)

            HStack(alignment: .center, spacing: VoiceRecordingWaveform.barSpacing) {
                // Keyed by slot, not by sample: each slot keeps its capsule and only its height
                // changes as the window slides, so there is nothing for SwiftUI to animate,
                // transition, or fall behind on. The travel is the data moving through the slots.
                ForEach(Array(visible.enumerated()), id: \.offset) { index, level in
                    Capsule()
                        .fill(fillColor(atIndex: index, of: visible.count))
                        .frame(
                            width: VoiceRecordingWaveform.barWidth,
                            height: max(Self.restingBarHeight, geometry.size.height * level)
                        )
                }
            }
            // Leading, so the strip grows rightwards from empty and only starts travelling once it
            // is full. Trailing would slide the whole recording sideways from the first bar. A
            // stopped take keeps the same edge, so it stays where it was drawn a moment ago.
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        }
        .accessibilityHidden(true)
    }

    private func visibleLevels(forWidth width: CGFloat) -> [CGFloat] {
        switch window {
        case .liveTail:
            VoiceRecordingWaveform.visibleLevels(
                window: levels,
                barCount: VoiceRecordingWaveform.barCount(forWidth: width)
            )
        case .stopped(let recordedSeconds):
            VoiceRecordingWaveform.condensedLevels(
                history: levels,
                barCount: VoiceRecordingWaveform.stoppedBarCount(
                    width: width,
                    recordedSeconds: recordedSeconds
                )
            )
        }
    }

    private func fillColor(atIndex index: Int, of count: Int) -> Color {
        guard let playback else { return barColor }
        let position = CGFloat(index) / CGFloat(max(1, count - 1))
        return position <= playback.progress ? playback.playedColor : barColor
    }
}
