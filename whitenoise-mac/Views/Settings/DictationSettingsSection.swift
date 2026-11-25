import SwiftUI

/// The dictation switch and the state of the speech model it needs. Lives in
/// `PreferencesSettingsView`, offered only where `SpeechAnalyzer` exists (macOS 26).
@available(macOS 26.0, *)
struct DictationSettingsSection: View {
    let preference: DictationPreference
    let installer: DictationModelInstaller
    /// The languages the model is checked for; read from the Mac by default.
    var languages: @MainActor () -> [String] = { DictationLanguages.candidates }

    var body: some View {
        SettingsSection(
            title: L10n.string("Dictation"),
            footer: L10n.string(
                "Click the waveform button next to the message field and speak; your words appear in the field for you to check and send. macOS turns your speech into text on this Mac and downloads its speech model from Apple. The audio isn't saved or sent."
            )
        ) {
            WNToggle(
                L10n.string("Dictate Messages"),
                systemImage: "waveform",
                isOn: Binding(
                    get: { preference.isEnabled },
                    set: { preference.setEnabled($0) }
                )
            )

            if preference.isEnabled {
                LabeledContent(L10n.string("Speech Model")) {
                    Text(installer.status.label)
                        .foregroundStyle(WNColor.backgroundContentSecondary)
                }

                if installer.status.offersDownload {
                    Button(L10n.string("Download Speech Model")) {
                        installer.install(localeIdentifiers: languages())
                    }
                    .wnSecondaryButtonStyle()
                }
            }
        }
        .task(id: preference.isEnabled) {
            guard preference.isEnabled else { return }
            await installer.refresh(localeIdentifiers: languages())
        }
    }
}

#Preview("Dictation settings") {
    if #available(macOS 26.0, *) {
        Form {
            DictationSettingsSection(
                preference: DictationPreference(defaults: UserDefaults(suiteName: "dictation-settings-preview")!),
                installer: DictationModelInstaller()
            )
        }
        .formStyle(.grouped)
        .frame(width: 520)
    }
}
