//
//  AppearanceSettingsView.swift
//  whitenoise-mac
//
//  The Appearance page: how closely White Noise follows the macOS appearance.
//

import SwiftUI

struct AppearanceSettingsView: View {
    @Environment(WorkspaceState.self) private var workspace

    var body: some View {
        @Bindable var workspace = workspace

        // No subtitle: the two groups below are named "Theme" and "Language", and a line
        // under the title saying the page is about the theme and the language would only be
        // reading those two headers back. The reference design titles this screen and stops.
        SettingsScaffold(title: L10n.string("Appearance")) {
            // Three options, drawn as the three options rather than as a pop-up that hides two
            // of them: what Light and Dark mean is only clear next to System.
            //
            // The note under them says what each one does rather than repeating the page title,
            // because "System" is the only one of the three whose behaviour is not in its name —
            // it is the one that keeps changing after it is chosen.
            SettingsChoiceSection(
                title: L10n.string("Theme"),
                footer: L10n.string(
                    "System follows your Mac appearance. Light and Dark keep the selected appearance."
                ),
                choices: AppearancePreference.allCases,
                selection: $workspace.appearancePreference
            ) { preference in
                preference.label
            }

            // Language keeps the pop-up: ten of them is past the point where laying the list out
            // in the group helps, and the chosen one is the only one that has to be legible.
            SettingsSection(
                footer: L10n.string(
                    "System follows your Mac language. Other choices update White Noise immediately."
                )
            ) {
                Picker(L10n.string("Language"), selection: $workspace.languagePreference) {
                    ForEach(AppLanguage.pickerChoices) { language in
                        Text(language.displayName).tag(language)
                    }
                }
            }
        }
    }
}
