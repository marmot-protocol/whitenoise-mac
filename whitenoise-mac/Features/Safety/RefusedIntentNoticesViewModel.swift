import Foundation
import MarmotKit
import Observation

/// Wording for a send MDK dropped after waiting for its group to settle (MarmotKit 0.15
/// `QueuedIntentRefused`), shared with iOS. Nothing retries it, so the user has to be told.
///
/// Since 0.16.0 a reason of `event_too_large` carries which artifact no relay would take:
/// `.commit` (the change itself is too large for every group relay) or `.welcome` (every inbox
/// relay of the invitee refuses the invitation).
nonisolated enum RefusedIntentPresentation {
    static func title(intentKind: String) -> String {
        switch intentKind {
        case "invite":
            L10n.string("Invitation not sent")
        case "remove_members":
            L10n.string("Member not removed")
        case "update_group_data", "update_app_components":
            L10n.string("Group details not updated")
        case "leave":
            L10n.string("Couldn't leave group")
        case "disband", "enable_disbanding":
            L10n.string("Couldn't end the group")
        case "app_message":
            L10n.string("Message not sent")
        default:
            L10n.string("Group change not made")
        }
    }

    static func message(reason: String, artifact: OversizedArtifactFfi? = nil) -> String {
        switch reason {
        case "event_too_large":
            switch artifact {
            case .welcome:
                L10n.string(
                    "The invitation is too large for this person's inbox relays, so it wasn't sent. Try inviting fewer people at once."
                )
            default:
                L10n.string("This group change is too large for this chat's relays, so it wasn't made.")
            }
        case "not_group_admin":
            L10n.string("You're no longer an admin of this group.")
        case "not_a_member":
            L10n.string("You're no longer a member of this group.")
        default:
            L10n.string("The group changed while this was waiting to send. Check the chat, then try again.")
        }
    }
}

/// Raises a toast when MDK drops a queued send because the settled group refused it.
///
/// MDK can deliver the same refusal more than once, so each intent id is announced once (the last
/// 64 are remembered). Owned by `AccountScope`, so an account switch discards it.
@MainActor
@Observable
final class RefusedIntentNoticesViewModel {
    static let displayDuration: Duration = .seconds(6)
    private static let rememberedIntentLimit = 64

    private(set) var notice: ModerationReportNotice?

    @ObservationIgnored private let accountIdHex: String
    @ObservationIgnored private let runtime: (any MarmotRuntime)?
    @ObservationIgnored private var eventsTask: Task<Void, Never>?
    @ObservationIgnored private var announcedIntentIds: [String] = []

    init(accountIdHex: String, runtime: (any MarmotRuntime)?) {
        self.accountIdHex = accountIdHex.lowercased()
        self.runtime = runtime
    }

    func start() {
        guard eventsTask == nil, let runtime else { return }
        let subscription = runtime.subscribeEvents()
        eventsTask = Task { [weak self] in
            await self?.observe(subscription)
        }
    }

    func stop() {
        eventsTask?.cancel()
        eventsTask = nil
        notice = nil
    }

    func dismissNotice(_ id: ModerationReportNotice.ID) {
        guard notice?.id == id else { return }
        notice = nil
    }

    /// Shows the refusal unless this intent was already announced. Returns whether it was shown.
    @discardableResult
    func announce(
        intentIdHex: String,
        intentKind: String,
        reason: String,
        artifact: OversizedArtifactFfi? = nil
    ) -> Bool {
        let intentId = intentIdHex.lowercased()
        guard !announcedIntentIds.contains(intentId) else { return false }
        announcedIntentIds.append(intentId)
        if announcedIntentIds.count > Self.rememberedIntentLimit {
            announcedIntentIds.removeFirst(announcedIntentIds.count - Self.rememberedIntentLimit)
        }
        notice = ModerationReportNotice(
            kind: .failure,
            title: RefusedIntentPresentation.title(intentKind: intentKind),
            message: RefusedIntentPresentation.message(reason: reason, artifact: artifact)
        )
        return true
    }

    private func observe(_ subscription: EventsSubscription) async {
        guard let runtime else { return }
        while !Task.isCancelled {
            let event: MarmotEventFfi?
            do {
                event = try await runtime.nextEvent(subscription: subscription)
            } catch {
                return
            }
            guard let event else { return }
            if case .groupEvent(let eventAccountIdHex, _, _, let groupEvent) = event,
                eventAccountIdHex.lowercased() == accountIdHex,
                case .queuedIntentRefused(let intentIdHex, let intentKind, let reason, let artifact, _) = groupEvent
            {
                announce(intentIdHex: intentIdHex, intentKind: intentKind, reason: reason, artifact: artifact)
            }
        }
    }
}
