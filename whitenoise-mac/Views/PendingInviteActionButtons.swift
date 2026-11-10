//
//  PendingInviteActionButtons.swift
//  whitenoise-mac
//
//  The two buttons a pending invite is answered with, shared by the composer
//  prompt and by chat info.
//

import SwiftUI

/// `Accept` on the app's glass beside `Decline` as an outline button, filling the row between them.
///
/// One view for both places an invite can be answered, because it is one decision offered twice —
/// and the two copies drifted every time they were touched separately: different icons, `Accept`
/// against `Accept Invite`, and for a while a destructive `role` on one of the two Declines. What
/// broke visibly was the shape, since only one of them named a radius at all.
///
/// Both sibling clients build this pair the same way, and it is the shape that carries over rather
/// than the metrics: the iOS prototype's `invitationActionBar` puts the two side by side at
/// `.controlSize(.large)` with `.buttonSizing(.flexible)`, and Flutter's `chat_invite_screen.dart`
/// stretches `WnButton(type: .outline)` and a default `WnButton` full width, swapping each label for
/// a spinner while its call is in flight.
///
/// The actions arrive as closures because the two prompts answer different invites: the composer
/// answers the chat it is standing in, chat info answers the details it has open.
struct PendingInviteActionButtons: View {
    @Environment(WorkspaceState.self) private var workspace
    let accept: () async -> Void
    /// Declines; calls the closure it is handed to ask before stepping down as admin
    /// (`AdminInviteDecline`), and answers `false` if the user cancels.
    let decline: (_ confirmAdminStepDown: @escaping @MainActor () async -> Bool) async -> Void
    /// The decline waiting on the admin step-down confirmation, if any.
    @State private var stepDownConfirmation: CheckedContinuation<Bool, Never>?

    var body: some View {
        HStack(spacing: 10) {
            Button {
                Task { await accept() }
            } label: {
                PendingInviteActionLabel(
                    title: L10n.string("Accept"),
                    inFlightTitle: L10n.string("Accepting..."),
                    systemImage: "checkmark.circle",
                    isInFlight: workspace.isAcceptingGroupInvite
                )
            }
            .wnPrimaryButtonStyle()
            .help(L10n.string("Accept invite"))
            .accessibilityIdentifier("invite.accept")

            // No destructive `role`: both sibling clients build Decline as their outline button, and
            // marking it destructive while rendering it secondary is a trap — see the note in
            // `WNSecondaryButtonStyle`, which is deliberately blind to the role.
            Button {
                Task { await decline(askToStepDown) }
            } label: {
                PendingInviteActionLabel(
                    title: L10n.string("Decline"),
                    inFlightTitle: L10n.string("Declining..."),
                    systemImage: "xmark.circle",
                    isInFlight: workspace.isDecliningGroupInvite
                )
            }
            .buttonStyle(.wnSecondary)
            .help(L10n.string("Decline invite"))
            .accessibilityIdentifier("invite.decline")
        }
        .controlSize(.large)
        // Answering is one commit either way, so neither button is offered while the other is
        // waiting on the core.
        .disabled(workspace.isAcceptingGroupInvite || workspace.isDecliningGroupInvite)
        .confirmationDialog(
            AdminInviteDecline.confirmationTitle,
            isPresented: Binding(
                get: { stepDownConfirmation != nil },
                set: { if !$0 { resolveStepDown(false) } }
            ),
            titleVisibility: .visible
        ) {
            Button(AdminInviteDecline.confirmAction, role: .destructive) { resolveStepDown(true) }
            Button(L10n.string("Cancel"), role: .cancel) { resolveStepDown(false) }
        } message: {
            Text(AdminInviteDecline.confirmationMessage)
        }
        // A prompt nobody can answer any more must not hold the decline open.
        .onDisappear { resolveStepDown(false) }
    }

    private func askToStepDown() async -> Bool {
        resolveStepDown(false)
        return await withCheckedContinuation { stepDownConfirmation = $0 }
    }

    private func resolveStepDown(_ confirmed: Bool) {
        guard let continuation = stepDownConfirmation else { return }
        stepDownConfirmation = nil
        continuation.resume(returning: confirmed)
    }
}

/// One button's label: the action's icon, or a spinner in its place once the call is in flight.
///
/// Filling the width it is offered is what makes the pair equal halves of the row — the flexible
/// sizing the prototype gets from `.buttonSizing(.flexible)`. Height is left to each style, so both
/// buttons stand at their natural `.large` height; a `minHeight` on the label used to be added to
/// the outline style's own vertical padding and to nothing on the glass one, which left the pair
/// mismatched in height as well as in shape.
private struct PendingInviteActionLabel: View {
    let title: String
    let inFlightTitle: String
    let systemImage: String
    let isInFlight: Bool

    var body: some View {
        HStack(spacing: 8) {
            if isInFlight {
                ProgressView()
                    .controlSize(.small)
            } else {
                Image(systemName: systemImage)
            }

            Text(isInFlight ? inFlightTitle : title)
        }
        .frame(maxWidth: .infinity)
    }
}
