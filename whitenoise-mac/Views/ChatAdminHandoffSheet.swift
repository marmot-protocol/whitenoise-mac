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

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            explanation
            Divider()
            candidateList
            Divider()
            footer
        }
        .frame(width: 420, height: 460)
    }

    private var header: some View {
        HStack {
            Text(L10n.string("Choose a new admin"))
                .wnFont(.semiBold14)
            Spacer()
            Button(L10n.string("Cancel")) { dismiss() }
                .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var explanation: some View {
        Text(target.subject.adminHandoffExplanation)
            .wnFont(.medium12)
            .foregroundStyle(WNColor.backgroundContentSecondary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
    }

    private var candidateList: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(target.candidates) { candidate in
                    ChatAdminHandoffCandidateRow(
                        candidate: candidate,
                        isSelected: candidate.id == selectedMemberId
                    ) {
                        selectedMemberId = candidate.id
                    }

                    if candidate.id != target.candidates.last?.id {
                        Divider().padding(.leading, 54)
                    }
                }
            }
            .padding(.vertical, 4)
        }
    }

    private var footer: some View {
        HStack {
            Spacer()
            Button {
                guard let selectedMember else { return }
                Task { await workspace.confirmChatAdminHandoff(target, successor: selectedMember) }
            } label: {
                Text(L10n.string("Make Admin & Leave")).frame(minWidth: 96)
            }
            .keyboardShortcut(.defaultAction)
            .nativeGlassProminentButtonStyle()
            // Only the leave half is destructive, and it is the half the confirmation below the
            // button already describes — so the affordance stays a plain prominent action rather
            // than shouting at a user whose alternative is being stuck in the group forever.
            .disabled(selectedMember == nil || workspace.hasInFlightGroupCommit)
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
                        .wnFont(.medium12)
                        .lineLimit(1)
                    Text(candidate.detailLabel)
                        .wnFont(.medium10)
                        .foregroundStyle(WNColor.backgroundContentSecondary)
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
