//
//  GroupAddMembersSheet.swift
//  whitenoise-mac
//
//  A staging picker for inviting people to a group. It runs the same people search as the
//  compose flow's Choose members — contacts by name, people discovered through your network, or a
//  pasted NIP-05 / npub / profile link — then invites everyone staged in one commit.
//

import SwiftUI

struct GroupAddMembersSheet: View {
    @Environment(WorkspaceState.self) private var workspace
    @Environment(\.dismiss) private var dismiss
    /// Owned and hosted here: the window cannot show an alert from under this sheet.
    @State private var advisory = GroupChangeAdvisoryPrompter()

    let existingMemberIds: Set<String>
    /// Whether the account blocked this account id hex. A blocked person is refused at Invite.
    let isBlocked: (String) -> Bool

    @State private var staged: [NewChatRecipient] = []
    @State private var inviteError: String?
    /// Who the core refused, said once, under the chips that show them dimmed.
    @State private var unreachableNotice: String?
    /// Invite is resolving a typed identifier. The fold-in resolves off the field's own lookup, so
    /// `isResolvingNewChat` doesn't cover it; this keeps a second press from inviting twice.
    @State private var isFoldingIdentifier = false
    /// The Invite press in flight. Cancelled when the sheet goes away: a press resolving an
    /// identifier outlives the sheet, and must not commit for a user who pressed Cancel or Escape
    /// meanwhile. Once `inviteMembers` is running the commit is already on its way, and the
    /// cancellation doesn't stop it.
    @State private var inviteTask: Task<Void, Never>?

    private var lockedMemberIds: Set<String> {
        Set(existingMemberIds.map { $0.lowercased() })
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            VStack(spacing: 10) {
                // Off `lastError`: the group details pane behind the sheet renders it for its own
                // actions, so the search field must not paint a red line there, nor wipe one.
                // Invite itself still goes through `inviteMembers`, which does both; that goes
                // away with `lastError` as a global channel.
                MemberSearchField(accessibilityIdentifier: "addMembers.search", reportsErrors: false)
                    // Invite has committed to the text it is resolving; an edit now would be
                    // ambiguous between "invite that one too" and "not that one". Focus comes back
                    // when the resolve ends, so an error can be fixed in place.
                    .disabled(isFoldingIdentifier)
                if !staged.isEmpty {
                    SelectedMemberChips(members: staged, isDimmed: isUnreachable) { member in
                        staged.removeAll { $0.accountIdHex == member.accountIdHex }
                    }
                }
            }
            .padding(16)
            if let inviteError {
                Text(inviteError)
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
            MemberSearchResults(
                listAccessibilityIdentifier: "addMembers.list",
                isSelected: { hex in staged.contains { $0.accountIdHex == hex } },
                isLocked: { lockedMemberIds.contains($0.lowercased()) },
                onToggle: toggle
            )
            Divider()
            footer
        }
        .frame(width: 420, height: 520)
        // A fresh staging session asks the core again rather than inheriting marks from the last
        // sheet, which may have been a different group or a different day. The search starts empty
        // and is released on close, so no traversal outlives the sheet.
        .task {
            workspace.resetInviteRefusals()
            workspace.clearComposeSearch(preservingLastError: true)
            await workspace.refreshComposeContacts()
        }
        .groupChangeAdvisoryAlert(advisory)
        .onDisappear {
            advisory.cancelPending()
            inviteTask?.cancel()
            workspace.clearComposeSearch(preservingLastError: true)
        }
        // The error was about the text it was raised for; editing that text retires it.
        .onChange(of: workspace.newChatQuery) { inviteError = nil }
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

    private var footer: some View {
        HStack {
            Spacer()
            Button {
                inviteTask = Task { await inviteStaged() }
            } label: {
                Text(inviteLabel).frame(minWidth: 96)
            }
            .keyboardShortcut(returnInvites ? .defaultAction : nil)
            .nativeGlassProminentButtonStyle()
            .disabled(
                (reachableStaged.isEmpty && pendingIdentifier == nil)
                    || workspace.hasInFlightGroupCommit
                    || workspace.isResolvingNewChat
                    || isFoldingIdentifier)
        }
        .padding(16)
    }

    /// Staged people the core hasn't refused — the roster an invite would actually carry.
    private var reachableStaged: [NewChatRecipient] {
        workspace.reachableInviteRecipients(staged)
    }

    /// A pasted npub / NIP-05 / profile link / hex key still in the field. Invite folds it in, so
    /// one press works without clicking the resolved row first. A name search is not one: there is
    /// nothing to resolve, so it never enables Invite on its own.
    private var pendingIdentifier: String? {
        let query = workspace.newChatQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        return !query.isEmpty && workspace.looksLikeMemberRef(query) ? query : nil
    }

    private var returnInvites: Bool {
        let query = workspace.newChatQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        return GroupInviteStaging.returnInvites(query: query, isIdentifier: pendingIdentifier != nil)
    }

    private var inviteLabel: String {
        let pendingAddsOne = GroupInviteStaging.pendingIdentifierAddsOne(
            isIdentifier: pendingIdentifier != nil,
            resolved: workspace.resolvedNewChatRecipient,
            to: staged,
            lockedMemberIds: lockedMemberIds,
            isBlocked: isBlocked
        )
        let count = reachableStaged.count + (pendingAddsOne && !reachableStaged.isEmpty ? 1 : 0)
        return count <= 1 ? L10n.string("Invite") : String(format: L10n.string("Invite %lld"), count)
    }

    private func isUnreachable(_ recipient: NewChatRecipient) -> Bool {
        workspace.unreachableInviteMemberIdHexes.contains(recipient.accountIdHex.lowercased())
    }

    private func toggle(_ recipient: NewChatRecipient) {
        if staged.contains(where: { $0.accountIdHex == recipient.accountIdHex }) {
            staged.removeAll { $0.accountIdHex == recipient.accountIdHex }
        } else {
            staged.append(recipient)
            // As `toggleComposeMember` does: the field is ready for the next paste.
            workspace.clearComposeSearch(preservingLastError: true)
        }
    }

    /// Fold in an identifier still typed in the field, then commit. Dismiss only on success.
    private func inviteStaged() async {
        let query = workspace.newChatQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        let isIdentifier = pendingIdentifier != nil
        guard !isFoldingIdentifier else { return }
        if isIdentifier { inviteError = nil }
        isFoldingIdentifier = true
        // Pressed inside the field's 250 ms debounce, this resolve and the field's own lookup both
        // run for the same text: two `refreshProfile` round-trips. Deliberate. Invalidating the
        // field's lookup wouldn't stop it (the debounced lookup hasn't started, so it starts after
        // the invalidate), and resolving through the field's generation would let that lookup
        // steal it and fold in nobody.
        let outcome = await GroupInviteStaging.foldPending(
            query: query,
            isIdentifier: isIdentifier,
            resolved: workspace.resolvedNewChatRecipient,
            // Leaves the field's lookup state and `lastError` alone.
            resolve: { try? await workspace.resolveNewChatRecipient(for: $0) },
            into: { staged },
            lockedMemberIds: lockedMemberIds,
            isBlocked: isBlocked,
            shouldCommit: { !Task.isCancelled }
        )
        isFoldingIdentifier = false
        guard case .staged(let roster) = outcome else {
            inviteError = outcome.errorMessage
            return
        }
        if isIdentifier {
            staged = roster
            // The field is disabled while the identifier resolves, but a result row picked meanwhile
            // clears it; only clear the text this press folded in.
            if workspace.newChatQuery.trimmingCharacters(in: .whitespacesAndNewlines) == query {
                workspace.clearComposeSearch(preservingLastError: true)
            }
        }
        guard !reachableStaged.isEmpty else { return }
        inviteError = nil
        unreachableNotice = nil
        // `inviteMembers` can refuse before it clears `lastError`, which may still hold the group
        // pane's own error; only an error this press raised is the sheet's to show.
        let errorBefore = workspace.lastError
        if await workspace.inviteMembers(staged, advisory: advisory) {
            dismiss()
            return
        }
        // One press learns every refusal, so this names all of them at once — and the plain error
        // line is kept for failures that aren't about who these people are.
        let refused = workspace.unreachableInviteRecipients(staged)
        unreachableNotice = unreachableMessage(for: refused)
        if unreachableNotice == nil {
            let raised = workspace.lastError != errorBefore ? workspace.lastError : nil
            inviteError = raised ?? L10n.string("Couldn't add members.")
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
}

#Preview {
    GroupAddMembersSheet(existingMemberIds: [], isBlocked: { _ in false })
        .environment(WorkspaceState.preview())
        .environment(SessionState())
}
