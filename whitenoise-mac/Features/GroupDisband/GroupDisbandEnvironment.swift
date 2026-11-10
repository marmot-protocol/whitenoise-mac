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
}
