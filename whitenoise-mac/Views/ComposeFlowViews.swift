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
                        let matches = workspace.filteredComposeContacts(matching: trimmedQuery)
                        if matches.isEmpty {
                            ComposeNoMatchesView(onPaste: pasteIntoSearch)
                        } else {
                            ComposeSectionHeader(title: L10n.string("Contacts"))
                            contactRows(matches)
                        }
                    }

                    if let lastError = workspace.lastError {
                        Text(lastError)
                            .font(.caption)
                            .foregroundStyle(.red)
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
    private var loadingFooter: some View {
        if workspace.isLoadingComposeContacts {
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text(L10n.string("Finding people from your groups..."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
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
                        let matches = workspace.filteredComposeContacts(matching: trimmedQuery)
                        if matches.isEmpty {
                            ComposeNoMatchesView()
                        } else {
                            ComposeSectionHeader(title: L10n.string("Contacts"))
                            selectableRows(matches)
                        }
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 8)
            }
            .accessibilityIdentifier("compose.members.list")

            GlassSeparator(axis: .horizontal)

            HStack {
                Text(L10n.plural("%lld members", Int64(workspace.newChatRecipients.count)))
                    .font(.caption)
                    .foregroundStyle(.secondary)
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
                        .font(MessagesType.rowLabel)
                        .focused($isNameFocused)
                        .onSubmit {
                            Task { await workspace.createGroupFromDraft() }
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 9)
                        .glassCard()
                        .overlay {
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .stroke(isNameFocused ? Color.accentColor : Color.clear, lineWidth: 1)
                        }
                        .accessibilityIdentifier("compose.groupName")

                    disappearingRow

                    VStack(alignment: .leading, spacing: 4) {
                        Text(L10n.plural("%lld members", Int64(workspace.newChatRecipients.count)))
                            .font(MessagesType.sectionHeader)
                            .foregroundStyle(.secondary)
                        ForEach(workspace.newChatRecipients, id: \.accountIdHex) { member in
                            memberRow(member)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    if let lastError = workspace.lastError {
                        Text(lastError)
                            .font(.caption)
                            .foregroundStyle(.red)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(12)
            }

            GlassSeparator(axis: .horizontal)

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
                .disabled(trimmedName.isEmpty || workspace.isCreatingChat)
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
                .font(.system(size: 30, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 84, height: 84)
                .background(Circle().fill(.quaternary))
        } else {
            AvatarView(seed: trimmedName, initials: trimmedName, size: 84, isSelected: false)
        }
    }

    private var disappearingRow: some View {
        HStack {
            Text(L10n.string("Disappearing messages"))
                .font(MessagesType.rowLabel)
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

    private func memberRow(_ member: NewChatRecipient) -> some View {
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
                    .font(MessagesType.rowLabel)
                    .lineLimit(1)
                Text(shortKey(npub: member.npub, hex: member.accountIdHex))
                    .font(MessagesType.meta)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 4)
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
}

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
            GlassCircleCloseButton(symbol: "chevron.backward", help: L10n.string("Back"), action: onBack)
            Spacer()
        }
        .overlay {
            Text(title)
                .font(MessagesType.paneTitle)
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
            .font(MessagesType.sectionHeader)
            .foregroundStyle(.secondary)
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
                    .font(.system(size: 13, weight: .semibold))
                    .frame(width: 32, height: 32)
                    .background(Circle().fill(.quaternary))
                Text(title)
                    .font(MessagesType.rowLabel)
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
                        .font(MessagesType.rowLabel)
                        .lineLimit(1)
                    Text(subtitle)
                        .font(MessagesType.meta)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 0)
                if isBusy {
                    ProgressView()
                        .controlSize(.small)
                } else if let selection {
                    Image(systemName: selection ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 19))
                        .foregroundStyle(selection ? Color.accentColor : Color.secondary)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

private struct ComposeResolvingRow: View {
    var body: some View {
        HStack(spacing: 10) {
            ProgressView()
                .controlSize(.small)
            Text(L10n.string("Resolving..."))
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .padding(12)
    }
}

private struct ComposeNoMatchesView: View {
    var onPaste: (() -> Void)?

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 30))
                .foregroundStyle(.tertiary)
            Text(L10n.string("No matches"))
                .font(.callout)
                .foregroundStyle(.secondary)
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
                    .font(MessagesType.preview)
                    .lineLimit(1)
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.secondary)
            }
            .padding(.leading, 4)
            .padding(.trailing, 7)
            .padding(.vertical, 4)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(.quaternary))
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
