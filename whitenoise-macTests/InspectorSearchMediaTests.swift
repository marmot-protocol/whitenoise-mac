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
        var liveSelection: String? = "alpha"
        let command = ConversationSearchCommand(
            accountID: activeAccountId,
            chatID: selectedChat.id,
            model: searchModel,
            open: {},
            selectedTextForFind: { liveSelection },
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

        // Use Selection for Find (⌘E) routes the live selection and disables immediately when focus leaves.
        #expect(
            ConversationFindCommandPolicy.selectedQueryForFind(messenger: messenger, conversation: command) == "alpha")
        ConversationFindCommandPolicy.useSelectionForFind(messenger: messenger, conversation: command)
        #expect(usedSelection == "alpha")

        liveSelection = nil
        usedSelection = nil
        #expect(ConversationFindCommandPolicy.selectedQueryForFind(messenger: messenger, conversation: command) == nil)
        ConversationFindCommandPolicy.useSelectionForFind(messenger: messenger, conversation: command)
        #expect(usedSelection == nil)

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

    @Test func openSidebarGlobalSearchPreservesNewGroupDraft() throws {
        let workspace = WorkspaceState.preview()
        let activeAccountId = try #require(workspace.activeAccountId)
        workspace.showNewChat()
        workspace.composePane = .nameGroup
        workspace.groupDraftRetentionSecs = 86_400

        let globalSearch = SidebarGlobalSearchViewModel(debounce: .zero)
        let context = MessengerCommandContext(
            workspace: workspace,
            accountID: activeAccountId,
            onSearchAllMessages: {
                SidebarGlobalSearchViewModel.open(in: workspace, globalSearch: globalSearch)
            },
            isMessengerWindowTarget: { true }
        )

        context.searchAllMessages()
        #expect(globalSearch.isActive)
        #expect(workspace.isNewChatComposerVisible)
        #expect(workspace.composePane == .nameGroup)
        #expect(workspace.groupDraftRetentionSecs == 86_400)

        globalSearch.dismiss()
        #expect(!globalSearch.isActive)
        #expect(workspace.isNewChatComposerVisible)
        #expect(workspace.groupDraftRetentionSecs == 86_400)
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

    @Test func useSelectionForFindAcceptsTranscriptSelectionAndRejectsComposerAndSecureField() {
        let transcriptTable = TranscriptNSTableView()
        let transcriptTextView = NSTextView()
        transcriptTable.addSubview(transcriptTextView)
        transcriptTextView.string = "Hello   world\nagain"
        transcriptTextView.setSelectedRange(NSRange(location: 0, length: 19))
        #expect(ConversationFindSelection.selectedQuery(from: transcriptTextView) == "Hello world again")

        transcriptTextView.setSelectedRange(NSRange(location: 0, length: 0))
        #expect(ConversationFindSelection.selectedQuery(from: transcriptTextView) == nil)

        transcriptTextView.string = "   ...  "
        transcriptTextView.setSelectedRange(NSRange(location: 0, length: 8))
        #expect(ConversationFindSelection.selectedQuery(from: transcriptTextView) == nil)

        // A composer or sidebar text view outside `TranscriptNSTableView` must never feed `⌘E`.
        let composerContainer = NSView()
        let composerTextView = NSTextView()
        composerContainer.addSubview(composerTextView)
        composerTextView.string = "unsent draft text"
        composerTextView.setSelectedRange(NSRange(location: 0, length: 12))
        #expect(ConversationFindSelection.selectedQuery(from: composerTextView) == nil)

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

        // Reordering chats without changing membership keeps results and selection untouched.
        model.handleVisibleChatsChanged(visibleGroupIds: ["g1", "g2"])
        let resultsAfterFirstSet = await waitForSearchIdle(model)
        #expect(resultsAfterFirstSet == [hit])
        #expect(model.moveSelection(down: true))
        #expect(model.selectedResultID == hit.id)

        var runnerCalls = 0
        let reorderModel = SidebarGlobalSearchViewModel(
            debounce: .zero,
            searchRunner: { query, _ in
                runnerCalls += 1
                return query == "release" ? [hit] : []
            }
        )
        reorderModel.handleVisibleChatsChanged(visibleGroupIds: ["g1", "g2"])
        reorderModel.activate(initialQuery: "release")
        _ = await waitForSearchIdle(reorderModel)
        #expect(runnerCalls == 1)
        #expect(reorderModel.moveSelection(down: true))
        #expect(reorderModel.selectedResultID == hit.id)

        // Same membership in any order does not clear results, reset selection, or re-run search.
        reorderModel.handleVisibleChatsChanged(visibleGroupIds: ["g2", "g1"])
        #expect(runnerCalls == 1)
        #expect(reorderModel.results == [hit])
        #expect(reorderModel.selectedResultID == hit.id)

        // Removing a chat invalidates and re-runs the search.
        reorderModel.handleVisibleChatsChanged(visibleGroupIds: ["g2"])
        _ = await waitForSearchIdle(reorderModel)
        #expect(runnerCalls == 2)

        // Stopping (as AccountScope.cancelAll does on account switch) resets everything cleanly.
        model.stop()
        #expect(!model.isActive)
        #expect(model.query.isEmpty)
        #expect(model.results.isEmpty)
        #expect(model.selectedResultID == nil)
    }

    @Test func lateResultOpenCannotDismissNewerSearchSession() async {
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
            searchRunner: { _, _ in [hit] }
        )
        model.activate(initialQuery: "release")
        _ = await waitForSearchIdle(model)

        var resumeNavigate: CheckedContinuation<GlobalMessageNavigationTarget?, Never>?
        model.openResult(hit, query: "release") { result, query in
            await withCheckedContinuation { continuation in
                resumeNavigate = continuation
            }
        }
        // Let the openResult task suspend at navigate.
        await Task.yield()

        // User backs out and opens a fresh search session while the old open is still suspended.
        model.dismiss()
        model.activate(initialQuery: "newer")
        _ = await waitForSearchIdle(model)
        #expect(model.isActive)
        #expect(model.query == "newer")

        // The stale navigation completes now; it must NOT dismiss the newer search session.
        resumeNavigate?.resume(
            returning: GlobalMessageNavigationTarget(
                requestId: UUID(), groupId: hit.groupId, messageId: hit.messageId, searchQuery: "release"
            )
        )
        await Task.yield()
        await Task.yield()

        #expect(model.isActive)
        #expect(model.query == "newer")
    }

    @Test func openGlobalMessageSearchResultReturnsNilWhenChatIsMissingAndCarriesQueryWhenPresent() async throws {
        let workspace = WorkspaceState.preview()
        let missing = GlobalMessageSearchResult(
            messageId: "m1",
            groupId: "missing-chat-id",
            chatTitle: "Deleted",
            senderName: "Alice",
            timelineAt: 10,
            snippet: GlobalMessageSearchSnippet(leading: "", match: "needle", trailing: "")
        )

        let missingTarget = await workspace.openGlobalMessageSearchResult(missing, searchQuery: "needle")
        #expect(missingTarget == nil)
        #expect(workspace.pendingMessageNavigation == nil)

        let chat = try #require(workspace.activeChats.first)
        workspace.selectChat(chat)
        workspace.timelineTaskGroupId = chat.id
        let present = GlobalMessageSearchResult(
            messageId: String(repeating: "b", count: 64),
            groupId: chat.id,
            chatTitle: chat.title,
            senderName: "Alice",
            timelineAt: 10,
            snippet: GlobalMessageSearchSnippet(leading: "", match: "needle", trailing: "")
        )
        let target = await workspace.openGlobalMessageSearchResult(present, searchQuery: "  needle  ")
        #expect(target?.groupId == chat.id)
        #expect(target?.messageId == present.messageId)
        #expect(target?.searchQuery == "needle")
        #expect(workspace.pendingMessageNavigation == target)
    }

    @Test func attachmentViewModelReopeningInspectorDoesNotEraseInFlightLoadMorePages() async throws {
        let runtime = FakeMarmotRuntime(accounts: [desktopAccount()])
        let entry1 = Self.sharedImageEntry(messageId: "m1", fileName: "one.png", timelineAt: 200)
        let entry2 = Self.sharedImageEntry(messageId: "m2", fileName: "two.png", timelineAt: 100)
        let page1 = AttachmentPageReadFfi.page(
            page: AttachmentPageFfi(
                entries: [entry1],
                version: AttachmentHistoryVersion(noPointer: .init()),
                nextCursor: nil,
                hasMore: true
            )
        )
        let page2 = AttachmentPageReadFfi.page(
            page: AttachmentPageFfi(
                entries: [entry2],
                version: AttachmentHistoryVersion(noPointer: .init()),
                nextCursor: nil,
                hasMore: false
            )
        )
        runtime.attachmentHistoryPageQueue = [page1, page2]
        let model = AttachmentViewModel(accountRef: "Desktop Account", groupIdHex: "g1", runtime: runtime)
        await model.refreshHistory()
        #expect(model.items.map(\.messageIdHex) == ["m1"])

        // Pause page 2 in flight and simulate reopening Chat Info calling refreshHistory().
        let enteredPage2 = AsyncStream<Void>.makeStream()
        let releasePage2 = AsyncStream<Void>.makeStream()
        runtime.attachmentHistoryPageHook = {
            enteredPage2.continuation.yield(())
            var iterator = releasePage2.stream.makeAsyncIterator()
            _ = await iterator.next()
        }

        let loadMoreTask = Task { await model.loadMore() }
        var enteredIterator = enteredPage2.stream.makeAsyncIterator()
        _ = await enteredIterator.next()

        // Calling refreshHistory while loadMore is in flight must NOT wipe entries/cursor/version.
        await model.refreshHistory()
        #expect(model.items.map(\.messageIdHex) == ["m1"])

        releasePage2.continuation.yield(())
        await loadMoreTask.value
        #expect(model.items.map(\.messageIdHex) == ["m1", "m2"])
    }

    @Test func attachmentViewModelTransferObservationSurvivesFirstCloseAndDoesNotRestartAfterFinalClose() async throws {
        let runtime = FakeMarmotRuntime(accounts: [desktopAccount()])
        let entry = Self.sharedImageEntry(messageId: "m1", fileName: "one.png", timelineAt: 200)
        let target = AttachmentLocalTargetFfi(messageIdHex: "m1", sourceMessageIdHex: "m1", attachmentIndex: 0)
        runtime.attachmentHistoryPageResult = .page(
            page: AttachmentPageFfi(
                entries: [entry],
                version: AttachmentHistoryVersion(noPointer: .init()),
                nextCursor: nil,
                hasMore: false
            )
        )
        runtime.attachmentTransferSnapshots = [
            AttachmentTransferSnapshotFfi(items: [
                AttachmentTransferStatusFfi(
                    reference: "ref-1",
                    state: .downloading,
                    attempt: 1,
                    received: 64,
                    total: 128,
                    retryAt: nil
                )
            ])
        ]
        runtime.attachmentTransferDelayNanoseconds = 60_000_000

        let model = AttachmentViewModel(accountRef: "Desktop Account", groupIdHex: "g1", runtime: runtime)
        let inspectorOwner = model.beginTransferObservation()
        let libraryOwner = model.beginTransferObservation()
        await model.refreshHistory()

        // Close the first surface while the transfer snapshot is still pending.
        model.endTransferObservation(inspectorOwner)
        #expect(runtime.attachmentTransferCancellationCount == 0)

        // The second surface still receives the snapshot!
        let deadline = ContinuousClock.now + .seconds(5)
        while model.transfersByTarget[target]?.state != .downloading && ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(5))
        }
        #expect(model.transfersByTarget[target]?.state == .downloading)

        // Now pause an explicit refreshLocalAssets() in flight, close the FINAL owner, then let the
        // refresh finish: it must NOT start a replacement transfer subscription with zero owners!
        let subscriptionsBeforeFinalClose = runtime.attachmentTransferSubscriptionCount
        let enteredRefresh = AsyncStream<Void>.makeStream()
        let releaseRefresh = AsyncStream<Void>.makeStream()
        runtime.attachmentLocalAssetsHook = {
            enteredRefresh.continuation.yield(())
            var iterator = releaseRefresh.stream.makeAsyncIterator()
            _ = await iterator.next()
        }

        let refreshTask = Task { await model.refreshLocalAssets() }
        var enteredRefreshIterator = enteredRefresh.stream.makeAsyncIterator()
        _ = await enteredRefreshIterator.next()

        model.endTransferObservation(libraryOwner)
        #expect(runtime.attachmentTransferCancellationCount >= 1)

        releaseRefresh.continuation.yield(())
        await refreshTask.value
        #expect(runtime.attachmentTransferSubscriptionCount == subscriptionsBeforeFinalClose)
    }

    private static func sharedImageEntry(messageId: String, fileName: String, timelineAt: UInt64)
        -> AttachmentEntryFfi
    {
        AttachmentEntryFfi(
            messageIdHex: messageId,
            sourceMessageIdHex: messageId,
            sender: "alice",
            timelineAt: timelineAt,
            receivedAt: timelineAt,
            sourceEpoch: 1,
            category: .image,
            role: .shared,
            attachment: .accepted(
                attachmentIndex: 0,
                reference: MediaAttachmentReferenceFfi(
                    locators: [],
                    ciphertextSha256: "ciphertext-\(messageId)",
                    plaintextSha256: "plaintext-\(messageId)",
                    nonceHex: "nonce-\(messageId)",
                    fileName: fileName,
                    mediaType: "image/png",
                    version: .v2,
                    sourceEpoch: 1,
                    dim: nil,
                    thumbhash: nil
                )
            )
        )
    }

    private func waitForSearchIdle(_ model: SidebarGlobalSearchViewModel) async -> [GlobalMessageSearchResult] {
        let deadline = ContinuousClock.now + .seconds(5)
        while model.isSearching && ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(2))
        }
        return model.results
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
