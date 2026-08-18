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
            Section(L10n.string("Local Alerts")) {
                Toggle(
                    isOn: Binding(
                        get: { workspace.notificationSettings.localNotificationsEnabled },
                        set: { enabled in
                            Task { await workspace.setLocalNotificationsEnabled(enabled) }
                        }
                    )
                ) {
                    Label(L10n.string("Local notifications"), systemImage: "bell.badge")
                }
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

                if workspace.notificationAuthorizationStatus == .notDetermined {
                    Button {
                        Task { await workspace.requestLocalNotificationPermission() }
                    } label: {
                        Label(L10n.string("Allow Notifications"), systemImage: "checkmark.circle")
                    }
                    .buttonStyle(.wnSecondary)
                } else if workspace.notificationAuthorizationStatus == .denied {
                    Button {
                        workspace.openSystemNotificationSettings()
                    } label: {
                        Label(L10n.string("Open System Settings"), systemImage: "gear")
                    }
                    .buttonStyle(.wnSecondary)
                }
            }

            Section(L10n.string("Privacy")) {
                Picker(L10n.string("Message preview"), selection: $workspace.notificationPreviewMode) {
                    ForEach(NotificationPreviewMode.allCases) { mode in
                        Text(mode.label).tag(mode)
                    }
                }
                .disabled(!workspace.notificationSettings.localNotificationsEnabled)

                Text(workspace.notificationPreviewMode.detail)
                    .foregroundStyle(WNColor.backgroundContentSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

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
