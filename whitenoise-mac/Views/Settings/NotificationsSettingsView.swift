//
//  NotificationsSettingsView.swift
//  whitenoise-mac
//
//  The Notifications page: whether White Noise may post an alert, how it gets woken up
//  to post one, and how much of the message that alert is allowed to repeat.
//
//  Three decisions, three groups, in the order they depend on each other — permission
//  first, because nothing below it can happen without it. Each group carries its own
//  footer rather than one paragraph explaining the page, so a reader can stop at the
//  toggle they came for.
//

import AppKit
import SwiftUI

struct NotificationsSettingsView: View {
    @Environment(WorkspaceState.self) private var workspace

    var body: some View {
        SettingsScaffold(
            title: L10n.string("Notifications"),
            // Names the two decisions the page actually holds — whether an alert is posted at
            // all, and how much of the message it repeats — rather than restating the title the
            // way "Local alerts for this Mac." did. The second half is the one a reader may not
            // know is theirs to make.
            subtitle: L10n.string("Choose when White Noise alerts you and how much of a message it shows.")
        ) {
            // First, and only while there is something to ask for. Every control below it is
            // inert without the permission, so a reader who lands here with notifications off
            // meets the one button that changes that before the switches it would enable.
            NotificationPermissionSection()

            SettingsSection(
                footer: L10n.string(
                    "Creates message notifications on this Mac. Without native push, delivery may wait until White Noise is running."
                )
            ) {
                WNToggle(
                    L10n.string("Local notifications"),
                    systemImage: "bell.badge",
                    isOn: Binding(
                        get: {
                            workspace.notificationAuthorizationStatus.canPostNotifications
                                && workspace.notificationSettings.localNotificationsEnabled
                        },
                        set: { enabled in
                            Task { await workspace.setLocalNotificationsEnabled(enabled) }
                        }
                    )
                )
            }
            // The permission is the switch's precondition, not a consequence of flipping it: with
            // notifications off at the system level this row can promise nothing, so the group
            // above — the only thing that can change that — is the live control on the page.
            .disabled(
                workspace.activeAccount == nil
                    || workspace.isSavingNotifications
                    || !workspace.notificationAuthorizationStatus.canPostNotifications
            )

            NotificationDeliverySection()

            NotificationPreviewSection()
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
/// the other sends the reader to System Settings — and each says why in its own voice: an
/// invitation above the button in the first case, a statement of the current state in the second.
/// Once permission is settled this draws nothing, because a granted permission is not a setting.
struct NotificationPermissionSection: View {
    @Environment(WorkspaceState.self) private var workspace

    var body: some View {
        switch workspace.notificationAuthorizationStatus {
        case .notDetermined:
            SettingsSection {
                Label(
                    L10n.string("Allow notifications to use these options."),
                    systemImage: "bell.badge"
                )

                Button {
                    Task { await workspace.requestLocalNotificationPermission() }
                } label: {
                    Label(L10n.string("Allow Notifications"), systemImage: "checkmark.circle")
                }
                .buttonStyle(.wnSecondary)
            }

        case .denied:
            SettingsSection {
                NotificationsOffRow()

                Button {
                    workspace.openSystemNotificationSettings()
                } label: {
                    Label(L10n.string("Open System Settings"), systemImage: "gear")
                }
                .buttonStyle(.wnSecondary)
            }

        case .authorized, .provisional, .ephemeral:
            EmptyView()
        }
    }
}

/// The denied state, said plainly: what is true on the first line, what to do about it on the
/// second. No warning colour and no callout box — nothing has gone wrong, a permission is simply
/// off, and the button underneath is already the remedy.
struct NotificationsOffRow: View {
    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text(L10n.string("Notifications are off"))

                Text(L10n.string("Turn them on in System Settings to use these options."))
                    .wnFont(.medium10)
                    .foregroundStyle(WNColor.backgroundContentSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } icon: {
            Image(systemName: "bell.slash")
                .foregroundStyle(WNColor.backgroundContentSecondary)
        }
    }
}

/// The generic wake-up, in a group of its own because it is a different promise from the one
/// above it: local notifications decide whether an alert is posted, this decides only whether
/// the Mac is woken to post it. It supplements local notifications rather than replacing them,
/// so it is unavailable — not merely unchecked — while they are off.
struct NotificationDeliverySection: View {
    @Environment(WorkspaceState.self) private var workspace

    private var isEnabled: Bool {
        workspace.notificationAuthorizationStatus.canPostNotifications
            && workspace.notificationSettings.localNotificationsEnabled
    }

    var body: some View {
        SettingsSection(
            footer: L10n.string(
                "Sends a generic wake-up so White Noise can check for new messages in the background. Message details never leave this Mac."
            )
        ) {
            WNToggle(
                L10n.string("Native push"),
                systemImage: "antenna.radiowaves.left.and.right",
                isOn: Binding(
                    get: { isEnabled && workspace.notificationSettings.nativePushEnabled },
                    set: { enabled in
                        Task { await workspace.setNativePushEnabled(enabled) }
                    }
                )
            )
        }
        .disabled(workspace.activeAccount == nil || workspace.isSavingNotifications || !isEnabled)
    }
}

/// How much of a message an alert may repeat, and the alert that choice produces.
///
/// The example is the point of the group: "Sender only" names what is withheld, while
/// `Alice · New message` shows what a person standing behind you would actually read. It sits
/// inside the card with the rows it describes; the footer under the card keeps saying what the
/// choice means for the message's contents, which is the privacy statement this page makes.
struct NotificationPreviewSection: View {
    @Environment(WorkspaceState.self) private var workspace

    var body: some View {
        @Bindable var workspace = workspace

        SettingsSection(
            title: L10n.string("Preview"),
            footer: workspace.notificationPreviewMode.detail
        ) {
            WNSelect(
                options: NotificationPreviewMode.allCases,
                selection: $workspace.notificationPreviewMode
            ) { mode in
                mode.label
            }

            NotificationPreviewExample(text: workspace.notificationPreviewMode.example)
        }
        .disabled(
            !workspace.notificationAuthorizationStatus.canPostNotifications
                || !workspace.notificationSettings.localNotificationsEnabled
        )
    }
}

/// The notification the chosen mode would post.
///
/// A row of the group rather than a note under it, because it is the chosen option said back —
/// so it recedes with the rest of the group when the group is off, which is why `isEnabled` is
/// read here and not by the section that disables it.
struct NotificationPreviewExample: View {
    @Environment(\.isEnabled) private var isEnabled

    let text: String

    var body: some View {
        Label(text, systemImage: "bell.badge")
            .foregroundStyle(isEnabled ? WNColor.backgroundContentSecondary : WNColor.backgroundContentTertiary)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}
