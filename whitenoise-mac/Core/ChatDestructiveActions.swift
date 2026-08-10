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

    /// The members this account may hand the admin role to on its way out.
    var adminHandoffCandidates: [GroupMemberItem] {
        ChatDestructiveActions.adminHandoffCandidates(from: members)
    }

    /// What the inspector says beneath the leave button. Prefers the handoff hint over the raw
    /// `.lastAdmin` blocker, so a sole admin with someone to promote is told leaving *will* work
    /// rather than that it won't.
    var leaveGuidance: ChatDestructiveActions.LeaveGuidance? {
        ChatDestructiveActions.leaveGuidance(
            membership: selfMembership,
            eligibility: leaveEligibility,
            hasAdminHandoffCandidate: !adminHandoffCandidates.isEmpty
        )
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

/// Chat awaiting the user's choice of a successor admin, because the account leaving it is the
/// group's only admin.
///
/// The candidate roster is resolved once, when the picker opens, and carried here rather than
/// re-derived by the sheet: the sheet is presented from `ContentView` and may outlive the selection
/// of the chat it belongs to, so it cannot read `groupDetailsSnapshot`.
struct ChatAdminHandoffTarget: Equatable, Identifiable {
    let groupIdHex: String
    let title: String
    /// Never empty — a target with no candidate is the genuine dead end, reported as the
    /// `.lastAdmin` blocker instead of opening a picker with nothing in it.
    let candidates: [GroupMemberItem]

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

    /// The admin handoff a leave depends on failed, so the leave was never attempted. Reported
    /// separately from `leaveFailed()` because the two leave the group in different states: this one
    /// left the account exactly where it was, still the sole admin.
    static func adminHandoffFailed() -> ChatActionAlert {
        ChatActionAlert(
            title: L10n.string("Couldn't hand over admin"),
            message: L10n.string("Try again.")
        )
    }

    /// Reports why a leave is unavailable, and nothing more.
    ///
    /// Deliberately offers no local-delete alternative: dropping the local copy while still a
    /// member would leave the rest of the group sending messages to someone who can never read
    /// them, with nothing on the wire to say so.
    ///
    /// Only reached for blockers the app cannot resolve on the user's behalf. A sole admin with a
    /// promotable member never lands here — that case opens the successor picker instead.
    static func leaveBlocked(_ blocker: ChatDestructiveActions.LeaveBlocker) -> ChatActionAlert {
        ChatActionAlert(
            title: L10n.string("Couldn't leave chat"),
            message: blocker.message
        )
    }
}

/// The one status badge a chat row shows, or `nil` for an ordinary active chat.
///
/// Lives beside `ChatDestructiveActions` because the two must agree: the only state that reads as
/// `.leaving` is the only state that offers no destructive action, so a row can never both claim a
/// leave is in progress and offer to leave again — nor, as it used to, show a `.leaving` badge
/// forever while hiding the delete that would clear it.
nonisolated enum ChatRowStatus: Equatable {
    /// A leave the group has not seen yet. Genuinely transient.
    case leaving
    /// The account left or was removed. Terminal.
    case membershipEnded(ChatSelfMembership)
    case pendingInvite

    /// Membership outranks both flags.
    ///
    /// `leaveRequestPending` stays true from the moment the SelfRemove publishes until some
    /// remaining member commits it — possibly never. Reading it first pinned departed chats to a
    /// progress badge they could never leave; reading membership first reports the settled fact and
    /// leaves the outstanding commit as the protocol detail it is (the inspector still lists it).
    ///
    /// An ended membership also supersedes a pending invite, so the row shows a single badge rather
    /// than a contradictory "Invite" + "Removed" pair if the FFI ever delivers both flags together.
    static func status(
        membership: ChatSelfMembership,
        leaveRequestPending: Bool,
        pendingConfirmation: Bool
    ) -> ChatRowStatus? {
        if membership != .member { return .membershipEnded(membership) }
        if leaveRequestPending { return .leaving }
        return pendingConfirmation ? .pendingInvite : nil
    }

    static func status(for chat: ChatItem) -> ChatRowStatus? {
        status(
            membership: chat.selfMembership,
            leaveRequestPending: chat.leaveRequestPending,
            pendingConfirmation: chat.pendingConfirmation
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
        /// that would deplete the admin set, so leaving requires promoting another member first.
        ///
        /// As a *blocker* this is the dead end only: the app resolves the ordinary case itself by
        /// offering the successor picker (`LeaveGuidance.adminHandoffRequired`), so this reaches the
        /// user only when there is nobody to promote — an admin alone in the group, or one whose
        /// only companions the core refuses to let it promote. Hence the wording, which asks for a
        /// member rather than for a promotion.
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
                return L10n.string(
                    "You're the only admin, and there's no one here who can take over. Invite someone before you leave."
                )
            case .unavailable:
                return L10n.string("Leaving isn't available for this chat right now.")
            }
        }

    }

    /// What a surface says about leaving beyond offering the button — the inspector's footer today.
    ///
    /// Distinguishing the two `.lastAdmin` outcomes is the whole point: a sole admin with a
    /// promotable member is not blocked, they are one extra step away, and telling them "you can't
    /// leave" would be wrong.
    enum LeaveGuidance: Equatable {
        /// Leaving cannot proceed, for a reason no action in this app resolves.
        case blocked(LeaveBlocker)
        /// Leaving works, but routes through the successor picker first.
        case adminHandoffRequired

        var message: String {
            switch self {
            case .blocked(let blocker):
                return blocker.message
            case .adminHandoffRequired:
                return L10n.string("You're the only admin. You'll pick who takes over before you leave.")
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
    ///
    /// `leaveRequestPending` only ever suppresses a *second* leave; it never withholds the local
    /// delete. The flag is orthogonal to membership, not a precursor to it: the core sets it when
    /// the SelfRemove is requested and clears it only once a remaining member commits that removal,
    /// which for a group whose others never come back online is never. Gating the delete on it too
    /// stranded every departed chat in a permanent "Leaving" state with no way out — the bug this
    /// split fixes. Once membership has actually ended, the departure is already on the wire and the
    /// local copy is the user's to drop.
    static func action(membership: ChatSelfMembership, leaveRequestPending: Bool) -> Action? {
        guard membership == .member else { return .deleteLocally }
        // Still a member with a request outstanding: the SelfRemove has not reached the group, so
        // neither action is honest yet — the core rejects a repeat leave, and dropping the local
        // copy here is the exact stranding the rule above forbids.
        return leaveRequestPending ? nil : .leave
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

    /// Whether the `.lastAdmin` block is the resolvable kind — the one the successor picker exists
    /// for. `false` for every other blocker, including a `.lastAdmin` with nobody to promote.
    static func offersAdminHandoff(
        _ blocker: LeaveBlocker?,
        hasAdminHandoffCandidate: Bool
    ) -> Bool {
        blocker == .lastAdmin && hasAdminHandoffCandidate
    }

    /// The blocker a surface should explain, refined by whether the app can resolve it in-flow.
    /// `nil` when leaving is plain and needs no explanation.
    static func leaveGuidance(
        membership: ChatSelfMembership,
        eligibility: ChatLeaveEligibility,
        hasAdminHandoffCandidate: Bool
    ) -> LeaveGuidance? {
        guard let blocker = leaveBlocker(membership: membership, eligibility: eligibility) else {
            return nil
        }
        if offersAdminHandoff(blocker, hasAdminHandoffCandidate: hasAdminHandoffCandidate) {
            return .adminHandoffRequired
        }
        return .blocked(blocker)
    }
}

extension ChatDestructiveActions {
    /// The members a departing last admin may hand the admin role to.
    ///
    /// `canPromote` is the core's own verdict on whether the promotion would commit, so it — not the
    /// app's reading of the roster — decides who is offered. A member who is already an admin is
    /// excluded because promoting them changes nothing, and self for the obvious reason. An empty
    /// result means the `.lastAdmin` block is a genuine dead end.
    ///
    /// `@MainActor` rather than `nonisolated` like the rest of this policy: the target builds with
    /// `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`, which isolates `GroupMemberItem`'s members.
    @MainActor
    static func adminHandoffCandidates(from members: [GroupMemberItem]) -> [GroupMemberItem] {
        members.filter { !$0.isSelf && !$0.isAdmin && $0.canPromote }
    }
}
