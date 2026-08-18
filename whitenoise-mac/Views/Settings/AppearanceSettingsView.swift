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
            Section(L10n.string("Appearance")) {
                Picker(L10n.string("Theme"), selection: $workspace.appearancePreference) {
                    ForEach(AppearancePreference.allCases) { preference in
                        Text(preference.label).tag(preference)
                    }
                }

                Picker(L10n.string("Language"), selection: $workspace.languagePreference) {
                    ForEach(AppLanguage.pickerChoices) { language in
                        Text(language.displayName).tag(language)
                    }
                }

                Text(L10n.string("System follows your Mac language. Other choices update White Noise immediately."))
                    .foregroundStyle(WNColor.backgroundContentSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
