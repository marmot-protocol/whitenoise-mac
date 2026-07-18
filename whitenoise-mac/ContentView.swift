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

    var body: some View {
        MessengerShellView()
            .frame(minWidth: 940, minHeight: 620)
            .preferredColorScheme(workspace.preferredColorScheme)
            .environment(\.locale, workspace.preferredLocale)
            .environment(
                \.openURL,
                OpenURLAction { url in
                    workspace.handleMessageLinkOpen(url)
                }
            )
            .tint(Color(nsColor: .systemBlue))
            .nativeWindowGlassBackground()
            .onOpenURL { url in
                workspace.handleDeepLinkURL(url)
            }
            .onAppear {
                applyAppearance(workspace.appearancePreference)
            }
            .onChange(of: workspace.appearancePreference) { _, preference in
                applyAppearance(preference)
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
                Task {
                    await workspace.handleConversationVisibilityChange()
                    await workspace.refreshAccountProfiles()
                }
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
    }
}

#Preview {
    ContentView()
        .environment(WorkspaceState.preview())
}
