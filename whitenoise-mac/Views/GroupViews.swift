//
//  GroupViews.swift
//  whitenoise-mac
//
//  Group management UI: the group details sheet, member rows, diagnostics
//  rows, and the group-image picker/results. Extracted verbatim from
//  MessengerShellView.swift (no behavior change).
//

import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Disappearing-timer picker selection: a concrete preset/current value, or the "Custom…" entry
/// that opens the value+unit editor rather than committing immediately.
private enum DisappearingChoice: Hashable {
    case preset(DisappearingMessageOption)
    case customEntry
}

struct GroupDetailsSheet: View {
    @Environment(WorkspaceState.self) private var workspace
    @State private var showArchiveConfirmation = false
    @State private var showLeaveConfirmation = false
    @State private var showSelfDemoteConfirmation = false
    @State private var showRemoveLocallyConfirmation = false
    @State private var isAddMembersPresented = false
    @State private var isCustomDisappearingPresented = false
    // Kept as an exactly parsed decimal string: `UInt64.Stride` is `Int`, so any
    // range-based numeric control spanning past `Int.max` traps in stride math,
    // and narrowing to `Int` silently clamps large core values.
    @State private var customDurationText = "1"
    @State private var customDurationUnit = DisappearingMessageDurationUnit.days
    let chat: ChatItem

    private var hasProfileChanges: Bool {
        guard let snapshot = workspace.groupDetailsSnapshot else { return false }
        return workspace.groupProfileDraftName.trimmingCharacters(in: .whitespacesAndNewlines) != snapshot.name
            || workspace.groupProfileDraftDescription.trimmingCharacters(in: .whitespacesAndNewlines)
                != snapshot.description
    }

    private var headerAvatarURL: URL? {
        GroupDetailsHeaderAvatar.sanitizedURL(snapshot: workspace.groupDetailsSnapshot, fallback: chat)
    }

    /// Under the group name: the disappearing-message timer as a bare icon + duration (no label)
    /// when it's on, otherwise the member count.
    private var headerSubtitle: some View {
        let snapshot = workspace.groupDetailsSnapshot
        let durationSeconds =
            snapshot?.disappearingMessagesEnabled == true
            ? snapshot?.disappearingMessageSecs : nil
        return DisappearingMessageHeaderSubtitle(
            durationSeconds: durationSeconds,
            fallback: snapshot?.memberCountLabel ?? "Group details"
        )
        .font(.callout)
    }

    /// Prefill the custom-duration fields from the group's current timer, choosing the largest
    /// unit that divides it evenly so a 4-week timer opens as "4 weeks".
    private func seedCustomDuration(from seconds: UInt64) {
        guard let duration = DisappearingMessageDurationUnit.largestWholeUnit(for: seconds) else {
            customDurationText = "1"
            customDurationUnit = .days
            return
        }
        // Stays UInt64-exact so any core value round-trips through Set unchanged.
        customDurationText = String(duration.count)
        customDurationUnit = duration.unit
    }

    private func customDurationPopover(groupIdHex: String) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(L10n.string("Custom duration"))
                .font(.headline)
            HStack(spacing: 8) {
                // Closure-based stepper: no range, so no stride arithmetic to
                // trap on; the parsed value saturates at the UInt64 bounds.
                Stepper {
                    TextField("", text: $customDurationText)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 64)
                        .accessibilityLabel(L10n.string("Duration value"))
                } onIncrement: {
                    guard let value = customDurationValue, value < UInt64.max else { return }
                    customDurationText = String(value + 1)
                } onDecrement: {
                    guard let value = customDurationValue, value > 1 else { return }
                    customDurationText = String(value - 1)
                }
                // Real label for VoiceOver, hidden from the visual layout.
                Picker(L10n.string("Duration unit"), selection: $customDurationUnit) {
                    ForEach(DisappearingMessageDurationUnit.allCases) { unit in
                        Text(unit.label).tag(unit)
                    }
                }
                .labelsHidden()
                .frame(width: 120)
            }
            HStack {
                Spacer()
                Button(L10n.string("Set")) { commitCustomDuration(groupIdHex: groupIdHex) }
                    .keyboardShortcut(.defaultAction)
                    .nativeGlassProminentButtonStyle()
                    // Validate rather than clamp: disable Set for a non-positive or overflowing
                    // total so a valid core value round-trips unchanged and nothing is silently
                    // truncated.
                    .disabled(customDurationSeconds == nil)
            }
        }
        .padding(16)
        .frame(width: 300)
    }

    /// The entered count, exactly parsed; `nil` for anything that isn't a decimal `UInt64`.
    private var customDurationValue: UInt64? {
        UInt64(customDurationText.trimmingCharacters(in: .whitespaces))
    }

    /// The entered duration in seconds, or `nil` when it isn't a positive value that fits `UInt64`.
    /// Bounds the *total* (value × unit), not a raw per-unit cap, so large-but-valid values commit.
    private var customDurationSeconds: UInt64? {
        guard let value = customDurationValue, value >= 1 else { return nil }
        let (seconds, overflow) =
            value
            .multipliedReportingOverflow(by: customDurationUnit.seconds)
        return overflow ? nil : seconds
    }

    private func commitCustomDuration(groupIdHex: String) {
        guard let seconds = customDurationSeconds else { return }
        isCustomDisappearingPresented = false
        Task { await workspace.setDisappearingMessages(groupIdHex: groupIdHex, seconds: seconds) }
    }

    var body: some View {
        @Bindable var workspace = workspace

        VStack(spacing: 0) {
            HStack(spacing: 12) {
                ProfileImageAvatarView(
                    seed: chat.avatarSeed,
                    initials: chat.title,
                    sanitizedPictureURL: headerAvatarURL,
                    localImagePayload: chat.groupImagePayload,
                    size: 48,
                    isSelected: false
                )

                VStack(alignment: .leading, spacing: 2) {
                    Text(workspace.groupDetailsSnapshot?.name ?? chat.title)
                        .font(.title3.weight(.semibold))
                        .lineLimit(1)
                    headerSubtitle
                }

                Spacer()

                if workspace.isLoadingGroupDetails {
                    ProgressView()
                        .controlSize(.small)
                }

                if let snapshot = workspace.groupDetailsSnapshot,
                    snapshot.canInvite, snapshot.selfMembership == .member
                {
                    Button {
                        isAddMembersPresented = true
                    } label: {
                        Image(systemName: "person.badge.plus")
                            .font(.system(size: 16, weight: .semibold))
                            .frame(width: 30, height: 30)
                            .background { MessagesCircleControlBackground() }
                    }
                    .buttonStyle(.plain)
                    .disabled(workspace.hasInFlightGroupCommit)
                    .help(L10n.string("Add members"))
                }

                GlassCircleCloseButton(symbol: "chevron.backward", help: "Back to chat") {
                    workspace.closeGroupDetails()
                }
            }
            .padding(20)

            GlassSeparator(axis: .horizontal)

            if let snapshot = workspace.groupDetailsSnapshot {
                Form {
                    if snapshot.pendingConfirmation {
                        Section(L10n.string("Invitation")) {
                            VStack(alignment: .leading, spacing: 10) {
                                Text(
                                    L10n.string(
                                        "Accept this invite to confirm membership, or decline it to remove the group from your chat list."
                                    )
                                )
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)

                                HStack(spacing: 10) {
                                    Button {
                                        Task { await workspace.acceptSelectedGroupInvite() }
                                    } label: {
                                        Label(
                                            workspace.isAcceptingGroupInvite
                                                ? L10n.string("Accepting...") : L10n.string("Accept Invite"),
                                            systemImage: "checkmark.circle"
                                        )
                                    }
                                    .nativeGlassProminentButtonStyle()
                                    .disabled(workspace.isAcceptingGroupInvite || workspace.isDecliningGroupInvite)

                                    Button(role: .destructive) {
                                        Task { await workspace.declineSelectedGroupInvite() }
                                    } label: {
                                        Label(
                                            workspace.isDecliningGroupInvite
                                                ? L10n.string("Declining...") : L10n.string("Decline"),
                                            systemImage: "xmark.circle"
                                        )
                                    }
                                    .disabled(workspace.isAcceptingGroupInvite || workspace.isDecliningGroupInvite)

                                    Spacer()
                                }
                            }
                        }
                    }

                    if let endedDescription = snapshot.selfMembership.endedDescription {
                        Section(L10n.string("Membership")) {
                            Label {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(endedDescription)
                                        .font(.callout.weight(.semibold))

                                    Text(ChatSelfMembership.endedHistoryExplanation)
                                        .font(.callout)
                                        .foregroundStyle(.secondary)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            } icon: {
                                Image(systemName: snapshot.selfMembership.endedSymbolName ?? "")
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }

                    Section(L10n.string("Profile")) {
                        TextField(L10n.string("Group name"), text: $workspace.groupProfileDraftName)
                            .textFieldStyle(.roundedBorder)
                        TextField(
                            L10n.string("Description"), text: $workspace.groupProfileDraftDescription, axis: .vertical
                        )
                        .textFieldStyle(.roundedBorder)
                        .lineLimit(2...4)

                        HStack(spacing: 10) {
                            // Group image is a group-only affordance;
                            // `showGroupImagePicker` no-ops for direct chats, so
                            // don't surface a dead button when a DM opens details.
                            if !chat.isDirect {
                                Button {
                                    workspace.closeGroupDetails()
                                    workspace.showGroupImagePicker(for: chat)
                                } label: {
                                    Label(L10n.string("Search Web Image"), systemImage: "photo.badge.plus")
                                }
                                .disabled(workspace.hasInFlightGroupCommit)
                            }

                            Spacer()

                            Button {
                                Task { await workspace.saveGroupProfile() }
                            } label: {
                                Label(
                                    workspace.isSavingGroupProfile ? L10n.string("Saving...") : L10n.string("Save"),
                                    systemImage: "checkmark.circle")
                            }
                            .nativeGlassProminentButtonStyle()
                            .disabled(
                                !hasProfileChanges
                                    || workspace.hasInFlightGroupCommit
                            )
                        }
                    }
                    // Profile edits publish a group commit, which the core rejects for a
                    // non-member the same way it rejects sends (`invalid_transition`).
                    .disabled(snapshot.selfMembership != .member)

                    if chat.isDirect {
                        Section(L10n.string("Groups in Common")) {
                            if workspace.isLoadingCommonGroups
                                && workspace.commonGroupsForContact.isEmpty
                            {
                                HStack(spacing: 8) {
                                    ProgressView()
                                        .controlSize(.small)
                                    Text(L10n.string("Checking shared groups…"))
                                        .foregroundStyle(.secondary)
                                }
                            } else if workspace.commonGroupsForContact.isEmpty {
                                Label(L10n.string("No groups in common"), systemImage: "person.2.slash")
                                    .foregroundStyle(.secondary)
                            } else {
                                ForEach(workspace.commonGroupsForContact) { commonGroup in
                                    Button {
                                        workspace.openCommonGroup(commonGroup)
                                    } label: {
                                        HStack(spacing: 10) {
                                            ProfileImageAvatarView(
                                                seed: commonGroup.avatarSeed,
                                                initials: commonGroup.title,
                                                sanitizedPictureURL: commonGroup.sanitizedPictureURL,
                                                localImagePayload: commonGroup.groupImagePayload,
                                                size: 34,
                                                isSelected: false
                                            )

                                            VStack(alignment: .leading, spacing: 2) {
                                                Text(commonGroup.title)
                                                    .font(.callout.weight(.semibold))
                                                    .foregroundStyle(.primary)
                                                    .lineLimit(1)
                                                Text(commonGroup.subtitle)
                                                    .font(.caption)
                                                    .foregroundStyle(.secondary)
                                                    .lineLimit(1)
                                            }

                                            Spacer()
                                            Image(systemName: "chevron.right")
                                                .font(.caption.weight(.semibold))
                                                .foregroundStyle(.tertiary)
                                        }
                                        .contentShape(Rectangle())
                                    }
                                    .buttonStyle(.plain)
                                }
                            }

                            if workspace.commonGroupsLoadHadFailures {
                                Text(L10n.string("Some groups could not be checked."))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }

                    GroupSharedMediaSection(groupIdHex: snapshot.groupIdHex)

                    Section {
                        if snapshot.members.isEmpty {
                            ContentUnavailableView("No members", systemImage: "person.2.slash")
                                .frame(minHeight: 120)
                        } else {
                            ForEach(snapshot.members) { member in
                                GroupMemberRow(member: member)
                            }
                        }
                        if snapshot.canInvite && snapshot.selfMembership == .member {
                            Button {
                                isAddMembersPresented = true
                            } label: {
                                Label(L10n.string("Add members"), systemImage: "person.badge.plus")
                            }
                            .disabled(workspace.hasInFlightGroupCommit)
                        }
                    } header: {
                        Text(snapshot.memberCountLabel)
                    }

                    Section(L10n.string("Disappearing Messages")) {
                        Picker(
                            selection: Binding<DisappearingChoice>(
                                get: {
                                    .preset(DisappearingMessageOption.option(for: snapshot.disappearingMessageSecs))
                                },
                                set: { choice in
                                    switch choice {
                                    case .preset(let option):
                                        Task {
                                            await workspace.setDisappearingMessages(
                                                groupIdHex: snapshot.groupIdHex,
                                                seconds: option.seconds
                                            )
                                        }
                                    case .customEntry:
                                        seedCustomDuration(from: snapshot.disappearingMessageSecs)
                                        isCustomDisappearingPresented = true
                                    }
                                }
                            )
                        ) {
                            ForEach(DisappearingMessageOption.options(for: snapshot.disappearingMessageSecs)) {
                                option in
                                Text(option.label).tag(DisappearingChoice.preset(option))
                            }
                            Text(L10n.string("Custom…")).tag(DisappearingChoice.customEntry)
                        } label: {
                            Label(L10n.string("Auto-delete after"), systemImage: "timer")
                        }
                        // Retention changes are group commits — rejected for non-members.
                        // "Delete expired now" below stays enabled: it is a local prune.
                        .disabled(
                            workspace.hasInFlightGroupCommit || snapshot.selfMembership != .member
                        )
                        .popover(isPresented: $isCustomDisappearingPresented, arrowEdge: .bottom) {
                            customDurationPopover(groupIdHex: snapshot.groupIdHex)
                        }

                        if snapshot.disappearingMessagesEnabled {
                            Button {
                                Task { await workspace.secureDeleteExpiredMessages(groupIdHex: snapshot.groupIdHex) }
                            } label: {
                                Label(L10n.string("Delete expired now"), systemImage: "trash")
                            }
                            .disabled(workspace.isSecureDeletingExpired)
                            .help(L10n.string("Securely prune already-expired messages on this device"))
                        }
                    }

                    Section(L10n.string("Group Actions")) {
                        HStack(spacing: 10) {
                            Button(role: snapshot.archived ? nil : .destructive) {
                                showArchiveConfirmation = true
                            } label: {
                                Label(
                                    archiveButtonTitle(snapshot: snapshot),
                                    systemImage: snapshot.archived ? "tray.and.arrow.up" : "archivebox"
                                )
                            }
                            .disabled(workspace.isArchivingGroup)

                            if snapshot.isSelfAdmin {
                                Button(role: .destructive) {
                                    showSelfDemoteConfirmation = true
                                } label: {
                                    Label(L10n.string("Step Down as Admin"), systemImage: "star.slash")
                                }
                                .disabled(workspace.hasInFlightGroupCommit || snapshot.isLastAdmin)
                            }

                            Button(role: .destructive) {
                                showLeaveConfirmation = true
                            } label: {
                                Label(
                                    workspace.isLeavingGroup || snapshot.leaveRequestPending
                                        ? L10n.string("Leaving...")
                                        : L10n.string("Leave Group"),
                                    systemImage: "rectangle.portrait.and.arrow.right")
                            }
                            .disabled(
                                workspace.hasInFlightGroupCommit
                                    || snapshot.leaveRequestPending
                                    || !snapshot.canLeave
                                    || snapshot.requiresSelfDemoteBeforeLeave
                            )

                            Button(role: .destructive) {
                                showRemoveLocallyConfirmation = true
                            } label: {
                                Label(
                                    workspace.isDeletingGroupLocally
                                        ? L10n.string("Removing...") : L10n.string("Remove From This Device"),
                                    systemImage: "trash.slash")
                            }
                            .disabled(workspace.isDeletingGroupLocally)
                            .help(L10n.string("Delete this conversation locally without notifying the group"))

                            Spacer()
                        }

                        if snapshot.leaveRequestPending {
                            Text(
                                L10n.string(
                                    "Your leave request is pending. This conversation will update when the group commits it."
                                )
                            )
                            .font(.callout)
                            .foregroundStyle(.secondary)
                        } else if snapshot.requiresSelfDemoteBeforeLeave {
                            Text(L10n.string("Demote yourself from admin before leaving this group."))
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        } else if snapshot.isLastAdmin {
                            Text(L10n.string("Make another member an admin before stepping down or leaving."))
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
                    }

                    if workspace.developerMode {
                        Section(L10n.string("Developer")) {
                            HStack(spacing: 10) {
                                Button {
                                    workspace.startExportSelectedGroupTranscript()
                                } label: {
                                    Label(
                                        workspace.isExportingGroupTranscript
                                            ? L10n.string("Exporting Transcript…")
                                            : L10n.string("Export Transcript…"),
                                        systemImage: "square.and.arrow.down"
                                    )
                                }
                                .disabled(workspace.isExportingGroupTranscript)

                                if workspace.isExportingGroupTranscript {
                                    ProgressView()
                                        .controlSize(.small)
                                    Button(L10n.string("Cancel"), role: .cancel) {
                                        workspace.cancelGroupTranscriptExport()
                                    }
                                } else if let status = workspace.groupTranscriptExportStatus {
                                    Label(status, systemImage: "checkmark.circle")
                                        .font(.callout)
                                        .foregroundStyle(.green)
                                }
                            }

                            GroupDiagnosticsValueRow(title: L10n.string("Group ID"), value: snapshot.groupIdHex)
                            GroupDiagnosticsValueRow(
                                title: L10n.string("Nostr group ID"), value: snapshot.nostrGroupIdHex)
                            GroupDiagnosticsValueRow(title: L10n.string("Endpoint"), value: snapshot.endpoint)
                            GroupDiagnosticsValueRow(title: L10n.string("Avatar URL"), value: snapshot.avatarURL ?? "")
                            GroupDiagnosticsValueRow(
                                title: L10n.string("Avatar dimension"), value: snapshot.avatarDimension ?? "")
                            GroupDiagnosticsValueRow(
                                title: L10n.string("Relays"), value: snapshot.relays.joined(separator: "\n"),
                                lineLimit: 4)
                            GroupDiagnosticsValueRow(
                                title: L10n.string("Admins"), value: snapshot.adminIds.joined(separator: "\n"),
                                lineLimit: 4)
                            GroupDiagnosticsValueRow(
                                title: L10n.string("Self admin"),
                                value: snapshot.isSelfAdmin ? L10n.string("Yes") : L10n.string("No"), copyable: false)
                            GroupDiagnosticsValueRow(
                                title: L10n.string("Last admin"),
                                value: snapshot.isLastAdmin ? L10n.string("Yes") : L10n.string("No"), copyable: false)
                            GroupDiagnosticsValueRow(
                                title: L10n.string("Can invite"),
                                value: snapshot.canInvite ? L10n.string("Yes") : L10n.string("No"),
                                copyable: false)
                            GroupDiagnosticsValueRow(
                                title: L10n.string("Can leave"),
                                value: snapshot.canLeave ? L10n.string("Yes") : L10n.string("No"),
                                copyable: false)
                            GroupDiagnosticsValueRow(
                                title: L10n.string("Leave request pending"),
                                value: snapshot.leaveRequestPending ? L10n.string("Yes") : L10n.string("No"),
                                copyable: false)
                            GroupDiagnosticsValueRow(
                                title: L10n.string("Leave requested at (ms)"),
                                value: snapshot.leaveRequestedAtMs.map(String.init) ?? "",
                                copyable: false)
                            GroupDiagnosticsValueRow(
                                title: L10n.string("Pending confirmation"),
                                value: snapshot.pendingConfirmation ? L10n.string("Yes") : L10n.string("No"),
                                copyable: false)
                            GroupDiagnosticsValueRow(
                                title: L10n.string("Self membership"),
                                value: snapshot.selfMembership.sidebarBadgeLabel ?? L10n.string("Member"),
                                copyable: false)
                        }
                    }

                    SettingsErrorView(error: workspace.lastError)
                }
                .formStyle(.grouped)
                .scrollContentBackground(.hidden)
            } else if workspace.isLoadingGroupDetails {
                ProgressView()
                    .controlSize(.regular)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ContentUnavailableView("Group details unavailable", systemImage: "person.2")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .overlay(alignment: .bottom) {
                        SettingsErrorView(error: workspace.lastError)
                            .padding()
                    }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background {
            MessagesTranscriptBackground()
        }
        .task(id: chat.id) {
            await workspace.loadSharedMedia(groupIdHex: chat.id)
        }
        .onDisappear {
            workspace.clearSharedMedia()
        }
        .sheet(isPresented: $isAddMembersPresented) {
            GroupAddMembersSheet(
                existingMemberIds: Set(workspace.groupDetailsSnapshot?.members.map(\.id) ?? [])
            )
        }
        .confirmationDialog(
            archiveConfirmationTitle,
            isPresented: $showArchiveConfirmation,
            titleVisibility: .visible
        ) {
            if let snapshot = workspace.groupDetailsSnapshot {
                Button(
                    snapshot.archived ? L10n.string("Unarchive Group") : L10n.string("Archive Group"),
                    role: snapshot.archived ? nil : .destructive
                ) {
                    Task { await workspace.setSelectedGroupArchived(!snapshot.archived) }
                }
            }
            Button(L10n.string("Cancel"), role: .cancel) {}
        } message: {
            Text(L10n.string("Archived groups are hidden from the active chat list."))
        }
        .confirmationDialog(
            L10n.string("Step down as admin?"),
            isPresented: $showSelfDemoteConfirmation,
            titleVisibility: .visible
        ) {
            Button(L10n.string("Step Down"), role: .destructive) {
                Task { await workspace.selfDemoteSelectedGroupAdmin() }
            }
            .disabled(workspace.hasInFlightGroupCommit)
            Button(L10n.string("Cancel"), role: .cancel) {}
        } message: {
            Text(L10n.string("You'll stay in the group, but another admin will need to restore your admin status."))
        }
        .confirmationDialog(
            L10n.string("Leave this group?"),
            isPresented: $showLeaveConfirmation,
            titleVisibility: .visible
        ) {
            Button(L10n.string("Leave Group"), role: .destructive) {
                Task { await workspace.leaveSelectedGroup() }
            }
            .disabled(
                workspace.hasInFlightGroupCommit
                    || workspace.groupDetailsSnapshot?.leaveRequestPending == true
            )
            Button(L10n.string("Cancel"), role: .cancel) {}
        } message: {
            Text(L10n.string("You will no longer receive messages from this group on this account."))
        }
        .confirmationDialog(
            L10n.string("Remove this conversation from this device?"),
            isPresented: $showRemoveLocallyConfirmation,
            titleVisibility: .visible
        ) {
            Button(L10n.string("Remove From This Device"), role: .destructive) {
                Task { await workspace.deleteGroupLocally(groupIdHex: chat.id) }
            }
            Button(L10n.string("Cancel"), role: .cancel) {}
        } message: {
            Text(
                L10n.string(
                    "This deletes the local copy only. Other members are not notified, and you can be re-added later."))
        }
    }

    private var archiveConfirmationTitle: String {
        if workspace.groupDetailsSnapshot?.archived == true {
            return L10n.string("Unarchive this group?")
        }
        return L10n.string("Archive this group?")
    }

    private func archiveButtonTitle(snapshot: GroupDetailsSnapshot) -> String {
        if workspace.isArchivingGroup {
            return snapshot.archived ? L10n.string("Unarchiving...") : L10n.string("Archiving...")
        }
        return snapshot.archived ? L10n.string("Unarchive Group") : L10n.string("Archive Group")
    }
}

struct GroupDiagnosticsValueRow: View {
    @Environment(WorkspaceState.self) private var workspace
    let title: String
    let value: String
    var lineLimit = 2
    var copyable = true

    private var displayValue: String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? L10n.string("None") : trimmed
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.callout.weight(.semibold))

                Text(displayValue)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(lineLimit)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            if copyable && !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Button {
                    workspace.copyText(value)
                } label: {
                    Image(systemName: "doc.on.doc")
                        .frame(width: 24, height: 24)
                }
                .nativeGlassButtonStyle()
                .help(String(format: L10n.string("Copy %@"), title))
            }
        }
    }
}

struct GroupMemberRow: View {
    @Environment(WorkspaceState.self) private var workspace
    @State private var showRemoveConfirmation = false
    let member: GroupMemberItem

    private var isMutating: Bool {
        workspace.mutatingGroupMemberId == member.id
    }

    private var hasActions: Bool {
        member.canPromote || member.canDemote || member.canRemove
    }

    var body: some View {
        HStack(spacing: 10) {
            Button {
                Task { await workspace.showContactDetails(for: member) }
            } label: {
                HStack(spacing: 10) {
                    AvatarView(seed: member.id, initials: member.initials, size: 34, isSelected: false)

                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(member.displayName)
                                .font(.callout.weight(.semibold))
                                .lineLimit(1)

                            if member.isAdmin {
                                Text(L10n.string("Admin"))
                                    .font(.caption2.weight(.semibold))
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(.thinMaterial, in: Capsule())
                            }

                            if member.isSelf {
                                Text(L10n.string("You"))
                                    .font(.caption2.weight(.semibold))
                                    .foregroundStyle(.secondary)
                            }
                        }

                        Text(member.detailLabel)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }

                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(
                String(format: L10n.string("View contact %@"), member.displayName)
            )

            if isMutating {
                ProgressView()
                    .controlSize(.small)
            }

            if hasActions {
                Menu {
                    if member.canPromote {
                        Button(L10n.string("Make Admin")) {
                            Task { await workspace.promoteGroupMember(member) }
                        }
                    }

                    if member.canDemote {
                        Button(member.isSelf ? L10n.string("Demote Myself") : L10n.string("Remove Admin")) {
                            Task { await workspace.demoteGroupMember(member) }
                        }
                    }

                    if member.canRemove {
                        Button(L10n.string("Remove Member"), role: .destructive) {
                            showRemoveConfirmation = true
                        }
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .frame(width: 28, height: 28)
                }
                .menuStyle(.borderlessButton)
                .disabled(workspace.hasInFlightGroupCommit)
            }
        }
        .confirmationDialog(
            L10n.string("Remove this member?"),
            isPresented: $showRemoveConfirmation,
            titleVisibility: .visible
        ) {
            Button(L10n.string("Remove Member"), role: .destructive) {
                Task { await workspace.removeGroupMember(member) }
            }
            .disabled(workspace.hasInFlightGroupCommit)
            Button(L10n.string("Cancel"), role: .cancel) {}
        } message: {
            Text(
                String(
                    format: L10n.string("This removes %@ from the group."),
                    PeerDisplayText.templateFragment(member.displayName)))
        }
    }
}

struct ContactDetailsView: View {
    @Environment(WorkspaceState.self) private var workspace
    let contact: NewChatRecipient

    private var isSelf: Bool {
        workspace.activeAccount?.accountIdHex.lowercased() == contact.accountIdHex.lowercased()
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                ProfileImageAvatarView(
                    seed: contact.accountIdHex,
                    initials: contact.title,
                    sanitizedPictureURL: contact.sanitizedPictureURL,
                    size: 48,
                    isSelected: false
                )

                VStack(alignment: .leading, spacing: 2) {
                    Text(contact.title)
                        .font(.title3.weight(.semibold))
                        .lineLimit(1)
                    Text(isSelf ? L10n.string("You") : L10n.string("Contact"))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                if workspace.isLoadingContactDetails {
                    ProgressView()
                        .controlSize(.small)
                }

                GlassCircleCloseButton(symbol: "chevron.backward", help: "Back") {
                    workspace.closeContactDetails()
                }
            }
            .padding(20)

            GlassSeparator(axis: .horizontal)

            Form {
                Section(L10n.string("Contact")) {
                    LabeledContent(L10n.string("Public key")) {
                        Text(contact.npub.isEmpty ? contact.accountIdHex : contact.npub)
                            .font(.callout.monospaced())
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .textSelection(.enabled)
                    }

                    HStack(spacing: 10) {
                        Button {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(
                                contact.npub.isEmpty ? contact.accountIdHex : contact.npub,
                                forType: .string
                            )
                        } label: {
                            Label(L10n.string("Copy Public Key"), systemImage: "doc.on.doc")
                        }

                        if !isSelf {
                            Spacer()
                            Button {
                                Task { await workspace.messageContact(contact) }
                            } label: {
                                Label(L10n.string("Message"), systemImage: "message")
                            }
                            .nativeGlassProminentButtonStyle()
                            .disabled(workspace.isCreatingChat)
                        }
                    }
                }

                Section(L10n.string("Groups in Common")) {
                    if workspace.isLoadingCommonGroups
                        && workspace.commonGroupsForContact.isEmpty
                    {
                        HStack(spacing: 8) {
                            ProgressView()
                                .controlSize(.small)
                            Text(L10n.string("Checking shared groups…"))
                                .foregroundStyle(.secondary)
                        }
                    } else if workspace.commonGroupsForContact.isEmpty {
                        Label(L10n.string("No groups in common"), systemImage: "person.2.slash")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(workspace.commonGroupsForContact) { commonGroup in
                            Button {
                                workspace.openCommonGroup(commonGroup)
                            } label: {
                                HStack(spacing: 10) {
                                    ProfileImageAvatarView(
                                        seed: commonGroup.avatarSeed,
                                        initials: commonGroup.title,
                                        sanitizedPictureURL: commonGroup.sanitizedPictureURL,
                                        localImagePayload: commonGroup.groupImagePayload,
                                        size: 34,
                                        isSelected: false
                                    )
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(commonGroup.title)
                                            .font(.callout.weight(.semibold))
                                            .foregroundStyle(.primary)
                                            .lineLimit(1)
                                        Text(commonGroup.subtitle)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                            .lineLimit(1)
                                    }
                                    Spacer()
                                    Image(systemName: "chevron.right")
                                        .font(.caption.weight(.semibold))
                                        .foregroundStyle(.tertiary)
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }

                    if workspace.commonGroupsLoadHadFailures {
                        Text(L10n.string("Some groups could not be checked."))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
        }
    }
}

struct GroupImagePickerSheet: View {
    @Environment(WorkspaceState.self) private var workspace
    @State private var isFileImporterPresented = false

    private let columns = [
        GridItem(.adaptive(minimum: 132, maximum: 168), spacing: 12)
    ]

    var body: some View {
        @Bindable var workspace = workspace

        VStack(spacing: 0) {
            if let chat = workspace.selectedChat {
                HStack(spacing: 12) {
                    ProfileImageAvatarView(
                        seed: chat.avatarSeed,
                        initials: chat.title,
                        sanitizedPictureURL: chat.sanitizedPictureURL,
                        localImagePayload: chat.groupImagePayload,
                        size: 46,
                        isSelected: false
                    )

                    VStack(alignment: .leading, spacing: 2) {
                        Text(chat.title)
                            .font(.headline)
                            .lineLimit(1)
                        Text(L10n.string("Group image"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    GlassCircleCloseButton {
                        workspace.closeGroupImagePicker()
                    }
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 16)

                Divider()

                VStack(spacing: 12) {
                    HStack {
                        Button {
                            isFileImporterPresented = true
                        } label: {
                            Label(L10n.string("Choose from Mac"), systemImage: "photo.badge.plus")
                        }
                        .disabled(workspace.hasInFlightGroupCommit)

                        Text(L10n.string("or search the web"))
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        Spacer()
                    }

                    HStack(spacing: 8) {
                        TextField(L10n.string("Search images"), text: $workspace.groupImageSearchQuery)
                            .textFieldStyle(.roundedBorder)
                            .onSubmit {
                                Task { await workspace.searchGroupImages() }
                            }

                        if workspace.isSearchingGroupImages {
                            ProgressView()
                                .controlSize(.small)
                        }

                        Button {
                            Task { await workspace.searchGroupImages() }
                        } label: {
                            Label(L10n.string("Search"), systemImage: "magnifyingglass")
                        }
                        .nativeGlassProminentButtonStyle()
                        .disabled(
                            workspace.groupImageSearchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                || workspace.isSearchingGroupImages
                        )
                        .help(L10n.string("Search"))
                    }

                    Text(L10n.string("Search terms are sent to Openverse."))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    HStack {
                        SettingsErrorView(error: workspace.lastError)
                        Spacer()

                        if chat.pictureURL != nil || chat.groupImageHashHex != nil {
                            Button {
                                Task { await workspace.clearGroupImage() }
                            } label: {
                                Label(L10n.string("Clear"), systemImage: "xmark.circle")
                            }
                            .controlSize(.small)
                            .disabled(workspace.hasInFlightGroupCommit)
                        }
                    }
                    .frame(minHeight: 24)

                    ScrollView {
                        if workspace.groupImageResults.isEmpty {
                            VStack(spacing: 10) {
                                Image(systemName: "photo.on.rectangle.angled")
                                    .font(.system(size: 28, weight: .light))
                                    .foregroundStyle(.secondary)
                                Text(
                                    workspace.isSearchingGroupImages
                                        ? L10n.string("Searching") : L10n.string("No images")
                                )
                                .font(.callout.weight(.medium))
                                .foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: .infinity, minHeight: 300)
                        } else {
                            LazyVGrid(columns: columns, spacing: 12) {
                                ForEach(workspace.groupImageResults) { result in
                                    Button {
                                        Task { await workspace.setGroupImage(result) }
                                    } label: {
                                        GroupImageResultTile(result: result)
                                    }
                                    .buttonStyle(.plain)
                                    .disabled(workspace.hasInFlightGroupCommit)
                                }
                            }
                            .padding(.vertical, 2)
                        }
                    }
                }
                .padding(18)
            }
        }
        .frame(width: 620, height: 560)
        .background {
            LiquidGlassBackground()
        }
        .fileImporter(
            isPresented: $isFileImporterPresented,
            allowedContentTypes: [.image],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                guard let url = urls.first else { return }
                Task { await workspace.setGroupImage(fileURL: url) }
            case .failure(let error):
                workspace.reportUserActionError(error.localizedDescription)
            }
        }
    }
}

struct GroupImageResultTile: View {
    let result: GroupImageSearchResult

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(.regularMaterial)

                if let imageURL = result.previewURL {
                    DownsampledAsyncImage(url: imageURL, maxPixelSize: 320) { image in
                        image
                            .resizable()
                            .scaledToFill()
                    } placeholder: {
                        Image(systemName: "photo")
                            .font(.system(size: 24, weight: .light))
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Image(systemName: "photo")
                        .font(.system(size: 24, weight: .light))
                        .foregroundStyle(.secondary)
                }
            }
            .aspectRatio(1.18, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

            Text(result.title)
                .font(.caption.weight(.semibold))
                .lineLimit(2)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)

            Text(result.creditLine)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(8)
        .glassCard()
        .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}
