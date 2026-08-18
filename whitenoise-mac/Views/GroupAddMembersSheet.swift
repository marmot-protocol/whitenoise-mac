//
//  GroupAddMembersSheet.swift
//  whitenoise-mac
//
//  A staging picker for inviting people to a group: resolve a NIP-05 / npub / profile link / hex
//  key to a recipient, stage several, then invite them all in one commit.
//

import SwiftUI

struct GroupAddMembersSheet: View {
    @Environment(WorkspaceState.self) private var workspace
    @Environment(\.dismiss) private var dismiss

    let existingMemberIds: Set<String>

    @State private var query = ""
    @State private var staged: [NewChatRecipient] = []
    @State private var isResolving = false
    @State private var resolveError: String?
    /// Who the core refused, said once, under the roster that shows them dimmed.
    @State private var unreachableNotice: String?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            entryField
            if let resolveError {
                Text(resolveError)
                    .wnFont(.medium10)
                    .foregroundStyle(WNColor.backgroundContentDestructive)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 6)
            }
            // Deliberately not the destructive style, and never shown alongside a red line saying
            // something different: who can't be added is an answer, not an error.
            if let unreachableNotice {
                Text(unreachableNotice)
                    .wnFont(.medium10)
                    .foregroundStyle(WNColor.backgroundContentSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 6)
                    .accessibilityIdentifier("addMembers.notOnWhiteNoise")
            }
            Divider()
            stagedList
            Divider()
            footer
        }
        .frame(width: 420, height: 460)
        // A fresh staging session asks the core again rather than inheriting marks from the last
        // sheet, which may have been a different group or a different day.
        .task { workspace.resetInviteRefusals() }
    }

    private var header: some View {
        HStack {
            Text(L10n.string("Add members"))
                .wnFont(.semiBold14)
            Spacer()
            Button(L10n.string("Cancel")) { dismiss() }
                .buttonStyle(.wnSecondary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var entryField: some View {
        HStack(spacing: 10) {
            TextField(L10n.string("NIP-05, npub, profile link, or hex public key"), text: $query)
                .textFieldStyle(.roundedBorder)
                .onSubmit { Task { await resolveAndStage() } }
            Button {
                Task { await resolveAndStage() }
            } label: {
                if isResolving {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "plus")
                }
            }
            .disabled(isResolving || query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .padding(16)
    }

    @ViewBuilder
    private var stagedList: some View {
        if staged.isEmpty {
            VStack(spacing: 6) {
                Image(systemName: "person.2")
                    .wnFont(.medium24)
                    .foregroundStyle(WNColor.backgroundContentTertiary)
                Text(L10n.string("No one added yet"))
                    .wnFont(.medium12)
                    .foregroundStyle(WNColor.backgroundContentSecondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(staged, id: \.accountIdHex) { recipient in
                        recipientRow(recipient)
                        if recipient.accountIdHex != staged.last?.accountIdHex {
                            Divider().padding(.leading, 54)
                        }
                    }
                }
                .padding(.vertical, 4)
            }
        }
    }

    private func recipientRow(_ recipient: NewChatRecipient) -> some View {
        let isExcluded = workspace.unreachableInviteMemberIdHexes.contains(
            recipient.accountIdHex.lowercased())
        return HStack(spacing: 10) {
            ProfileImageAvatarView(
                seed: recipient.accountIdHex,
                initials: recipient.title,
                sanitizedPictureURL: recipient.sanitizedPictureURL,
                size: 32,
                isSelected: false
            )
            VStack(alignment: .leading, spacing: 1) {
                Text(recipient.title)
                    .wnFont(.medium12)
                    .lineLimit(1)
                // The key gives way to the reason: someone who can't be added needs explaining
                // more than they need identifying a second time.
                Text(
                    isExcluded
                        ? L10n.string("Not on White Noise yet")
                        : DisplayText.short(recipient.npub)
                )
                .wnFont(.medium10)
                .foregroundStyle(WNColor.backgroundContentSecondary)
                .lineLimit(1)
            }
            Spacer(minLength: 8)
            Button {
                staged.removeAll { $0.accountIdHex == recipient.accountIdHex }
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(WNColor.backgroundContentSecondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
        // Dimmed rather than dropped, the way the compose panel marks them: "who do I still need to
        // invite" is the question this sheet has to answer.
        .opacity(isExcluded ? 0.55 : 1)
        .help(isExcluded ? L10n.string("Not on White Noise yet — they won't be added to this group.") : "")
    }

    private var footer: some View {
        HStack {
            Spacer()
            Button {
                Task { await inviteStaged() }
            } label: {
                Text(inviteLabel).frame(minWidth: 96)
            }
            .keyboardShortcut(.defaultAction)
            .nativeGlassProminentButtonStyle()
            .disabled(!canInvite || isResolving || workspace.hasInFlightGroupCommit)
        }
        .padding(16)
    }

    private var pendingQuery: Bool {
        !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Staged people the core hasn't refused — the roster an invite would actually carry.
    private var reachableStaged: [NewChatRecipient] {
        workspace.reachableInviteRecipients(staged)
    }

    private var canInvite: Bool {
        !reachableStaged.isEmpty || pendingQuery
    }

    private var inviteLabel: String {
        let count = reachableStaged.count + (pendingQuery && !reachableStaged.isEmpty ? 1 : 0)
        return count <= 1 ? L10n.string("Invite") : String(format: L10n.string("Invite %lld"), count)
    }

    /// Fold in any recipient still typed in the field so a single "Invite" (or Return) works even
    /// when the user didn't press "+" first, then commit. Dismiss only on success.
    private func inviteStaged() async {
        if pendingQuery {
            await resolveAndStage()
            guard resolveError == nil else { return }
        }
        guard !reachableStaged.isEmpty else { return }
        resolveError = nil
        unreachableNotice = nil
        if await workspace.inviteMembers(staged) {
            dismiss()
            return
        }
        // One press learns every refusal, so this names all of them at once — and the plain error
        // line is kept for failures that aren't about who these people are.
        let refused = workspace.unreachableInviteRecipients(staged)
        unreachableNotice = unreachableMessage(for: refused)
        if unreachableNotice == nil {
            resolveError = workspace.lastError ?? L10n.string("Couldn't add members.")
        }
    }

    private func unreachableMessage(for refused: [NewChatRecipient]) -> String? {
        if refused.count > 1 {
            return L10n.plural(
                "%lld people here aren't on White Noise yet, so they can't be added.", Int64(refused.count))
        }
        if let only = refused.first {
            return String(
                format: L10n.string("%@ isn't on White Noise yet, so they can't be added."), only.title)
        }
        guard workspace.hasUnnamedInviteRefusal else { return nil }
        return L10n.string("Someone you picked isn't on White Noise yet, so they can't be added.")
    }

    private func resolveAndStage() async {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isResolving else { return }
        isResolving = true
        resolveError = nil
        defer { isResolving = false }
        do {
            guard let recipient = try await workspace.resolveNewChatRecipient(for: trimmed) else {
                resolveError = L10n.string("Enter a valid NIP-05, npub, profile link, or hex public key.")
                return
            }
            if existingMemberIds.contains(recipient.accountIdHex) {
                resolveError = L10n.string("That person is already in this group.")
                return
            }
            if staged.contains(where: { $0.accountIdHex == recipient.accountIdHex }) {
                query = ""
                return
            }
            staged.append(recipient)
            query = ""
        } catch {
            resolveError = L10n.string("Enter a valid NIP-05, npub, profile link, or hex public key.")
        }
    }
}
