//
//  GroupDisband.swift
//  whitenoise-mac
//
//  The policy for ending a group for everyone ("disbanding" in MDK): where a group stands on the
//  way to ending, whether this account may end it, and how each outcome is worded. Pure values,
//  read by the inspector, the sidebar row and the composer alike, so no surface decides on its own
//  that a group is over.
//

import Foundation
import MarmotKit

/// Where a group stands in its life, as far as anyone using it can tell.
///
/// Folds MDK's `lifecycleState` and `disbanding` into the one question every surface asks — can
/// this group still be used? A disband runs in two stages: the request is accepted and *every*
/// ordinary outbound action stops at once (`.ending`), and the group only reaches its terminal
/// state once the final commit converges (`.ended`). The first stage also covers a disband another
/// admin started, which this account learns about from an inbound candidate.
nonisolated enum GroupLifecycle: Hashable, Sendable {
    case active
    case ending
    case ended

    init(lifecycleState: GroupLifecycleStateFfi, disbanding: Bool) {
        if lifecycleState == .disbanded {
            self = .ended
        } else if disbanding {
            self = .ending
        } else {
            self = .active
        }
    }

    /// The core blocks every send while a group is ending and after it has ended.
    var allowsMessaging: Bool { self == .active }

    /// What stands in for the composer once messaging is over, or `nil` while it is not.
    var composerNotice: String? {
        switch self {
        case .active: nil
        case .ending: L10n.string("This group is ending. New messages are disabled.")
        case .ended: L10n.string("This group has ended. New messages are disabled.")
        }
    }

    /// The capsule a sidebar row wears for this state, or `nil` for an ordinary group.
    var sidebarBadgeLabel: String? {
        switch self {
        case .active: nil
        case .ending: L10n.string("Ending")
        case .ended: L10n.string("Ended")
        }
    }

    var symbolName: String? {
        switch self {
        case .active: nil
        case .ending: "hourglass"
        case .ended: "xmark.circle.fill"
        }
    }
}

/// What the inspector reports about a disband, beyond offering one.
nonisolated enum GroupDisbandStatus: Equatable {
    case none
    /// Accepted and converging. Everything but reading is off.
    case pending
    /// This account's request stopped before the group ended. The user dismisses it.
    case failed(DisbandFailureReasonFfi)
    case disbanded
}

/// Everything about ending one group that a surface needs, lifted out of the FFI records that carry
/// it so the rules below can be evaluated — and tested — without either of them.
nonisolated struct GroupDisbandState: Hashable {
    let lifecycle: GroupLifecycle
    let isSelfAdmin: Bool
    /// Core-computed: the group already carries the lifecycle component, and nothing blocks the
    /// disband itself.
    let canDisband: Bool
    /// Core-computed: an admin may install the lifecycle component, which a group created before
    /// disbanding existed needs before it can be ended. One commit, run on the way to the disband.
    let canEnableDisbanding: Bool
    /// Members whose clients cannot follow a disband, and so must update before it is allowed.
    let blockerCount: Int
    /// This account's own request, while it is outstanding or after it failed.
    let request: DisbandRequestFfi?

    init(
        lifecycle: GroupLifecycle = .active,
        isSelfAdmin: Bool = false,
        canDisband: Bool = false,
        canEnableDisbanding: Bool = false,
        blockerCount: Int = 0,
        request: DisbandRequestFfi? = nil
    ) {
        self.lifecycle = lifecycle
        self.isSelfAdmin = isSelfAdmin
        self.canDisband = canDisband
        self.canEnableDisbanding = canEnableDisbanding
        self.blockerCount = blockerCount
        self.request = request
    }

    /// An ordinary group nobody is ending, and which this account may not end.
    static let inactive = GroupDisbandState()

    /// `group` is the record the details call returns beside the management state. Either may know
    /// about a request first, so a request or a `disbanding` flag on either counts — and a failure
    /// on either wins over a pending request on the other, because the failure is the later fact
    /// and the one the user still has to dismiss.
    init(managementState state: GroupManagementStateFfi, group: AppGroupRecordFfi? = nil) {
        let disbanded = state.lifecycleState == .disbanded || group?.disbanded == true
        let requests = [state.disbandRequest, group?.disbandRequest].compactMap { $0 }
        self.init(
            lifecycle: disbanded
                ? .ended
                : GroupLifecycle(
                    lifecycleState: state.lifecycleState,
                    disbanding: state.disbanding || group?.disbanding == true
                ),
            isSelfAdmin: state.isSelfAdmin,
            canDisband: state.canDisband,
            canEnableDisbanding: state.canEnableDisbanding,
            blockerCount: state.disbandingBlockers.count,
            request: requests.first(where: \.isFailure) ?? requests.first
        )
    }

    /// The order matters: an ended group reports that whatever request preceded it, and a failed
    /// request is reported even while the group still reads as ending, because the failure is the
    /// thing left for the user to act on.
    var status: GroupDisbandStatus {
        if lifecycle == .ended { return .disbanded }
        if case .failed(_, let reason) = request { return .failed(reason) }
        if lifecycle == .ending { return .pending }
        return .none
    }

    /// Whether the End Group action would do anything now — directly, or after enabling the group
    /// for disbanding first.
    var canEndGroup: Bool {
        isSelfAdmin && lifecycle == .active && (canDisband || canEnableDisbanding)
    }

    /// Whether the End Group row belongs on screen at all. Wider than `canEndGroup` on purpose: an
    /// admin held back by members on old clients sees the row disabled, with the reason beneath
    /// it, rather than an inspector that never mentions groups can be ended.
    var showsEndGroup: Bool {
        isSelfAdmin && lifecycle == .active && request == nil
    }

    /// Whether this state already says a request exists — the group is past `.active`, or a
    /// request is on record. Once it does, a request held from elsewhere has nothing left to add.
    var reportsRequest: Bool { lifecycle != .active || request != nil }

    /// This state with `accepted` — the request `disbandGroup` returned — standing in until the
    /// group's own state reports one. MDK accepts durably before its projections catch up, so the
    /// read-back right after the commit can still describe an active group; without this the admin
    /// would be offered End Group again, and a second tap would earn `GroupDisbanding`.
    func merging(request accepted: DisbandRequestFfi?) -> GroupDisbandState {
        guard let accepted, !reportsRequest else { return self }
        return GroupDisbandState(
            // MDK reports failures later, through the group's state, so `disbandGroup` is not
            // expected to return one. The type allows it, though, and a refusal ends nothing: the
            // group stays active and shows the failure instead of claiming to be ending.
            lifecycle: accepted.isFailure ? lifecycle : .ending,
            isSelfAdmin: isSelfAdmin,
            canDisband: false,
            canEnableDisbanding: false,
            blockerCount: blockerCount,
            request: accepted
        )
    }

    /// Why an admin cannot end the group, when the reason is members on old clients — the one
    /// blocker the user can do something about.
    var blockerMessage: String? {
        guard isSelfAdmin, lifecycle == .active, !canEndGroup, blockerCount > 0 else { return nil }
        return GroupDisbandPresentation.updateRequiredMessage(count: blockerCount)
    }
}

nonisolated enum GroupDisbandPresentation {
    static var confirmationTitle: String { L10n.string("End this group?") }

    static var confirmationMessage: String {
        L10n.string(
            "Everyone will be removed and the group will be permanently disbanded. No one will be able to send new messages. This can't be undone."
        )
    }

    static func updateRequiredMessage(count: Int) -> String {
        L10n.plural("%lld members must update White Noise before you can end this group.", Int64(count))
    }

    static func failureMessage(_ reason: DisbandFailureReasonFfi) -> String {
        switch reason {
        case .noLongerAdmin:
            L10n.string("The group wasn't ended because you're no longer an admin.")
        case .noLongerMember:
            L10n.string("The group wasn't ended because you're no longer a member.")
        }
    }

    /// The core's refusals of an End Group, in the user's terms. Anything else keeps its own
    /// description, the way every other group change reports it.
    static func message(for error: Error) -> String {
        switch error as? MarmotKitError {
        case .DisbandingUnsupportedMembers(_, let memberIdsHex):
            updateRequiredMessage(count: memberIdsHex.count)
        case .DisbandingNotEnabled:
            L10n.string("Group ending isn't ready yet. Try again.")
        case .GroupDisbanding:
            L10n.string("This group is ending. New messages are disabled.")
        default:
            error.localizedDescription
        }
    }
}

nonisolated extension DisbandRequestFfi {
    var isFailure: Bool {
        if case .failed = self { return true }
        return false
    }
}

nonisolated extension ChatActionAlert {
    static func endGroupFailed(_ message: String) -> ChatActionAlert {
        ChatActionAlert(title: L10n.string("Couldn't end group"), message: message)
    }

    static func disbandFailureDismissFailed(_ message: String) -> ChatActionAlert {
        ChatActionAlert(title: L10n.string("Couldn't dismiss group status"), message: message)
    }
}
