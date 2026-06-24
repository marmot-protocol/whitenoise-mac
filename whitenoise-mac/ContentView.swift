//
//  ContentView.swift
//  whitenoise-mac
//
//  Created by Jeff Gardner on 26/05/2026.
//

import AppKit
import SwiftUI

struct ContentView: View {
    @Environment(WorkspaceState.self) private var workspace
    @State private var effectiveColorScheme: ColorScheme?

    var body: some View {
        MessengerShellView()
            .frame(minWidth: 940, minHeight: 620)
            .preferredColorScheme(effectiveColorScheme)
            .environment(\.locale, workspace.preferredLocale)
            .tint(Color(nsColor: .systemBlue))
            .nativeWindowGlassBackground()
            .onAppear {
                applyAppearance(workspace.appearancePreference)
            }
            .onChange(of: workspace.appearancePreference) { _, preference in
                applyAppearance(preference)
            }
            .onReceive(
                DistributedNotificationCenter.default().publisher(
                    for: Notification.Name("AppleInterfaceThemeChangedNotification")
                )
            ) { _ in
                refreshSystemAppearance()
            }
            .onReceive(
                NotificationCenter.default.publisher(
                    for: NSLocale.currentLocaleDidChangeNotification
                )
            ) { _ in
                workspace.refreshSystemLanguageIfNeeded()
            }
            .onReceive(
                NotificationCenter.default.publisher(
                    for: NSApplication.didBecomeActiveNotification
                )
            ) { _ in
                workspace.refreshSystemLanguageIfNeeded()
                // The app just regained focus. Flush any read-marking that was deferred
                // while it was in the background so the selected chat clears its unread
                // state now that the user may be looking at it again.
                Task { await workspace.handleConversationVisibilityChange() }
            }
            .onReceive(
                NotificationCenter.default.publisher(
                    for: NSWindow.didBecomeKeyNotification
                )
            ) { _ in
                Task { await workspace.handleConversationVisibilityChange() }
            }
            .onReceive(
                NotificationCenter.default.publisher(
                    for: NSWindow.didDeminiaturizeNotification
                )
            ) { _ in
                Task { await workspace.handleConversationVisibilityChange() }
            }
    }

    private func applyAppearance(_ preference: AppearancePreference) {
        NativeAppearanceController.apply(preference)
        effectiveColorScheme = NativeAppearanceController.preferredColorScheme(for: preference)

        DispatchQueue.main.async {
            effectiveColorScheme = NativeAppearanceController.preferredColorScheme(for: preference)
        }
    }

    private func refreshSystemAppearance() {
        guard workspace.appearancePreference == .system else { return }
        effectiveColorScheme = NativeAppearanceController.preferredColorScheme(for: .system)
    }
}

#Preview {
    ContentView()
        .environment(WorkspaceState.preview())
}
