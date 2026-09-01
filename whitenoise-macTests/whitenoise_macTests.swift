//
//  whitenoise_macTests.swift
//  whitenoise-macTests
//
//  Created by Jeff Gardner on 26/05/2026.
//
//  What is left of the suite that used to hold all 880 runtime-backed tests. The rest now live
//  in `TimelineTests`, `ChatListTests`, `GroupsTests`, `MediaTests`, `SettingsTests` and
//  `AccountTests`, one non-serialised suite per domain, with the fakes and fixtures they share
//  in `Support/`.
//
//  This suite keeps `.serialized`, and keeps two things. First, the tests that cannot run beside
//  a sibling because they read or write a process-global preference — the selected app language,
//  the drawing appearance, the notification preview mode — that `UserDefaults.standard` hands to
//  whatever else is running at the time. Second, the background-listener restarts, which belong
//  to no one domain: they are about the session's streams coming back, not about the chat list,
//  the timeline or notifications in particular.
//

import AppKit
import Combine
import CryptoKit
import Darwin
import Foundation
import ImageIO
import MarmotKit
import Observation
import SwiftUI
import Testing
import UniformTypeIdentifiers
import UserNotifications

@testable import whitenoise_mac

@Suite(.serialized)
struct whitenoise_macTests: WorkspaceTestSupport {
    @MainActor
    @Test func chatSearchMatchesTitleSubtitleAndPreview() async throws {
        let chats = ChatItem.samples

        #expect(ChatFilter.filtered(chats, query: "relay").map(\.id) == ["chat-relays"])
        #expect(ChatFilter.filtered(chats, query: "desktop").map(\.id) == ["chat-design"])
        #expect(ChatFilter.filtered(chats, query: "direct").map(\.id) == ["chat-nvk"])

        // A query is matched against each field independently and never across
        // field boundaries, so "NVK Direct" does not match the chat whose title
        // is "NVK" and subtitle is "Direct message".
        #expect(ChatFilter.filtered(chats, query: "NVK Direct").isEmpty)
    }

    @MainActor
    @Test func chatListRelativeTimestampUsesSelectedAppLanguage() async throws {
        let previousLanguage = UserDefaults.standard.object(forKey: AppLanguage.storageKey)
        defer { restoreDefault(previousLanguage, forKey: AppLanguage.storageKey) }
        UserDefaults.standard.set(AppLanguage.spanish.rawValue, forKey: AppLanguage.storageKey)
        AppLanguage.refreshCachedLocale()

        let messageDate = Date(timeIntervalSince1970: 1_700_000_000)
        let sameWeekNow = messageDate.addingTimeInterval(86_400)
        let expected = messageDate.formatted(
            Date.FormatStyle.dateTime.weekday(.abbreviated)
                .locale(Locale(identifier: AppLanguage.spanish.rawValue))
        )

        #expect(DisplayText.relativeTimestamp(for: messageDate, now: sameWeekNow) == expected)
    }

    @MainActor
    @Test func messageTimestampUsesSelectedAppLanguage() async throws {
        let previousLanguage = UserDefaults.standard.object(forKey: AppLanguage.storageKey)
        defer { restoreDefault(previousLanguage, forKey: AppLanguage.storageKey) }
        UserDefaults.standard.set(AppLanguage.spanish.rawValue, forKey: AppLanguage.storageKey)
        AppLanguage.refreshCachedLocale()

        let messageDate = Date(timeIntervalSince1970: 1_700_000_000)
        // Message times force a 12-hour clock with a meridiem while still following the selected
        // language, so the expected value forces the same hour cycle on the Spanish locale.
        var components = Locale.Components(locale: Locale(identifier: AppLanguage.spanish.rawValue))
        components.hourCycle = .oneToTwelve
        let expected = messageDate.formatted(
            Date.FormatStyle(date: .omitted, time: .shortened).locale(Locale(components: components))
        )

        #expect(DisplayText.messageTimestamp(for: messageDate, now: messageDate) == expected)
    }

    @MainActor
    @Test func twelveHourLocaleCacheInvalidatesWithSelectedLanguage() {
        let previousLanguage = UserDefaults.standard.object(forKey: AppLanguage.storageKey)
        defer { restoreDefault(previousLanguage, forKey: AppLanguage.storageKey) }

        UserDefaults.standard.set(AppLanguage.spanish.rawValue, forKey: AppLanguage.storageKey)
        AppLanguage.refreshCachedLocale()
        let spanish = AppLanguage.currentTwelveHourLocale

        UserDefaults.standard.set(AppLanguage.german.rawValue, forKey: AppLanguage.storageKey)
        AppLanguage.refreshCachedLocale()
        let german = AppLanguage.currentTwelveHourLocale

        #expect(spanish.identifier != german.identifier)
        #expect(Locale.Components(locale: spanish).hourCycle == .oneToTwelve)
        #expect(Locale.Components(locale: german).hourCycle == .oneToTwelve)
        #expect(AppLanguage.twelveHourLocale(for: AppLanguage.currentLocale) == german)
    }

    @MainActor
    @Test func longDateTimeTimestampUsesSelectedAppLanguage() async throws {
        let previousLanguage = UserDefaults.standard.object(forKey: AppLanguage.storageKey)
        defer { restoreDefault(previousLanguage, forKey: AppLanguage.storageKey) }
        UserDefaults.standard.set(AppLanguage.spanish.rawValue, forKey: AppLanguage.storageKey)
        AppLanguage.refreshCachedLocale()

        let messageDate = Date(timeIntervalSince1970: 1_700_000_000)
        let expected = messageDate.formatted(
            Date.FormatStyle(date: .long, time: .shortened)
                .locale(Locale(identifier: AppLanguage.spanish.rawValue))
        )

        #expect(DisplayText.longDateTimeTimestamp(for: messageDate) == expected)
    }

    @MainActor
    @Test func timelineDayGroupingLabelsOnlyDayBoundaries() async throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let now = calendar.date(from: DateComponents(year: 2026, month: 7, day: 17, hour: 12))!
        let older = calendar.date(byAdding: .day, value: -3, to: now)!
        let yesterday = calendar.date(byAdding: .day, value: -1, to: now)!
        let laterYesterday = calendar.date(byAdding: .hour, value: 2, to: yesterday)!
        let messages = [older, yesterday, laterYesterday, now].enumerated().map { index, date in
            MessageItem(
                id: "day-\(index)",
                senderName: "Alice",
                body: "Message \(index)",
                sentAt: date,
                isOutgoing: false
            )
        }

        let items = TimelineMessageDisplayItem.make(
            from: messages,
            now: now,
            calendar: calendar,
            locale: Locale(identifier: "en_US")
        )

        #expect(items[0].dayLabel != nil)
        #expect(items[1].dayLabel == "Yesterday")
        #expect(items[2].dayLabel == nil)
        #expect(items[3].dayLabel == "Today")
        #expect(items.map(\.id) == messages.map(\.id))
    }

    @MainActor
    @Test func timelineStoreMemoizesDayGroupingUntilItsInputsChange() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let sentAt = try #require(calendar.date(from: DateComponents(year: 2026, month: 7, day: 17, hour: 10)))
        let sameDay = try #require(calendar.date(byAdding: .hour, value: 2, to: sentAt))
        let laterSameDay = try #require(calendar.date(byAdding: .hour, value: 6, to: sentAt))
        let nextDay = try #require(calendar.date(byAdding: .day, value: 1, to: sameDay))
        let locale = Locale(identifier: "en_US")
        let store = MessageTimelineStore(
            messages: [
                MessageItem(
                    id: "cached-day",
                    senderName: "Alice",
                    body: "Hello",
                    sentAt: sentAt,
                    isOutgoing: false
                )
            ],
            isLoaded: true,
            displayReferenceDate: sameDay,
            displayCalendar: calendar,
            displayLocale: locale
        )

        #expect(store.displayItems.first?.dayLabel == "Today")
        _ = store.displayItems
        _ = store.displayItems
        #expect(store.displayItemsBuildCount == 1)

        store.refreshDisplayItems(referenceDate: laterSameDay, calendar: calendar, locale: locale)
        #expect(store.displayItemsBuildCount == 1)

        store.refreshDisplayItems(referenceDate: nextDay, calendar: calendar, locale: locale)
        #expect(store.displayItems.first?.dayLabel == "Yesterday")
        #expect(store.displayItemsBuildCount == 2)
    }

    @MainActor
    @Test func timestampLabelsRefreshForReferenceDay() async throws {
        let calendar = Calendar.autoupdatingCurrent
        let dayStart = calendar.startOfDay(for: Date())
        let sentAt = try #require(calendar.date(byAdding: .hour, value: 15, to: dayStart))
        let sameDayNow = try #require(calendar.date(byAdding: .hour, value: 16, to: dayStart))
        let nextDayNow = try #require(calendar.date(byAdding: .day, value: 1, to: sameDayNow))
        let locale = Locale(identifier: "en_US")
        let expectedTime = sentAt.formatted(
            Date.FormatStyle(date: .omitted, time: .shortened).locale(locale)
        )
        let expectedDateTime = sentAt.formatted(
            Date.FormatStyle(date: .abbreviated, time: .shortened).locale(locale)
        )

        #expect(DisplayText.messageTimestamp(for: sentAt, now: sameDayNow, locale: locale) == expectedTime)
        #expect(DisplayText.messageTimestamp(for: sentAt, now: nextDayNow, locale: locale) == expectedDateTime)

        let chat = ChatItem(
            id: "day-boundary-chat",
            title: "Day Boundary",
            subtitle: "",
            preview: "",
            updatedAt: sentAt,
            avatarSeed: "day-boundary-chat",
            pictureURL: nil,
            unreadCount: 0
        )
        let message = MessageItem(
            id: "day-boundary-message",
            senderName: "Alice",
            body: "Still here",
            sentAt: sentAt,
            isEdited: true,
            isOutgoing: false
        )

        #expect(chat.timestampLabel(at: sameDayNow, locale: locale) == expectedTime)
        #expect(chat.timestampLabel(at: nextDayNow, locale: locale) != expectedTime)
        #expect(message.timeLabel(at: nextDayNow, locale: locale) == expectedDateTime)
        #expect(
            message.metadataLabel(at: nextDayNow, locale: locale)
                == "\(expectedDateTime)  \(L10n.string("Edited"))"
        )
    }

    @MainActor
    @Test func localizedStringUsesSelectedAppLanguage() async throws {
        let previousLanguage = UserDefaults.standard.object(forKey: AppLanguage.storageKey)
        defer { restoreDefault(previousLanguage, forKey: AppLanguage.storageKey) }

        UserDefaults.standard.set(AppLanguage.spanish.rawValue, forKey: AppLanguage.storageKey)
        AppLanguage.refreshCachedLocale()
        #expect(L10n.string("Save") == "Guardar")
    }

    @Test func memberCountLocalizationUsesLocalePluralRules() {
        let russian = Locale(identifier: "ru")
        #expect(L10n.plural("%lld members", Int64(1), locale: russian) == "1 участник")
        #expect(L10n.plural("%lld members", Int64(2), locale: russian) == "2 участника")
        #expect(L10n.plural("%lld members", Int64(5), locale: russian) == "5 участников")
        #expect(L10n.plural("%lld members", Int64(21), locale: russian) == "21 участник")
        #expect(L10n.plural("%lld members", Int64(2), locale: Locale(identifier: "tr")) == "2 üye")
    }

    @MainActor
    @Test func conversationMetadataSubtitleUsesMemberPluralRules() async throws {
        let previousLanguage = UserDefaults.standard.object(forKey: AppLanguage.storageKey)
        defer { restoreDefault(previousLanguage, forKey: AppLanguage.storageKey) }

        UserDefaults.standard.set(AppLanguage.english.rawValue, forKey: AppLanguage.storageKey)
        AppLanguage.refreshCachedLocale()

        let oneMember = ConversationMetadata(memberCount: 1, disappearingMessageSecs: 0, isSelfAdmin: false)
        let twoMembers = ConversationMetadata(memberCount: 2, disappearingMessageSecs: 0, isSelfAdmin: false)
        #expect(oneMember.subtitle == "1 member")
        #expect(twoMembers.subtitle == "2 members")
    }

    @MainActor
    @Test func memberCountLocalizationUsesSelectedAppLanguage() async throws {
        let previousLanguage = UserDefaults.standard.object(forKey: AppLanguage.storageKey)
        defer { restoreDefault(previousLanguage, forKey: AppLanguage.storageKey) }

        UserDefaults.standard.set(AppLanguage.russian.rawValue, forKey: AppLanguage.storageKey)
        AppLanguage.refreshCachedLocale()
        #expect(L10n.plural("%lld members", Int64(2)) == "2 участника")

        UserDefaults.standard.set(AppLanguage.turkish.rawValue, forKey: AppLanguage.storageKey)
        AppLanguage.refreshCachedLocale()
        #expect(L10n.plural("%lld members", Int64(2)) == "2 üye")
    }

    @MainActor
    @Test func localizedStringBundleCacheInvalidatesOnLanguageChange() async throws {
        // Regression for the residual half of #28 (#117): `L10n.string` caches the
        // resolved `.lproj` bundle to avoid a per-call filesystem stat + `Bundle`
        // allocation. The cache must be invalidated by `refreshCachedLocale()` when
        // the language preference changes, otherwise a stale bundle keeps serving
        // the previous language. Switch between two non-source languages and assert
        // each read reflects the current preference.
        let previousLanguage = UserDefaults.standard.object(forKey: AppLanguage.storageKey)
        defer { restoreDefault(previousLanguage, forKey: AppLanguage.storageKey) }

        UserDefaults.standard.set(AppLanguage.spanish.rawValue, forKey: AppLanguage.storageKey)
        AppLanguage.refreshCachedLocale()
        // Prime the cache while Spanish is selected.
        #expect(L10n.string("Save") == "Guardar")

        UserDefaults.standard.set(AppLanguage.german.rawValue, forKey: AppLanguage.storageKey)
        AppLanguage.refreshCachedLocale()
        // The cache must have been cleared, so this resolves the German bundle.
        #expect(L10n.string("Save") == "Speichern")

        // And back again, confirming the cache tracks the preference in both directions.
        UserDefaults.standard.set(AppLanguage.spanish.rawValue, forKey: AppLanguage.storageKey)
        AppLanguage.refreshCachedLocale()
        #expect(L10n.string("Save") == "Guardar")
    }

    @MainActor
    @Test func localizedStringWithExplicitLocaleIgnoresCachedPreference() async throws {
        // `L10n.string(_:locale:)` is what SwiftUI views localize through so the language is
        // a tracked dependency of their body. It must resolve the locale it is handed, not
        // the cached preference, and must still be correct when the two agree.
        let previousLanguage = UserDefaults.standard.object(forKey: AppLanguage.storageKey)
        defer { restoreDefault(previousLanguage, forKey: AppLanguage.storageKey) }

        UserDefaults.standard.set(AppLanguage.spanish.rawValue, forKey: AppLanguage.storageKey)
        AppLanguage.refreshCachedLocale()

        let spanish = Locale(identifier: AppLanguage.spanish.rawValue)
        let german = Locale(identifier: AppLanguage.german.rawValue)
        #expect(L10n.string("Save", locale: spanish) == "Guardar")
        #expect(L10n.string("Save", locale: german) == "Speichern")
        // An unknown key falls back to itself, like `string(_:)` does.
        #expect(L10n.string("whitenoise.not.a.key", locale: german) == "whitenoise.not.a.key")
    }

    @MainActor
    @Test func systemLocaleChangeInvalidatesLocalizedStringCacheWhenPreferenceIsSystem() async throws {
        let previousLanguage = UserDefaults.standard.object(forKey: AppLanguage.storageKey)
        defer {
            AppLanguage.setSystemLocaleOverrideForTesting(nil)
            restoreDefault(previousLanguage, forKey: AppLanguage.storageKey)
        }

        UserDefaults.standard.removeObject(forKey: AppLanguage.storageKey)
        AppLanguage.setSystemLocaleOverrideForTesting(Locale(identifier: AppLanguage.spanish.rawValue))
        AppLanguage.refreshCachedLocale()
        let state = WorkspaceState(clientFactory: { FakeMarmotRuntime(accounts: []) })
        // Prime the system-preference cache while the effective system language is Spanish.
        #expect(L10n.string("Save") == "Guardar")

        state.refreshSystemLanguageIfNeeded()
        #expect(state.systemLocaleRefreshRevision == 0)

        AppLanguage.setSystemLocaleOverrideForTesting(Locale(identifier: AppLanguage.german.rawValue))

        state.refreshSystemLanguageIfNeeded()

        #expect(L10n.string("Save") == "Speichern")
        #expect(state.systemLocaleRefreshRevision == 1)
    }

    @MainActor
    @Test func systemLocaleChangeDoesNotOverrideSelectedAppLanguage() async throws {
        let previousLanguage = UserDefaults.standard.object(forKey: AppLanguage.storageKey)
        defer {
            AppLanguage.setSystemLocaleOverrideForTesting(nil)
            restoreDefault(previousLanguage, forKey: AppLanguage.storageKey)
        }

        UserDefaults.standard.set(AppLanguage.spanish.rawValue, forKey: AppLanguage.storageKey)
        AppLanguage.setSystemLocaleOverrideForTesting(Locale(identifier: AppLanguage.german.rawValue))
        AppLanguage.refreshCachedLocale()
        let state = WorkspaceState(clientFactory: { FakeMarmotRuntime(accounts: []) })

        state.refreshSystemLanguageIfNeeded()

        #expect(state.languagePreference == .spanish)
        #expect(L10n.string("Save") == "Guardar")
    }

    /// The audio player, the download/failed status rows, and the document row draw white content
    /// keyed off `isOutgoing`, but they sit *beside* the bubble rather than inside it, so they never
    /// inherit `BubbleBackground`'s fill. The outgoing fill was `white.opacity(0.12)`, which
    /// composited against the window background instead of covering it — white-on-white in light
    /// appearance, so sent voice notes and documents took up their space and rendered nothing.
    /// Dark appearance hid it, because there the wash happened to land on a dark backdrop.
    ///
    /// Opacity in *both* appearances is the property that matters: an alpha < 1 here means the row
    /// is at the mercy of whatever is behind it, which is exactly the bug.
    @Test func outgoingAttachmentRowFillCoversTheWindowBackgroundInBothAppearances() throws {
        #expect(AttachmentRowPalette.fill(isOutgoing: true) == AttachmentRowPalette.outgoingFill)
        #expect(AttachmentRowPalette.fill(isOutgoing: false) == AttachmentRowPalette.incomingFill)

        for appearanceName in [NSAppearance.Name.aqua, .darkAqua] {
            let appearance = try #require(NSAppearance(named: appearanceName))
            var outgoing: NSColor?
            var windowBackground: NSColor?
            appearance.performAsCurrentDrawingAppearance {
                outgoing = NSColor(AttachmentRowPalette.outgoingFill).usingColorSpace(.sRGB)
                windowBackground = NSColor.windowBackgroundColor.usingColorSpace(.sRGB)
            }
            let fill = try #require(outgoing)
            let backdrop = try #require(windowBackground)

            #expect(
                fill.alphaComponent == 1,
                "Outgoing attachment row fill must be opaque in \(appearanceName.rawValue), got alpha \(fill.alphaComponent)"
            )
            // And it must actually read as a different surface than the backdrop it covers — an
            // opaque fill that matches the window background would be just as invisible.
            let distance =
                abs(fill.redComponent - backdrop.redComponent)
                + abs(fill.greenComponent - backdrop.greenComponent)
                + abs(fill.blueComponent - backdrop.blueComponent)
            #expect(
                distance > 0.2,
                "Outgoing attachment row fill matches the window background in \(appearanceName.rawValue) (channel distance \(distance))"
            )
        }
    }

    @MainActor
    @Test func backgroundListenerFailureRoutesToBackgroundStatusNotLastError() async throws {
        let account = AccountSummaryFfi(
            label: "Desktop Account",
            accountIdHex: "abcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890",
            localSigning: true,
            externalSigning: false,
            signedOut: false,
            running: true
        )
        let runtime = FakeMarmotRuntime(accounts: [account])
        // A background notification-listener failure must not surface on the shared
        // per-screen error field that login/settings/new-chat render (issue #24).
        runtime.subscribeNotificationsError = NSError(
            domain: "test.background",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "background listener dropped"]
        )
        let state = WorkspaceState(clientFactory: { runtime })

        await state.bootstrap()

        let routedToBackground = await waitFor {
            state.backgroundStatus == "background listener dropped"
        }
        #expect(routedToBackground)
        // The user-facing per-screen error field must remain untouched.
        #expect(state.lastError == nil)

        // The banner is dismissible without affecting lastError.
        state.clearBackgroundStatus()
        #expect(state.backgroundStatus == nil)
        #expect(state.lastError == nil)
    }

    @MainActor
    @Test func notificationListenerRestartsWhenStreamEnds() async throws {
        let account = AccountSummaryFfi(
            label: "Desktop Account",
            accountIdHex: "abcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890",
            localSigning: true,
            externalSigning: false,
            signedOut: false,
            running: true
        )
        let runtime = FakeMarmotRuntime(accounts: [account])
        runtime.notificationStreamEndsImmediately = true
        let state = WorkspaceState(clientFactory: { runtime })

        await state.bootstrap()
        let didRestart = await waitFor {
            runtime.notificationSubscriptionCount >= 2
        }

        #expect(didRestart)
        await state.deleteAllData()
    }

    @MainActor
    @Test func chatListListenerRestartsWhenUpdateStreamEnds() async throws {
        let account = AccountSummaryFfi(
            label: "Desktop Account",
            accountIdHex: "abcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890",
            localSigning: true,
            externalSigning: false,
            signedOut: false,
            running: true
        )
        let runtime = FakeMarmotRuntime(accounts: [account])
        runtime.installDirectGroup(
            directGroup(),
            selfAccountIdHex: account.accountIdHex,
            otherAccountIdHex: "alice1234567890alice1234567890alice1234567890alice1234567890",
            otherDisplayName: "Alice",
            otherProfile: UserProfileMetadataFfi(
                name: "alice",
                displayName: "Alice",
                about: nil,
                picture: nil,
                nip05: nil,
                lud16: nil
            )
        )
        runtime.chatListStreamEndsAfterUpdates = true
        let state = WorkspaceState(clientFactory: { runtime })

        await state.bootstrap()
        let didRestart = await waitFor {
            runtime.chatListSubscriptionCount >= 2
        }

        #expect(didRestart)
        await state.deleteAllData()
    }

    @MainActor
    @Test func timelineListenerRestartsWhenLiveStreamEndsForSelectedChat() async throws {
        let account = AccountSummaryFfi(
            label: "Desktop Account",
            accountIdHex: "abcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890",
            localSigning: true,
            externalSigning: false,
            signedOut: false,
            running: true
        )
        let aliceId = "alice1234567890alice1234567890alice1234567890alice1234567890"
        let runtime = FakeMarmotRuntime(accounts: [account])
        runtime.installDirectGroup(
            directGroup(),
            selfAccountIdHex: account.accountIdHex,
            otherAccountIdHex: aliceId,
            otherDisplayName: "Alice",
            otherProfile: UserProfileMetadataFfi(
                name: "alice",
                displayName: "Alice",
                about: nil,
                picture: nil,
                nip05: nil,
                lud16: nil
            )
        )
        runtime.installMessages(
            [
                appMessage(
                    id: "initial",
                    groupIdHex: "direct-group",
                    sender: aliceId,
                    plaintext: "Initial message",
                    kind: 9,
                    recordedAt: 1_700_000_000
                )
            ], groupIdHex: "direct-group")
        runtime.timelineStreamEndsAfterUpdates = true
        let state = WorkspaceState(clientFactory: { runtime })

        await state.bootstrap()
        let didRestart = await waitFor {
            runtime.timelineSubscriptionCount >= 2
        }

        #expect(didRestart)
        await state.deleteAllData()
    }

    @MainActor
    @Test func notificationDeliveryFailureRoutesToBackgroundStatusNotLastError() async throws {
        let account = AccountSummaryFfi(
            label: "Desktop Account",
            accountIdHex: "abcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890",
            localSigning: true,
            externalSigning: false,
            signedOut: false,
            running: true
        )
        let runtime = FakeMarmotRuntime(accounts: [account])
        runtime.notificationSettings = notificationSettings(for: account, localEnabled: true)
        // `handleNotificationUpdate(_:)` runs on the background notification listener.
        // A failure posting the local notification must surface on the non-modal
        // background banner, never on the per-screen `lastError` that login/settings/
        // new-chat render (issue #24 — see PR #49 review finding).
        let notificationCenter = FakeLocalNotificationCenter(
            status: .authorized,
            postError: NSError(
                domain: "test.notification",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "notification delivery failed"]
            )
        )
        let state = WorkspaceState(
            localNotificationCenter: notificationCenter,
            appActivityProvider: { false },
            clientFactory: { runtime }
        )

        await state.bootstrap()
        await state.handleNotificationUpdate(
            notificationUpdate(
                account: account,
                notificationKey: "notice-1",
                groupIdHex: "direct-group",
                senderName: "Alice",
                previewText: "See you there."
            ))

        #expect(state.backgroundStatus == "notification delivery failed")
        // The user-facing per-screen error field must remain untouched.
        #expect(state.lastError == nil)
    }

    // MARK: - Tests that share the process-global notification preview preference
    //
    // `notificationPreviewMode` is written straight through to `UserDefaults.standard`, so a test
    // that sets `.hidden` sets it for every test running beside it, and the `defer` that puts the
    // old value back lands long after a concurrent reader has already seen the wrong one. These
    // are the only tests that read or write it, so they stay here, serialised against each other,
    // rather than in the domain suites their subject matter would otherwise put them in.

    @MainActor
    @Test func notificationTitlesUseTheTargetedAccountsNickname() async throws {
        let primary = desktopAccount()
        let secondary = AccountSummaryFfi(
            label: "Backup Account",
            accountIdHex: String(repeating: "1", count: 64),
            localSigning: true,
            externalSigning: false,
            signedOut: false,
            running: true
        )
        let sender = "alice1234567890alice1234567890alice1234567890alice1234567890"
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("whitenoise-nickname-notifications-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ContactNicknameFileStore(directoryURL: directory)
        try store.write([sender: "Mum"], forOwnerAccountIdHex: primary.accountIdHex)

        let previousPreviewMode = UserDefaults.standard.object(forKey: WorkspaceState.notificationPreviewModeKey)
        defer { restoreDefault(previousPreviewMode, forKey: WorkspaceState.notificationPreviewModeKey) }
        UserDefaults.standard.set(
            NotificationPreviewMode.full.rawValue,
            forKey: WorkspaceState.notificationPreviewModeKey
        )

        let state = WorkspaceState(
            accounts: [AccountItem(summary: primary), AccountItem(summary: secondary)],
            contactNicknameStore: store,
            clientFactory: { FakeMarmotRuntime(accounts: [primary, secondary]) }
        )
        state.activeAccountId = primary.label
        state.loadContactNicknames()

        let toPrimary = state.localNotificationRequest(
            for: notificationUpdate(
                account: primary,
                notificationKey: "primary-dm",
                senderName: "Alice",
                previewText: "See you soon"
            )
        )
        #expect(toPrimary.title == "Mum")

        let toSecondary = state.localNotificationRequest(
            for: notificationUpdate(
                account: secondary,
                notificationKey: "secondary-dm",
                senderName: "Alice",
                previewText: "See you soon"
            )
        )
        #expect(toSecondary.title == "Alice")

        let groupBody = state.localNotificationRequest(
            for: notificationUpdate(
                account: primary,
                notificationKey: "primary-group",
                groupIdHex: "group",
                senderName: "Alice",
                previewText: "See you soon",
                isDm: false,
                groupName: "Book club"
            )
        )
        #expect(groupBody.title == "Book club")
        #expect(groupBody.body.contains("Mum"))
        #expect(!groupBody.body.contains("Alice"))
    }

    @MainActor
    @Test func incomingNotificationPostsLocalAlertWhenEnabledAndInactive() async throws {
        let account = AccountSummaryFfi(
            label: "Desktop Account",
            accountIdHex: "abcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890",
            localSigning: true,
            externalSigning: false,
            signedOut: false,
            running: true
        )
        let runtime = FakeMarmotRuntime(accounts: [account])
        runtime.notificationSettings = notificationSettings(for: account, localEnabled: true)
        let notificationCenter = FakeLocalNotificationCenter(status: .authorized)
        let state = WorkspaceState(
            localNotificationCenter: notificationCenter,
            appActivityProvider: { false },
            clientFactory: { runtime }
        )

        await state.bootstrap()
        await state.handleNotificationUpdate(
            notificationUpdate(
                account: account,
                notificationKey: "notice-1",
                groupIdHex: "direct-group",
                senderName: "Alice",
                previewText: "See you there."
            ))

        #expect(notificationCenter.postedRequests.count == 1)
        #expect(notificationCenter.postedRequests.first?.identifier == "notice-1")
        #expect(notificationCenter.postedRequests.first?.title == "Alice")
        #expect(notificationCenter.postedRequests.first?.body == "See you there.")
        #expect(notificationCenter.postedRequests.first?.threadIdentifier == "direct-group")
        #expect(notificationCenter.postedRequests.first?.userInfo["groupIdHex"] == "direct-group")
    }

    @MainActor
    @Test func notificationPreviewSanitizesAndIsolatesPeerControlledMessageText() async throws {
        let account = desktopAccount()
        let runtime = FakeMarmotRuntime(accounts: [account])
        let state = WorkspaceState(clientFactory: { runtime })
        await state.bootstrap()

        let maliciousPreview = "Pay\u{202E} 123\u{2066}\nnow"
        let dm = state.localNotificationRequest(
            for: notificationUpdate(
                account: account,
                notificationKey: "dm-notice",
                senderName: "Alice",
                previewText: maliciousPreview
            ))
        let group = state.localNotificationRequest(
            for: notificationUpdate(
                account: account,
                notificationKey: "group-notice",
                groupIdHex: "team-group",
                senderName: "Alice",
                previewText: maliciousPreview,
                isDm: false,
                groupName: "Engineering"
            ))

        #expect(dm.body == "Pay 123now")
        #expect(group.body == "\u{2068}Alice\u{2069}: \u{2068}Pay 123now\u{2069}")
        #expect(!dm.body.unicodeScalars.contains { $0.value == 0x202E || $0.value == 0x2066 })
    }

    @MainActor
    @Test func senderOnlyPreviewModeOmitsDecryptedMessageBody() async throws {
        // Issue #30: notification body must never leak decrypted plaintext when
        // the user opts into sender-only previews. DM => body is generic, group
        // => body is just the sender name; neither contains the message text.
        let previousMode = UserDefaults.standard.object(forKey: "whitenoise.mac.notificationPreviewMode")
        defer { restoreDefault(previousMode, forKey: "whitenoise.mac.notificationPreviewMode") }

        let account = desktopAccount()
        let runtime = FakeMarmotRuntime(accounts: [account])
        runtime.notificationSettings = notificationSettings(for: account, localEnabled: true)
        let notificationCenter = FakeLocalNotificationCenter(status: .authorized)
        let state = WorkspaceState(
            localNotificationCenter: notificationCenter,
            appActivityProvider: { false },
            clientFactory: { runtime }
        )

        await state.bootstrap()
        state.notificationPreviewMode = .senderOnly

        await state.handleNotificationUpdate(
            notificationUpdate(
                account: account,
                notificationKey: "dm-notice",
                groupIdHex: "direct-group",
                senderName: "Alice",
                previewText: "Top secret plaintext."
            ))
        await state.handleNotificationUpdate(
            notificationUpdate(
                account: account,
                notificationKey: "group-notice",
                groupIdHex: "team-group",
                senderName: "Bob",
                previewText: "More secret plaintext.",
                isDm: false,
                groupName: "Engineering"
            ))

        #expect(notificationCenter.postedRequests.count == 2)
        let dm = notificationCenter.postedRequests[0]
        #expect(dm.title == "Alice")
        #expect(dm.body == "New message")
        #expect(!dm.body.contains("Top secret plaintext."))

        let group = notificationCenter.postedRequests[1]
        #expect(group.title == "Engineering")
        #expect(group.body == "Bob")
        #expect(!group.body.contains("More secret plaintext."))
    }

    @MainActor
    @Test func hiddenPreviewModeRevealsNeitherSenderNorContents() async throws {
        // Issue #30: hidden mode must reveal nothing about who or what — generic
        // title and body for both DMs and groups.
        let previousMode = UserDefaults.standard.object(forKey: "whitenoise.mac.notificationPreviewMode")
        defer { restoreDefault(previousMode, forKey: "whitenoise.mac.notificationPreviewMode") }

        let account = desktopAccount()
        let runtime = FakeMarmotRuntime(accounts: [account])
        runtime.notificationSettings = notificationSettings(for: account, localEnabled: true)
        let notificationCenter = FakeLocalNotificationCenter(status: .authorized)
        let state = WorkspaceState(
            localNotificationCenter: notificationCenter,
            appActivityProvider: { false },
            clientFactory: { runtime }
        )

        await state.bootstrap()
        state.notificationPreviewMode = .hidden

        await state.handleNotificationUpdate(
            notificationUpdate(
                account: account,
                notificationKey: "dm-notice",
                groupIdHex: "direct-group",
                senderName: "Alice",
                previewText: "Top secret plaintext."
            ))
        await state.handleNotificationUpdate(
            notificationUpdate(
                account: account,
                notificationKey: "group-notice",
                groupIdHex: "team-group",
                senderName: "Bob",
                previewText: "More secret plaintext.",
                isDm: false,
                groupName: "Engineering"
            ))

        #expect(notificationCenter.postedRequests.count == 2)
        for request in notificationCenter.postedRequests {
            #expect(request.title == "White Noise")
            #expect(request.body == "New message")
            #expect(!request.body.contains("plaintext"))
            #expect(request.title != "Alice")
            #expect(request.title != "Engineering")
        }
    }

    @MainActor
    @Test func groupStateNotificationsAnnounceTheEventAndNameTheGroup() async throws {
        // MarmotKit 0.9.15 added `removedFromGroup`, `madeAdmin`, and `removedAsAdmin`. The core
        // raises them only when the local account is the subject and sends no `previewText`, so
        // the body has to be the event itself — never the "New message" placeholder an absent
        // preview otherwise falls back to. There is no decrypted text in one of these, so
        // `.senderOnly` withholds nothing and must read exactly like `.full`.
        let previousMode = UserDefaults.standard.object(forKey: "whitenoise.mac.notificationPreviewMode")
        defer { restoreDefault(previousMode, forKey: "whitenoise.mac.notificationPreviewMode") }

        let account = desktopAccount()
        let runtime = FakeMarmotRuntime(accounts: [account])
        let state = WorkspaceState(clientFactory: { runtime })
        await state.bootstrap()

        // Compared through `L10n.string` rather than against English literals: the assertion
        // is which catalog entry the trigger maps to, and the test host runs in whatever app
        // language is persisted on the machine.
        let notices: [(trigger: NotificationTriggerFfi, body: String)] = [
            (.removedFromGroup, L10n.string("You were removed from this group")),
            (.madeAdmin, L10n.string("You were made an admin")),
            (.removedAsAdmin, L10n.string("You are no longer an admin")),
        ]

        for mode in [NotificationPreviewMode.full, .senderOnly] {
            state.notificationPreviewMode = mode
            for notice in notices {
                let request = state.localNotificationRequest(
                    for: notificationUpdate(
                        account: account,
                        notificationKey: "group-state-\(notice.trigger)-\(mode.rawValue)",
                        groupIdHex: "team-group",
                        senderName: "Alice",
                        isDm: false,
                        groupName: "Engineering",
                        trigger: notice.trigger
                    ))
                #expect(request.title == "Engineering")
                #expect(request.body == notice.body)
            }
        }
    }

    @MainActor
    @Test func hiddenPreviewModeWithholdsTheGroupStateNoticeItself() async throws {
        // Hidden mode drops the sender and the group from a message banner, and a group-state
        // notice has to lose more than the group name: "You were made an admin" on a lock screen
        // discloses membership and admin status on its own. Settings promises hidden previews
        // "only say a new message arrived", so these read exactly like a withheld message —
        // the same generic body, with nothing of the event left in it.
        let previousMode = UserDefaults.standard.object(forKey: "whitenoise.mac.notificationPreviewMode")
        defer { restoreDefault(previousMode, forKey: "whitenoise.mac.notificationPreviewMode") }

        let account = desktopAccount()
        let runtime = FakeMarmotRuntime(accounts: [account])
        let state = WorkspaceState(clientFactory: { runtime })
        await state.bootstrap()
        state.notificationPreviewMode = .hidden

        let notices: [(trigger: NotificationTriggerFfi, notice: String)] = [
            (.removedFromGroup, L10n.string("You were removed from this group")),
            (.madeAdmin, L10n.string("You were made an admin")),
            (.removedAsAdmin, L10n.string("You are no longer an admin")),
        ]

        for notice in notices {
            let request = state.localNotificationRequest(
                for: notificationUpdate(
                    account: account,
                    notificationKey: "hidden-group-state-\(notice.trigger)",
                    groupIdHex: "team-group",
                    senderName: "Alice",
                    isDm: false,
                    groupName: "Engineering",
                    trigger: notice.trigger
                ))
            #expect(request.title == L10n.string("White Noise"))
            #expect(request.body == L10n.string("New message"))
            #expect(request.body != notice.notice)
            #expect(!request.body.contains("Engineering"))
            #expect(!request.body.contains("Alice"))
        }
    }

    @MainActor
    @Test func groupStateNotificationWithoutAGroupNameStillPostsTheEvent() async throws {
        // The core reports no name for a group it cannot read back (`UnknownGroup`) and often
        // no actor at all for an inbound admin diff. Neither may push the actor's name — or
        // the "Someone" fallback — into the banner in place of the missing group.
        let account = desktopAccount()
        let runtime = FakeMarmotRuntime(accounts: [account])
        runtime.notificationSettings = notificationSettings(for: account, localEnabled: true)
        let notificationCenter = FakeLocalNotificationCenter(status: .authorized)
        let state = WorkspaceState(
            localNotificationCenter: notificationCenter,
            appActivityProvider: { false },
            clientFactory: { runtime }
        )
        await state.bootstrap()

        await state.handleNotificationUpdate(
            notificationUpdate(
                account: account,
                notificationKey: "unknown-group-removal",
                groupIdHex: "team-group",
                senderName: "Alice",
                isDm: false,
                groupName: nil,
                trigger: .removedFromGroup
            ))

        #expect(notificationCenter.postedRequests.count == 1)
        let request = try #require(notificationCenter.postedRequests.first)
        #expect(request.title == L10n.string("White Noise"))
        #expect(request.body == L10n.string("You were removed from this group"))
        #expect(request.body != L10n.string("New message"))
        #expect(!request.body.contains("Alice"))
        #expect(!request.body.contains(L10n.string("Someone")))
    }

    @MainActor
    @Test func fullPreviewModeIsDefaultAndPreservesLegacyBody() async throws {
        // Backward-compatible default: full previews keep the prior behavior so
        // existing users see no change unless they opt into a stricter mode.
        let previousMode = UserDefaults.standard.object(forKey: "whitenoise.mac.notificationPreviewMode")
        UserDefaults.standard.removeObject(forKey: "whitenoise.mac.notificationPreviewMode")
        defer { restoreDefault(previousMode, forKey: "whitenoise.mac.notificationPreviewMode") }

        let account = desktopAccount()
        let runtime = FakeMarmotRuntime(accounts: [account])
        runtime.notificationSettings = notificationSettings(for: account, localEnabled: true)
        let notificationCenter = FakeLocalNotificationCenter(status: .authorized)
        let state = WorkspaceState(
            localNotificationCenter: notificationCenter,
            appActivityProvider: { false },
            clientFactory: { runtime }
        )

        await state.bootstrap()
        #expect(state.notificationPreviewMode == .full)

        await state.handleNotificationUpdate(
            notificationUpdate(
                account: account,
                notificationKey: "group-notice",
                groupIdHex: "team-group",
                senderName: "\u{202E}Bob\u{2066}",
                previewText: "The launch plan is ready.",
                isDm: false,
                groupName: "\u{202E}Engineering\u{2066}"
            ))

        #expect(notificationCenter.postedRequests.count == 1)
        #expect(notificationCenter.postedRequests.first?.title == "Engineering")
        #expect(
            notificationCenter.postedRequests.first?.body
                == "\(isolated("Bob")): \(isolated("The launch plan is ready."))")
    }
}

@Suite(.serialized)
struct MarmotKit098IntegrationTests {
    @MainActor
    @Test func legacyMediaOnlyPreviewStillUsesAttachmentFallback() async throws {
        let row = chatListRow(
            groupIdHex: "group",
            title: "Planning",
            preview: "",
            sender: "alice",
            timelineAt: 1_700_000_000
        )

        let chat = ChatItem(row: row, activeAccountIdHex: "self")

        #expect(chat.preview == L10n.string("Attachment"))
        // No reported kind still means the row carries media, so it keeps the generic glyph.
        #expect(chat.previewAttachmentKind == .mixed)
    }

    @MainActor
    @Test func chatRowProjectsAttachmentGlyphMatchingTheReportedKind() async throws {
        let expectedKinds: [(ChatListAttachmentKindFfi?, ChatPreviewAttachmentKind)] = [
            (.photo, .photo),
            (.video, .video),
            (.audio, .audio),
            (.file, .file),
            (.mixed, .mixed),
            (nil, .mixed),
        ]

        for (reported, expected) in expectedKinds {
            let row = chatListRow(
                groupIdHex: "group",
                title: "Planning",
                preview: "",
                sender: "alice",
                timelineAt: 1_700_000_000,
                attachmentKind: reported,
                attachmentCount: 1
            )

            let chat = ChatItem(row: row, activeAccountIdHex: "self")

            #expect(chat.previewAttachmentKind == expected)
        }
    }

    @MainActor
    @Test func chatRowKeepsAttachmentGlyphAlongsideACaption() async throws {
        let row = chatListRow(
            groupIdHex: "group",
            title: "Planning",
            preview: "Look at this",
            sender: "alice",
            timelineAt: 1_700_000_000,
            attachmentKind: .video,
            attachmentCount: 1
        )

        let chat = ChatItem(row: row, activeAccountIdHex: "self")

        // The caption is the whole preview text, so the glyph is all that marks the row as media.
        #expect(chat.preview == "Look at this")
        #expect(chat.previewAttachmentKind == .video)
    }

    @MainActor
    @Test func chatRowOmitsAttachmentGlyphWithoutAttachments() async throws {
        let textOnly = chatListRow(
            groupIdHex: "group",
            title: "Planning",
            preview: "Ready when you are",
            sender: "alice",
            timelineAt: 1_700_000_000
        )

        #expect(ChatItem(row: textOnly, activeAccountIdHex: "self").previewAttachmentKind == nil)

        let deleted = chatListRow(
            groupIdHex: "group",
            title: "Planning",
            preview: "",
            sender: "alice",
            timelineAt: 1_700_000_000,
            attachmentKind: .photo,
            attachmentCount: 2,
            deleted: true
        )
        let deletedChat = ChatItem(row: deleted, activeAccountIdHex: "self")

        #expect(deletedChat.preview == L10n.string("Message deleted"))
        #expect(deletedChat.previewAttachmentKind == nil)
    }

    @MainActor
    @Test func resolvedMetadataMergeKeepsTheAttachmentGlyphWithItsPreview() async throws {
        let mediaRow = chatListRow(
            groupIdHex: "group",
            title: "Planning",
            preview: "",
            sender: "alice",
            timelineAt: 1_700_000_000,
            attachmentKind: .photo,
            attachmentCount: 1
        )
        let textRow = chatListRow(
            groupIdHex: "group",
            title: "Planning",
            preview: "Ready when you are",
            sender: "alice",
            timelineAt: 1_600_000_000
        )
        let media = ChatItem(row: mediaRow, activeAccountIdHex: "self")
        let text = ChatItem(row: textRow, activeAccountIdHex: "self")

        // The merge takes `preview` from the incoming row, so the glyph has to travel with it in
        // both directions — otherwise a text preview keeps a stale photo glyph.
        #expect(ChatListOrdering.preservingResolvedMetadata(in: media, from: text).previewAttachmentKind == .photo)
        #expect(ChatListOrdering.preservingResolvedMetadata(in: text, from: media).previewAttachmentKind == nil)
    }

    @MainActor
    @Test func chatRowProjectsDurableInteractionFields() async throws {
        let row = ChatListRowFfi(
            groupIdHex: "direct-group",
            pinned: false,
            pinnedPosition: nil,
            archived: false,
            pendingConfirmation: false,
            lifecycleState: .stable,
            disbanding: false,
            disbandRequest: nil,
            title: "Alice",
            groupName: "",
            avatarUrl: nil,
            avatar: nil,
            lastMessage: ChatListMessagePreviewFfi(
                messageIdHex: "message",
                sender: "alice",
                senderDisplayName: "Alice",
                plaintext: "",
                contentTokens: emptyMarkdownDocument(),
                kind: 9,
                timelineAt: 1_700_000_000,
                deleted: false,
                attachmentKind: .photo,
                attachmentCount: 2,
                deliveryState: .failed
            ),
            unreadCount: 0,
            hasUnread: true,
            manuallyMarkedUnread: true,
            unreadMentionCount: 0,
            unreadMention: false,
            firstUnreadMessageIdHex: nil,
            lastReadMessageIdHex: nil,
            lastReadTimelineAt: nil,
            conversationCreatedAt: 1_600_000_000,
            activitySortAt: 1_700_000_000,
            updatedAt: 1_800_000_000,
            selfMembership: .member,
            conversationKind: .direct,
            muted: true,
            mutedUntilMs: nil,
            leaveRequestPending: true,
            leaveRequestedAtMs: 1_700_000_000_000
        )

        let chat = ChatItem(row: row, activeAccountIdHex: "self")

        #expect(chat.updatedAt == Date(timeIntervalSince1970: 1_700_000_000))
        #expect(chat.preview == "\(isolated("Alice")): 2 photos")
        #expect(chat.isDirect)
        #expect(chat.hasAuthoritativeConversationKind)
        #expect(chat.hasUnread && chat.manuallyMarkedUnread && chat.unreadCount == 0)
        #expect(chat.muted && chat.leaveRequestPending)
        #expect(chat.latestMessageDelivery == .failed)
    }

    @MainActor
    @Test func chatPreferenceActionsCall098RuntimeSurface() async throws {
        let runtime = FakeMarmotRuntime(accounts: [desktopAccount()])
        runtime.installGroups([messageGroup()])
        let state = WorkspaceState(clientFactory: { runtime })
        await state.bootstrap()
        let chat = try #require(state.activeChats.first)

        await state.setChatManuallyUnread(chat, manuallyUnread: true)
        await state.setChatMuted(chat, duration: nil)
        await state.clearChatMuted(chat)

        #expect(runtime.setChatManuallyUnreadCallCount == 1)
        #expect(runtime.lastManuallyUnreadValue == true)
        #expect(runtime.setChatMutedCallCount == 1)
        #expect(runtime.lastMutedUntilMs == nil)
        #expect(runtime.clearChatMutedCallCount == 1)
    }

    @MainActor
    @Test func startupReportsHostReadinessAndSchedulesRetentionSweep() async throws {
        let runtime = FakeMarmotRuntime(accounts: [desktopAccount()])
        let state = WorkspaceState(clientFactory: { runtime })

        await state.bootstrap()
        for _ in 0..<1_000 where runtime.sweepExpiredRetentionCallCount == 0 {
            await Task.yield()
        }

        #expect(runtime.sweepExpiredRetentionCallCount == 1)
        #expect(
            runtime.recordedHostPerformance.contains {
                $0.0 == .splashReady && $0.2 == .success
            }
        )

        state.recordForegroundLocalReady(since: DispatchTime.now().uptimeNanoseconds)
        #expect(runtime.recordedHostPerformance.last?.0 == .foregroundLocalReady)
        #expect(runtime.recordedHostPerformance.last?.2 == .success)
    }

    /// A leave already recorded by the core is neither an error nor an invitation to publish a
    /// second one: the affordance resolves to "already leaving", with no dialog and no alert.
    @MainActor
    @Test func pendingLeaveIntentBlocksDuplicatePublish() async throws {
        let account = desktopAccount()
        let runtime = FakeMarmotRuntime(accounts: [account])
        runtime.installGroupDetails(
            groupDetailsFixture(selfAccountIdHex: account.accountIdHex, selfIsAdmin: false),
            managementState: GroupManagementStateFfi(
                myAccountIdHex: account.accountIdHex,
                isSelfAdmin: false,
                isLastAdmin: false,
                canInvite: false,
                canLeave: false,
                requiresSelfDemoteBeforeLeave: false,
                leaveRequestPending: true,
                leaveRequestedAtMs: 1_700_000_000_000,
                memberActions: []
            )
        )
        let state = WorkspaceState(clientFactory: { runtime })
        await state.bootstrap()
        let chat = try #require(state.activeChats.first)
        await state.showGroupDetails(for: chat)

        await state.prepareSelectedChatLeave()

        #expect(state.groupDetailsSnapshot?.leaveRequestPending == true)
        #expect(runtime.leaveGroupCallCount == 0)
        #expect(state.chatPendingLeave == nil)
        #expect(state.chatActionAlert == nil)
        #expect(state.lastError == nil)
    }
}
