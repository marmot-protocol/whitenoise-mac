import SwiftUI

/// The app menu's single Settings command (`⌘,`), opening Settings inside the main window.
struct SettingsCommandButton: View {
    let isEnabled: Bool
    let locale: Locale
    let coordinator: SettingsWindowCoordinator

    var body: some View {
        Button(L10n.string("Settings…", locale: locale)) {
            coordinator.open()
        }
        .keyboardShortcut(",", modifiers: .command)
        .disabled(!isEnabled)
    }
}

#Preview {
    SettingsCommandButton(
        isEnabled: true,
        locale: .current,
        coordinator: SettingsWindowCoordinator(workspace: .preview())
    )
    .padding()
}
