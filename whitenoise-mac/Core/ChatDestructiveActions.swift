//
//  ChatDestructiveActions.swift
//  whitenoise-mac
//
//  The single policy for the two destructive chat actions — leaving a chat and deleting its
//  local copy. Both the sidebar row context menu and the group-details inspector evaluate the
//  functions here, so the two surfaces cannot drift apart on when either action is legal.
//

import Foundation
import MarmotKit

/// The eligibility fields any surface needs to decide whether leaving is legal, lifted out of
/// whichever type supplied them.
///
/// The inspector holds a `GroupDetailsSnapshot`; the chat-list path fetches a
/// `GroupManagementStateFfi`. Both project into this one value (see the adapters below), so the
/// rule is evaluated by one implementation rather than by two copies that can drift.
nonisolated struct ChatLeaveEligibility: Equatable {
    /// Core-computed: the account is a member, is *not* an admin, has no leave in flight, and
    /// ordinary group actions are enabled.
    let canLeave: Bool
    /// Core-computed: true for *any* self-admin, **including the last admin**. Not a promise that
    /// self-demotion is legal — always pair it with `isLastAdmin`.
    let requiresSelfDemoteBeforeLeave: Bool
    let leaveRequestPending: Bool
    let isLastAdmin: Bool

    init(
        canLeave: Bool,
        requiresSelfDemoteBeforeLeave: Bool,
        leaveRequestPending: Bool,
        isLastAdmin: Bool
    ) {
        self.canLeave = canLeave
        self.requiresSelfDemoteBeforeLeave = requiresSelfDemoteBeforeLeave
        self.leaveRequestPending = leaveRequestPending
        self.isLastAdmin = isLastAdmin
    }

    nonisolated init(_ state: GroupManagementStateFfi) {
        self.init(
            canLeave: state.canLeave,
            requiresSelfDemoteBeforeLeave: state.requiresSelfDemoteBeforeLeave,
            leaveRequestPending: state.leaveRequestPending,
            isLastAdmin: state.isLastAdmin
        )
    }
}

extension GroupDetailsSnapshot {
    var leaveEligibility: ChatLeaveEligibility {
        ChatLeaveEligibility(
            canLeave: canLeave,
            requiresSelfDemoteBeforeLeave: requiresSelfDemoteBeforeLeave,
            leaveRequestPending: leaveRequestPending,
            isLastAdmin: isLastAdmin
        )
    }

    /// True when the local account left or was removed. Mirrors `ChatItem.isNoLongerMember` so the
    /// inspector and the sidebar row read the same way.
    var isNoLongerMember: Bool { selfMembership != .member }

    /// The destructive action the inspector may offer — the same function the sidebar row uses, so
    /// the two surfaces agree by construction rather than by convention.
    var destructiveAction: ChatDestructiveActions.Action? {
        ChatDestructiveActions.action(
            membership: selfMembership,
            leaveRequestPending: leaveRequestPending
        )
    }

    var leaveBlocker: ChatDestructiveActions.LeaveBlocker? {
        ChatDestructiveActions.leaveBlocker(membership: selfMembership, eligibility: leaveEligibility)
    }
}

/// Chat awaiting a leave confirmation. `requiresSelfDemote` is captured at preparation time so the
/// dialog can say so, and re-derived before the leave actually runs — eligibility can move between
/// the two taps.
nonisolated struct ChatLeaveTarget: Equatable, Identifiable {
    let groupIdHex: String
    let title: String
    let requiresSelfDemote: Bool

    var id: String { groupIdHex }
}

/// Chat awaiting a local-delete confirmation.
nonisolated struct ChatLocalDeleteTarget: Equatable, Identifiable {
    let groupIdHex: String
    let title: String

    var id: String { groupIdHex }
}

/// A destructive chat action's outcome that needs reporting.
nonisolated struct ChatActionAlert: Equatable, Identifiable {
    let title: String
    let message: String

    var id: String { "\(title)\u{1F}\(message)" }

    static func leaveFailed() -> ChatActionAlert {
        ChatActionAlert(
            title: L10n.string("Couldn't leave chat"),
            message: L10n.string("Try again.")
        )
    }

    static func localDeleteFailed() -> ChatActionAlert {
        ChatActionAlert(
            title: L10n.string("Couldn't delete chat"),
            message: L10n.string("Try again.")
        )
    }

    /// Reports why a leave is unavailable, and nothing more.
    ///
    /// Deliberately offers no local-delete alternative: dropping the local copy while still a
    /// member would leave the rest of the group sending messages to someone who can never read
    /// them, with nothing on the wire to say so. The remedy the message names — promote another
    /// member to admin, then leave — keeps the group informed.
    static func leaveBlocked(_ blocker: ChatDestructiveActions.LeaveBlocker) -> ChatActionAlert {
        ChatActionAlert(
            title: L10n.string("Couldn't leave chat"),
            message: blocker.message
        )
    }
}

nonisolated enum ChatDestructiveActions {
    /// The destructive action a surface may offer for one chat. The two are mutually exclusive:
    /// a chat you can still leave is not one you may silently drop from this device.
    enum Action: Equatable {
        case leave
        case deleteLocally
    }

    /// Why leaving is unavailable. `nil` from `leaveBlocker(membership:eligibility:)` means
    /// leaving is available.
    enum LeaveBlocker: Equatable {
        /// A leave is already in flight; the core would reject a second one with
        /// `MarmotKitError.LeaveAlreadyRequested`.
        case pending
        /// The account is the group's only admin. MIP-03 §149/§150 forbids an admin self-removal
        /// that would deplete the admin set, so no sequence of actions lets this account leave —
        /// another member must be promoted to admin first.
        case lastAdmin
        /// Ordinary group actions are disabled (the group is disbanding, or its lifecycle is
        /// terminal). Reachable from remote admin action even though this app never initiates a
        /// disband itself.
        case unavailable

        var message: String {
            switch self {
            case .pending:
                return L10n.string(
                    "Your leave request is pending. This conversation will update when the group commits it."
                )
            case .lastAdmin:
                return L10n.string("You're the only admin. Make another member an admin before you leave.")
            case .unavailable:
                return L10n.string("Leaving isn't available for this chat right now.")
            }
        }

    }

    /// Which destructive action a surface may offer, from membership alone.
    ///
    /// **Membership is the whole rule, on every surface.** A local delete is only ever offered once
    /// the account has actually left or been removed. Offering it earlier — say as a fallback when
    /// leaving is blocked — would let someone drop a chat locally while the group still counts them
    /// as a member, so the others keep sending messages nobody will ever read and get no signal that
    /// happened. Leaving is the only way out of a group, and it is a group commit precisely so the
    /// rest of the group learns about it.
    ///
    /// A `ChatListRowFfi`-derived `ChatItem` carries membership but not `canLeave` / `isLastAdmin`,
    /// and a SwiftUI `contextMenu` cannot await an FFI call to find out — so both surfaces offer
    /// `.leave` for a member and report a `leaveBlocker` if leaving turns out to be unavailable. The
    /// inspector, which holds eligibility up front, pre-disables the button and shows the blocker as
    /// a footer instead.
    static func action(membership: ChatSelfMembership, leaveRequestPending: Bool) -> Action? {
        guard !leaveRequestPending else { return nil }
        return membership == .member ? .leave : .deleteLocally
    }

    static func action(for chat: ChatItem) -> Action? {
        action(membership: chat.selfMembership, leaveRequestPending: chat.leaveRequestPending)
    }

    /// Whether a leave would do anything, counting the self-demote-first path as available.
    static func canLeave(_ eligibility: ChatLeaveEligibility) -> Bool {
        eligibility.canLeave || shouldSelfDemoteBeforeLeave(eligibility)
    }

    /// Whether leaving must step the account down as admin first.
    ///
    /// `requiresSelfDemoteBeforeLeave` is true for the last admin too, but the core rejects that
    /// self-removal, so the `!isLastAdmin` conjunct is load-bearing: without it this would fire a
    /// `selfDemoteAdminDetailed` the core is guaranteed to refuse.
    static func shouldSelfDemoteBeforeLeave(_ eligibility: ChatLeaveEligibility) -> Bool {
        eligibility.requiresSelfDemoteBeforeLeave
            && !eligibility.isLastAdmin
            && !eligibility.leaveRequestPending
    }

    /// Why leaving is unavailable, or `nil` when it is available. Rendered as the inspector's
    /// footer and as the row menu's post-tap alert message, so both surfaces explain the same rule
    /// in the same words. `nil` for a non-member: there is nothing left to leave.
    static func leaveBlocker(
        membership: ChatSelfMembership,
        eligibility: ChatLeaveEligibility
    ) -> LeaveBlocker? {
        guard membership == .member else { return nil }
        if eligibility.leaveRequestPending { return .pending }
        if canLeave(eligibility) { return nil }
        return eligibility.isLastAdmin ? .lastAdmin : .unavailable
    }
}
