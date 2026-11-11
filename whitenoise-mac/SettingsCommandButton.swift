import SwiftUI

/// App menu ▸ Settings… (⌘,). Settings is a pane of the single main window rather than a scene of
/// its own, so the command reopens that window if it was closed and then selects the pane.
struct SettingsCommandButton: View {
    let isEnabled: Bool
    let showSettings: () -> Void

    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button(L10n.string("Settings…")) {
            openWindow(id: whitenoise_macApp.mainWindowID)
            showSettings()
        }
        .keyboardShortcut(",", modifiers: .command)
        .disabled(!isEnabled)
    }
}

#Preview {
    SettingsCommandButton(isEnabled: true, showSettings: {})
        .padding()
}
