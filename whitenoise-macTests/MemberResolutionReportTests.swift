//
//  MemberResolutionReportTests.swift
//  whitenoise-macTests
//

import Foundation
import MarmotKit
import Testing

@testable import whitenoise_mac

/// How MDK's per-member outcomes become the marks and notices the compose flow shows. The flows that
/// apply them are covered in `GroupsTests`; this pins the mapping itself.
@MainActor
struct MemberResolutionReportTests {
    private static let bob = NewChatRecipient(
        sourceQuery: "npub1p0p", memberRef: "npub1p0p", accountIdHex: String(repeating: "b", count: 64),
        npub: "npub1p0p", displayName: "Bob", pictureURL: nil)

    private static func outcome(_ accountIdHex: String, _ status: MemberResolutionStatusFfi)
        -> MemberResolutionOutcomeFfi
    {
        MemberResolutionOutcomeFfi(
            accountIdHex: accountIdHex, status: status, selectedDeviceCount: status == .selected ? 1 : 0)
    }

    @Test func everyStatusLandsInTheRightReason() {
        let statuses: [(MemberResolutionStatusFfi, MemberResolutionReport.Reason?)] = [
            (.selected, nil),
            (.missingKeyPackage, .unreachable),
            (.invalidKeyPackage, .unreachable),
            (.incompatibleKeyPackage, .unreachable),
            (.missingInboxRoute, .unreachable),
            (.obsoleteKeyPackage, .needsAppUpdate),
            (.incomplete, .incomplete),
        ]
        for (status, reason) in statuses {
            let report = MemberResolutionReport(
                outcomes: [Self.outcome(Self.bob.accountIdHex, status)], recipients: [Self.bob])
            #expect(report.skipped.first?.reason == reason, "\(status)")
        }
    }

    @Test func onlyUnreachableMembersAreMarked() {
        // Outdated and unanswered members are reachable once they update or the relays answer, so
        // a mark that takes them out of the next attempt would be wrong.
        let carol = String(repeating: "c", count: 64)
        let report = MemberResolutionReport(
            outcomes: [
                Self.outcome(Self.bob.accountIdHex.uppercased(), .missingKeyPackage), Self.outcome(carol, .incomplete),
            ],
            recipients: [Self.bob])

        #expect(report.unreachableRecipientIdHexes == [Self.bob.accountIdHex])
        #expect(!report.hasUnnamedUnreachable)
    }

    @Test func anUnmatchedAccountIsNamedByItsShortIdAndCountsAsUnnamed() {
        let stranger = String(repeating: "e", count: 64)
        let report = MemberResolutionReport(
            outcomes: [Self.outcome(stranger, .missingKeyPackage)], recipients: [Self.bob])

        #expect(report.unreachableRecipientIdHexes.isEmpty)
        #expect(report.hasUnnamedUnreachable)
        #expect(report.skipped.first?.title == DisplayText.short(stranger))
    }

    @Test func aPartialCreateNamesEveryoneLeftOutInOneSentence() {
        let carol = String(repeating: "c", count: 64)
        let report = MemberResolutionReport(
            outcomes: [
                Self.outcome(Self.bob.accountIdHex, .obsoleteKeyPackage), Self.outcome(carol, .incomplete),
            ],
            recipients: [Self.bob])

        #expect(
            report.notAddedNotice
                == String(
                    format: L10n.string("Couldn’t add %@ to the group."),
                    ListFormatter.localizedString(byJoining: ["Bob", DisplayText.short(carol)])))
    }

    @Test func anUnansweredMemberIsToldToRetryWhenNothingWasCreated() {
        let report = MemberResolutionReport(
            outcomes: [Self.outcome(Self.bob.accountIdHex, .incomplete)], recipients: [Self.bob])

        #expect(
            report.nothingAddedMessage
                == String(format: L10n.string("Couldn’t add %@. Try again in a moment."), "Bob"))
    }

    @Test func everyoneSelectedLeavesNothingToSay() {
        let report = MemberResolutionReport(
            outcomes: [Self.outcome(Self.bob.accountIdHex, .selected)], recipients: [Self.bob])

        #expect(report.isEmpty)
        #expect(report.notAddedNotice == nil)
        #expect(report.nothingAddedMessage == nil)
    }
}
