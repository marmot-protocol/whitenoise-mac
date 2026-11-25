import SwiftUI

/// The app menu's single Settings command. Its environment supplies the native scene action.
struct SettingsCommandButton: View {
    let isEnabled: Bool
    let locale: Locale
    let coordinator: SettingsWindowCoordinator

    @Environment(\.openSettings) private var openSettings

    var body: some View {
        Button(L10n.string("Settings…", locale: locale)) {
            coordinator.open(show: { openSettings() })
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
