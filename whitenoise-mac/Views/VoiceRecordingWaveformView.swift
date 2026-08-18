//
//  VoiceRecordingWaveformView.swift
//  whitenoise-mac
//

import SwiftUI

/// The waveform while the mic is hot: narrow bars whose height is the volume just recorded, filling
/// in from the left and then travelling left at one bar per 40 ms of sound.
///
/// This is a separate view from the playback `ComposerAudioWaveformView` rather than another mode of
/// it, because the two are drawn on opposite terms. Playback has a fixed number of samples and
/// divides the width between them; a live recording has a fixed bar width and takes as many bars as
/// fit. Playback also never moves — progress only recolors bars that are already there.
struct VoiceRecordingWaveformView: View {
    /// The tail of the recording, oldest first. Sliced to what fits once the width is known.
    let levels: [CGFloat]
    let barColor: Color

    private static let restingBarHeight: CGFloat = 3

    var body: some View {
        GeometryReader { geometry in
            let visible = VoiceRecordingWaveform.visibleLevels(
                window: levels,
                barCount: VoiceRecordingWaveform.barCount(forWidth: geometry.size.width)
            )

            HStack(alignment: .center, spacing: VoiceRecordingWaveform.barSpacing) {
                // Keyed by slot, not by sample: each slot keeps its capsule and only its height
                // changes as the window slides, so there is nothing for SwiftUI to animate,
                // transition, or fall behind on. The travel is the data moving through the slots.
                ForEach(Array(visible.enumerated()), id: \.offset) { _, level in
                    Capsule()
                        .fill(barColor)
                        .frame(
                            width: VoiceRecordingWaveform.barWidth,
                            height: max(Self.restingBarHeight, geometry.size.height * level)
                        )
                }
            }
            // Leading, so the strip grows rightwards from empty and only starts travelling once it
            // is full. Trailing would slide the whole recording sideways from the first bar.
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        }
        .accessibilityHidden(true)
    }
}
