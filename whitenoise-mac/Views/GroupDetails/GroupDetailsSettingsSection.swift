//
//  GroupDetailsSettingsSection.swift
//  whitenoise-mac
//
//  Group info's Settings: the disappearing-message timer, the expired-message prune, and
//  archiving. Ported from the iOS client's `settingsSection`.
//

import SwiftUI

struct GroupDetailsSettingsSection: View {
    @Environment(WorkspaceState.self) private var workspace
    @State private var isTimerPresented = false
    @State private var showArchiveConfirmation = false
    let snapshot: GroupDetailsSnapshot
    let permissions: GroupDetailsPermissions

    var body: some View {
        SettingsSection(
            title: L10n.string("Settings"),
            footer: L10n.string("Archiving hides the chat from your main list. It doesn't notify anyone.")
        ) {
            DetailsDisclosureRow(
                title: L10n.string("Disappearing messages"),
                systemImage: "timer",
                value: DisappearingMessageOption.option(for: snapshot.disappearingMessageSecs).label,
                action: permissions.canEditGroup ? { isTimerPresented = true } : nil
            )
            .disabled(workspace.hasInFlightGroupCommit)
            .popover(isPresented: $isTimerPresented, arrowEdge: .trailing) {
                DisappearingTimerPopover(currentSeconds: snapshot.disappearingMessageSecs) { seconds in
                    isTimerPresented = false
                    Task { await workspace.setDisappearingMessages(groupIdHex: snapshot.groupIdHex, seconds: seconds) }
                }
                .environment(\.locale, workspace.preferredLocale)
            }

            // A local prune, not a group commit — so it stays available to a former member whose
            // history still holds expired messages.
            if snapshot.disappearingMessagesEnabled {
                Button {
                    Task { await workspace.secureDeleteExpiredMessages(groupIdHex: snapshot.groupIdHex) }
                } label: {
                    Label(L10n.string("Delete expired now"), systemImage: "trash")
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .disabled(workspace.isSecureDeletingExpired)
                .help(L10n.string("Securely prune already-expired messages on this device"))
            }

            // Reversible, and drawn neutral in both directions — the other clients build it as
            // `outline`, not `destructive` (`group_info_screen.dart`).
            Button {
                showArchiveConfirmation = true
            } label: {
                Label(archiveTitle, systemImage: snapshot.archived ? "tray.and.arrow.up" : "archivebox")
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .disabled(workspace.isArchivingGroup)
        }
        .confirmationDialog(
            L10n.string(snapshot.archived ? "Unarchive this group?" : "Archive this group?"),
            isPresented: $showArchiveConfirmation,
            titleVisibility: .visible
        ) {
            Button(
                L10n.string(snapshot.archived ? "Unarchive Group" : "Archive Group"),
                role: snapshot.archived ? nil : .destructive
            ) {
                Task { await workspace.setSelectedGroupArchived(!snapshot.archived) }
            }
            Button(L10n.string("Cancel"), role: .cancel) {}
        } message: {
            Text(L10n.string("Archived groups are hidden from the active chat list."))
        }
    }

    private var archiveTitle: String {
        if workspace.isArchivingGroup {
            return L10n.string(snapshot.archived ? "Unarchiving..." : "Archiving...")
        }
        return L10n.string(snapshot.archived ? "Unarchive Group" : "Archive Group")
    }
}
