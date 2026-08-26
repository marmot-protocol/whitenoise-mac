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

        SettingsScaffold(
            title: L10n.string("Appearance"),
            subtitle: L10n.string("Choose how White Noise follows macOS appearance.")
        ) {
            // Three options, drawn as the three options rather than as a pop-up that hides two
            // of them. What Light and Dark mean is only clear next to System, so the alternatives
            // are the explanation and there is no footer to write.
            SettingsChoiceSection(
                title: L10n.string("Theme"),
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
