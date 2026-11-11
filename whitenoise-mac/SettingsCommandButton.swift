import SwiftUI

/// App menu ▸ Settings… (⌘,). Settings is a pane of the single main window rather than a scene of
/// its own, so the command reopens that window if it was closed and then selects the pane.
///
/// `locale` is passed in because commands sit outside the window's `\.locale` environment, and
/// `L10n.string(_:)` alone is not a dependency SwiftUI can see: without it the menu would keep the
/// previous language after an in-app language change.
struct SettingsCommandButton: View {
    let isEnabled: Bool
    let locale: Locale
    let showSettings: () -> Void

    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button(L10n.string("Settings…", locale: locale)) {
            openWindow(id: whitenoise_macApp.mainWindowID)
            showSettings()
        }
        .keyboardShortcut(",", modifiers: .command)
        .disabled(!isEnabled)
    }
}

#Preview {
    SettingsCommandButton(isEnabled: true, locale: .current, showSettings: {})
        .padding()
}
