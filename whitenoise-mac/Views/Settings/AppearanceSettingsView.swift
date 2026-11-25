//
//  AppearanceSettingsView.swift
//  whitenoise-mac
//
//  The Appearance page: how closely White Noise follows the macOS appearance and language.
//

import SwiftUI

struct AppearanceSettingsView: View {
    @Environment(WorkspaceState.self) private var workspace
    @Environment(\.locale) private var locale

    var body: some View {
        @Bindable var workspace = workspace

        SettingsScaffold(
            title: L10n.string("Appearance", locale: locale),
            subtitle: L10n.string("Choose the appearance and language White Noise uses.", locale: locale)
        ) {
            SettingsSection(
                footer: L10n.string(
                    "System follows your Mac appearance. Light and Dark keep the selected appearance.",
                    locale: locale
                )
            ) {
                Picker(L10n.string("Appearance", locale: locale), selection: $workspace.appearancePreference) {
                    ForEach(AppearancePreference.allCases) { preference in
                        Text(preference.label(in: locale)).tag(preference)
                    }
                }
                .pickerStyle(.segmented)
                .accessibilityIdentifier("settings.appearance.mode")
            }

            SettingsSection(
                footer: L10n.string(
                    "System follows your Mac language. Other choices update White Noise immediately.",
                    locale: locale
                )
            ) {
                Picker(L10n.string("Language", locale: locale), selection: $workspace.languagePreference) {
                    ForEach(AppLanguage.pickerChoices) { language in
                        Text(language.displayName(in: locale)).tag(language)
                    }
                }
                .pickerStyle(.menu)
                .accessibilityIdentifier("settings.appearance.language")
            }
        }
    }
}

#Preview("Appearance settings") {
    AppearanceSettingsView()
        .environment(WorkspaceState.preview())
        .frame(width: 560, height: 420)
}
