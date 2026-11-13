//
//  GroupDisbandEnvironment.swift
//  whitenoise-mac
//
//  Which groups are mid End Group, handed down from the shell to every surface that would start a
//  group commit of its own.
//

import SwiftUI

extension EnvironmentValues {
    /// Groups whose End Group run is in flight (`AccountScope.endingGroupIds`). Installed by
    /// `ContentView`; a surface that starts a group commit combines it with the workspace's
    /// `hasInFlightGroupCommit`. Empty by default, so a surface outside the shell only loses this
    /// half of the guard, never the workspace's.
    @Entry var endingGroupIds: Set<String> = []

    /// A bulk leave from the chat list is publishing (`ChatListSelectionViewModel.isLeaving`).
    /// Installed by `ContentView` beside `endingGroupIds`, and re-installed with it on every sheet
    /// that starts a group commit, since a sheet does not inherit it.
    @Entry var isBulkLeavingChats = false
}

/// Whether a surface may start a group commit of its own. The one place the sources are combined,
/// so a new commit-blocking flag is added here once rather than to every surface that reads it.
@MainActor
enum GroupCommitGuard {
    /// A group commit — the workspace's, an End Group run, or a bulk leave from the chat list —
    /// is in flight. Every source is a required argument, so a surface cannot forget one.
    static func isInFlight(workspace: WorkspaceState, endingGroupIds: Set<String>, isBulkLeavingChats: Bool) -> Bool {
        workspace.hasInFlightGroupCommit || !endingGroupIds.isEmpty || isBulkLeavingChats
    }
}
