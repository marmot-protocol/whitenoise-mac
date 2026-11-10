import MarmotKit

/// MarmotKit 0.15 treats declining an invite like leaving: an invitee the inviter made an admin must
/// step down first, or `declineGroupInvite` fails with `AdminCannotSelfRemove`. The app asks before
/// sending that step-down, because it is a group change other members see.
nonisolated enum AdminInviteDecline {
    /// Whether declining this invite needs the step-down first. A last admin cannot step down at
    /// all, so it is not offered one MDK would refuse; the decline then reports MDK's refusal.
    static func requiresStepDown(_ state: GroupManagementStateFfi) -> Bool {
        state.requiresSelfDemoteBeforeLeave && state.isSelfAdmin && !state.isLastAdmin
    }

    static var confirmationTitle: String { L10n.string("Step down as admin to decline?") }
    static var confirmationMessage: String {
        L10n.string(
            "You were made an admin of this group. To decline, you'll first step down as admin, which the group's members can see."
        )
    }
    static var confirmAction: String { L10n.string("Step Down and Decline") }
}
