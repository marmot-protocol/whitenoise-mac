//
//  whitenoise_macApp.swift
//  whitenoise-mac
//
//  Created by Jeff Gardner on 26/05/2026.
//

import SwiftUI

@main
struct whitenoise_macApp: App {
    @State private var workspace: WorkspaceState
    private let shouldBootstrapWorkspace: Bool

    init() {
        let configuration = AppLaunchConfiguration.current
        _workspace = State(initialValue: configuration.makeWorkspace())
        shouldBootstrapWorkspace = configuration.shouldBootstrapWorkspace
    }

    var body: some Scene {
        // A single `Window` scene (not `WindowGroup`) intentionally restricts the app to
        // exactly one window. The whole UI is driven by one shared `WorkspaceState`
        // (selection, search text, composer drafts, reply context, chat-list visibility,
        // sheet-presentation flags, etc.), so a second window would not be an independent
        // workspace — it would be a live mirror that fights the first over the same mutable
        // state. `Window` also removes the automatic File ▸ New Window (⌘N) command and
        // multi-window restoration that `WindowGroup` provides. See issue #46.
        Window("White Noise", id: "main") {
            ContentView()
                .environment(workspace)
                .task {
                    if shouldBootstrapWorkspace {
                        // Started before the bootstrap it runs alongside, not after: a cold start
                        // with no network is exactly when the offline notice has something to say,
                        // and bootstrap is the part that will be sitting there waiting on relays.
                        // Gated on the same flag as bootstrap so a UI fixture launch stays offline
                        // in the literal sense — it opens no sockets at all.
                        workspace.startConnectivityMonitoring()
                        await workspace.bootstrap()
                    }
                }
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentMinSize)
        .commands {
            CommandMenu("Navigate") {
                Button(L10n.string("Search All Messages…")) {
                    workspace.presentGlobalMessageSearch()
                }
                .keyboardShortcut("f", modifiers: [.command, .shift])
                .disabled(workspace.activeAccount == nil)
            }
        }
    }
}
