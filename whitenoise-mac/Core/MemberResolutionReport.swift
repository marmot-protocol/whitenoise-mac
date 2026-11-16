//
//  MemberResolutionReport.swift
//  whitenoise-mac
//
//  What a create or invite did with each person it was asked to add.
//

import Foundation
import MarmotKit

/// The members a create or invite left out, read from MDK's per-account `memberOutcomes`.
///
/// Since MarmotKit 0.17 a create or invite goes ahead with the members MDK can reach and reports
/// every requested account's outcome, in request order, instead of failing on the first one it
/// cannot. There is no all-or-nothing mode over the FFI, so the app cannot learn who is
/// unreachable before it commits: when anyone is available the group is created (or the invite
/// sent) with them, and this report names the rest afterwards. When nobody is, nothing is created,
/// and the report is what the compose panel or the add-members sheet marks.
nonisolated struct MemberResolutionReport: Equatable {
    /// Why MDK did not add someone, grouped by what the user can do about it.
    enum Reason: Equatable {
        /// No usable messaging setup: no KeyPackage, an unusable or incompatible one, or no inbox
        /// relay to deliver a Welcome to. The app's long-standing copy for this is "not on White
        /// Noise yet", and the compose flow offers an invitation.
        case unreachable
        /// On White Noise, but every KeyPackage they published is from an outdated app.
        case needsAppUpdate
        /// MDK's relay reads for this account did not finish. Not a verdict on the person, so it
        /// is never marked as one; trying again can succeed.
        case incomplete
    }

    struct Skipped: Equatable {
        let accountIdHex: String
        /// The staged recipient MDK's account id belongs to, when the caller had one.
        let recipient: NewChatRecipient?
        let reason: Reason

        /// The name the notice uses: the recipient's label, or a short form of the account id.
        var title: String {
            recipient?.title ?? DisplayText.short(accountIdHex)
        }
    }

    /// Every requested account MDK did not select, in request order.
    let skipped: [Skipped]

    init(outcomes: [MemberResolutionOutcomeFfi], recipients: [NewChatRecipient]) {
        skipped = outcomes.compactMap { outcome in
            let reason: Reason
            switch outcome.status {
            case .selected:
                return nil
            case .missingKeyPackage, .invalidKeyPackage, .incompatibleKeyPackage, .missingInboxRoute:
                reason = .unreachable
            case .obsoleteKeyPackage:
                reason = .needsAppUpdate
            case .incomplete:
                reason = .incomplete
            }
            let recipient = recipients.first {
                $0.accountIdHex.caseInsensitiveCompare(outcome.accountIdHex) == .orderedSame
            }
            return Skipped(accountIdHex: outcome.accountIdHex, recipient: recipient, reason: reason)
        }
    }

    var isEmpty: Bool { skipped.isEmpty }

    /// Lowercased account ids of the staged recipients MDK found no messaging setup for: what the
    /// compose panel and the add-members sheet mark and leave out of the next attempt. Outdated and
    /// incomplete members are not marked; one is told to update, the other can simply be retried.
    var unreachableRecipientIdHexes: Set<String> {
        Set(
            skipped.lazy.filter { $0.reason == .unreachable && $0.recipient != nil }
                .map { $0.accountIdHex.lowercased() })
    }

    /// Someone unreachable whom no staged recipient matches, so no row can carry the mark.
    var hasUnnamedUnreachable: Bool {
        skipped.contains { $0.reason == .unreachable && $0.recipient == nil }
    }

    /// The members the notices name for `reason`, as a localized list ("Bob and Carol").
    func names(for reason: Reason) -> String? {
        let titles = skipped.filter { $0.reason == reason }.map(\.title)
        guard !titles.isEmpty else { return nil }
        return ListFormatter.localizedString(byJoining: titles)
    }

    /// Shown in the rare case a group was created or an invite sent without some of the people
    /// asked for. The compose flow checks for KeyPackages before anyone is added, so this is a plain
    /// problem report that names them, not an explanation of why.
    var notAddedNotice: String? {
        guard !skipped.isEmpty else { return nil }
        return String(
            format: L10n.string("Couldn’t add %@ to the group."),
            ListFormatter.localizedString(byJoining: skipped.map(\.title)))
    }

    /// For a create or invite that changed nothing: the part of the answer the panel's marks cannot
    /// carry. Unreachable members are marked instead, so only outdated and incomplete ones are
    /// spelled out here.
    var nothingAddedMessage: String? {
        var lines: [String] = []
        if let names = names(for: .needsAppUpdate) {
            lines.append(ChatCreationFailure.needsAppUpdateMessage(recipientName: names))
        }
        if let names = names(for: .incomplete) {
            lines.append(String(format: L10n.string("Couldn’t add %@. Try again in a moment."), names))
        }
        return lines.isEmpty ? nil : lines.joined(separator: " ")
    }
}
