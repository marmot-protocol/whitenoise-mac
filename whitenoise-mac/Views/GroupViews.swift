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
    @State private var showSelfDemoteConfirmation = false
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
        .wnFont(.medium12)
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
                .wnFont(.semiBold14)
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
            DetailsPaneHeader(
                backHelp: "Back to chat",
                onBack: { workspace.closeGroupDetails() },
                avatarSeed: chat.avatarSeed,
                avatarInitials: chat.title,
                avatarURL: headerAvatarURL,
                avatarImagePayload: chat.groupImagePayload,
                title: workspace.groupDetailsSnapshot?.name ?? chat.title,
                subtitle: { headerSubtitle },
                actions: {
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
                                .wnFont(.semiBold16)
                                .frame(width: 30, height: 30)
                                .background { MessagesCircleControlBackground() }
                        }
                        .buttonStyle(.plain)
                        .disabled(workspace.hasInFlightGroupCommit)
                        .help(L10n.string("Add members"))
                    }
                }
            )

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
                                .wnFont(.medium12)
                                .foregroundStyle(WNColor.backgroundContentSecondary)
                                .fixedSize(horizontal: false, vertical: true)

                                PendingInviteActionButtons(
                                    accept: { await workspace.acceptSelectedGroupInvite() },
                                    decline: { await workspace.declineSelectedGroupInvite() }
                                )
                            }
                        }
                    }

                    if let endedDescription = snapshot.selfMembership.endedDescription {
                        Section(L10n.string("Membership")) {
                            Label {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(endedDescription)
                                        .wnFont(.semiBold12)

                                    Text(ChatSelfMembership.endedHistoryExplanation)
                                        .wnFont(.medium12)
                                        .foregroundStyle(WNColor.backgroundContentSecondary)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            } icon: {
                                Image(systemName: snapshot.selfMembership.endedSymbolName ?? "")
                                    .foregroundStyle(WNColor.backgroundContentSecondary)
                            }
                        }
                    }
                    if let contactAccountIdHex = chat.directPeerAccountIdHex {
                        Section(L10n.string("Contact")) {
                            ContactNicknameRow(
                                accountIdHex: contactAccountIdHex,
                                publishedName: chat.publishedTitle
                            )
                            ContactFollowControl(accountIdHex: contactAccountIdHex)
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
                                .buttonStyle(.wnSecondary)
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
                                        .foregroundStyle(WNColor.backgroundContentSecondary)
                                }
                            } else if workspace.commonGroupsForContact.isEmpty {
                                Label(L10n.string("No groups in common"), systemImage: "person.2.slash")
                                    .foregroundStyle(WNColor.backgroundContentSecondary)
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
                                                    .wnFont(.semiBold12)
                                                    .foregroundStyle(WNColor.backgroundContentPrimary)
                                                    .lineLimit(1)
                                                Text(commonGroup.subtitle)
                                                    .wnFont(.medium10)
                                                    .foregroundStyle(WNColor.backgroundContentSecondary)
                                                    .lineLimit(1)
                                            }

                                            Spacer()
                                            Image(systemName: "chevron.right")
                                                .wnFont(.semiBold10)
                                                .foregroundStyle(WNColor.backgroundContentTertiary)
                                        }
                                        .contentShape(Rectangle())
                                    }
                                    .buttonStyle(.plain)
                                }
                            }

                            if workspace.commonGroupsLoadHadFailures {
                                Text(L10n.string("Some groups could not be checked."))
                                    .wnFont(.medium10)
                                    .foregroundStyle(WNColor.backgroundContentSecondary)
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
                            .buttonStyle(.wnSecondary)
                            .disabled(workspace.isSecureDeletingExpired)
                            .help(L10n.string("Securely prune already-expired messages on this device"))
                        }
                    }

                    Section(L10n.string("Group Actions")) {
                        HStack(spacing: 10) {
                            // Archiving is reversible and the other clients draw it as `outline`
                            // rather than `destructive` (`group_info_screen.dart`), so it takes the
                            // secondary style in both directions instead of turning red to archive
                            // and plain to unarchive.
                            Button {
                                showArchiveConfirmation = true
                            } label: {
                                Label(
                                    archiveButtonTitle(snapshot: snapshot),
                                    systemImage: snapshot.archived ? "tray.and.arrow.up" : "archivebox"
                                )
                            }
                            .buttonStyle(.wnSecondary)
                            .disabled(workspace.isArchivingGroup)

                            if snapshot.isSelfAdmin {
                                // `group_member_screen.dart` builds "remove admin role" as
                                // `outline`, keeping `destructive` for removing someone from the
                                // group. Giving up your own admin rights is reversible by another
                                // admin, so it follows that split rather than reading as a deletion.
                                Button {
                                    showSelfDemoteConfirmation = true
                                } label: {
                                    Label(L10n.string("Step Down as Admin"), systemImage: "star.slash")
                                }
                                .buttonStyle(.wnSecondary)
                                .disabled(workspace.hasInFlightGroupCommit || snapshot.isLastAdmin)
                            }

                            // Leave / Delete come from the same policy the sidebar row menu uses, so
                            // the two surfaces cannot disagree on which is legal. Membership is
                            // very nearly the whole rule: a member is offered the leave even when
                            // eligibility will block it, and `prepareSelectedChatLeave` either
                            // explains the block or resolves it — with the successor picker for a
                            // sole admin who has someone to promote. The one exception is an account
                            // alone in a chat it cannot leave, which this inspector can see from the
                            // roster and so offers the local delete outright.
                            switch snapshot.destructiveAction {
                            case .leave:
                                Button(role: .destructive) {
                                    Task { await workspace.prepareSelectedChatLeave() }
                                } label: {
                                    Label(
                                        workspace.leavingChatId == snapshot.groupIdHex
                                            ? L10n.string("Leaving...")
                                            : L10n.string("Leave Chat"),
                                        systemImage: "rectangle.portrait.and.arrow.right")
                                }
                                .disabled(
                                    workspace.leavingChatId != nil
                                        || workspace.preparingChatLeaveId != nil
                                        || workspace.handingOffAdminChatId != nil)

                            case .deleteLocally:
                                Button(role: .destructive) {
                                    workspace.requestSelectedChatLocalDelete()
                                } label: {
                                    Label(
                                        workspace.deletingChatId == snapshot.groupIdHex
                                            ? L10n.string("Removing...")
                                            : L10n.string("Remove From This Device"),
                                        systemImage: "trash.slash")
                                }
                                // Progress is per-chat, but the guard in `deleteGroupLocally` is
                                // global, so the affordance stays disabled for any in-flight delete.
                                .disabled(workspace.isDeletingGroupLocally)
                                .help(
                                    L10n.string(
                                        "Delete this conversation locally without notifying the group"))

                            case nil:
                                EmptyView()
                            }

                            Spacer()
                        }

                        // Sourced from the shared policy so the footer and the row menu's alert
                        // cannot drift apart. `leaveGuidance` rather than `leaveBlocker` because the
                        // sole admin of a group with someone to promote is not blocked — they are one
                        // extra step from leaving, and the footer says which step.
                        if let guidance = snapshot.leaveGuidance {
                            Text(guidance.message)
                                .wnFont(.medium12)
                                .foregroundStyle(WNColor.backgroundContentSecondary)
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
                                        .wnFont(.medium12)
                                        .foregroundStyle(WNColor.intentionSuccessContent)
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
        // The leave and local-delete confirmations are not declared here: both actions are also
        // offered from the sidebar row menu, and they share the one dialog installed by
        // `chatDestructiveActionsConfirmation()` in `ContentView` so each has a single wording.
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
                    .wnFont(.semiBold12)

                Text(displayValue)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(WNColor.backgroundContentSecondary)
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
                .buttonStyle(.wnSecondary)
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
                                .wnFont(.semiBold12)
                                .lineLimit(1)

                            if member.isAdmin {
                                Text(L10n.string("Admin"))
                                    .wnFont(.semiBold10)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(.thinMaterial, in: Capsule())
                            }

                            if member.isSelf {
                                Text(L10n.string("You"))
                                    .wnFont(.semiBold10)
                                    .foregroundStyle(WNColor.backgroundContentSecondary)
                            }
                        }

                        Text(member.detailLabel)
                            .wnFont(.medium10)
                            .foregroundStyle(WNColor.backgroundContentSecondary)
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
                    Group {
                        if member.canPromote {
                            Button {
                                Task { await workspace.promoteGroupMember(member) }
                            } label: {
                                Label(L10n.string("Make Admin"), systemImage: "star")
                            }
                        }

                        if member.canDemote {
                            Button {
                                Task { await workspace.demoteGroupMember(member) }
                            } label: {
                                Label(
                                    member.isSelf ? L10n.string("Demote Myself") : L10n.string("Remove Admin"),
                                    systemImage: "star.slash"
                                )
                            }
                        }

                        if member.canRemove {
                            Button(role: .destructive) {
                                showRemoveConfirmation = true
                            } label: {
                                Label(L10n.string("Remove Member"), systemImage: "person.badge.minus")
                            }
                        }
                    }
                    .menuLabelIcons()
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
            DetailsPaneHeader(
                backHelp: "Back",
                onBack: { workspace.closeContactDetails() },
                avatarSeed: contact.accountIdHex,
                avatarInitials: contact.title,
                avatarURL: contact.sanitizedPictureURL,
                title: contact.title,
                subtitle: {
                    Text(isSelf ? L10n.string("You") : L10n.string("Contact"))
                        .wnFont(.medium12)
                        .foregroundStyle(WNColor.backgroundContentSecondary)
                },
                actions: {
                    if workspace.isLoadingContactDetails {
                        ProgressView()
                            .controlSize(.small)
                    }
                }
            )

            GlassSeparator(axis: .horizontal)

            // Follow and Message lead the profile, above every detail row, so neither can be
            // missed. `isSelf` only covers the active account; the follow control hides itself
            // for any other identity signed in on this device.
            if !isSelf {
                ContactProfileActionsRow(contact: contact)

                GlassSeparator(axis: .horizontal)
            }

            Form {
                Section(L10n.string("Contact")) {
                    ContactNicknameRow(
                        accountIdHex: contact.accountIdHex,
                        publishedName: contact.publishedDisplayName
                    )

                    LabeledContent(L10n.string("Public key")) {
                        Text(contact.npub.isEmpty ? contact.accountIdHex : contact.npub)
                            .font(.callout.monospaced())
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .textSelection(.enabled)
                    }

                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(
                            contact.npub.isEmpty ? contact.accountIdHex : contact.npub,
                            forType: .string
                        )
                    } label: {
                        Label(L10n.string("Copy Public Key"), systemImage: "doc.on.doc")
                    }
                    .buttonStyle(.wnSecondary)

                    SettingsErrorView(error: workspace.lastError)
                }

                Section(L10n.string("Groups in Common")) {
                    if workspace.isLoadingCommonGroups
                        && workspace.commonGroupsForContact.isEmpty
                    {
                        HStack(spacing: 8) {
                            ProgressView()
                                .controlSize(.small)
                            Text(L10n.string("Checking shared groups…"))
                                .foregroundStyle(WNColor.backgroundContentSecondary)
                        }
                    } else if workspace.commonGroupsForContact.isEmpty {
                        Label(L10n.string("No groups in common"), systemImage: "person.2.slash")
                            .foregroundStyle(WNColor.backgroundContentSecondary)
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
                                            .wnFont(.semiBold12)
                                            .foregroundStyle(WNColor.backgroundContentPrimary)
                                            .lineLimit(1)
                                        Text(commonGroup.subtitle)
                                            .wnFont(.medium10)
                                            .foregroundStyle(WNColor.backgroundContentSecondary)
                                            .lineLimit(1)
                                    }
                                    Spacer()
                                    Image(systemName: "chevron.right")
                                        .wnFont(.semiBold10)
                                        .foregroundStyle(WNColor.backgroundContentTertiary)
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }

                    if workspace.commonGroupsLoadHadFailures {
                        Text(L10n.string("Some groups could not be checked."))
                            .wnFont(.medium10)
                            .foregroundStyle(WNColor.backgroundContentSecondary)
                    }
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
        }
    }
}

/// Follow and Message, side by side directly under the profile header.
///
/// Both sibling clients lead a profile with these two: iOS puts them in equal-width buttons
/// above the detail rows, and the Flutter app stacks Follow first in its action column. This
/// app used to keep Follow inside a form row beside "Copy Public Key", where a small bordered
/// button next to a clipboard action read as another utility rather than as the way to follow
/// someone — the feature was there and still could not be found.
/// What a contact profile offers above the form, in the order it offers it.
///
/// Follow leads. It used to sit inside the same form row as "Copy Public Key", several screens of
/// detail below the fold, which is why nobody could find it — so the order is the fix and is stated
/// here rather than left implicit in a stack.
nonisolated enum ContactProfileAction: Hashable, CaseIterable, Sendable {
    case follow
    case message

    static let ordered: [ContactProfileAction] = [.follow, .message]
}

struct ContactProfileActionsRow: View {
    @Environment(WorkspaceState.self) private var workspace
    let contact: NewChatRecipient

    var body: some View {
        HStack(spacing: 10) {
            ForEach(ContactProfileAction.ordered, id: \.self) { action in
                switch action {
                case .follow:
                    ContactFollowControl(accountIdHex: contact.accountIdHex)

                case .message:
                    Button {
                        Task { await workspace.messageContact(contact) }
                    } label: {
                        Label(L10n.string("Message"), systemImage: "message")
                            .frame(maxWidth: .infinity)
                    }
                    .wnPrimaryButtonStyle()
                    .disabled(workspace.isCreatingChat)
                }
            }
        }
        .controlSize(.large)
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .accessibilityIdentifier("contact.details.actions")
    }
}

/// Follow/unfollow for one contact. The control keeps its place in the row through all three
/// states — reading, known, and failed — so a relationship that cannot be read reads as a
/// problem to retry rather than as a feature that isn't there.
///
/// Every state fills the width it is given, so it reads as a primary action in the profile's
/// action row and as a full-width row in chat info, rather than as a chip trailing a label.
private struct ContactFollowControl: View {
    @Environment(WorkspaceState.self) private var workspace
    let accountIdHex: String

    var body: some View {
        // Never offer to follow another identity on this device, not just the active one.
        if !workspace.canOfferFollow(accountIdHex: accountIdHex) {
            EmptyView()
        } else {
            switch workspace.contactFollowStatus(accountIdHex: accountIdHex) {
            case .loading:
                HStack(spacing: 6) {
                    ProgressView()
                        .controlSize(.small)
                    Text(L10n.string("Checking…"))
                        .foregroundStyle(WNColor.backgroundContentSecondary)
                }
                .frame(maxWidth: .infinity)
                .accessibilityIdentifier("contact.details.follow.loading")

            case .known(let isFollowing):
                Button {
                    Task { await workspace.toggleFollow(accountIdHex: accountIdHex) }
                } label: {
                    if workspace.isTogglingFollow {
                        ProgressView()
                            .controlSize(.small)
                            .frame(maxWidth: .infinity)
                    } else {
                        Label(
                            isFollowing ? L10n.string("Unfollow") : L10n.string("Follow"),
                            systemImage: isFollowing ? "person.badge.minus" : "person.badge.plus"
                        )
                        .frame(maxWidth: .infinity)
                    }
                }
                .buttonStyle(.wnSecondary)
                .disabled(workspace.isTogglingFollow)
                .accessibilityLabel(isFollowing ? L10n.string("Unfollow") : L10n.string("Follow"))
                .accessibilityIdentifier("contact.details.follow")

            case .unavailable:
                Button {
                    Task { await workspace.refreshFollowStatus(forContactIdHex: accountIdHex) }
                } label: {
                    Label(L10n.string("Retry"), systemImage: "arrow.clockwise")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.wnSecondary)
                .help(L10n.string("Couldn't check whether you follow this person."))
                .accessibilityIdentifier("contact.details.follow.retry")
            }
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
                            .wnFont(.semiBold14)
                            .lineLimit(1)
                        Text(L10n.string("Group image"))
                            .wnFont(.medium10)
                            .foregroundStyle(WNColor.backgroundContentSecondary)
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
                            .wnFont(.medium10)
                            .foregroundStyle(WNColor.backgroundContentSecondary)

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
                        .wnFont(.medium10)
                        .foregroundStyle(WNColor.backgroundContentSecondary)
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
                                    .wnFont(.medium28)
                                    .foregroundStyle(WNColor.backgroundContentSecondary)
                                Text(
                                    workspace.isSearchingGroupImages
                                        ? L10n.string("Searching") : L10n.string("No images")
                                )
                                .wnFont(.medium12)
                                .foregroundStyle(WNColor.backgroundContentSecondary)
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
                            .wnFont(.medium24)
                            .foregroundStyle(WNColor.backgroundContentSecondary)
                    }
                } else {
                    Image(systemName: "photo")
                        .wnFont(.medium24)
                        .foregroundStyle(WNColor.backgroundContentSecondary)
                }
            }
            .aspectRatio(1.18, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

            Text(result.title)
                .wnFont(.semiBold10)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)

            Text(result.creditLine)
                .wnFont(.medium10)
                .foregroundStyle(WNColor.backgroundContentSecondary)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(8)
        .glassCard()
        .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}
