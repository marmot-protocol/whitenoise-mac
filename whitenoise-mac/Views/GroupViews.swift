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

struct GroupDetailsSheet: View {
    @Environment(WorkspaceState.self) private var workspace
    @State private var showArchiveConfirmation = false
    @State private var showLeaveConfirmation = false
    @State private var showSelfDemoteConfirmation = false
    @State private var showRemoveLocallyConfirmation = false
    let chat: ChatItem

    private var hasProfileChanges: Bool {
        guard let snapshot = workspace.groupDetailsSnapshot else { return false }
        return workspace.groupProfileDraftName.trimmingCharacters(in: .whitespacesAndNewlines) != snapshot.name
            || workspace.groupProfileDraftDescription.trimmingCharacters(in: .whitespacesAndNewlines)
                != snapshot.description
    }

    private var headerAvatarURL: URL? {
        guard let snapshot = workspace.groupDetailsSnapshot else { return chat.sanitizedPictureURL }
        return snapshot.sanitizedAvatarURL
    }

    var body: some View {
        @Bindable var workspace = workspace

        VStack(spacing: 0) {
            HStack(spacing: 12) {
                ProfileImageAvatarView(
                    seed: chat.avatarSeed,
                    initials: chat.title,
                    sanitizedPictureURL: headerAvatarURL,
                    size: 48,
                    isSelected: false
                )

                VStack(alignment: .leading, spacing: 2) {
                    Text(workspace.groupDetailsSnapshot?.name ?? chat.title)
                        .font(.title3.weight(.semibold))
                        .lineLimit(1)
                    Text(workspace.groupDetailsSnapshot?.memberCountLabel ?? "Group details")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                if workspace.isLoadingGroupDetails {
                    ProgressView()
                        .controlSize(.small)
                }

                Button {
                    workspace.closeGroupDetails()
                } label: {
                    Image(systemName: "chevron.backward")
                        .font(.system(size: 13, weight: .semibold))
                        .frame(width: 28, height: 28)
                }
                .nativeGlassCircleButtonStyle()
                .help("Back to chat")
            }
            .padding(20)

            GlassSeparator(axis: .horizontal)

            if let snapshot = workspace.groupDetailsSnapshot {
                Form {
                    if snapshot.pendingConfirmation {
                        Section("Invitation") {
                            VStack(alignment: .leading, spacing: 10) {
                                Text(
                                    "Accept this invite to confirm membership, or decline it to remove the group from your chat list."
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

                    Section("Profile") {
                        TextField("Group name", text: $workspace.groupProfileDraftName)
                            .textFieldStyle(.roundedBorder)
                        TextField("Description", text: $workspace.groupProfileDraftDescription, axis: .vertical)
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
                                    Label("Search Web Image", systemImage: "photo.badge.plus")
                                }
                                .disabled(workspace.isSavingGroupImage)
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
                            .disabled(!hasProfileChanges || workspace.isSavingGroupProfile)
                        }
                    }

                    Section("Members") {
                        if snapshot.members.isEmpty {
                            ContentUnavailableView("No members", systemImage: "person.2.slash")
                                .frame(minHeight: 120)
                        } else {
                            ForEach(snapshot.members) { member in
                                GroupMemberRow(member: member)
                            }
                        }
                    }

                    Section("Disappearing Messages") {
                        Picker(
                            selection: Binding(
                                get: { DisappearingMessageOption.option(for: snapshot.disappearingMessageSecs) },
                                set: { option in
                                    Task {
                                        await workspace.setDisappearingMessages(
                                            groupIdHex: snapshot.groupIdHex,
                                            seconds: option.seconds
                                        )
                                    }
                                }
                            )
                        ) {
                            ForEach(DisappearingMessageOption.options(for: snapshot.disappearingMessageSecs)) {
                                option in
                                Text(option.label).tag(option)
                            }
                        } label: {
                            Label("Auto-delete after", systemImage: "timer")
                        }
                        .disabled(workspace.isUpdatingDisappearingMessages)

                        if snapshot.disappearingMessagesEnabled {
                            Button {
                                Task { await workspace.secureDeleteExpiredMessages(groupIdHex: snapshot.groupIdHex) }
                            } label: {
                                Label("Delete expired now", systemImage: "trash")
                            }
                            .disabled(workspace.isSecureDeletingExpired)
                            .help(L10n.string("Securely prune already-expired messages on this device"))
                        }
                    }

                    if snapshot.canInvite {
                        Section("Invite") {
                            HStack(spacing: 10) {
                                TextField(
                                    "npub, profile link, or hex public key", text: $workspace.groupInviteMemberQuery
                                )
                                .textFieldStyle(.roundedBorder)

                                Button {
                                    Task { await workspace.inviteMemberToSelectedGroup() }
                                } label: {
                                    Label(
                                        workspace.isInvitingGroupMember
                                            ? L10n.string("Inviting...") : L10n.string("Invite"),
                                        systemImage: "person.badge.plus")
                                }
                                .disabled(
                                    workspace.isInvitingGroupMember
                                        || workspace.groupInviteMemberQuery.trimmingCharacters(
                                            in: .whitespacesAndNewlines
                                        ).isEmpty
                                )
                            }
                        }
                    }

                    Section("Group Actions") {
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
                                    Label("Step Down as Admin", systemImage: "star.slash")
                                }
                                .disabled(workspace.mutatingGroupMemberId != nil || snapshot.isLastAdmin)
                            }

                            Button(role: .destructive) {
                                showLeaveConfirmation = true
                            } label: {
                                Label(
                                    workspace.isLeavingGroup ? L10n.string("Leaving...") : L10n.string("Leave Group"),
                                    systemImage: "rectangle.portrait.and.arrow.right")
                            }
                            .disabled(
                                workspace.isLeavingGroup || !snapshot.canLeave || snapshot.requiresSelfDemoteBeforeLeave
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

                        if snapshot.requiresSelfDemoteBeforeLeave {
                            Text("Demote yourself from admin before leaving this group.")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        } else if snapshot.isLastAdmin {
                            Text("Make another member an admin before stepping down or leaving.")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
                    }

                    if workspace.developerMode {
                        Section("Developer") {
                            HStack(spacing: 10) {
                                Button {
                                    Task { await workspace.copySelectedGroupTranscriptJSON() }
                                } label: {
                                    Label(
                                        workspace.isExportingGroupTranscript
                                            ? L10n.string("Copying Transcript...")
                                            : L10n.string("Copy Transcript JSON"),
                                        systemImage: "doc.on.doc"
                                    )
                                }
                                .disabled(workspace.isExportingGroupTranscript)

                                if let status = workspace.groupTranscriptExportStatus {
                                    Label(status, systemImage: "checkmark.circle")
                                        .font(.callout)
                                        .foregroundStyle(.green)
                                }
                            }

                            GroupDiagnosticsValueRow(title: "Group ID", value: snapshot.groupIdHex)
                            GroupDiagnosticsValueRow(title: "Nostr group ID", value: snapshot.nostrGroupIdHex)
                            GroupDiagnosticsValueRow(title: "Endpoint", value: snapshot.endpoint)
                            GroupDiagnosticsValueRow(title: "Avatar URL", value: snapshot.avatarURL ?? "")
                            GroupDiagnosticsValueRow(title: "Avatar dimension", value: snapshot.avatarDimension ?? "")
                            GroupDiagnosticsValueRow(
                                title: "Relays", value: snapshot.relays.joined(separator: "\n"), lineLimit: 4)
                            GroupDiagnosticsValueRow(
                                title: "Admins", value: snapshot.adminIds.joined(separator: "\n"), lineLimit: 4)
                            GroupDiagnosticsValueRow(
                                title: "Self admin",
                                value: snapshot.isSelfAdmin ? L10n.string("Yes") : L10n.string("No"), copyable: false)
                            GroupDiagnosticsValueRow(
                                title: "Last admin",
                                value: snapshot.isLastAdmin ? L10n.string("Yes") : L10n.string("No"), copyable: false)
                            GroupDiagnosticsValueRow(
                                title: "Can invite", value: snapshot.canInvite ? L10n.string("Yes") : L10n.string("No"),
                                copyable: false)
                            GroupDiagnosticsValueRow(
                                title: "Can leave", value: snapshot.canLeave ? L10n.string("Yes") : L10n.string("No"),
                                copyable: false)
                            GroupDiagnosticsValueRow(
                                title: "Pending confirmation",
                                value: snapshot.pendingConfirmation ? L10n.string("Yes") : L10n.string("No"),
                                copyable: false)
                        }
                    }

                    SettingsErrorView(error: workspace.lastError)
                }
                .formStyle(.grouped)
                .scrollContentBackground(.hidden)
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
            LiquidGlassBackground()
        }
        .confirmationDialog(
            archiveConfirmationTitle,
            isPresented: $showArchiveConfirmation,
            titleVisibility: .visible
        ) {
            if let snapshot = workspace.groupDetailsSnapshot {
                Button(
                    snapshot.archived ? "Unarchive Group" : "Archive Group",
                    role: snapshot.archived ? nil : .destructive
                ) {
                    Task { await workspace.setSelectedGroupArchived(!snapshot.archived) }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Archived groups are hidden from the active chat list.")
        }
        .confirmationDialog(
            "Step down as admin?",
            isPresented: $showSelfDemoteConfirmation,
            titleVisibility: .visible
        ) {
            Button("Step Down", role: .destructive) {
                Task { await workspace.selfDemoteSelectedGroupAdmin() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("You'll stay in the group, but another admin will need to restore your admin status.")
        }
        .confirmationDialog(
            "Leave this group?",
            isPresented: $showLeaveConfirmation,
            titleVisibility: .visible
        ) {
            Button("Leave Group", role: .destructive) {
                Task { await workspace.leaveSelectedGroup() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("You will no longer receive messages from this group on this account.")
        }
        .confirmationDialog(
            "Remove this conversation from this device?",
            isPresented: $showRemoveLocallyConfirmation,
            titleVisibility: .visible
        ) {
            Button("Remove From This Device", role: .destructive) {
                Task { await workspace.deleteGroupLocally(groupIdHex: chat.id) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This deletes the local copy only. Other members are not notified, and you can be re-added later.")
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
                .help("\(L10n.string("Copy")) \(title)")
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
            AvatarView(seed: member.id, initials: member.initials, size: 34, isSelected: false)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(member.displayName)
                        .font(.callout.weight(.semibold))
                        .lineLimit(1)

                    if member.isAdmin {
                        Text("Admin")
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(.thinMaterial, in: Capsule())
                    }

                    if member.isSelf {
                        Text("You")
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

            if isMutating {
                ProgressView()
                    .controlSize(.small)
            }

            if hasActions {
                Menu {
                    if member.canPromote {
                        Button("Make Admin") {
                            Task { await workspace.promoteGroupMember(member) }
                        }
                    }

                    if member.canDemote {
                        Button(member.isSelf ? "Demote Myself" : "Remove Admin") {
                            Task { await workspace.demoteGroupMember(member) }
                        }
                    }

                    if member.canRemove {
                        Button("Remove Member", role: .destructive) {
                            showRemoveConfirmation = true
                        }
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .frame(width: 28, height: 28)
                }
                .menuStyle(.borderlessButton)
                .disabled(workspace.mutatingGroupMemberId != nil)
            }
        }
        .confirmationDialog(
            "Remove this member?",
            isPresented: $showRemoveConfirmation,
            titleVisibility: .visible
        ) {
            Button("Remove Member", role: .destructive) {
                Task { await workspace.removeGroupMember(member) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes \(member.displayName) from the group.")
        }
    }
}

struct GroupImagePickerSheet: View {
    @Environment(WorkspaceState.self) private var workspace

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
                        size: 46,
                        isSelected: false
                    )

                    VStack(alignment: .leading, spacing: 2) {
                        Text(chat.title)
                            .font(.headline)
                            .lineLimit(1)
                        Text("Group image")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    Button {
                        workspace.closeGroupImagePicker()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 12, weight: .bold))
                            .frame(width: 28, height: 28)
                    }
                    .nativeGlassCircleButtonStyle()
                    .help("Close")
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 16)

                Divider()

                VStack(spacing: 12) {
                    HStack(spacing: 8) {
                        TextField("Search images", text: $workspace.groupImageSearchQuery)
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
                            Label("Search", systemImage: "magnifyingglass")
                        }
                        .nativeGlassProminentButtonStyle()
                        .disabled(
                            workspace.groupImageSearchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                || workspace.isSearchingGroupImages
                        )
                        .help("Search")
                    }

                    Text("Search terms are sent to Openverse.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    HStack {
                        SettingsErrorView(error: workspace.lastError)
                        Spacer()

                        if chat.pictureURL != nil {
                            Button {
                                Task { await workspace.clearGroupImage() }
                            } label: {
                                Label("Clear", systemImage: "xmark.circle")
                            }
                            .controlSize(.small)
                            .disabled(workspace.isSavingGroupImage)
                        }
                    }
                    .frame(minHeight: 24)

                    ScrollView {
                        if workspace.groupImageResults.isEmpty {
                            VStack(spacing: 10) {
                                Image(systemName: "photo.on.rectangle.angled")
                                    .font(.system(size: 28, weight: .light))
                                    .foregroundStyle(.secondary)
                                Text(workspace.isSearchingGroupImages ? "Searching" : "No images")
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
                                    .disabled(workspace.isSavingGroupImage)
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

private extension GroupImageSearchResult {
    var previewURL: URL? {
        if let thumbnailURL, let url = URL(string: thumbnailURL) {
            return url
        }
        return URL(string: imageURL)
    }
}

/// Selectable disappearing-message timer presets for a group. `custom` carries a
/// non-preset value returned by the core so the picker can still display it.
enum DisappearingMessageOption: Hashable, Identifiable {
    case off
    case oneHour
    case oneDay
    case oneWeek
    case oneMonth
    case custom(UInt64)

    static let presets: [DisappearingMessageOption] = [.off, .oneHour, .oneDay, .oneWeek, .oneMonth]
    static var allCases: [DisappearingMessageOption] { presets }

    var id: UInt64 { seconds }

    var seconds: UInt64 {
        switch self {
        case .off: return 0
        case .oneHour: return 3600
        case .oneDay: return 86_400
        case .oneWeek: return 604_800
        case .oneMonth: return 2_592_000
        case .custom(let value): return value
        }
    }

    var label: String {
        switch self {
        case .off: return L10n.string("Off")
        case .oneHour: return L10n.string("1 hour")
        case .oneDay: return L10n.string("1 day")
        case .oneWeek: return L10n.string("1 week")
        case .oneMonth: return L10n.string("1 month")
        case .custom(let value): return String(format: L10n.string("%llu seconds"), CUnsignedLongLong(value))
        }
    }

    /// The matching preset for `seconds`, or a `.custom` wrapper when none match.
    static func option(for seconds: UInt64) -> DisappearingMessageOption {
        presets.first { $0.seconds == seconds } ?? .custom(seconds)
    }

    /// The presets plus the current value when it isn't already a preset, so the
    /// picker always has a tag matching the active selection.
    static func options(for seconds: UInt64) -> [DisappearingMessageOption] {
        let current = option(for: seconds)
        return presets.contains(current) ? presets : presets + [current]
    }
}
