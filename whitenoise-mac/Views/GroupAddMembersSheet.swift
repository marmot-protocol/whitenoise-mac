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

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            entryField
            if let resolveError {
                Text(resolveError)
                    .font(.caption)
                    .foregroundStyle(WNColor.backgroundContentDestructive)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 6)
            }
            Divider()
            stagedList
            Divider()
            footer
        }
        .frame(width: 420, height: 460)
    }

    private var header: some View {
        HStack {
            Text(L10n.string("Add members"))
                .font(.headline)
            Spacer()
            Button(L10n.string("Cancel")) { dismiss() }
                .buttonStyle(.plain)
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
                    .font(.title)
                    .foregroundStyle(WNColor.backgroundContentTertiary)
                Text(L10n.string("No one added yet"))
                    .font(.callout)
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
        HStack(spacing: 10) {
            ProfileImageAvatarView(
                seed: recipient.accountIdHex,
                initials: recipient.title,
                sanitizedPictureURL: recipient.sanitizedPictureURL,
                size: 32,
                isSelected: false
            )
            VStack(alignment: .leading, spacing: 1) {
                Text(recipient.title)
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
                Text(DisplayText.short(recipient.npub))
                    .font(.caption)
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

    private var canInvite: Bool {
        !staged.isEmpty || pendingQuery
    }

    private var inviteLabel: String {
        let count = staged.count + (pendingQuery && !staged.isEmpty ? 1 : 0)
        return count <= 1 ? L10n.string("Invite") : String(format: L10n.string("Invite %lld"), count)
    }

    /// Fold in any recipient still typed in the field so a single "Invite" (or Return) works even
    /// when the user didn't press "+" first, then commit. Dismiss only on success.
    private func inviteStaged() async {
        if pendingQuery {
            await resolveAndStage()
            guard resolveError == nil else { return }
        }
        guard !staged.isEmpty else { return }
        if await workspace.inviteMembers(staged) {
            dismiss()
        } else {
            resolveError = workspace.lastError ?? L10n.string("Couldn't add members.")
        }
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
