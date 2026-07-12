//
//  ContentView.swift
//  whitenoise-mac
//
//  Created by Jeff Gardner on 26/05/2026.
//

import AppKit
import SwiftUI

private struct TimestampReferenceDateKey: EnvironmentKey {
    static let defaultValue = Date()
}

extension EnvironmentValues {
    var timestampReferenceDate: Date {
        get { self[TimestampReferenceDateKey.self] }
        set { self[TimestampReferenceDateKey.self] = newValue }
    }
}

struct ContentView: View {
    @Environment(WorkspaceState.self) private var workspace
    @State private var timestampReferenceDate = Date()

    var body: some View {
        MessengerShellView()
            .frame(minWidth: 940, minHeight: 620)
            .preferredColorScheme(workspace.preferredColorScheme)
            .environment(\.locale, workspace.preferredLocale)
            .environment(\.timestampReferenceDate, timestampReferenceDate)
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
                NotificationCenter.default.publisher(for: .NSCalendarDayChanged)
            ) { _ in
                timestampReferenceDate = Date()
            }
            .onReceive(
                NotificationCenter.default.publisher(
                    for: NSApplication.didBecomeActiveNotification
                )
            ) { _ in
                refreshTimestampReferenceDateIfNeeded()
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
    }

    private func refreshTimestampReferenceDateIfNeeded(now: Date = Date()) {
        guard !Calendar.autoupdatingCurrent.isDate(timestampReferenceDate, inSameDayAs: now) else { return }
        timestampReferenceDate = now
    }
}

#Preview {
    ContentView()
        .environment(WorkspaceState.preview())
}
