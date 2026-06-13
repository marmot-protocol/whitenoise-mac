//
//  whitenoise_macApp.swift
//  whitenoise-mac
//
//  Created by Jeff Gardner on 26/05/2026.
//

import SwiftUI

@main
struct whitenoise_macApp: App {
    @State private var workspace = WorkspaceState()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(workspace)
                .task {
                    await workspace.bootstrap()
                }
        }
        .windowStyle(.hiddenTitleBar)
        .windowToolbarStyle(.unifiedCompact(showsTitle: false))
        .windowResizability(.contentMinSize)
    }
}
