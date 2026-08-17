//
//  ComposeFlowViews.swift
//  whitenoise-mac
//
//  The drawer's new-chat flow: pick a person to message, or step through
//  choose-members → name-group to create a group.
//

import AppKit
import SwiftUI

// MARK: - New chat

struct NewChatPanelView: View {
    @Environment(WorkspaceState.self) private var workspace

    private var trimmedQuery: String {
        workspace.newChatQuery.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        @Bindable var workspace = workspace

        VStack(spacing: 0) {
            ComposePaneHeader(title: L10n.string("New chat")) {
                workspace.composeGoBack()
            }

            MessagesSearchField(
                text: $workspace.newChatQuery,
                accessibilityIdentifier: "compose.search",
                placeholder: L10n.string("Name or npub"),
                autofocus: true
            )
            .padding(.horizontal, 12)
            .padding(.bottom, 12)
            .debouncedNewChatQueryResolution(for: workspace.newChatQuery)
            .userDiscovery(for: workspace.newChatQuery)

            // Above the list, not inside it: the row that failed can be anywhere in a long
            // contact list, and a prompt appended below the results would land off screen.
            // `visible…` rather than the raw prompt so editing the query hides it immediately,
            // without waiting on the resolution debounce.
            if let prompt = workspace.visibleStartChatInvitePrompt {
                StartChatInviteNotice(prompt: prompt)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 12)
            }

            GlassSeparator(axis: .horizontal)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    if trimmedQuery.isEmpty {
                        ComposeActionRow(symbol: "person.2.fill", title: L10n.string("New group")) {
                            workspace.composeShowChooseMembers()
                        }
                        .accessibilityIdentifier("compose.newGroup")

                        ComposeActionRow(symbol: "doc.on.clipboard", title: L10n.string("Paste npub")) {
                            pasteIntoSearch()
                        }

                        if !workspace.composeContacts.isEmpty {
                            ComposeSectionHeader(title: L10n.string("Contacts"))
                            contactRows(workspace.composeContacts)
                        }
                        loadingFooter
                    } else if workspace.looksLikeMemberRef(trimmedQuery) {
                        ComposeIdentifierResults(
                            isBusy: { workspace.creatingDirectChatIdHex == $0.accountIdHex },
                            isDisabled: workspace.isCreatingChat,
                            onPaste: pasteIntoSearch
                        ) { recipient in
                            Task { await workspace.startDirectChat(with: recipient) }
                        }
                    } else {
                        let results = workspace.composeSearchResults(matching: trimmedQuery)
                        if !results.known.isEmpty {
                            ComposeSectionHeader(title: L10n.string("Contacts"))
                            contactRows(results.known)
                        }
                        if !results.discovered.isEmpty {
                            ComposeSectionHeader(title: L10n.string("People"))
                            discoveredRows(results.discovered)
                        }
                        if UserDiscoveryPresentation.showsNoMatches(
                            results: results,
                            isSearching: workspace.isSearchingPeople
                        ) {
                            ComposeNoMatchesView(onPaste: pasteIntoSearch)
                        }
                        ComposeDiscoveryStatusRow()
                    }

                    if let lastError = workspace.lastError {
                        Text(lastError)
                            .wnFont(.medium10)
                            .foregroundStyle(WNColor.backgroundContentDestructive)
                            .padding(.horizontal, 12)
                            .padding(.top, 6)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 8)
            }
            .accessibilityIdentifier("compose.list")
        }
        .onExitCommand {
            workspace.composeGoBack()
        }
        .task {
            await workspace.refreshComposeContacts()
        }
    }

    @ViewBuilder
    private func contactRows(_ contacts: [ComposeContact]) -> some View {
        ForEach(contacts) { contact in
            ComposeContactRow(
                title: contact.title,
                subtitle: contact.subtitle,
                avatarSeed: contact.accountIdHex,
                sanitizedPictureURL: contact.sanitizedPictureURL,
                isBusy: workspace.creatingDirectChatIdHex == contact.accountIdHex
            ) {
                Task { await workspace.startDirectChat(with: contact.recipient) }
            }
            .accessibilityIdentifier("compose.contact.\(contact.accountIdHex)")
            .disabled(workspace.isCreatingChat && workspace.creatingDirectChatIdHex != contact.accountIdHex)
        }
    }

    @ViewBuilder
    private func discoveredRows(_ people: [DiscoveredPerson]) -> some View {
        ForEach(people) { person in
            DiscoveredPersonRow(
                person: person,
                isBusy: workspace.creatingDirectChatIdHex == person.accountIdHex
            ) {
                Task { await workspace.startDirectChat(with: person.recipient) }
            }
            .accessibilityIdentifier("compose.discovered.\(person.accountIdHex)")
            .disabled(workspace.isCreatingChat && workspace.creatingDirectChatIdHex != person.accountIdHex)
        }
    }

    @ViewBuilder
    private var loadingFooter: some View {
        if workspace.isLoadingComposeContacts {
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text(L10n.string("Finding people from your groups..."))
                    .wnFont(.medium10)
                    .foregroundStyle(WNColor.backgroundContentSecondary)
            }
            .padding(12)
        }
    }

    private func pasteIntoSearch() {
        guard let value = NSPasteboard.general.string(forType: .string) else { return }
        workspace.newChatQuery = value.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - Choose members

struct ChooseMembersPanelView: View {
    @Environment(WorkspaceState.self) private var workspace

    private var trimmedQuery: String {
        workspace.newChatQuery.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        @Bindable var workspace = workspace

        VStack(spacing: 0) {
            ComposePaneHeader(title: L10n.string("Choose members")) {
                workspace.composeGoBack()
            }

            VStack(spacing: 10) {
                MessagesSearchField(
                    text: $workspace.newChatQuery,
                    accessibilityIdentifier: "compose.members.search",
                    placeholder: L10n.string("Name or npub"),
                    autofocus: true
                )
                .debouncedNewChatQueryResolution(for: workspace.newChatQuery)
                .userDiscovery(for: workspace.newChatQuery)

                if !workspace.newChatRecipients.isEmpty {
                    ScrollView {
                        ChipFlowLayout(spacing: 6) {
                            ForEach(workspace.newChatRecipients, id: \.accountIdHex) { member in
                                MemberChip(member: member) {
                                    workspace.removeNewChatRecipient(member)
                                }
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 88)
                }
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 12)

            GlassSeparator(axis: .horizontal)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    if trimmedQuery.isEmpty {
                        if !workspace.composeContacts.isEmpty {
                            ComposeSectionHeader(title: L10n.string("Contacts"))
                            selectableRows(workspace.composeContacts)
                        }
                    } else if workspace.looksLikeMemberRef(trimmedQuery) {
                        ComposeIdentifierResults(
                            selection: { isSelected(accountIdHex: $0.accountIdHex) }
                        ) { recipient in
                            workspace.toggleComposeMember(recipient)
                        }
                    } else {
                        let results = workspace.composeSearchResults(matching: trimmedQuery)
                        if !results.known.isEmpty {
                            ComposeSectionHeader(title: L10n.string("Contacts"))
                            selectableRows(results.known)
                        }
                        if !results.discovered.isEmpty {
                            ComposeSectionHeader(title: L10n.string("People"))
                            selectableDiscoveredRows(results.discovered)
                        }
                        if UserDiscoveryPresentation.showsNoMatches(
                            results: results,
                            isSearching: workspace.isSearchingPeople
                        ) {
                            ComposeNoMatchesView()
                        }
                        ComposeDiscoveryStatusRow()
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 8)
            }
            .accessibilityIdentifier("compose.members.list")

            GlassSeparator(axis: .horizontal)

            HStack {
                Text(L10n.plural("%lld members", Int64(workspace.newChatRecipients.count)))
                    .wnFont(.medium10)
                    .foregroundStyle(WNColor.backgroundContentSecondary)
                Spacer()
                Button(L10n.string("Next")) {
                    workspace.composeShowNameGroup()
                }
                .nativeGlassProminentButtonStyle()
                .disabled(workspace.newChatRecipients.isEmpty)
                .accessibilityIdentifier("compose.next")
            }
            .padding(12)
        }
        .onExitCommand {
            workspace.composeGoBack()
        }
        .task {
            await workspace.refreshComposeContacts()
        }
    }

    @ViewBuilder
    private func selectableRows(_ contacts: [ComposeContact]) -> some View {
        ForEach(contacts) { contact in
            ComposeContactRow(
                title: contact.title,
                subtitle: contact.subtitle,
                avatarSeed: contact.accountIdHex,
                sanitizedPictureURL: contact.sanitizedPictureURL,
                selection: isSelected(accountIdHex: contact.accountIdHex)
            ) {
                workspace.toggleComposeMember(contact.recipient)
            }
            .accessibilityIdentifier("compose.member.\(contact.accountIdHex)")
        }
    }

    @ViewBuilder
    private func selectableDiscoveredRows(_ people: [DiscoveredPerson]) -> some View {
        ForEach(people) { person in
            DiscoveredPersonRow(
                person: person,
                selection: isSelected(accountIdHex: person.accountIdHex)
            ) {
                workspace.toggleComposeMember(person.recipient)
            }
            .accessibilityIdentifier("compose.member.discovered.\(person.accountIdHex)")
        }
    }

    private func isSelected(accountIdHex: String) -> Bool {
        workspace.newChatRecipients.contains { $0.accountIdHex == accountIdHex }
    }
}

// MARK: - Name group

struct NameGroupPanelView: View {
    @Environment(WorkspaceState.self) private var workspace
    @FocusState private var isNameFocused: Bool

    private var trimmedName: String {
        workspace.newChatName.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        @Bindable var workspace = workspace

        VStack(spacing: 0) {
            ComposePaneHeader(title: L10n.string("Name this group")) {
                workspace.composeGoBack()
            }

            ScrollView {
                VStack(spacing: 16) {
                    groupAvatar
                        .padding(.top, 8)

                    TextField(L10n.string("Group name (required)"), text: $workspace.newChatName)
                        .textFieldStyle(.plain)
                        .wnFont(MessagesType.rowLabel)
                        .focused($isNameFocused)
                        .onSubmit {
                            Task { await workspace.createGroupFromDraft() }
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 9)
                        .glassCard()
                        .overlay {
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                // `borderTertiary` at rest, not `fillTertiary`: a border takes a
                                // border token, and `fillTertiary` is the ghost control's
                                // transparent resting fill — it drew nothing at all here.
                                .stroke(
                                    isNameFocused ? WNColor.borderPrimary : WNColor.borderTertiary,
                                    lineWidth: 1)
                        }
                        .accessibilityIdentifier("compose.groupName")

                    disappearingRow

                    GroupDraftMembersSection()

                    if let lastError = workspace.lastError {
                        Text(lastError)
                            .wnFont(.medium10)
                            .foregroundStyle(WNColor.backgroundContentDestructive)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(12)
            }

            GlassSeparator(axis: .horizontal)

            // Pinned above the button rather than left in the scrolling list: this is the one
            // thing the user must see before pressing Create, and the members list can be
            // scrolled away. It deliberately does *not* live in the button's title — a primary
            // action whose label rewrites itself between presses reads as a different button
            // each time. The first press that meets a refusal fills this in completely and
            // creates nothing, so it is never a partial account of who was left out.
            if !workspace.unreachableDraftMembers.isEmpty || workspace.hasUnnamedGroupDraftRefusal {
                GroupDraftInviteNotice(
                    members: workspace.unreachableDraftMembers,
                    hasUnnamedRefusal: workspace.hasUnnamedGroupDraftRefusal
                )
                .padding(.horizontal, 12)
                .padding(.top, 12)
            }

            HStack {
                Spacer()
                Button {
                    Task { await workspace.createGroupFromDraft() }
                } label: {
                    if workspace.isCreatingChat {
                        HStack(spacing: 6) {
                            ProgressView()
                                .controlSize(.small)
                            Text(L10n.string("Creating..."))
                        }
                    } else {
                        Text(L10n.string("Create"))
                    }
                }
                .nativeGlassProminentButtonStyle()
                .disabled(trimmedName.isEmpty || workspace.isCreatingChat || workspace.reachableDraftMembers.isEmpty)
                .accessibilityIdentifier("compose.create")
            }
            .padding(12)
        }
        .onExitCommand {
            workspace.composeGoBack()
        }
        .task {
            isNameFocused = true
        }
    }

    @ViewBuilder
    private var groupAvatar: some View {
        if trimmedName.isEmpty {
            Image(systemName: "person.2.fill")
                .wnFont(.semiBold32)
                .foregroundStyle(WNColor.backgroundContentSecondary)
                .frame(width: 84, height: 84)
                .background(Circle().fill(WNColor.fillSecondary))
                .overlay(Circle().strokeBorder(WNColor.borderTertiary, lineWidth: 1))
        } else {
            AvatarView(seed: trimmedName, initials: trimmedName, size: 84, isSelected: false)
        }
    }

    private var disappearingRow: some View {
        HStack {
            Text(L10n.string("Disappearing messages"))
                .wnFont(MessagesType.rowLabel)
            Spacer()
            Menu {
                ForEach(DisappearingMessageOption.presets) { option in
                    Button {
                        workspace.groupDraftRetentionSecs = option.seconds
                    } label: {
                        if workspace.groupDraftRetentionSecs == option.seconds {
                            Label(option.label, systemImage: "checkmark")
                        } else {
                            Text(option.label)
                        }
                    }
                }
            } label: {
                Text(DisappearingMessageOption.option(for: workspace.groupDraftRetentionSecs).label)
            }
            .fixedSize()
            .accessibilityIdentifier("compose.disappearing")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .glassCard()
    }

}

// MARK: - Group draft members

/// The chosen members, split by whether the core will accept them. Everyone stays on screen: a
/// member the core refused is dimmed under its own heading rather than dropped, because "who do I
/// still need to invite" is the whole question this panel has to answer.
private struct GroupDraftMembersSection: View {
    @Environment(WorkspaceState.self) private var workspace

    var body: some View {
        let reachable = workspace.reachableDraftMembers
        let unreachable = workspace.unreachableDraftMembers

        VStack(alignment: .leading, spacing: 16) {
            if !reachable.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text(L10n.plural("%lld members", Int64(reachable.count)))
                        .wnFont(MessagesType.sectionHeader)
                        .foregroundStyle(WNColor.backgroundContentSecondary)
                    ForEach(reachable, id: \.accountIdHex) { member in
                        GroupDraftMemberRow(member: member)
                    }
                }
            }

            if !unreachable.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text(L10n.string("Not on White Noise yet"))
                        .wnFont(MessagesType.sectionHeader)
                        .foregroundStyle(WNColor.backgroundContentSecondary)
                    ForEach(unreachable, id: \.accountIdHex) { member in
                        GroupDraftMemberRow(member: member, isExcluded: true)
                    }
                    // The explanation and the invite action live in the pinned footer notice, so
                    // this section stays a plain roster and the two never disagree.
                }
                .accessibilityIdentifier("compose.notOnWhiteNoise")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct GroupDraftMemberRow: View {
    let member: NewChatRecipient
    var isExcluded = false

    var body: some View {
        HStack(spacing: 10) {
            ProfileImageAvatarView(
                seed: member.accountIdHex,
                initials: member.title,
                sanitizedPictureURL: member.sanitizedPictureURL,
                size: 32,
                isSelected: false
            )
            VStack(alignment: .leading, spacing: 1) {
                Text(member.title)
                    .wnFont(MessagesType.rowLabel)
                    .lineLimit(1)
                Text(shortKey(npub: member.npub, hex: member.accountIdHex))
                    .wnFont(MessagesType.meta)
                    .foregroundStyle(WNColor.backgroundContentSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 4)
        // Dimming is how the other clients mark an excluded member, and it carries here without
        // a second colour: the row keeps its own tokens, it just recedes.
        .opacity(isExcluded ? 0.55 : 1)
        .help(isExcluded ? L10n.string("Not on White Noise yet — they won't be added to this group.") : "")
    }
}

/// Why the dimmed members can't join, and the one action that changes it. Also the only place the
/// panel speaks about a refusal it could not pin on anyone: two claims in two styles — a red error
/// line over this notice — read as two different answers about the same draft.
private struct GroupDraftInviteNotice: View {
    let members: [NewChatRecipient]
    /// The core refused someone it did not name and no member could be held responsible.
    var hasUnnamedRefusal = false

    var body: some View {
        // Text block over the action, the shape `PendingGroupInviteComposerNotice` already uses:
        // the compose drawer is narrow, and a button parked beside two wrapping lines squeezes
        // both. `.firstTextBaseline` sits the icon on the headline rather than the box.
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Image(systemName: "person.badge.plus")
                    .wnFont(.semiBold14)
                    .foregroundStyle(WNColor.intentionInfoContent)

                VStack(alignment: .leading, spacing: 3) {
                    Text(headline)
                        .wnFont(.semiBold12)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(L10n.string("Invite them to White Noise, then add them to the group once they're set up."))
                        .wnFont(.medium10)
                        .foregroundStyle(WNColor.backgroundContentSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 0)
            }

            ShareLink(item: WhiteNoiseInvite.message) {
                Text(L10n.string("Invite"))
            }
            .buttonStyle(.wnSecondary)
            .accessibilityIdentifier("compose.invite")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .glassCard()
    }

    private var headline: String {
        // A refusal nobody owned up to outranks the count. It means there is someone here beyond
        // the rows already dimmed above, so a headline claiming a number would be claiming the
        // wrong one — and a count next to "and also someone else" is the pair of answers that made
        // this panel confusing in the first place.
        guard let first = members.first, !hasUnnamedRefusal else {
            return L10n.string("Someone in this group isn't on White Noise yet, so it can't be created.")
        }
        guard members.count > 1 else {
            return String(
                format: L10n.string("%@ isn't on White Noise yet, so they can't be added."),
                first.title)
        }
        return L10n.plural("%lld people here aren't on White Noise yet, so they can't be added.", Int64(members.count))
    }
}

/// The one-to-one counterpart: nothing to restage, so the panel drops the error and offers the
/// invite directly.
private struct StartChatInviteNotice: View {
    let prompt: StartChatInvitePrompt

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Image(systemName: "person.badge.plus")
                    .wnFont(.semiBold14)
                    .foregroundStyle(WNColor.intentionInfoContent)

                Text(prompt.detail)
                    .wnFont(.semiBold12)
                    .fixedSize(horizontal: false, vertical: true)

                Spacer(minLength: 0)
            }

            ShareLink(item: WhiteNoiseInvite.message) {
                Text(L10n.string("Invite"))
            }
            .buttonStyle(.wnSecondary)
            .accessibilityIdentifier("compose.invite")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .glassCard()
        .accessibilityIdentifier("compose.startChatInvite")
    }
}

// MARK: - Shared pieces

private func shortKey(npub: String, hex: String) -> String {
    DisplayText.short(npub.isEmpty ? hex : npub, head: 12, tail: 8)
}

private extension View {
    func debouncedNewChatQueryResolution(for query: String) -> some View {
        modifier(NewChatQueryResolutionModifier(query: query))
    }

    func userDiscovery(for query: String) -> some View {
        modifier(UserDiscoveryModifier(query: query))
    }
}

/// Debounces the *identifier* branch (npub / nprofile / hex / NIP-05 resolution) only. The
/// people-search branch has its own 300 ms debounce inside `scheduleUserDiscovery()`; the two are
/// deliberately separate because they gate mutually exclusive query branches and never both fire
/// for one query. Do not unify them — retuning one would silently retune the other.
private struct NewChatQueryResolutionModifier: ViewModifier {
    @Environment(WorkspaceState.self) private var workspace
    let query: String

    func body(content: Content) -> some View {
        content.task(id: query) {
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard !Task.isCancelled else { return }
            await workspace.resolveNewChatQueryIfReady()
        }
    }
}

/// Kicks off the web-of-trust people search on every query change. The 300 ms debounce lives
/// inside `scheduleUserDiscovery()` (which cancels the previous traversal), not here — see the
/// note on `NewChatQueryResolutionModifier` about keeping the two debounces separate.
private struct UserDiscoveryModifier: ViewModifier {
    @Environment(WorkspaceState.self) private var workspace
    let query: String

    func body(content: Content) -> some View {
        content.task(id: query) {
            workspace.scheduleUserDiscovery()
        }
    }
}

private struct ComposeIdentifierResults: View {
    @Environment(WorkspaceState.self) private var workspace
    private let selection: (NewChatRecipient) -> Bool?
    private let isBusy: (NewChatRecipient) -> Bool
    private let isDisabled: Bool
    private let onPaste: (() -> Void)?
    private let onSelect: (NewChatRecipient) -> Void

    init(
        selection: @escaping (NewChatRecipient) -> Bool? = { _ in nil },
        isBusy: @escaping (NewChatRecipient) -> Bool = { _ in false },
        isDisabled: Bool = false,
        onPaste: (() -> Void)? = nil,
        onSelect: @escaping (NewChatRecipient) -> Void
    ) {
        self.selection = selection
        self.isBusy = isBusy
        self.isDisabled = isDisabled
        self.onPaste = onPaste
        self.onSelect = onSelect
    }

    @ViewBuilder
    var body: some View {
        if workspace.isResolvingNewChat {
            ComposeResolvingRow()
        } else if let recipient = workspace.resolvedNewChatRecipient {
            ComposeContactRow(
                title: recipient.title,
                subtitle: shortKey(npub: recipient.npub, hex: recipient.accountIdHex),
                avatarSeed: recipient.accountIdHex,
                sanitizedPictureURL: recipient.sanitizedPictureURL,
                isBusy: isBusy(recipient),
                selection: selection(recipient)
            ) {
                onSelect(recipient)
            }
            .disabled(isDisabled)
        } else {
            ComposeNoMatchesView(onPaste: onPaste)
        }
    }
}

private struct ComposePaneHeader: View {
    let title: String
    let onBack: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            GlassCircleCloseButton(symbol: "chevron.backward", help: "Back", appearance: .outline, action: onBack)
            Spacer()
        }
        .overlay {
            Text(title)
                .wnFont(MessagesType.paneTitle)
                .lineLimit(1)
        }
        .padding(.horizontal, 12)
        .padding(.top, MessagesLayout.sidebarTitlebarTopPadding)
        .padding(.bottom, 12)
    }
}

private struct ComposeSectionHeader: View {
    let title: String

    var body: some View {
        Text(title)
            .wnFont(MessagesType.sectionHeader)
            .foregroundStyle(WNColor.backgroundContentSecondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.top, 10)
            .padding(.bottom, 2)
    }
}

private struct ComposeActionRow: View {
    let symbol: String
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: symbol)
                    .wnFont(.semiBold14)
                    .frame(width: 32, height: 32)
                    .background(Circle().fill(WNColor.fillSecondary))
                    .overlay(Circle().strokeBorder(WNColor.borderTertiary, lineWidth: 1))
                Text(title)
                    .wnFont(MessagesType.rowLabel)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

private struct ComposeContactRow: View {
    let title: String
    let subtitle: String
    let avatarSeed: String
    let sanitizedPictureURL: URL?
    /// Third line describing where this person came from. Only discovery rows set it.
    var provenance: String?
    var isBusy = false
    /// `nil` hides the selection indicator (tap opens a chat instead of toggling).
    var selection: Bool?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                ProfileImageAvatarView(
                    seed: avatarSeed,
                    initials: title,
                    sanitizedPictureURL: sanitizedPictureURL,
                    size: 36,
                    isSelected: false
                )
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .wnFont(MessagesType.rowLabel)
                        .lineLimit(1)
                    Text(subtitle)
                        .wnFont(MessagesType.meta)
                        .foregroundStyle(WNColor.backgroundContentSecondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if let provenance {
                        Text(provenance)
                            .wnFont(MessagesType.meta)
                            .foregroundStyle(WNColor.backgroundContentTertiary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
                if isBusy {
                    ProgressView()
                        .controlSize(.small)
                } else if let selection {
                    Image(systemName: selection ? "checkmark.circle.fill" : "circle")
                        .wnFont(.medium20)
                        .foregroundStyle(
                            selection
                                ? WNColor.backgroundContentPrimary : WNColor.backgroundContentSecondary)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// A stranger found by the web-of-trust search. Same metrics as `ComposeContactRow` plus a
/// provenance line, because a search result must be visibly distinguishable from a contact.
private struct DiscoveredPersonRow: View {
    let person: DiscoveredPerson
    var isBusy = false
    var selection: Bool?
    let action: () -> Void

    var body: some View {
        ComposeContactRow(
            title: person.title,
            subtitle: person.subtitle,
            avatarSeed: person.accountIdHex,
            sanitizedPictureURL: person.sanitizedPictureURL,
            provenance: UserDiscoveryPresentation.provenanceLabel(radius: person.radius),
            isBusy: isBusy,
            selection: selection,
            action: action
        )
    }
}

/// Searching / partial / failed, never two at once — the resolution lives in
/// `UserDiscoveryPresentation.status` so it is testable without a view.
private struct ComposeDiscoveryStatusRow: View {
    @Environment(WorkspaceState.self) private var workspace

    @ViewBuilder
    var body: some View {
        switch workspace.userDiscoveryStatus {
        case .none:
            EmptyView()
        case .searching:
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text(L10n.string("Searching your network..."))
                    .wnFont(.medium10)
                    .foregroundStyle(WNColor.backgroundContentSecondary)
            }
            .padding(12)
        case .failed:
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle")
                    .foregroundStyle(WNColor.backgroundContentSecondary)
                Text(L10n.string("Search couldn't be completed."))
                    .wnFont(.medium10)
                    .foregroundStyle(WNColor.backgroundContentSecondary)
                Button(L10n.string("Retry")) {
                    workspace.scheduleUserDiscovery()
                }
                .buttonStyle(.link)
            }
            .padding(12)
        case .partial:
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle")
                    .foregroundStyle(WNColor.backgroundContentSecondary)
                Text(L10n.string("Some results may be missing."))
                    .wnFont(.medium10)
                    .foregroundStyle(WNColor.backgroundContentSecondary)
            }
            .padding(12)
        }
    }
}

private struct ComposeResolvingRow: View {
    var body: some View {
        HStack(spacing: 10) {
            ProgressView()
                .controlSize(.small)
            Text(L10n.string("Resolving..."))
                .wnFont(.medium12)
                .foregroundStyle(WNColor.backgroundContentSecondary)
        }
        .padding(12)
    }
}

private struct ComposeNoMatchesView: View {
    var onPaste: (() -> Void)?

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .wnFont(.medium32)
                .foregroundStyle(WNColor.backgroundContentTertiary)
            Text(L10n.string("No matches"))
                .wnFont(.medium12)
                .foregroundStyle(WNColor.backgroundContentSecondary)
            if let onPaste {
                Button(L10n.string("Paste npub"), action: onPaste)
                    .buttonStyle(.link)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 28)
    }
}

private struct MemberChip: View {
    let member: NewChatRecipient
    let onRemove: () -> Void

    var body: some View {
        Button(action: onRemove) {
            HStack(spacing: 5) {
                ProfileImageAvatarView(
                    seed: member.accountIdHex,
                    initials: member.title,
                    sanitizedPictureURL: member.sanitizedPictureURL,
                    size: 18,
                    isSelected: false
                )
                Text(member.title)
                    .wnFont(MessagesType.preview)
                    .lineLimit(1)
                Image(systemName: "xmark")
                    .wnFont(.bold10)
                    .foregroundStyle(WNColor.backgroundContentSecondary)
            }
            .padding(.leading, 4)
            .padding(.trailing, 7)
            .padding(.vertical, 4)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(WNColor.fillSecondary))
            .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .buttonStyle(.plain)
        .help(L10n.string("Remove member"))
    }
}

/// Left-aligned wrapping layout for the selected-member chips.
nonisolated private struct ChipFlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        var widest: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > maxWidth {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            x += size.width + spacing
            widest = max(widest, x - spacing)
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: proposal.width ?? widest, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: .unspecified)
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
