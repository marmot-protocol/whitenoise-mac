//
//  AccountSetupDeviceNoticeTests.swift
//  whitenoise-macTests
//

import Foundation
import MarmotKit
import Testing

@testable import whitenoise_mac

/// The "Chats on this device" step's copy: what each discovery outcome says, that it explains a
/// separate installation only when another app may exist, and which publication date it names.
struct AccountSetupDeviceNoticeTests {
    private typealias F = OnboardingFixtures

    private static let now = Date(timeIntervalSince1970: 2_000_000_000)
    private static let english = Locale(identifier: "en_US")

    private func notice(_ discovery: OnboardingDeviceDiscoveryFfi, publishedAt: [UInt64] = [])
        -> AccountSetupDeviceNotice
    {
        AccountSetupDeviceNotice(F.notice(discovery, publishedAt: publishedAt), now: Self.now)
    }

    @Test func buttonDistinguishesCleanAndUncertainDiscovery() {
        #expect(notice(.noneFound).actionKey == "Continue")
        #expect(notice(.unknown).actionKey == "Continue anyway")
        #expect(notice(.otherInstallationPossible, publishedAt: [1]).actionKey == "Continue anyway")
        #expect(AccountSetupDeviceNotice(nil).actionKey == "Continue anyway")
    }

    @Test func eachCheckedOutcomeStatesItsFinding() {
        #expect(AccountSetupDeviceNotice(nil).findingKey == nil)
        #expect(AccountSetupDeviceNotice(nil).finding(locale: Self.english) == nil)
        #expect(notice(.noneFound).findingKey == "We didn’t find messaging keys from another app or device.")
        #expect(
            notice(.unknown).findingKey
                == "We couldn’t check whether this account uses another app or device for messaging.")
        #expect(
            notice(.otherInstallationPossible).findingKey
                == "We found messaging keys this account published from another app or device.")
        #expect(
            notice(.otherInstallationPossible, publishedAt: [1_900_000_000]).findingKey
                == "We found messaging keys this account published from another app or device, most recently on %@.")
    }

    @Test func explanationDescribesASeparateInstallationOnlyWhenAnotherAppMayExist() {
        #expect(notice(.noneFound).explanationKeys.isEmpty)
        let unchecked = [
            "If you use another app for messaging, this device will have its own separate chats, and chats in that app won’t appear here."
        ]
        #expect(notice(.unknown).explanationKeys == unchecked)
        // A failed or pending check makes no claim about other apps either way.
        #expect(AccountSetupDeviceNotice(nil).explanationKeys == unchecked)
        #expect(
            notice(.otherInstallationPossible, publishedAt: [1]).explanationKeys == [
                "This device will have its own separate chats. Chats in the other app stay there and won’t appear here.",
                "When someone starts a new chat with you, it may arrive in either app.",
            ])
    }

    /// The copy must never promise multi-device support White Noise does not have.
    @Test func copyNeverSaysTheDeviceIsAddedLinkedOrSynced() {
        let notices =
            [notice(.noneFound), notice(.unknown), notice(.otherInstallationPossible, publishedAt: [1])]
            + [AccountSetupDeviceNotice(nil)]
        let lines = notices.flatMap { [$0.finding(locale: Self.english)].compactMap { $0 } + $0.explanationKeys }
        for line in lines {
            for word in ["added", "linked", "sync"] {
                #expect(!line.localizedCaseInsensitiveContains(word), "\(line)")
            }
        }
    }

    @Test func otherAppsFindingNamesTheLatestPastPublication() throws {
        let older: UInt64 = 1_700_000_000
        let latest: UInt64 = 1_900_000_000
        let future: UInt64 = 2_100_000_000
        func finding(_ publishedAt: [UInt64]) -> String? {
            notice(.otherInstallationPossible, publishedAt: publishedAt).finding(locale: Self.english)
        }
        let undated = try #require(finding([]))
        let latestOnly = try #require(finding([latest]))

        let expectedDate = Date(timeIntervalSince1970: TimeInterval(latest))
            .formatted(Date.FormatStyle(date: .long, time: .omitted, locale: Self.english))
        #expect(latestOnly.contains(expectedDate))
        #expect(!latestOnly.contains("%@"))
        #expect(latestOnly != undated)
        #expect(latestOnly != finding([older]))
        #expect(finding([older, latest]) == latestOnly)
        #expect(finding([latest, future]) == latestOnly)
        #expect(finding([future]) == undated)
        #expect(finding([.max]) == undated)
        #expect(finding([0]) == undated)
    }

    @Test func findingFormatsTheDateInTheRequestedLocale() throws {
        let german = Locale(identifier: "de")
        let latest = Date(timeIntervalSince1970: 1_900_000_000)
        let finding = try #require(
            notice(.otherInstallationPossible, publishedAt: [1_900_000_000]).finding(locale: german))
        #expect(finding.contains(latest.formatted(Date.FormatStyle(date: .long, time: .omitted, locale: german))))
        #expect(finding.hasPrefix("Wir haben"))
    }
}
