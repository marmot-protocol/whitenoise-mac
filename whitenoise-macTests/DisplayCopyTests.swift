//
//  DisplayCopyTests.swift
//  whitenoise-macTests
//

import AppKit
import Foundation
import Testing

@testable import whitenoise_mac

struct DisplayCopyTests {
    private static let english = Locale(identifier: "en")

    private static let settingsPages: [SettingsPage] = [
        .overview, .preferences, .profile, .identityKeys, .relays, .keyPackages, .appearance,
        .privacySecurity, .blockedUsers, .notifications, .storage, .agents, .support, .donate,
        .developerMode, .quarantinedGroups,
    ]

    /// A mistyped SF Symbol name compiles and renders as empty space, so the only place it can be
    /// caught is by asking the system to resolve it.
    private func expectResolvableSymbols(_ names: [String], sourceLocation: SourceLocation = #_sourceLocation) {
        for name in names {
            #expect(
                NSImage(systemSymbolName: name, accessibilityDescription: nil) != nil,
                "SF Symbol \(name) does not exist",
                sourceLocation: sourceLocation
            )
        }
    }

    @Test func everySettingsDestinationHasItsOwnResolvableGlyphAndTitle() {
        let symbols = Self.settingsPages.map(\.systemImage)
        expectResolvableSymbols(symbols)
        #expect(Set(symbols).count == symbols.count)

        let titles = Self.settingsPages.map { $0.title(in: Self.english) }
        #expect(titles.allSatisfy { !$0.isEmpty })
        #expect(Set(titles).count == titles.count)
    }

    @Test func chatAndMessageGlyphsResolve() {
        expectResolvableSymbols(ChatListFilter.allCases.map(\.systemImage))
        expectResolvableSymbols(
            [MessageMediaKind.image, .audio, .video, .file].map(\.systemImageName)
        )
        expectResolvableSymbols(
            [ChatPreviewAttachmentKind.photo, .video, .audio, .file, .mixed].map(\.systemImageName)
        )
        expectResolvableSymbols(
            [
                MessagePresentation.chat, .agentStreamStart, .agentActivity, .agentOperation, .groupSystem,
                .unsupported,
            ].map(\.systemImage)
        )
        expectResolvableSymbols([ChatSelfMembership.left, .removed].compactMap(\.endedSymbolName))
        #expect(ChatSelfMembership.member.endedSymbolName == nil)
        expectResolvableSymbols(RelayRole.allCases.map(\.symbol))
        expectResolvableSymbols([RelayPublishState.published, .notPublished].map(\.symbol))
    }

    @Test func messagePresentationDebugLabelsAreDistinct() {
        let labels = [
            MessagePresentation.chat, .agentStreamStart, .agentActivity, .agentOperation, .groupSystem, .unsupported,
        ].map(\.debugLabel)
        #expect(Set(labels).count == labels.count)
        #expect(MessagePresentation.chat.isChatBubble)
        #expect(!MessagePresentation.groupSystem.isChatBubble)
    }

    @Test func withheldNotificationPreviewsNeverShowTheMessageText() throws {
        // The settings copy is the privacy contract: "Sender only" and "Hide all" promise the
        // message text never reaches the banner, so their worked examples must not show it.
        let fullExample = NotificationPreviewMode.full.example
        let messageText = try #require(fullExample.split(separator: "·").last)
            .trimmingCharacters(in: .whitespaces)
        #expect(!messageText.isEmpty)
        for mode in [NotificationPreviewMode.senderOnly, .hidden] {
            #expect(!mode.example.contains(messageText))
        }

        let modes = NotificationPreviewMode.allCases
        #expect(Set(modes.map(\.label)).count == modes.count)
        #expect(Set(modes.map(\.detail)).count == modes.count)
        #expect(Set(modes.map(\.example)).count == modes.count)
    }

    @Test func appearanceAndFilterLabelsAreDistinct() {
        let appearance = AppearancePreference.allCases.map(\.label)
        #expect(appearance.allSatisfy { !$0.isEmpty })
        #expect(Set(appearance).count == appearance.count)

        let filters = ChatListFilter.allCases.map(\.title)
        #expect(Set(filters).count == filters.count)
    }

    @Test func languagePickerOffersSystemThenEveryLanguageOnceInItsOwnName() {
        #expect(AppLanguage.pickerChoices.first == .system)
        #expect(Set(AppLanguage.pickerChoices) == Set(AppLanguage.allCases))
        #expect(AppLanguage.pickerChoices.count == AppLanguage.allCases.count)
        #expect(!AppLanguage.supportedAppLanguages.contains(.system))

        let names = AppLanguage.supportedAppLanguages.map(\.displayName)
        #expect(Set(names).count == names.count)
        // Endonyms: a reader looking for their language finds it spelled the way they spell it,
        // whatever language the app is currently in.
        #expect(AppLanguage.spanish.displayName == "Español")
        #expect(AppLanguage.german.displayName == "Deutsch")
        #expect(AppLanguage.chineseTraditional.displayName == "繁體中文")
        #expect(AppLanguage.system.displayName == L10n.string("System"))
    }

    @Test func relayRolesAndPublishStatesDescribeThemselves() {
        let roleLabels = RelayRole.allCases.map(\.label)
        let explanations = RelayRole.allCases.map(\.explanation)
        #expect(Set(roleLabels).count == RelayRole.allCases.count)
        #expect(Set(explanations).count == RelayRole.allCases.count)
        #expect(RelayPublishState.published.label != RelayPublishState.notPublished.label)
    }

    @Test func relayRowsListTheirRolesInCanonicalOrder() {
        let item = RelayEndpointItem(
            id: "wss://relay.example",
            displayName: "relay.example",
            url: "wss://relay.example",
            roles: [.inbox, .profile],
            isInsecure: false,
            publishState: .published
        )
        #expect(item.orderedRoles == RelayRole.allCases)

        let inboxOnly = RelayEndpointItem(
            id: "wss://inbox.example",
            displayName: "inbox.example",
            url: "wss://inbox.example",
            roles: [.inbox],
            isInsecure: false,
            publishState: .notPublished
        )
        #expect(inboxOnly.orderedRoles == [.inbox])
    }

    @Test func everyAgentPromptCarriesTheNpubAndTheConnectorGuide() {
        let npub = "npub1agentowner"
        let guide = AIAgentConnector.documentationURL.absoluteString
        let connectors = AIAgentConnector.allCases
        for connector in connectors {
            let prompt = connector.prompt(npub: npub)
            #expect(prompt.contains(npub), "\(connector) prompt dropped the npub")
            #expect(prompt.contains(guide), "\(connector) prompt dropped the connector guide")
        }
        #expect(Set(connectors.map(\.name)).count == connectors.count)
        #expect(Set(connectors.map(\.subtitle)).count == connectors.count)
        #expect(Set(connectors.map { $0.prompt(npub: npub) }).count == connectors.count)
    }

    @Test func transcriptExportErrorsNameTheirPath() throws {
        let url = URL(fileURLWithPath: "/tmp/whitenoise-export/transcript.json")
        let errors: [ConversationTranscriptExport.ExportError] = [
            .emptyPageWithMoreHistory,
            .unableToCreateTemporaryFile(url),
            .unableToCreateReplacementDirectory(url),
            .invalidSpoolData,
            .destinationIsDirectory(url),
        ]
        let descriptions = try errors.map { try #require($0.errorDescription) }
        #expect(Set(descriptions).count == errors.count)
        #expect(descriptions[1].contains(url.path))
        #expect(descriptions[2].contains(url.path))
        #expect(descriptions[4].contains(url.path))
        #expect(!descriptions[0].contains(url.path))
    }
}
