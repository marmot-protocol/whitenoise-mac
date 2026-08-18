//
//  VoiceRecordingPulseDot.swift
//  whitenoise-mac
//

import SwiftUI

/// The "still recording" dot at the head of the voice-recording bar, pulsing on its own clock.
///
/// It is `fillPrimary` rather than the conventional recording red on purpose: the waveform beside it
/// was deliberately moved off the destructive palette, because a recording in progress is the
/// composer doing what it was asked to rather than an error. The dot pulses to say the mic is live
/// and leaves red to the trash can in the voice-draft bar.
struct VoiceRecordingPulseDot: View {
    private static let diameter: CGFloat = 8
    private static let dimmedOpacity: Double = 0.25

    /// Flipped once on appear: a repeating animation needs a value change to attach to, and the
    /// dot has no state of its own to key off.
    @State private var isDimmed = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Circle()
            .fill(WNColor.fillPrimary)
            .frame(width: Self.diameter, height: Self.diameter)
            .opacity(isDimmed ? Self.dimmedOpacity : 1)
            .animation(
                reduceMotion ? nil : .easeInOut(duration: 0.65).repeatForever(autoreverses: true),
                value: isDimmed
            )
            .onAppear { isDimmed = true }
            .accessibilityHidden(true)
    }
}
