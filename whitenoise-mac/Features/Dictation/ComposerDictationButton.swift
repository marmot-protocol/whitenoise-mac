import SwiftUI

/// Starts dictation from the composer row. A waveform rather than a microphone, because the mic
/// beside it already means "record a voice message", and the two must not be confused: this one
/// sends no audio, only the words it hears.
struct ComposerDictationButton: View {
    let isDisabled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(L10n.string("Dictate"), systemImage: "waveform")
                .labelStyle(.iconOnly)
                .font(.body)
                .foregroundStyle(.primary)
                .frame(width: 34, height: 36)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .help(L10n.string("Dictate"))
        .accessibilityLabel(L10n.string("Dictate"))
        .accessibilityIdentifier("composer.dictation.start")
    }
}

#Preview("Dictation button") {
    HStack {
        ComposerDictationButton(isDisabled: false, action: {})
        ComposerDictationButton(isDisabled: true, action: {})
    }
    .padding()
}
