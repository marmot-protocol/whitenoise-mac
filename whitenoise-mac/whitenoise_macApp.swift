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
                        await workspace.bootstrap()
                    }
                }
        }
        .windowStyle(.hiddenTitleBar)
        .windowToolbarStyle(.unifiedCompact(showsTitle: false))
        .windowResizability(.contentMinSize)
    }
}
