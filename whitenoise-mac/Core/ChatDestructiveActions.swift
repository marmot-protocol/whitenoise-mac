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

    /// The destructive action the inspector may offer — the same policy the sidebar row uses, so
    /// the two surfaces agree by construction rather than by convention. The inspector holds the
    /// roster and eligibility up front, so it takes the refined form: an account alone in a chat it
    /// cannot leave is offered the local delete directly, rather than a Leave button whose only
    /// possible outcome is an explanation.
    var destructiveAction: ChatDestructiveActions.Action? {
        ChatDestructiveActions.action(
            membership: selfMembership,
            leaveRequestPending: leaveRequestPending,
            leaveBlocker: leaveBlocker,
            lastAdminResolution: lastAdminResolution
        )
    }

    var leaveBlocker: ChatDestructiveActions.LeaveBlocker? {
        ChatDestructiveActions.leaveBlocker(membership: selfMembership, eligibility: leaveEligibility)
    }

    /// The members this account may hand the admin role to on its way out.
    var adminHandoffCandidates: [GroupMemberItem] {
        ChatDestructiveActions.adminHandoffCandidates(from: members)
    }

    /// How a `.lastAdmin` block on this chat resolves. Read even when the account is not blocked —
    /// the functions taking it ignore it unless the blocker is actually `.lastAdmin`.
    var lastAdminResolution: ChatDestructiveActions.LastAdminResolution {
        ChatDestructiveActions.lastAdminResolution(members: members)
    }

    /// What the inspector says beneath the leave button. Prefers the resolution over the raw
    /// `.lastAdmin` blocker, so a sole admin who can still get out — by promoting someone, or by
    /// dropping the local copy of a chat nobody else is in — is told what to do rather than that
    /// they are stuck.
    var leaveGuidance: ChatDestructiveActions.LeaveGuidance? {
        ChatDestructiveActions.leaveGuidance(
            membership: selfMembership,
            eligibility: leaveEligibility,
            lastAdminResolution: lastAdminResolution
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

    /// The successor the picker opens with already chosen, or `nil` when there is a choice to make.
    ///
    /// One candidate is not a choice. The core has named exactly one member this account may hand
    /// the role to, so the click that selects them carries no decision — it is a step between the
    /// user and the only way out of the group they have. Preselecting it makes the sheet what it
    /// actually is at that point: a confirmation.
    ///
    /// From two candidates up, nothing is preselected on purpose — see the `selectedMemberId`
    /// comment in `ChatAdminHandoffSheet`.
    var preselectedSuccessorId: String? {
        candidates.count == 1 ? candidates.first?.id : nil
    }
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
        /// As a *blocker* this is the dead end only, and the dead end is now narrow: the app
        /// resolves both ordinary cases itself, offering the successor picker
        /// (`LeaveGuidance.adminHandoffRequired`) when someone can take the role over and the local
        /// delete (`LeaveGuidance.localDeleteInstead`) when nobody else is in the group at all. What
        /// is left — the only shape that reaches the user — is a sole admin whose companions the
        /// core refuses to let it promote. Hence the wording, which asks for a member rather than
        /// for a promotion: the members present are unusable as successors.
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

    /// How a `.lastAdmin` leave block resolves, decided from the roster the block applies to.
    ///
    /// The core reports one flag for three quite different situations, and conflating them is what
    /// produced the dead end this type exists to remove — a user alone in a chat, told to invite
    /// someone before leaving.
    enum LastAdminResolution: Equatable {
        /// Someone else may take the admin role: promote them, then leave. The group survives and
        /// the departure still reaches it, which is why this is preferred whenever it is available.
        case handOffAdmin
        /// Nobody else is in the group at all, so there is no successor to promote *and* nobody the
        /// leave would inform. See `action(membership:leaveRequestPending:leaveBlocker:lastAdminResolution:)`
        /// for why the local delete is safe here and nowhere else.
        case deleteLocally
        /// Others remain, but the core will not let this account promote any of them — the genuine
        /// dead end, and the only one reported as a `.lastAdmin` blocker.
        case blocked
    }

    /// What a surface says about leaving beyond offering the button — the inspector's footer today.
    ///
    /// Distinguishing the `.lastAdmin` outcomes is the whole point: a sole admin with a promotable
    /// member is not blocked, they are one extra step away, and a sole admin with nobody left at all
    /// is not blocked either — they need a different action. Telling either "you can't leave" would
    /// be wrong.
    enum LeaveGuidance: Equatable {
        /// Leaving cannot proceed, for a reason no action in this app resolves.
        case blocked(LeaveBlocker)
        /// Leaving works, but routes through the successor picker first.
        case adminHandoffRequired
        /// Leaving is impossible and pointless — nobody else is in the chat — so the surface offers
        /// the local delete in its place.
        case localDeleteInstead

        var message: String {
            switch self {
            case .blocked(let blocker):
                return blocker.message
            case .adminHandoffRequired:
                return L10n.string("You're the only admin. You'll pick who takes over before you leave.")
            case .localDeleteInstead:
                return L10n.string(
                    "You're the only one left in this chat, so there's no one to hand admin to. Remove it from this device to close it out."
                )
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

    /// The roster-aware refinement, for surfaces holding eligibility and the roster up front — the
    /// inspector today.
    ///
    /// It can only ever turn `.leave` into `.deleteLocally`, and only for the one shape where the
    /// rule above has nothing left to protect: an account the core refuses to let leave *because it
    /// is the last admin*, in a group where it is also the last member. Leaving is otherwise the
    /// only way out precisely so the rest of the group learns this account stopped reading — but
    /// here there is no rest of the group to tell, and no leave the core will accept. The local
    /// delete strands nobody, and it is the only way to close the chat out.
    ///
    /// Every other blocker keeps the plain answer. In particular `.blocked` — others present, none
    /// promotable — stays a `.leave`, because those others *would* be stranded.
    static func action(
        membership: ChatSelfMembership,
        leaveRequestPending: Bool,
        leaveBlocker: LeaveBlocker?,
        lastAdminResolution: LastAdminResolution
    ) -> Action? {
        let action = action(membership: membership, leaveRequestPending: leaveRequestPending)
        guard action == .leave,
            leaveBlocker == .lastAdmin,
            lastAdminResolution == .deleteLocally
        else { return action }
        return .deleteLocally
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

    /// The blocker a surface should explain, refined by whether the app can resolve it in-flow.
    /// `nil` when leaving is plain and needs no explanation.
    ///
    /// `.lastAdmin` is the only blocker a roster can say anything about: a pending leave and a
    /// disabled group are unaffected by who else is present, so `lastAdminResolution` is ignored for
    /// them rather than allowed to invent a way out they don't have.
    static func leaveGuidance(
        membership: ChatSelfMembership,
        eligibility: ChatLeaveEligibility,
        lastAdminResolution: LastAdminResolution
    ) -> LeaveGuidance? {
        guard let blocker = leaveBlocker(membership: membership, eligibility: eligibility) else {
            return nil
        }
        guard blocker == .lastAdmin else { return .blocked(blocker) }

        switch lastAdminResolution {
        case .handOffAdmin: return .adminHandoffRequired
        case .deleteLocally: return .localDeleteInstead
        case .blocked: return .blocked(.lastAdmin)
        }
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

    /// True when nobody but this account is left in the group — the last member of a group everyone
    /// else left, or the remaining half of a DM whose peer is gone.
    ///
    /// Asks whether any *other* member exists rather than comparing a count, so an empty roster
    /// answers true as well: a group with nobody in it has nobody to strand either, and the exotic
    /// case where the core returns no members at all should not fall through to the dead end.
    @MainActor
    static func isSoleRemainingMember(_ members: [GroupMemberItem]) -> Bool {
        !members.contains { !$0.isSelf }
    }

    /// Which way out of a `.lastAdmin` block this roster allows.
    ///
    /// Handing the role over comes first whenever it is possible: it keeps the group alive and puts
    /// the departure on the wire, which the local delete cannot do. Only once there is no successor
    /// does being alone matter — and being alone is checked *specifically*, not inferred from the
    /// candidate list being empty. The two are not the same thing: a sole admin whose companions the
    /// core refuses to promote also has no candidates, and dropping the local copy there would
    /// strand the members still in the group.
    @MainActor
    static func lastAdminResolution(members: [GroupMemberItem]) -> LastAdminResolution {
        if !adminHandoffCandidates(from: members).isEmpty { return .handOffAdmin }
        return isSoleRemainingMember(members) ? .deleteLocally : .blocked
    }
}
