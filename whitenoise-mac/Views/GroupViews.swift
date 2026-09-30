//
//  GroupViews.swift
//  whitenoise-mac
//
//  Group management UI: member rows, diagnostics rows, the contact details pane, and the
//  group-image picker/results. The group details pane itself lives in `GroupDetails/`.
//

import AppKit
import MarmotKit
import SwiftUI
import UniformTypeIdentifiers

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
                    AvatarView(seed: member.id, initials: member.initials, size: 36, isSelected: false)

                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(member.displayName)
                                .wnFont(.semiBold12)
                                .lineLimit(1)

                            if member.isSelf {
                                GroupMemberBadge(kind: .you)
                            }

                            if member.isAdmin {
                                GroupMemberBadge(kind: .admin)
                            }
                        }

                        // Your own row already says "You" in its badge, so it shows the key the
                        // others see instead of saying it twice.
                        Text(member.isSelf ? DisplayText.short(member.npub, head: 12, tail: 8) : member.detailLabel)
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
    let blockedUsersModel: BlockedUsersViewModel

    private var isLocalProfile: Bool {
        workspace.accounts.contains {
            $0.accountIdHex.lowercased() == contact.accountIdHex.lowercased()
        }
    }

    private var isBlocked: Bool {
        blockedUsersModel.isBlocked(accountID: contact.accountIdHex)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                // Leading back control, matching GroupDetailsSheet: both panes slide in
                // over the transcript and return to it.
                GlassCircleCloseButton(symbol: "chevron.backward", help: "Back", appearance: .outline) {
                    workspace.closeContactDetails()
                }

                ProfileImageAvatarView(
                    seed: contact.accountIdHex,
                    initials: contact.title,
                    sanitizedPictureURL: contact.sanitizedPictureURL,
                    size: 48,
                    isSelected: false
                )

                VStack(alignment: .leading, spacing: 2) {
                    Text(contact.title)
                        .wnFont(.semiBold16)
                        .lineLimit(1)
                    Text(isLocalProfile ? L10n.string("You") : L10n.string("Contact"))
                        .wnFont(.medium12)
                        .foregroundStyle(WNColor.backgroundContentSecondary)
                }

                Spacer()

                if workspace.isLoadingContactDetails {
                    ProgressView()
                        .controlSize(.small)
                }
            }
            .padding(20)

            GlassSeparator(axis: .horizontal)

            // Follow and Message lead the profile, above every detail row, so neither can be
            // missed. `isSelf` only covers the active account; the follow control hides itself
            // for any other identity signed in on this device.
            if !isLocalProfile {
                if isBlocked {
                    BlockedContactNotice()
                } else {
                    ContactProfileActionsRow(contact: contact)
                }

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

                GroupsInCommonSection()

                if !isLocalProfile {
                    ContactBlockingSection(
                        model: blockedUsersModel,
                        accountID: contact.accountIdHex
                    )
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
private struct ContactProfileActionsRow: View {
    @Environment(WorkspaceState.self) private var workspace
    let contact: NewChatRecipient

    var body: some View {
        HStack(spacing: 10) {
            ContactFollowControl(accountIdHex: contact.accountIdHex)

            Button {
                Task { await workspace.messageContact(contact) }
            } label: {
                Label(L10n.string("Message"), systemImage: "message")
                    .frame(maxWidth: .infinity)
            }
            .wnPrimaryButtonStyle()
            .disabled(workspace.isCreatingChat)
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
struct ContactFollowControl: View {
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
