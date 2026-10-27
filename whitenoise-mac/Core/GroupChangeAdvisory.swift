//
//  GroupChangeAdvisory.swift
//  whitenoise-mac
//
//  MDK's advisory refusals of a group change, and the consent-then-retry loop every group
//  change runs through.
//

import Foundation
import MarmotKit
import Observation

/// MDK's advisory refusals of a group change (invite, remove, admin, profile, image, retention,
/// and the step-down before leaving). Messages and leaving are never refused. After the user
/// accepts the risk, one acknowledgement admits one attempt, so the host acknowledges and retries
/// the same change.
nonisolated enum GroupChangeAdvisory: Hashable, Sendable {
    /// History recovery covers this device's epoch: the group may have moved on, and a change from
    /// here could split it.
    case catchingUp
    /// The group's last change is still owed to one of its relays.
    case commitUndelivered

    init?(error: Error) {
        switch error as? MarmotKitError {
        case .GroupCatchingUp: self = .catchingUp
        case .GroupCommitUndelivered: self = .commitUndelivered
        default: return nil
        }
    }

    var title: String {
        switch self {
        case .catchingUp: L10n.string("This chat may be out of date")
        case .commitUndelivered: L10n.string("Last group change not delivered")
        }
    }

    /// Invites get the strongest wording: an invite onto a branch that loses leaves the new member
    /// with an invitation that no longer works.
    func message(isInvite: Bool) -> String {
        switch (self, isInvite) {
        case (.catchingUp, false):
            L10n.string(
                "This device may not have the group's latest changes yet. Changing the group now could split it for everyone. Wait for it to sync, or continue anyway?"
            )
        case (.catchingUp, true):
            L10n.string(
                "This device may not have the group's latest changes yet. Inviting now could split the group for everyone and leave the people you invite with an invitation that no longer works. Wait for it to sync, or continue anyway?"
            )
        case (.commitUndelivered, _):
            L10n.string(
                "The group's last change hasn't reached all of its relays yet. Members who use only those relays may not be able to follow this change. Wait, or continue anyway?"
            )
        }
    }

    /// The note shown when a leave stopped because the user chose Wait on the step-down: about the
    /// group, not "Couldn't leave chat".
    var waitedAlert: ChatActionAlert {
        ChatActionAlert(title: title, message: declinedMessage)
    }

    var declinedMessage: String {
        switch self {
        case .catchingUp: L10n.string("Group not changed. Try again once this chat has synced.")
        case .commitUndelivered:
            L10n.string("Group not changed. Try again once the last change has reached every relay.")
        }
    }
}

/// The user chose to wait rather than accept an advisory refusal. Nothing was published; the
/// description is the note the surface shows in place of an error.
nonisolated struct GroupChangeAdvisoryDeclined: LocalizedError, Equatable {
    let advisory: GroupChangeAdvisory
    var errorDescription: String? { advisory.declinedMessage }
}

nonisolated enum GroupChangeAdvisoryRetry {
    /// Runs `change`; after an advisory refusal, asks for consent, acknowledges and retries. A
    /// change can need both acknowledgements, and each kind is asked at most once per call, so a
    /// refusal that recurs after its acknowledgement is thrown.
    static func perform<Result>(
        _ change: () async throws -> Result,
        consent: (GroupChangeAdvisory) async -> Bool,
        acknowledge: (GroupChangeAdvisory) async throws -> Void
    ) async throws -> Result {
        var acknowledged: Set<GroupChangeAdvisory> = []
        while true {
            do {
                return try await change()
            } catch {
                guard let advisory = GroupChangeAdvisory(error: error), !acknowledged.contains(advisory) else {
                    throw error
                }
                guard await consent(advisory) else { throw GroupChangeAdvisoryDeclined(advisory: advisory) }
                try Task.checkCancellation()
                try await acknowledge(advisory)
                acknowledged.insert(advisory)
            }
        }
    }

    /// The runtime-backed form every group change uses. A `nil` prompter has nobody to ask, so an
    /// advisory refusal is reported as declined rather than acknowledged on the user's behalf.
    /// `consents` carries consent across the several commits one user action can make (an image
    /// swap that also clears a legacy URL, an invite that chases refusals), so the user is asked
    /// once per action rather than once per commit. Each commit is still acknowledged on its own.
    @MainActor
    static func perform<Result>(
        prompter: GroupChangeAdvisoryPrompter?,
        consents: GroupChangeAdvisoryConsents? = nil,
        isInvite: Bool = false,
        runtime: any MarmotRuntime,
        accountRef: String,
        groupIdHex: String,
        _ change: () async throws -> Result
    ) async throws -> Result {
        try await perform(
            change,
            consent: { advisory in
                if consents?.granted.contains(advisory) == true { return true }
                guard let prompter else { return false }
                let approved = await prompter.requestConsent(for: advisory, isInvite: isInvite)
                if approved { consents?.granted.insert(advisory) }
                return approved
            },
            acknowledge: { advisory in
                switch advisory {
                case .catchingUp:
                    _ = try await runtime.acknowledgeGroupCatchingUp(accountRef: accountRef, groupIdHex: groupIdHex)
                case .commitUndelivered:
                    _ = try await runtime.acknowledgeGroupCommitUndelivered(
                        accountRef: accountRef, groupIdHex: groupIdHex)
                }
            }
        )
    }
}

/// Consent given during one user action. See `GroupChangeAdvisoryRetry.perform(prompter:…)`.
@MainActor
final class GroupChangeAdvisoryConsents {
    fileprivate(set) var granted: Set<GroupChangeAdvisory> = []
}

/// Holds the one pending consent request; `groupChangeAdvisoryAlert` renders it. Owned by
/// `AccountScope`, so switching accounts declines whatever the old account was asking.
@MainActor
@Observable
final class GroupChangeAdvisoryPrompter {
    struct Prompt: Identifiable, Equatable {
        let id = UUID()
        let advisory: GroupChangeAdvisory
        let isInvite: Bool
        var title: String { advisory.title }
        var message: String { advisory.message(isInvite: isInvite) }
    }

    private(set) var prompt: Prompt?
    @ObservationIgnored private var continuation: CheckedContinuation<Bool, Never>?

    func requestConsent(for advisory: GroupChangeAdvisory, isInvite: Bool) async -> Bool {
        // A newer request never strands an older waiter.
        cancelPending()
        let prompt = Prompt(advisory: advisory, isInvite: isInvite)
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                self.continuation = continuation
                self.prompt = prompt
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.resolve(id: prompt.id, approved: false) }
        }
    }

    /// Resolves only the prompt it was shown for, so a late dismissal of one alert cannot answer
    /// the next.
    func resolve(id: Prompt.ID, approved: Bool) {
        guard prompt?.id == id, let continuation else { return }
        self.continuation = nil
        prompt = nil
        continuation.resume(returning: approved)
    }

    func cancelPending() {
        if let prompt { resolve(id: prompt.id, approved: false) }
    }
}
