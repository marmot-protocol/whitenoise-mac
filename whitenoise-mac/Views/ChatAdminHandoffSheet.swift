//
//  ChatAdminHandoffSheet.swift
//  whitenoise-mac
//
//  The successor picker a sole admin sees instead of a dead end when they leave a group.
//
//  MIP-03 forbids an admin self-removal that would empty the admin set, so the last admin of a
//  group genuinely cannot leave it as-is. The app used to stop there and say so, leaving the user to
//  work out that the fix was to open the member list, promote somebody, and try again. This sheet is
//  that fix, made into one step: pick who takes over, and the promotion and the leave run together.
//

import SwiftUI

struct ChatAdminHandoffSheet: View {
    @Environment(WorkspaceState.self) private var workspace
    @Environment(\.endingGroupIds) private var endingGroupIds
    @Environment(\.isBulkLeavingChats) private var isBulkLeavingChats
    @Environment(SessionState.self) private var session
    @Environment(\.dismiss) private var dismiss

    let target: ChatAdminHandoffTarget

    /// Seeded from `preselectedSuccessorId`, which is the sole candidate when there is only one and
    /// nothing otherwise: with a real choice on offer, handing someone the admin role is
    /// consequential, and a default would let a distracted return-press pick for them.
    @State private var selectedMemberId: String?

    init(target: ChatAdminHandoffTarget) {
        self.target = target
        _selectedMemberId = State(initialValue: target.preselectedSuccessorId)
    }

    private var selectedMember: GroupMemberItem? {
        target.candidates.first { $0.id == selectedMemberId }
    }

    private var isGroupCommitInFlight: Bool {
        GroupCommitGuard.isInFlight(
            workspace: workspace, endingGroupIds: endingGroupIds, isBulkLeavingChats: isBulkLeavingChats)
    }

    var body: some View {
        VStack(spacing: 0) {
            ChatAdminHandoffHeader()
            Divider()
            ChatAdminHandoffExplanation(text: target.subject.adminHandoffExplanation)
            Divider()
            ChatAdminHandoffCandidateList(
                candidates: target.candidates,
                selectedMemberId: $selectedMemberId
            )
            Divider()
            ChatAdminHandoffFooter(
                isConfirmDisabled: selectedMember == nil || isGroupCommitInFlight,
                onCancel: { dismiss() },
                onConfirm: {
                    guard let selectedMember else { return }
                    // The handoff closes this sheet as it starts, so a consent prompt is asked from the
                    // window, through the account's shared prompter.
                    let advisory = session.accountScope?.groupChangeAdvisory
                    Task {
                        await workspace.confirmChatAdminHandoff(target, successor: selectedMember, advisory: advisory)
                    }
                }
            )
        }
        .frame(width: 420, height: 460)
    }
}

private struct ChatAdminHandoffHeader: View {
    var body: some View {
        HStack {
            Text(L10n.string("Choose a new admin"))
                .font(.headline)
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }
}

private struct ChatAdminHandoffExplanation: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
    }
}

private struct ChatAdminHandoffCandidateList: View {
    let candidates: [GroupMemberItem]
    @Binding var selectedMemberId: String?

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(candidates) { candidate in
                    ChatAdminHandoffCandidateRow(
                        candidate: candidate,
                        isSelected: candidate.id == selectedMemberId
                    ) {
                        selectedMemberId = candidate.id
                    }

                    if candidate.id != candidates.last?.id {
                        Divider().padding(.leading, 54)
                    }
                }
            }
            .padding(.vertical, 4)
        }
    }
}

private struct ChatAdminHandoffFooter: View {
    let isConfirmDisabled: Bool
    let onCancel: () -> Void
    let onConfirm: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Spacer()
            Button(L10n.string("Cancel"), role: .cancel, action: onCancel)
                .wnSecondaryButtonStyle()
                .keyboardShortcut(.cancelAction)

            Button(action: onConfirm) {
                Text(L10n.string("Make Admin & Leave")).frame(minWidth: 96)
            }
            .keyboardShortcut(.defaultAction)
            .wnPrimaryButtonStyle()
            // Only the leave half is destructive, and it is the half the confirmation below the
            // button already describes — so the affordance stays a plain prominent action rather
            // than shouting at a user whose alternative is being stuck in the group forever.
            .disabled(isConfirmDisabled)
        }
        .padding(16)
    }
}

/// One selectable successor. Mirrors `GroupMemberRow`'s identity presentation — same avatar seed,
/// same nickname-aware `displayName`, same `detailLabel` — so the person picked here is recognisably
/// the person seen in the member list.
private struct ChatAdminHandoffCandidateRow: View {
    let candidate: GroupMemberItem
    let isSelected: Bool
    let select: () -> Void

    var body: some View {
        Button(action: select) {
            HStack(spacing: 10) {
                AvatarView(
                    seed: candidate.id,
                    initials: candidate.initials,
                    size: 32,
                    isSelected: false
                )

                VStack(alignment: .leading, spacing: 1) {
                    Text(candidate.displayName)
                        .font(.body)
                        .lineLimit(1)
                    Text(candidate.detailLabel)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 8)

                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(
                        isSelected ? WNColor.fillPrimary : WNColor.backgroundContentTertiary
                    )
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }
}

#Preview("Admin handoff") {
    let candidate = GroupMemberItem(
        id: "bob",
        displayName: "Bob",
        publishedDisplayName: nil,
        profileName: "Bob",
        npub: "npub1bob",
        accountLabel: nil,
        isLocal: false,
        isAdmin: false,
        isSelf: false,
        canRemove: true,
        canPromote: true,
        canDemote: false
    )
    ChatAdminHandoffSheet(
        target: ChatAdminHandoffTarget(
            groupIdHex: "group",
            subject: .namedGroup("Design Crew"),
            candidates: [candidate]
        )
    )
    .environment(WorkspaceState.preview())
    .environment(SessionState())
}
