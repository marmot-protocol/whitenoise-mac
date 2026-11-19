import SwiftUI

/// The composer while dictation runs: the words so far, a cancel, and a stop that puts them in
/// the message field. It stands in for the composer row the way the voice-recording bar does, so
/// nothing typed can race the words arriving.
///
/// Escape cancels and Return finishes — the message field is gone while this shows, so neither
/// key has anything else to do.
struct DictationComposerView: View {
    let state: ComposerDictationController.State
    let transcript: DictationTranscript
    let onCancel: () -> Void
    let onFinish: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            VoiceRecordingPulseDot()

            DictationTranscriptText(state: state, transcript: transcript)
                .frame(maxWidth: .infinity, alignment: .leading)

            Button(action: onCancel) {
                Image(systemName: "xmark")
                    .wnFont(.bold12)
                    .frame(width: 30, height: 30)
                    .background {
                        MessagesCircleControlBackground()
                    }
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.cancelAction)
            .help(L10n.string("Cancel dictation"))
            .accessibilityLabel(L10n.string("Cancel dictation"))
            .accessibilityIdentifier("composer.dictation.cancel")

            Button(action: onFinish) {
                Group {
                    if state == .finishing {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Image(systemName: "checkmark")
                            .wnFont(.bold12)
                            .foregroundStyle(WNColor.fillContentPrimary)
                    }
                }
                .frame(width: 30, height: 30)
                .background(WNColor.fillPrimary, in: .circle)
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.defaultAction)
            .disabled(state == .finishing)
            .help(L10n.string("Finish dictation"))
            .accessibilityLabel(L10n.string("Finish dictation"))
            .accessibilityIdentifier("composer.dictation.finish")
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(WNColor.borderTertiary, lineWidth: 1)
        }
    }
}

/// The recognized words, settled ones at full strength and the recognizer's current guess
/// dimmed, or what the recognizer is doing when there are no words yet.
private struct DictationTranscriptText: View {
    let state: ComposerDictationController.State
    let transcript: DictationTranscript

    var body: some View {
        if transcript.isEmpty {
            Text(state == .starting ? L10n.string("Getting dictation ready") : L10n.string("Listening…"))
                .wnFont(.medium14)
                .foregroundStyle(WNColor.backgroundContentSecondary)
        } else {
            Text(styledTranscript)
                .wnFont(.medium14)
                .lineLimit(1...4)
                .truncationMode(.head)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var styledTranscript: AttributedString {
        var settled = AttributedString(transcript.finalized)
        settled.foregroundColor = WNColor.backgroundContentPrimary
        var guess = AttributedString(transcript.volatile)
        guess.foregroundColor = WNColor.backgroundContentSecondary
        return settled + guess
    }
}

#Preview("Dictation") {
    VStack(spacing: 12) {
        DictationComposerView(state: .starting, transcript: DictationTranscript(), onCancel: {}, onFinish: {})
        DictationComposerView(
            state: .listening,
            transcript: DictationTranscript(finalized: "See you at the station ", volatile: "around six"),
            onCancel: {},
            onFinish: {}
        )
        DictationComposerView(
            state: .finishing,
            transcript: DictationTranscript(finalized: "See you at the station around six."),
            onCancel: {},
            onFinish: {}
        )
    }
    .padding()
    .frame(width: 520)
}
