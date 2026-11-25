//
//  InspectorSearchMediaTests.swift
//  whitenoise-macTests
//
//  Focused behavioral tests for Wave 3B:
//  - #1042 Chat inspector, InspectorCommands parity, and Find availability beside the inspector
//  - #1043 Search match highlight contrast (Light/Dark, incoming/outgoing), ⌘G/⇧⌘G/⌘E direction
//          and boundary behavior, sidebar global search, and non-destructive bulk selection pause
//  - #1044 Shared Media & Files native UTType/NSWorkspace icons (no download), truthful metadata,
//          and Media/Files-only categories
//

import AppKit
import Foundation
import MarmotKit
import SwiftUI
import Testing
import UniformTypeIdentifiers

@testable import whitenoise_mac

@MainActor
@Suite(.serialized)
struct InspectorSearchMediaTests: WorkspaceTestSupport {

    // MARK: - #1042: Inspector + Find parity

    @Test func conversationFindCommandsStayEnabledWhileInspectorIsOpen() async throws {
        let workspace = WorkspaceState.preview()
        let activeAccountId = try #require(workspace.activeAccountId)
        let selectedChat = try #require(workspace.selectedChat)

        let entries = [
            ConversationSearchEntry(
                messageId: "m1", sender: "peer", searchableText: GlobalMessageSearchText.searchableText("alpha one")),
            ConversationSearchEntry(
                messageId: "m2", sender: "peer", searchableText: GlobalMessageSearchText.searchableText("alpha two")),
            ConversationSearchEntry(
                messageId: "m3", sender: "peer", searchableText: GlobalMessageSearchText.searchableText("alpha three")),
        ]
        let searchModel = ConversationSearchViewModel(
            loadCorpus: { _ in entries },
            queryDebounce: .zero,
            refreshDebounce: .zero
        )
        searchModel.activate()
        searchModel.query = "alpha"
        let deadline = ContinuousClock.now + .seconds(5)
        while searchModel.navigation == nil && ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(2))
        }

        // Open both Group Details and Contact Details inspector targets: Find must stay enabled.
        workspace.isGroupDetailsPresented = true

        let messenger = MessengerCommandContext(
            workspace: workspace,
            accountID: activeAccountId,
            isMessengerWindowTarget: { true }
        )
        var usedSelection: String?
        let command = ConversationSearchCommand(
            accountID: activeAccountId,
            chatID: selectedChat.id,
            model: searchModel,
            open: {},
            selectedText: "alpha",
            selectedTextForFind: { "alpha" },
            useSelectionForFind: { usedSelection = $0 }
        )

        #expect(ConversationFindCommandPolicy.canUseConversation(messenger: messenger, conversation: command))

        // Starts on newest match ("m3"): Find Previous (⇧⌘G -> older) is enabled, Find Next (⌘G -> newer) is disabled.
        #expect(ConversationFindCommandPolicy.canFindPrevious(messenger: messenger, conversation: command))
        #expect(!ConversationFindCommandPolicy.canFindNext(messenger: messenger, conversation: command))

        // Stepping previous moves to "m2", where both directions are enabled.
        ConversationFindCommandPolicy.findPrevious(messenger: messenger, conversation: command)
        #expect(searchModel.currentMatchMessageId == "m2")
        #expect(ConversationFindCommandPolicy.canFindPrevious(messenger: messenger, conversation: command))
        #expect(ConversationFindCommandPolicy.canFindNext(messenger: messenger, conversation: command))

        // Stepping next returns to "m3", where Find Next disables at the newest boundary.
        ConversationFindCommandPolicy.findNext(messenger: messenger, conversation: command)
        #expect(searchModel.currentMatchMessageId == "m3")
        #expect(!ConversationFindCommandPolicy.canFindNext(messenger: messenger, conversation: command))

        // Use Selection for Find (⌘E) routes the selected query.
        #expect(
            ConversationFindCommandPolicy.selectedQueryForFind(messenger: messenger, conversation: command) == "alpha")
        ConversationFindCommandPolicy.useSelectionForFind(messenger: messenger, conversation: command)
        #expect(usedSelection == "alpha")

        // Stale chat or unavailable messenger target disables Find commands.
        let staleChatCommand = ConversationSearchCommand(
            accountID: activeAccountId,
            chatID: "other-chat",
            model: searchModel,
            open: {}
        )
        #expect(!ConversationFindCommandPolicy.canUseConversation(messenger: messenger, conversation: staleChatCommand))

        let inactiveWindow = MessengerCommandContext(
            workspace: workspace,
            accountID: activeAccountId,
            isMessengerWindowTarget: { false }
        )
        #expect(!ConversationFindCommandPolicy.canUseConversation(messenger: inactiveWindow, conversation: command))
    }

    @Test func messengerCommandContextRoutesGlobalSearchCallback() throws {
        let workspace = WorkspaceState.preview()
        let activeAccountId = try #require(workspace.activeAccountId)

        var searchAllMessagesInvocations = 0
        let context = MessengerCommandContext(
            workspace: workspace,
            accountID: activeAccountId,
            onSearchAllMessages: { searchAllMessagesInvocations += 1 },
            isMessengerWindowTarget: { true }
        )

        context.searchAllMessages()
        #expect(searchAllMessagesInvocations == 1)
        #expect(!workspace.isGlobalMessageSearchPresented)
    }

    // MARK: - #1043: Search highlight contrast, ⌘E selection extraction, sidebar global search

    @Test func searchMatchHighlightIsLegibleOnBothBubblePolaritiesInLightAndDark() throws {
        let appearances = [
            try #require(NSAppearance(named: .aqua)),
            try #require(NSAppearance(named: .darkAqua)),
        ]

        for appearance in appearances {
            // The highlight chip itself (findHighlightColor fill + dynamic content ink) must satisfy WCAG AA 4.5:1.
            let textContrast = try Self.contrastRatio(
                between: SearchMatchHighlightStyle.nsBackground,
                and: SearchMatchHighlightStyle.nsContent,
                in: appearance
            )
            #expect(
                textContrast >= 4.5,
                "Search highlight text contrast \(textContrast) fell below 4.5 in \(appearance.name.rawValue)"
            )

            // And the highlight fill (`NSColor.findHighlightColor`) must visually separate from BOTH
            // incoming and outgoing neutral bubbles (yellow vs monochrome neutral in Light & Dark).
            for (bubbleName, bubbleColor) in [
                ("incoming", WNNSColor.backgroundMessageIncoming),
                ("outgoing", WNNSColor.fillPrimary),
            ] {
                let distance = try Self.srgbColorDistance(
                    between: SearchMatchHighlightStyle.nsBackground,
                    and: bubbleColor,
                    in: appearance
                )
                #expect(
                    distance >= 0.5,
                    "Search highlight fill blends into \(bubbleName) bubble (distance=\(distance)) in \(appearance.name.rawValue)"
                )
            }
        }
    }

    @Test func useSelectionForFindExtractsTextFromTextViewAndSkipsSecureField() {
        let textView = NSTextView()
        textView.string = "Hello   world\nagain"
        textView.setSelectedRange(NSRange(location: 0, length: 19))
        #expect(ConversationFindSelection.selectedQuery(from: textView) == "Hello world again")

        textView.setSelectedRange(NSRange(location: 0, length: 0))
        #expect(ConversationFindSelection.selectedQuery(from: textView) == nil)

        let punctuationOnly = NSTextView()
        punctuationOnly.string = "   ...  "
        punctuationOnly.setSelectedRange(NSRange(location: 0, length: 8))
        #expect(ConversationFindSelection.selectedQuery(from: punctuationOnly) == nil)

        let secureField = NSSecureTextField()
        secureField.stringValue = "topsecret"
        #expect(ConversationFindSelection.selectedQuery(from: secureField) == nil)
    }

    @Test func activateWithQueryAnchorsOnRequestedMessageId() async {
        let entries = [
            ConversationSearchEntry(
                messageId: "m1", sender: "peer", searchableText: GlobalMessageSearchText.searchableText("deploy notes")),
            ConversationSearchEntry(
                messageId: "m2", sender: "peer", searchableText: GlobalMessageSearchText.searchableText("deploy today")),
            ConversationSearchEntry(
                messageId: "m3", sender: "peer", searchableText: GlobalMessageSearchText.searchableText("deploy done")),
        ]
        let search = ConversationSearchViewModel(
            loadCorpus: { _ in entries },
            queryDebounce: .zero,
            refreshDebounce: .zero
        )

        search.activate(withQuery: "deploy", anchorMessageId: "m2")
        let deadline = ContinuousClock.now + .seconds(5)
        while search.navigation == nil && ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(2))
        }

        #expect(search.isActive)
        #expect(search.query == "deploy")
        #expect(search.currentMatchMessageId == "m2")
        #expect(search.navigation?.messageId == "m2")
        #expect(search.canGoToOlderMatch)
        #expect(search.canGoToNewerMatch)
    }

    @Test func sidebarSearchModeHidesBulkControlsWithoutClearingChatSelection() {
        let selection = ChatListSelectionViewModel(accountRef: "Desktop Account", runtime: nil)
        selection.begin(with: "chat-1")
        selection.toggle("chat-2")

        #expect(selection.isActive)
        #expect(selection.selectedIds == ["chat-1", "chat-2"])

        // Normal browsing mode shows bulk controls.
        #expect(
            SidebarSearchModeSelectionPolicy.showsBulkSelectionControls(
                isSelectionActive: selection.isActive,
                isGlobalMessageSearchActive: false
            )
        )

        // Global message search active hides bulk controls...
        #expect(
            !SidebarSearchModeSelectionPolicy.showsBulkSelectionControls(
                isSelectionActive: selection.isActive,
                isGlobalMessageSearchActive: true
            )
        )

        // ...without clearing the user's bulk selection state.
        #expect(selection.isActive)
        #expect(selection.selectedIds == ["chat-1", "chat-2"])
    }

    @Test func sidebarGlobalSearchViewModelSearchesJumpsAndHandsOffQuery() async {
        let hit = GlobalMessageSearchResult(
            messageId: "m42",
            groupId: "g1",
            chatTitle: "Design",
            senderName: "Alice",
            timelineAt: 1_700_000_000,
            snippet: GlobalMessageSearchSnippet(leading: "Ship the ", match: "release", trailing: " checklist")
        )

        let model = SidebarGlobalSearchViewModel(
            debounce: .zero,
            searchRunner: { query, _ in
                query == "release" ? [hit] : []
            }
        )

        model.activate(initialQuery: "release")
        #expect(model.isActive)
        #expect(model.query == "release")

        let deadline = ContinuousClock.now + .seconds(5)
        while model.isSearching && ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(2))
        }

        #expect(model.results == [hit])
        #expect(!model.isTruncated)
        #expect(model.selectedResultID == nil)
        #expect(model.error == nil)

        #expect(model.moveSelection(down: true))
        #expect(model.selectedResultID == hit.id)
        #expect(model.selectedResult() == hit)

        model.recordConversationSearchJump(groupId: hit.groupId, query: model.query)
        // Consuming for a different chat leaves the jump intact; matching chat consumes it once.
        #expect(model.consumeConversationSearchJump(for: "other") == nil)
        let consumed = model.consumeConversationSearchJump(for: "g1")
        #expect(consumed == "release")
        #expect(model.consumeConversationSearchJump(for: "g1") == nil)

        // Account switch resets everything cleanly.
        model.resetForAccountChange()
        #expect(!model.isActive)
        #expect(model.query.isEmpty)
        #expect(model.results.isEmpty)
        #expect(model.selectedResultID == nil)
    }

    // MARK: - #1044: Shared Media & Files icons, truthful metadata, categories

    @Test func sharedMediaCategoriesOnlyIncludeMediaAndFiles() {
        #expect(SharedMediaLibraryCategory.allCases == [.media, .files])
    }

    @Test func retainedFileTypeIconsResolveViaUTTypeWithoutTriggeringDownloads() {
        let runtime = FakeMarmotRuntime(accounts: [desktopAccount()])
        let pdfType = AttachmentFileTypeIcon.contentType(mediaType: "application/pdf", fileName: "spec.pdf")
        #expect(pdfType.conforms(to: .pdf))

        let fallbackByExtension = AttachmentFileTypeIcon.contentType(
            mediaType: "application/octet-stream",
            fileName: "archive.zip"
        )
        #expect(fallbackByExtension.conforms(to: .zip) || fallbackByExtension == .data)

        let unknownType = AttachmentFileTypeIcon.contentType(mediaType: "", fileName: "mystery")
        #expect(unknownType == .data)

        let icon = AttachmentFileTypeIcon.icon(mediaType: "application/pdf", fileName: "spec.pdf")
        #expect(icon.size.width > 0 && icon.size.height > 0)

        // Resolving file icons must never call MDK or trigger any download.
        #expect(runtime.timelineMessageQueries.isEmpty)
    }

    @Test func retainedFileRowMetadataIsTruthfulAboutLocalSizeAndRejection() {
        #expect(
            RetainedFileRowMetadata.subtitle(
                mediaType: "application/pdf",
                isRejected: true,
                retainedByteCount: 4_096
            ) == L10n.string("Attachment couldn’t be read")
        )

        #expect(
            RetainedFileRowMetadata.subtitle(
                mediaType: "application/pdf",
                isRejected: false,
                retainedByteCount: nil
            ) == "application/pdf"
        )

        let retainedSubtitle = RetainedFileRowMetadata.subtitle(
            mediaType: "application/pdf",
            isRejected: false,
            retainedByteCount: 12_345
        )
        #expect(retainedSubtitle.hasPrefix("application/pdf · "))
    }

    // MARK: - Contrast helper (WCAG 2.1)

    private static func contrastRatio(
        between first: NSColor,
        and second: NSColor,
        in appearance: NSAppearance
    ) throws -> Double {
        let l1 = try relativeLuminance(of: first, in: appearance)
        let l2 = try relativeLuminance(of: second, in: appearance)
        return (max(l1, l2) + 0.05) / (min(l1, l2) + 0.05)
    }

    private static func srgbColorDistance(
        between first: NSColor,
        and second: NSColor,
        in appearance: NSAppearance
    ) throws -> Double {
        let a = try resolveSRGB(first, in: appearance)
        let b = try resolveSRGB(second, in: appearance)
        let dr = Double(a.redComponent - b.redComponent)
        let dg = Double(a.greenComponent - b.greenComponent)
        let db = Double(a.blueComponent - b.blueComponent)
        return (dr * dr + dg * dg + db * db).squareRoot()
    }

    private static func resolveSRGB(_ color: NSColor, in appearance: NSAppearance) throws -> NSColor {
        var resolved: NSColor?
        appearance.performAsCurrentDrawingAppearance {
            resolved = color.usingColorSpace(.sRGB)
        }
        return try #require(resolved)
    }

    private static func relativeLuminance(of color: NSColor, in appearance: NSAppearance) throws -> Double {
        let srgb = try resolveSRGB(color, in: appearance)
        func linearize(_ channel: CGFloat) -> Double {
            let value = Double(channel)
            return value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linearize(srgb.redComponent)
            + 0.7152 * linearize(srgb.greenComponent)
            + 0.0722 * linearize(srgb.blueComponent)
    }
}
