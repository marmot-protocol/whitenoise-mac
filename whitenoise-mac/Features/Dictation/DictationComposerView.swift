import SwiftUI

/// The composer while dictation runs: the words so far, a cancel, and a stop that puts them in
/// the message field. It stands in for the composer row the way the voice-recording bar does, so
/// nothing typed can race the words arriving.
///
/// Escape cancels and Return finishes — the message field is gone while this shows, so neither
/// key has anything else to do. The one exception is a field still on screen that binds the same
/// keys: while the in-chat search strip is open, Return steps to the next match and Escape closes
/// it, so `claimsReturnAndEscape` is false and the bar answers only to clicks. A window-level
/// shortcut would otherwise win over the focused field.
struct DictationComposerView: View {
    let state: ComposerDictationController.State
    let transcript: DictationTranscript
    var claimsReturnAndEscape = true
    let onCancel: () -> Void
    let onFinish: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            DictationLeadingIndicator(state: state)

            DictationTranscriptText(state: state, transcript: transcript)
                .frame(maxWidth: .infinity, alignment: .leading)

            Button(action: onCancel) {
                Label(L10n.string("Cancel dictation"), systemImage: "xmark")
                    .labelStyle(.iconOnly)
                    .frame(width: 20, height: 20)
            }
            .buttonBorderShape(.circle)
            .wnSecondaryButtonStyle()
            .controlSize(.regular)
            .keyboardShortcut(claimsReturnAndEscape ? .cancelAction : nil)
            .help(L10n.string("Cancel dictation"))
            .accessibilityLabel(L10n.string("Cancel dictation"))
            .accessibilityIdentifier("composer.dictation.cancel")

            Button(action: onFinish) {
                Group {
                    if state == .finishing {
                        ProgressView()
                            .controlSize(.small)
                            .scaleEffect(0.72)
                    } else {
                        Label(L10n.string("Finish dictation"), systemImage: "checkmark")
                            .labelStyle(.iconOnly)
                    }
                }
                .frame(width: 20, height: 20)
            }
            .buttonBorderShape(.circle)
            .wnPrimaryButtonStyle()
            .controlSize(.regular)
            .keyboardShortcut(claimsReturnAndEscape ? .defaultAction : nil)
            .disabled(state == .finishing)
            .help(L10n.string("Finish dictation"))
            .accessibilityLabel(L10n.string("Finish dictation"))
            .accessibilityIdentifier("composer.dictation.finish")
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(WNColor.fillSecondary, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 1)
        }
    }
}

/// Real state indicator for dictation: indeterminate progress while starting, the live pulse dot
/// only while actively listening (no decorative pulse outside actual recording/listening), and a
/// steady glyph while finishing.
private struct DictationLeadingIndicator: View {
    let state: ComposerDictationController.State

    var body: some View {
        switch state {
        case .starting:
            ProgressView()
                .controlSize(.small)
                .frame(width: 16, height: 16)
        case .listening:
            VoiceRecordingPulseDot()
                .frame(width: 16, height: 16)
        case .finishing, .idle:
            Image(systemName: "waveform")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 16, height: 16)
                .accessibilityHidden(true)
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
                .font(.body)
                .foregroundStyle(.secondary)
        } else {
            Text(styledTranscript)
                .font(.body)
                .lineLimit(1...4)
                .truncationMode(.head)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var styledTranscript: AttributedString {
        var settled = AttributedString(transcript.finalized)
        settled.foregroundColor = WNColor.textPrimary
        var guess = AttributedString(transcript.volatile)
        guess.foregroundColor = Color(nsColor: .secondaryLabelColor)
        return settled + guess
    }
}

#Preview("Dictation") {
    VStack(spacing: 12) {
        DictationComposerView(state: .starting, transcript: DictationTranscript(), onCancel: {}, onFinish: {})
        DictationComposerView(
            state: .listening,
            transcript: DictationTranscript(finalized: "See you at the station ", volatile: "around six"),
            claimsReturnAndEscape: false,
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
