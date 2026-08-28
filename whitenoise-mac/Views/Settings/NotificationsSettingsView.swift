//
//  NotificationsSettingsView.swift
//  whitenoise-mac
//
//  The Notifications page: the local alerts this Mac is allowed to post.
//

import AppKit
import SwiftUI

struct NotificationsSettingsView: View {
    @Environment(WorkspaceState.self) private var workspace

    var body: some View {
        @Bindable var workspace = workspace

        SettingsScaffold(
            title: L10n.string("Notifications"),
            subtitle: L10n.string("Local alerts for this Mac.")
        ) {
            SettingsSection(title: L10n.string("Local Alerts")) {
                WNToggle(
                    L10n.string("Local notifications"),
                    systemImage: "bell.badge",
                    isOn: Binding(
                        get: { workspace.notificationSettings.localNotificationsEnabled },
                        set: { enabled in
                            Task { await workspace.setLocalNotificationsEnabled(enabled) }
                        }
                    )
                )
                .disabled(workspace.activeAccount == nil || workspace.isSavingNotifications)

                LabeledContent(L10n.string("Permission")) {
                    HStack(spacing: 8) {
                        Text(workspace.notificationAuthorizationStatus.label)
                            .foregroundStyle(WNColor.backgroundContentSecondary)
                        if workspace.isSavingNotifications {
                            ProgressView()
                                .controlSize(.small)
                        }
                    }
                }
            }

            // Its own group, because it is the one thing on the page that is asked of the system
            // rather than chosen — and because only the denied case has something to explain.
            NotificationPermissionSection()

            // The mode's own description is the footer. It used to be a third row in this group,
            // which set the sentence explaining the choice level with the choice itself.
            SettingsChoiceSection(
                title: L10n.string("Privacy"),
                footer: workspace.notificationPreviewMode.detail,
                choices: NotificationPreviewMode.allCases,
                selection: $workspace.notificationPreviewMode
            ) { mode in
                mode.label
            }
            .disabled(!workspace.notificationSettings.localNotificationsEnabled)
        }
        .task {
            await workspace.refreshNotificationPermissionState()
        }
        .onReceive(
            NotificationCenter.default.publisher(
                for: NSApplication.didBecomeActiveNotification
            )
        ) { _ in
            // Notification permission can be changed outside White Noise. Treat the system as
            // the source of truth whenever the app returns from System Settings, so the pane
            // stops asking for a permission the user has already granted.
            Task { await workspace.refreshNotificationPermissionState() }
        }
    }
}

/// The one action that can change the notification permission, and nothing when there isn't one.
///
/// Not-determined and denied ask for different things — one asks White Noise for the permission,
/// the other sends the reader to System Settings — and only the second needs saying why, so only
/// the second carries a footer. Once permission is settled this draws nothing: a granted
/// permission is reported by the row above, not by a group with a button in it.
struct NotificationPermissionSection: View {
    @Environment(WorkspaceState.self) private var workspace

    var body: some View {
        switch workspace.notificationAuthorizationStatus {
        case .notDetermined:
            SettingsSection {
                Button {
                    Task { await workspace.requestLocalNotificationPermission() }
                } label: {
                    Label(L10n.string("Allow Notifications"), systemImage: "checkmark.circle")
                }
                .buttonStyle(.wnSecondary)
            }

        case .denied:
            SettingsSection(footer: L10n.string("Notifications are disabled in system settings.")) {
                Button {
                    workspace.openSystemNotificationSettings()
                } label: {
                    Label(L10n.string("Open System Settings"), systemImage: "gear")
                }
                .buttonStyle(.wnSecondary)
            }

        default:
            EmptyView()
        }
    }
}
