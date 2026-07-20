//
//  PureValueTests.swift
//  whitenoise-macTests
//
//  Pure, self-contained value-type tests moved out of the serialized
//  suite so they run in parallel (no shared global state).
//

import AppKit
import Combine
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

struct PureValueTests {
    @Test func selectedMentionsCanonicalizeByPickedNpubDespiteDisplayNameCollision() {
        let first = mentionCandidate(id: "first", displayName: "Alex", npub: "npub1qqqq")
        let second = mentionCandidate(id: "second", displayName: "Alex", npub: "npub1pppp")
        let draft = "Hi @Alex and @Alex"
        let nsDraft = draft as NSString
        let firstRange = nsDraft.range(of: "@Alex")
        let secondRange = nsDraft.range(of: "@Alex", options: [], range: NSRange(location: 8, length: 10))
        let selections = [
            ComposerMentionSelection(range: firstRange, displayText: "@Alex", npub: first.npub),
            ComposerMentionSelection(range: secondRange, displayText: "@Alex", npub: second.npub),
        ]

        #expect(
            ComposerMentionCanonicalizer.canonicalize(
                draft,
                selections: selections,
                candidates: [first, second]
            ) == "Hi @npub1qqqq and @npub1pppp"
        )
    }

    @Test func ambiguousTypedMentionIsNotGuessedWithoutPickerSelection() {
        let candidates = [
            mentionCandidate(id: "first", displayName: "Alex", npub: "npub1qqqq"),
            mentionCandidate(id: "second", displayName: "Alex", npub: "npub1pppp"),
        ]

        #expect(
            ComposerMentionCanonicalizer.canonicalize("Hi @Alex", candidates: candidates)
                == "Hi @Alex"
        )
    }

    @Test func selectedMentionIsIgnoredAfterItsVisibleTextIsEdited() {
        let candidate = mentionCandidate(id: "first", displayName: "Alex", npub: "npub1qqqq")
        let staleSelection = ComposerMentionSelection(
            range: NSRange(location: 3, length: 5),
            displayText: "@Alex",
            npub: candidate.npub
        )

        #expect(
            ComposerMentionCanonicalizer.canonicalize(
                "Hi @Alec",
                selections: [staleSelection],
                candidates: []
            ) == "Hi @Alec"
        )
    }

    @MainActor
    @Test func selectedMentionMarkersSurviveBoundaryEditsAndRejectInternalEdits() throws {
        let candidate = mentionCandidate(id: "first", displayName: "Alex", npub: "npub1qqqq")
        let textView = NSTextView()
        textView.isRichText = false
        textView.string = "@Alex "
        ComposerMentionMarkerStore.replaceAll(
            with: [
                ComposerMentionSelection(
                    range: NSRange(location: 0, length: 5),
                    displayText: "@Alex",
                    npub: candidate.npub
                )
            ],
            in: textView
        )

        textView.insertText("Hi ", replacementRange: NSRange(location: 0, length: 0))
        var selections = ComposerMentionMarkerStore.selections(in: textView)
        #expect(selections.map(\.range) == [NSRange(location: 3, length: 5)])

        textView.insertText(",", replacementRange: NSRange(location: 8, length: 0))
        selections = ComposerMentionMarkerStore.selections(in: textView)
        #expect(selections.map(\.range) == [NSRange(location: 3, length: 5)])
        #expect(
            ComposerMentionCanonicalizer.canonicalize(
                textView.string,
                selections: selections,
                candidates: [
                    candidate,
                    mentionCandidate(id: "second", displayName: "Alex", npub: "npub1pppp"),
                ]
            ) == "Hi @npub1qqqq, "
        )

        let editedMentionView = NSTextView()
        editedMentionView.isRichText = false
        editedMentionView.string = "@Alex "
        ComposerMentionMarkerStore.replaceAll(
            with: [
                ComposerMentionSelection(
                    range: NSRange(location: 0, length: 5),
                    displayText: "@Alex",
                    npub: candidate.npub
                )
            ],
            in: editedMentionView
        )
        editedMentionView.insertText("x", replacementRange: NSRange(location: 3, length: 0))
        #expect(ComposerMentionMarkerStore.selections(in: editedMentionView).isEmpty)
    }

    @MainActor
    @Test func mentionCoordinatorRepublishesContextAndRejectsStaleInsertionAcrossChats() throws {
        let firstScope = WorkspaceState.ComposerDraftKey(accountId: "account", chatId: "first")
        let secondScope = WorkspaceState.ComposerDraftKey(accountId: "account", chatId: "second")
        var boundText = "@Al"
        var measuredHeight: CGFloat = 20
        var boundSelections: [ComposerMentionSelection] = []
        var publishedContexts: [ComposerMentionContext?] = []
        var consumedInsertions: [UUID] = []
        let coordinator = ComposerMessageTextViewRepresentable.Coordinator(
            text: Binding(get: { boundText }, set: { boundText = $0 }),
            measuredHeight: Binding(get: { measuredHeight }, set: { measuredHeight = $0 }),
            mentionSelections: Binding(get: { boundSelections }, set: { boundSelections = $0 }),
            mentionContextScope: firstScope,
            onPasteMedia: { _ in },
            onSend: {},
            onMentionInsertionConsumed: { consumedInsertions.append($0) },
            onMentionContextChange: { publishedContexts.append($0) }
        )
        let textView = NSTextView()
        textView.string = boundText
        textView.setSelectedRange(NSRange(location: 3, length: 0))
        coordinator.textDidChange(Notification(name: NSText.didChangeNotification, object: textView))
        let firstContext = try #require(publishedContexts.last ?? nil)

        coordinator.synchronizeMentionContextScope(secondScope, in: textView)
        #expect(publishedContexts.compactMap { $0 }.count == 2)
        #expect(publishedContexts.last ?? nil == firstContext)

        let staleInsertion = ComposerMentionInsertion(
            scope: firstScope,
            context: firstContext,
            candidate: mentionCandidate(id: "first", displayName: "Alex", npub: "npub1qqqq")
        )
        coordinator.insertMentionIfNeeded(staleInsertion, into: textView)
        #expect(textView.string == "@Al")
        #expect(consumedInsertions == [staleInsertion.id])
    }

    @Test func mentionDisplayResolverRequiresACompleteBech32TokenBoundary() {
        let npub = "npub1qqqq"
        let names = [npub: "Alex"]

        #expect(MentionDisplayResolver.resolve(in: "Hi @\(npub)!", mentionNames: names) == "Hi @Alex!")
        #expect(MentionDisplayResolver.resolve(in: "Hi @\(npub)x", mentionNames: names) == "Hi @\(npub)x")
    }

    @Test func mentionQueryTracksMidDraftCaretAndSuppressesCompleteNpub() throws {
        let draft = "Before @Ale after"
        let caret = try #require(draft.range(of: "@Ale")?.upperBound)
        let session = try #require(ComposerMentionQuery.active(in: draft, upTo: caret))
        #expect(session.query == "Ale")
        #expect(String(draft[session.range]) == "@Ale")
        #expect(ComposerMentionQuery.active(in: "email@example.com") == nil)
        #expect(ComposerMentionQuery.looksLikeCompleteNpub("npub1" + String(repeating: "q", count: 58)))
    }

    @Test func mentionCandidateFilterMatchesAllIdentityFieldsAndCapsResults() {
        let candidates = (0..<12).map { index in
            mentionCandidate(
                id: "member-\(index)",
                displayName: index == 11 ? "Special Person" : "Member \(index)",
                npub: "npub1qqq\(index)"
            )
        }
        #expect(ComposerMentionQuery.filter(candidates, matching: "").count == 8)
        #expect(ComposerMentionQuery.filter(candidates, matching: "special").map(\.id) == ["member-11"])
        #expect(ComposerMentionQuery.filter(candidates, matching: "member-9").map(\.id) == ["member-9"])
        #expect(ComposerMentionQuery.filter(candidates, matching: "npub1qqq10").map(\.id) == ["member-10"])
    }

    @MainActor
    @Test func mentionRosterReusesCandidatesUntilGroupMembersChange() {
        let account = AccountItem.samples[0]
        let group = ChatItem.samples[0]
        let state = WorkspaceState(
            accounts: [account],
            chatsByAccount: [account.id: [group]],
            localNotificationCenter: NoopLocalNotificationCenter(),
            appActivityProvider: { false },
            conversationWindowVisibilityProvider: { false }
        )
        state.activeAccountId = account.id
        state.selection = .chat(group.id)

        let local = mentionMember(id: "self", displayName: "Local", npub: "npub1self", isSelf: true)
        let alice = mentionMember(id: "alice", displayName: "Alice", npub: "npub1alice")
        state.storeGroupMembers([local, alice], for: group.id)

        #expect(state.mentionRoster().map(\.id) == ["alice"])
        #expect(state.mentionRoster().map(\.id) == ["alice"])
        #expect(state.mentionRosterBuildCount == 1)

        let bob = mentionMember(id: "bob", displayName: "Bob", npub: "npub1bob")
        state.storeGroupMembers([local, bob], for: group.id)

        #expect(state.mentionRoster().map(\.id) == ["bob"])
        #expect(state.mentionRosterBuildCount == 2)
    }

    @Test func editedMessageAndHistoryResolveCanonicalMentionsButRetainWireText() async throws {
        let npub = "npub1qqqq"
        let base = MessageItem(
            id: "message",
            senderAccountIdHex: "sender",
            senderName: "Sender",
            body: "Original @\(npub)",
            mentionNames: [npub: "Alex"],
            sentAt: Date(timeIntervalSince1970: 1),
            timelineAt: 1,
            isOutgoing: false
        )
        let edited = base.applyingEdit(plaintext: "Edited @\(npub)")
        #expect(edited.body == "Edited @Alex")
        #expect(edited.wireBody == "Edited @\(npub)")

        let store = await MessageTimelineStore.loaded(with: [base])
        await store.replace(
            with: [base],
            editMutations: [
                .upsert(
                    MessageEditOverlay(
                        targetMessageIdHex: base.id,
                        editMessageIdHex: "edit",
                        sender: "sender",
                        plaintext: "Edited @\(npub)",
                        timelineAt: 2
                    )
                )
            ]
        )
        let history = await store.editHistory(forTarget: base.id)
        #expect(history.map(\.text) == ["Original @Alex", "Edited @Alex"])
    }

    @MainActor
    @Test func disappearingMessageCustomLabelFormatsCoreUInt64Value() async throws {
        // Regression for whitenoise-mac#212: values can originate from the core as
        // UInt64, and Int(value) traps above Int.max while `%d` truncates large
        // 64-bit values to misleading labels such as "-1 seconds".
        let above32BitSeconds = UInt64(Int32.max) + 1
        let oversizedSeconds = UInt64(Int.max) + 1

        #expect(DisappearingMessageOption.custom(above32BitSeconds).label == "2147483648 seconds")
        #expect(DisappearingMessageOption.custom(oversizedSeconds).label == "9223372036854775808 seconds")
    }

    @Test func messageDeletionCapabilityCoversEveryOwnershipAndRole() {
        struct Case {
            let name: String
            let isDirect: Bool
            let isOwn: Bool
            let isAdmin: Bool
            let forMe: Bool
            let forEveryone: Bool
        }
        let cases = [
            Case(name: "own DM", isDirect: true, isOwn: true, isAdmin: false, forMe: true, forEveryone: true),
            Case(name: "other's DM", isDirect: true, isOwn: false, isAdmin: false, forMe: true, forEveryone: false),
            // An admin flag on a DM's underlying two-member group must never grant for-everyone.
            Case(
                name: "other's DM, spurious admin", isDirect: true, isOwn: false, isAdmin: true,
                forMe: true, forEveryone: false),
            Case(name: "own group", isDirect: false, isOwn: true, isAdmin: false, forMe: true, forEveryone: true),
            Case(
                name: "other's group, admin", isDirect: false, isOwn: false, isAdmin: true,
                forMe: true, forEveryone: true),
            Case(
                name: "other's group, member", isDirect: false, isOwn: false, isAdmin: false,
                forMe: true, forEveryone: false),
        ]
        for testCase in cases {
            let capability = MessageDeletionCapability.resolve(
                isActionable: true,
                isDirectConversation: testCase.isDirect,
                isOwnMessage: testCase.isOwn,
                isSelfGroupAdmin: testCase.isAdmin
            )
            #expect(capability.canDeleteForMe == testCase.forMe, "for-me mismatch: \(testCase.name)")
            #expect(capability.canDeleteForEveryone == testCase.forEveryone, "for-everyone mismatch: \(testCase.name)")
        }
    }

    @Test func messageDeletionCapabilityIsEmptyForNonActionableBubbles() {
        // A deleted tombstone or system bubble offers no delete scope, regardless of role.
        let capability = MessageDeletionCapability.resolve(
            isActionable: false, isDirectConversation: false, isOwnMessage: true, isSelfGroupAdmin: true
        )
        #expect(capability == .none)
        #expect(!capability.canDelete)
    }

    @Test func messageDeletionCapabilityForMeIsUniversalForActionableBubbles() {
        // Any actionable message can be hidden locally, regardless of ownership or role.
        let otherMemberMessage = MessageDeletionCapability.resolve(
            isActionable: true, isDirectConversation: false, isOwnMessage: false, isSelfGroupAdmin: false
        )
        #expect(otherMemberMessage.canDeleteForMe)
        #expect(!otherMemberMessage.canDeleteForEveryone)
    }

    @Test func durationCountLabelsUseLocalePluralRules() {
        let russian = Locale(identifier: "ru")
        #expect(L10n.plural("%llu seconds", UInt64(1), locale: russian) == "1 секунда")
        #expect(L10n.plural("%llu seconds", UInt64(2), locale: russian) == "2 секунды")
        #expect(L10n.plural("%llu seconds", UInt64(5), locale: russian) == "5 секунд")
        #expect(L10n.plural("%llu days", UInt64(1), locale: russian) == "1 день")
        #expect(L10n.plural("%llu weeks", UInt64(1), locale: russian) == "1 неделя")
    }

    @Test func attachmentCountLabelsUseLocalePluralRules() {
        let russian = Locale(identifier: "ru")
        #expect(L10n.plural("%lld attachments", Int64(1), locale: russian) == "1 вложение")
        #expect(L10n.plural("%lld attachments", Int64(2), locale: russian) == "2 вложения")
        #expect(L10n.plural("%lld attachments", Int64(5), locale: russian) == "5 вложений")
    }

    @Test func composerAudioWaveformUsesPrecomputedFallbackBars() async throws {
        // Regression for whitenoise-mac#292: fallback waveform samples/bars are used
        // while metadata loads, including during playback-progress repaint ticks. Keep
        // the default fallback and its display bars as precomputed values so progress
        // updates can recolor an already-prepared waveform instead of regenerating it.
        #expect(MediaWaveformAnalyzer.fallbackSamples == MediaWaveformAnalyzer.fallback())
        #expect(
            ComposerAudioWaveformPresentation.fallbackPlaybackBars
                == ComposerAudioWaveformPresentation.bars(
                    for: MediaWaveformAnalyzer.fallbackSamples,
                    mode: .playback
                )
        )
    }

    @Test func composerAudioWaveformSelectsLoadedBarsForMatchingPayload() async throws {
        // The metadata-loaded path stores bars once, then playback progress should only
        // recolor those loaded bars. Stale or missing metadata keeps showing fallback.
        let loadedBars = ComposerAudioWaveformPresentation.bars(
            for: [0.15, 0.35, 0.65, 1.0],
            mode: .playback
        )

        #expect(
            ComposerAudioWaveformPresentation.visiblePlaybackBars(
                loadedBars: loadedBars,
                metadataPayloadID: "payload-a",
                currentPayloadID: "payload-a"
            ) == loadedBars
        )
        #expect(
            ComposerAudioWaveformPresentation.visiblePlaybackBars(
                loadedBars: loadedBars,
                metadataPayloadID: nil,
                currentPayloadID: "payload-a"
            ) == ComposerAudioWaveformPresentation.fallbackPlaybackBars
        )
        #expect(
            ComposerAudioWaveformPresentation.visiblePlaybackBars(
                loadedBars: loadedBars,
                metadataPayloadID: "payload-a",
                currentPayloadID: "payload-b"
            ) == ComposerAudioWaveformPresentation.fallbackPlaybackBars
        )
    }

    @Test func composerReturnKeyPolicySendsPlainReturnOnly() async throws {
        #expect(ComposerKeyboardShortcutPolicy.returnKeyAction(for: NSEvent.ModifierFlags()) == .send)
        #expect(ComposerKeyboardShortcutPolicy.returnKeyAction(for: .shift) == .insertLineBreak)
        #expect(ComposerKeyboardShortcutPolicy.returnKeyAction(for: .command) == .deferToSystem)
        #expect(
            ComposerKeyboardShortcutPolicy.returnKeyAction(for: [.shift, .command])
                == .deferToSystem
        )
        #expect(ComposerKeyboardShortcutPolicy.returnKeyAction(for: .option) == .deferToSystem)
    }

    @Test func emojiSearchMatchesNamesAndKeywordsWithStableRanking() async throws {
        let entries = [
            ChatEmojiCatalogEntry(emoji: "😂", name: "face with tears of joy", group: 0, keywords: ["laugh"]),
            ChatEmojiCatalogEntry(emoji: "😀", name: "grinning face", group: 0, keywords: ["happy"]),
            ChatEmojiCatalogEntry(emoji: "❤️", name: "red heart", group: 7, keywords: ["love"]),
        ]

        #expect(ChatEmojiSearch.results(in: entries, query: "laugh").map(\.emoji) == ["😂"])
        #expect(ChatEmojiSearch.results(in: entries, query: "red").map(\.emoji) == ["❤️"])
        #expect(ChatEmojiSearch.results(in: entries, query: "face").map(\.emoji) == ["😂", "😀"])
    }

    @Test func onlyOutgoingPlainTextMessagesCanEnterComposerEditing() async throws {
        let outgoing = MessageItem(
            id: "outgoing",
            senderName: "You",
            body: "Original",
            sentAt: .now,
            isOutgoing: true
        )
        let incoming = MessageItem(
            id: "incoming",
            senderName: "Friend",
            body: "Original",
            sentAt: .now,
            isOutgoing: false
        )
        let deleted = MessageItem(
            id: "deleted",
            senderName: "You",
            body: "Original",
            sentAt: .now,
            isDeleted: true,
            isOutgoing: true
        )

        #expect(outgoing.canEdit)
        #expect(!incoming.canEdit)
        #expect(!deleted.canEdit)
    }

    @Test func mediaDurationLabelClampsNonFiniteAndOversizedDurations() async throws {
        // Regression for whitenoise-mac#253: the audio duration is peer-derived
        // (MediaWaveformAnalyzer -> AVAudioFile.length / sampleRate), so it may be
        // NaN, ±Infinity, or larger than Int.max. Int(_:) traps on any of those, so
        // the label must clamp instead of crashing while rendering an audio row.
        #expect(MediaDurationLabel.string(for: .nan) == "0:00")
        #expect(MediaDurationLabel.string(for: .infinity) == "0:00")
        #expect(MediaDurationLabel.string(for: -.infinity) == "0:00")
        #expect(MediaDurationLabel.string(for: -1) == "0:00")

        // A crafted header can drive the duration above Int.max; clamping to Int.max
        // must not trap and must still format as an hours label. Double(Int.max)
        // rounds up to 2^63, which is > Int.max, so it exercises the clamp path.
        let expected = "2562047788015215:30:07"
        #expect(MediaDurationLabel.string(for: 1e19) == expected)
        #expect(MediaDurationLabel.string(for: Double(Int.max)) == expected)
        #expect(MediaDurationLabel.string(for: .greatestFiniteMagnitude) == expected)

        // Ordinary values keep formatting exactly as before.
        #expect(MediaDurationLabel.string(for: 3_599) == "59:59")
        #expect(MediaDurationLabel.string(for: 3_600) == "1:00:00")
    }

    @Test func outgoingMediaKindFallsBackToFileExtensionForGenericMediaTypes() async throws {
        // Regression for whitenoise-mac#317: the media type still drives classification,
        // but a generic/unknown type must consult the file extension instead of ignoring
        // it. A `clip.mp4` carried under `application/octet-stream` should partition as a
        // video, not a document.
        #expect(OutgoingMediaAttachmentPolicy.kind(mediaType: "video/mp4") == .video)
        #expect(OutgoingMediaAttachmentPolicy.kind(mediaType: "audio/mpeg") == .audio)
        #expect(OutgoingMediaAttachmentPolicy.kind(mediaType: "image/png") == .image)
        #expect(OutgoingMediaAttachmentPolicy.kind(mediaType: "application/pdf") == .file)

        #expect(
            OutgoingMediaAttachmentPolicy.kind(mediaType: "application/octet-stream", fileName: "clip.mp4") == .video
        )
        #expect(
            OutgoingMediaAttachmentPolicy.kind(mediaType: "application/octet-stream", fileName: "voice.m4a") == .audio
        )
        #expect(
            OutgoingMediaAttachmentPolicy.kind(mediaType: "application/octet-stream", fileName: "photo.png") == .image
        )

        // A concrete media type is authoritative and wins over a mismatched extension.
        #expect(
            OutgoingMediaAttachmentPolicy.kind(mediaType: "video/mp4", fileName: "report.pdf") == .video
        )
        #expect(
            OutgoingMediaAttachmentPolicy.kind(mediaType: "application/pdf", fileName: "clip.mp4") == .file
        )

        // A document extension (or a name without a media-bearing extension) still
        // resolves to a file.
        #expect(
            OutgoingMediaAttachmentPolicy.kind(mediaType: "application/octet-stream", fileName: "notes.txt") == .file
        )
        #expect(
            OutgoingMediaAttachmentPolicy.kind(mediaType: "application/octet-stream", fileName: "archive.pdf") == .file
        )
    }

    @Test func chatListRowClampsOversizedUnreadCounts() async throws {
        // Regression for whitenoise-mac#242: unread counts cross the FFI boundary as
        // UInt64, and Int(value) traps above Int.max while mapping the chat list.
        let row = ChatListRowFfi(
            groupIdHex: "group",
            archived: false,
            pendingConfirmation: false,
            title: "Planning",
            groupName: "Planning",
            avatarUrl: nil,
            avatar: nil,
            lastMessage: nil,
            unreadCount: UInt64(Int.max) + 1,
            hasUnread: true,
            unreadMentionCount: UInt64.max,
            unreadMention: true,
            firstUnreadMessageIdHex: nil,
            lastReadMessageIdHex: nil,
            lastReadTimelineAt: nil,
            updatedAt: 0,
            selfMembership: .member
        )

        let chat = ChatItem(row: row, activeAccountIdHex: nil)

        #expect(chat.unreadCount == Int.max)
        #expect(chat.unreadMentionCount == Int.max)
    }

    @Test func chatListRowFallsBackToUpdatedAtWhenPreviewTimelineIsUnknown() async throws {
        // Regression for whitenoise-mac#330: a last-message preview with timelineAt == 0
        // means the preview timestamp is unknown, so the chat row must keep using
        // updatedAt for sidebar ordering and timestamp display.
        let fallbackUpdatedAt: UInt64 = 1_800_000_000
        let row = ChatListRowFfi(
            groupIdHex: "group",
            archived: false,
            pendingConfirmation: false,
            title: "Planning",
            groupName: "Planning",
            avatarUrl: nil,
            avatar: nil,
            lastMessage: ChatListMessagePreviewFfi(
                messageIdHex: "message-1",
                sender: "alice1234567890alice1234567890alice1234567890alice1234567890",
                senderDisplayName: "Alice",
                plaintext: "Queued locally",
                contentTokens: MarkdownDocumentFfi(blocks: [], truncated: false),
                kind: 9,
                timelineAt: 0,
                deleted: false
            ),
            unreadCount: 0,
            hasUnread: false,
            unreadMentionCount: 0,
            unreadMention: false,
            firstUnreadMessageIdHex: nil,
            lastReadMessageIdHex: nil,
            lastReadTimelineAt: nil,
            updatedAt: fallbackUpdatedAt,
            selfMembership: .member
        )

        let chat = ChatItem(row: row, activeAccountIdHex: "self")

        #expect(chat.updatedAt == Date(timeIntervalSince1970: TimeInterval(fallbackUpdatedAt)))
    }

    @MainActor
    @Test func messageItemTimelineFallbackClampsPreEpochAndNonFiniteDates() async throws {
        // Regression for whitenoise-mac#247: the timelineAt fallback derives from
        // sentAt via UInt64(_:), which traps on negative (pre-1970) or non-finite
        // dates. The fallback must clamp instead of crashing the initializer.
        func timelineAt(for sentAt: Date) -> UInt64 {
            MessageItem(id: "t", senderName: "s", body: "b", sentAt: sentAt, isOutgoing: false).timelineAt
        }

        // Pre-epoch dates have a negative timeIntervalSince1970 and clamp to 0.
        #expect(timelineAt(for: Date(timeIntervalSince1970: -1)) == 0)
        #expect(timelineAt(for: Date(timeIntervalSince1970: -1_000)) == 0)

        // Non-finite dates also clamp to 0 rather than trapping.
        #expect(timelineAt(for: Date(timeIntervalSince1970: .nan)) == 0)
        #expect(timelineAt(for: Date(timeIntervalSince1970: .infinity)) == 0)
        #expect(timelineAt(for: Date(timeIntervalSince1970: -.infinity)) == 0)

        // Ordinary positive dates floor to their epoch seconds.
        #expect(timelineAt(for: Date(timeIntervalSince1970: 1_700_000_000.75)) == 1_700_000_000)

        // Oversized finite dates clamp to UInt64.max instead of trapping.
        #expect(timelineAt(for: Date(timeIntervalSince1970: 1e30)) == UInt64.max)

        // An explicit timelineAt still overrides the fallback entirely.
        let explicit = MessageItem(
            id: "t",
            senderName: "s",
            body: "b",
            sentAt: Date(timeIntervalSince1970: -5),
            timelineAt: 42,
            isOutgoing: false
        )
        #expect(explicit.timelineAt == 42)
    }

    @MainActor
    @Test func messageTimelineStoreToleratesDuplicateMessageIds() async throws {
        // Regression for whitenoise-mac#309: full-list index rebuilds keyed on FFI-derived
        // MessageItem.id must not trap on a duplicate id from runtime/relay/FFI. The store
        // resolves duplicates last-wins, mirroring applyProjection/upsert semantics.
        func message(id: String, body: String) -> MessageItem {
            MessageItem(
                id: id,
                senderName: "sender",
                body: body,
                sentAt: Date(timeIntervalSince1970: 1_700_000_000),
                isOutgoing: false
            )
        }

        let duplicates = [message(id: "dup", body: "first"), message(id: "dup", body: "second")]

        // init path does not trap, resolves the later item, and keeps observed arrays unique.
        let store = MessageTimelineStore.loaded(with: duplicates)
        #expect(store.messages.map(\.body) == ["second"])
        #expect(store.messageIDs == ["dup"])
        #expect(store.lookup["dup"]?.body == "second")

        // replace() (rebuildIndexes) path behaves identically.
        let replaced = MessageTimelineStore()
        replaced.replace(with: duplicates)
        #expect(replaced.messages.map(\.body) == ["second"])
        #expect(replaced.messageIDs == ["dup"])
        #expect(replaced.lookup["dup"]?.body == "second")

        // Later incremental upserts update the single retained row instead of leaving a stale twin.
        _ = replaced.applyProjection(
            upserts: [message(id: "dup", body: "third")],
            removals: [],
            anchoredToNewest: true,
            windowLimit: 10
        )
        #expect(replaced.messages.map(\.body) == ["third"])
    }

    @MainActor
    @Test func messageTimelineStoreTrimsSaturatedWindowWithoutStaleIndexes() async throws {
        // Regression for whitenoise-mac#422: once the live window is saturated, appending one
        // newer message should trim only the oldest row and keep the lookup/index structures
        // aligned without a full dedup/index rebuild on every message.
        func message(id: String, timelineAt: UInt64, body: String? = nil) -> MessageItem {
            MessageItem(
                id: id,
                senderName: "sender",
                body: body ?? id,
                sentAt: Date(timeIntervalSince1970: TimeInterval(timelineAt)),
                timelineAt: timelineAt,
                isOutgoing: false
            )
        }

        let store = MessageTimelineStore.loaded(with: [
            message(id: "m0", timelineAt: 0),
            message(id: "m1", timelineAt: 1),
            message(id: "m2", timelineAt: 2),
        ])

        let result = store.applyProjection(
            upserts: [message(id: "m3", timelineAt: 3)],
            removals: [],
            anchoredToNewest: true,
            windowLimit: 3
        )

        #expect(result.didTrimOlderMessages)
        #expect(store.messages.map(\.id) == ["m1", "m2", "m3"])
        #expect(store.messageIDs == ["m1", "m2", "m3"])
        #expect(!store.containsMessage(id: "m0"))
        #expect(store.lookup["m0"] == nil)
        #expect(store.lookup["m1"]?.body == "m1")

        _ = store.applyProjection(
            upserts: [message(id: "m1", timelineAt: 1, body: "updated")],
            removals: [],
            anchoredToNewest: true,
            windowLimit: 3
        )

        #expect(store.messages.map(\.body) == ["updated", "m2", "m3"])
        #expect(store.messageIDs == ["m1", "m2", "m3"])
        #expect(store.lookup["m1"]?.body == "updated")
    }

    @MainActor
    @Test func replacingTimelineWindowEvictsMediaDownloadsOutsideWindow() async throws {
        // Regression for whitenoise-mac#394: decrypted attachment payloads for messages that
        // leave the selected timeline window must be released instead of staying resident until
        // the user switches conversations.
        let account = AccountItem.samples[0]
        let chat = ChatItem.samples[0]
        let staleAttachment = MessageMediaAttachment(
            id: "stale-attachment",
            reference: mediaReference(fileName: "stale.png", mediaType: "image/png")
        )
        let retainedAttachment = MessageMediaAttachment(
            id: "retained-attachment",
            reference: mediaReference(fileName: "retained.png", mediaType: "image/png")
        )
        let staleMessage = MessageItem(
            id: "stale-message",
            groupIdHex: chat.id,
            senderName: "Alice",
            body: "Scrolled away",
            sentAt: Date(timeIntervalSince1970: 1_700_000_000),
            isOutgoing: false,
            mediaAttachments: [staleAttachment]
        )
        let retainedMessage = MessageItem(
            id: "retained-message",
            groupIdHex: chat.id,
            senderName: "Alice",
            body: "Still visible",
            sentAt: Date(timeIntervalSince1970: 1_700_000_001),
            isOutgoing: false,
            mediaAttachments: [retainedAttachment]
        )
        let state = WorkspaceState(
            accounts: [account],
            chatsByAccount: [account.id: [chat]],
            messagesByChat: [chat.id: [staleMessage, retainedMessage]],
            localNotificationCenter: NoopLocalNotificationCenter(),
            appActivityProvider: { false },
            conversationWindowVisibilityProvider: { false }
        )
        state.activeAccountId = account.id
        state.selection = .chat(chat.id)

        let staleKey = state.mediaDownloadKey(message: staleMessage, attachment: staleAttachment)
        let retainedKey = state.mediaDownloadKey(message: retainedMessage, attachment: retainedAttachment)
        let staleStore = mediaDownloadStore(
            plaintext: Data("stale decrypted plaintext".utf8),
            fileName: "stale.png",
            payloadId: "stale-payload"
        )
        let retainedStore = mediaDownloadStore(
            plaintext: Data("retained decrypted plaintext".utf8),
            fileName: "retained.png",
            payloadId: "retained-payload"
        )
        state.mediaDownloads[staleKey] = staleStore
        state.mediaDownloads[retainedKey] = retainedStore

        state.replaceMessages([retainedMessage], groupIdHex: chat.id)

        #expect(state.mediaDownloads[staleKey] == nil)
        #expect(staleStore.state == .idle)
        let retained = try #require(state.mediaDownloads[retainedKey])
        #expect(retained === retainedStore)
        let retainedData: Data?
        if case .loaded(let download) = retained.state {
            retainedData = download.data
        } else {
            retainedData = nil
        }
        #expect(retainedData == Data("retained decrypted plaintext".utf8))
    }

    @MainActor
    @Test func detachedWindowSuppressesUpsertNewerThanPostRemovalHead() async throws {
        // Regression for whitenoise-mac#331: applyProjection must recompute the window head
        // *after* removals. In a detached (scrolled-back) window, a delta that removes the
        // current newest row and upserts a row newer than the post-removal head must suppress
        // that upsert — a detached window must not grow a new head — matching the runtime's
        // apply_projection_to_window.
        func message(id: String, timelineAt: UInt64) -> MessageItem {
            MessageItem(
                id: id,
                senderName: "sender",
                body: id,
                sentAt: Date(timeIntervalSince1970: 1_700_000_000),
                timelineAt: timelineAt,
                isOutgoing: false
            )
        }

        // Window (oldest→newest): L(95), M(100). We are scrolled back, so anchoredToNewest == false.
        let store = MessageTimelineStore.loaded(with: [
            message(id: "L", timelineAt: 95),
            message(id: "M", timelineAt: 100),
        ])

        // The delta removes the current newest row M and upserts N(98). After M is gone the true
        // head is L(95); N(98) is strictly newer and must not become a new head.
        let result = store.applyProjection(
            upserts: [message(id: "N", timelineAt: 98)],
            removals: ["M"],
            anchoredToNewest: false,
            windowLimit: 10
        )

        #expect(store.messages.map(\.id) == ["L"])
        #expect(!store.containsMessage(id: "N"))
        #expect(result.didChange)
    }

    @MainActor
    @Test func messageTimelineStoreAppliesEditOverlaysToTargets() async throws {
        // Regression for whitenoise-mac#419: standalone edit overlays patch materialized targets,
        // reject forged senders, and stay pending until the target is inserted or replaced.
        let overlay = makeEditOverlay(
            editId: "edit-new",
            plaintext: "Edited body",
            timelineAt: 1_800_000_060
        )

        let materialized = MessageTimelineStore.loaded(with: [
            chatMessage(id: "target", body: "Original", timelineAt: 1_800_000_000)
        ])
        let applied = materialized.applyProjection(
            upserts: [],
            removals: [],
            editMutations: [editUpsert(overlay)],
            anchoredToNewest: true,
            windowLimit: 10
        )
        #expect(applied.didChange)
        let patched = try #require(materialized.lookup["target"])
        #expect(patched.body == "Edited body")
        #expect(patched.isEdited)
        #expect(patched.metadataLabel.contains("Edited"))

        let forged = MessageTimelineStore.loaded(with: [
            chatMessage(id: "target", body: "Original", timelineAt: 1_800_000_000)
        ])
        let rejected = forged.applyProjection(
            upserts: [],
            removals: [],
            editMutations: [
                editUpsert(
                    makeEditOverlay(
                        editId: "mallory-edit",
                        sender: "mallory",
                        plaintext: "Forged",
                        timelineAt: 1_800_000_030
                    )
                )
            ],
            anchoredToNewest: true,
            windowLimit: 10
        )
        #expect(!rejected.didChange)
        let untouched = try #require(forged.lookup["target"])
        #expect(untouched.body == "Original")
        #expect(!untouched.isEdited)

        let pending = MessageTimelineStore()
        let pendingOnly = pending.applyProjection(
            upserts: [],
            removals: [],
            editMutations: [editUpsert(overlay)],
            anchoredToNewest: true,
            windowLimit: 10
        )
        #expect(!pendingOnly.didChange)
        #expect(pending.messages.isEmpty)

        let inserted = pending.applyProjection(
            upserts: [chatMessage(id: "target", body: "Original", timelineAt: 1_800_000_000)],
            removals: [],
            editMutations: [],
            anchoredToNewest: true,
            windowLimit: 10
        )
        #expect(inserted.didChange)
        let deferred = try #require(pending.lookup["target"])
        #expect(deferred.body == "Edited body")
        #expect(deferred.isEdited)

        let poisoned = MessageTimelineStore()
        _ = poisoned.applyProjection(
            upserts: [],
            removals: [],
            editMutations: [
                editUpsert(
                    makeEditOverlay(
                        editId: "alice-edit",
                        plaintext: "Legitimate",
                        timelineAt: 1_800_000_030
                    )
                )
            ],
            anchoredToNewest: true,
            windowLimit: 10
        )
        let forgedFlood = (0..<200).map { index in
            editUpsert(
                makeEditOverlay(
                    editId: "mallory-edit-\(index)",
                    sender: "mallory",
                    plaintext: "Forged \(index)",
                    timelineAt: 1_800_000_060 + UInt64(index)
                )
            )
        }
        _ = poisoned.applyProjection(
            upserts: [],
            removals: [],
            editMutations: forgedFlood,
            anchoredToNewest: true,
            windowLimit: 10
        )
        _ = poisoned.applyProjection(
            upserts: [chatMessage(id: "target", body: "Original", timelineAt: 1_800_000_000)],
            removals: [],
            editMutations: [],
            anchoredToNewest: true,
            windowLimit: 10
        )
        let unpoisoned = try #require(poisoned.lookup["target"])
        #expect(unpoisoned.body == "Legitimate")
        #expect(unpoisoned.isEdited)

        let replacedStore = MessageTimelineStore()
        replacedStore.replace(
            with: [chatMessage(id: "target", body: "Original", timelineAt: 1_800_000_000)],
            editMutations: [editUpsert(overlay)]
        )
        let replaced = try #require(replacedStore.lookup["target"])
        #expect(replaced.body == "Edited body")
        #expect(replaced.isEdited)
    }

    @MainActor
    @Test func messageTimelineStoreIndexesEditCandidatesByTarget() async throws {
        // Regression for whitenoise-mac#586: rendering one materialized row must inspect only
        // that target's candidates, not every retained edit in the timeline window.
        let store = MessageTimelineStore.loaded(with: [
            chatMessage(id: "target", body: "Original", timelineAt: 1_800_000_000)
        ])
        var mutations = (0..<199).map { index in
            editUpsert(
                makeEditOverlay(
                    target: "unrelated-\(index)",
                    editId: "unrelated-edit-\(index)",
                    plaintext: "Unrelated \(index)",
                    timelineAt: 1_800_000_001 + UInt64(index)
                )
            )
        }
        mutations.append(
            editUpsert(
                makeEditOverlay(
                    editId: "target-edit",
                    plaintext: "Edited",
                    timelineAt: 1_800_000_200
                )
            )
        )

        _ = store.applyProjection(
            upserts: [],
            removals: [],
            editMutations: mutations,
            anchoredToNewest: true,
            windowLimit: 200
        )

        #expect(store.lookup["target"]?.body == "Edited")
        #expect(store.lastRenderEditCandidateVisitCount == 1)
    }

    @MainActor
    @Test func messageTimelineStoreReplaceReappliesStoredEditsAcrossWindowChanges() async throws {
        // Regression for whitenoise-mac#419: replace() rebuilds indexes before validating targets,
        // and stored overlays survive authoritative replaces that omit the edit record.
        let overlay = makeEditOverlay(
            editId: "edit-new",
            plaintext: "Edited",
            timelineAt: 300
        )

        let staleIndexStore = MessageTimelineStore.loaded(with: [
            chatMessage(id: "target", sender: "mallory", body: "Wrong row", timelineAt: 100),
            chatMessage(id: "other", sender: "bob", body: "Other", timelineAt: 200),
        ])
        staleIndexStore.replace(
            with: [
                chatMessage(id: "a", sender: "alice", body: "A", timelineAt: 10),
                chatMessage(id: "target", sender: "alice", body: "Original", timelineAt: 20),
            ],
            editMutations: [editUpsert(overlay)]
        )
        let reindexed = try #require(staleIndexStore.lookup["target"])
        #expect(reindexed.body == "Edited")
        #expect(reindexed.isEdited)

        let crossWindowStore = MessageTimelineStore()
        _ = crossWindowStore.applyProjection(
            upserts: [],
            removals: [],
            editMutations: [
                editUpsert(
                    makeEditOverlay(editId: "edit-new", plaintext: "Edited later", timelineAt: 1_800_000_060)
                )
            ],
            anchoredToNewest: true,
            windowLimit: 10
        )
        #expect(crossWindowStore.messages.isEmpty)

        crossWindowStore.replace(
            with: [chatMessage(id: "target", body: "Original", timelineAt: 1_800_000_000)],
            editMutations: []
        )
        let reapplied = try #require(crossWindowStore.lookup["target"])
        #expect(reapplied.body == "Edited later")
        #expect(reapplied.isEdited)
    }

    @MainActor
    @Test func messageTimelineStoreEditFallbackOnCandidateRetraction() async throws {
        // Regression for whitenoise-mac#419: removing the newest edit event falls back to the
        // next-newest valid candidate, then to the unedited base.
        let store = MessageTimelineStore.loaded(with: [
            chatMessage(id: "target", body: "Original", timelineAt: 1_800_000_000)
        ])
        _ = store.applyProjection(
            upserts: [],
            removals: [],
            editMutations: [
                editUpsert(
                    makeEditOverlay(editId: "edit-old", plaintext: "Edited older", timelineAt: 1_800_000_030)
                ),
                editUpsert(
                    makeEditOverlay(editId: "edit-new", plaintext: "Edited newer", timelineAt: 1_800_000_060)
                ),
            ],
            anchoredToNewest: true,
            windowLimit: 10
        )
        #expect(store.lookup["target"]?.body == "Edited newer")

        let removedNewest = store.applyProjection(
            upserts: [],
            removals: ["edit-new"],
            editMutations: [],
            anchoredToNewest: true,
            windowLimit: 10
        )
        #expect(removedNewest.didChange)
        #expect(store.lookup["target"]?.body == "Edited older")
        #expect(store.lookup["target"]?.isEdited == true)

        let removedOlder = store.applyProjection(
            upserts: [],
            removals: ["edit-old"],
            editMutations: [],
            anchoredToNewest: true,
            windowLimit: 10
        )
        #expect(removedOlder.didChange)
        let restored = try #require(store.lookup["target"])
        #expect(restored.body == "Original")
        #expect(!restored.isEdited)

        let reprojected = store.applyProjection(
            upserts: [chatMessage(id: "target", body: "Original", timelineAt: 1_800_000_000)],
            removals: [],
            editMutations: [
                editUpsert(
                    makeEditOverlay(editId: "edit-new", plaintext: "Edited newer", timelineAt: 1_800_000_060)
                )
            ],
            anchoredToNewest: true,
            windowLimit: 10
        )
        #expect(reprojected.didChange)
        let afterReupsert = try #require(store.lookup["target"])
        #expect(afterReupsert.body == "Edited newer")
        #expect(afterReupsert.isEdited)
    }

    @MainActor
    @Test func messageTimelineStoreEditOverlayLifecycleAndRetention() async throws {
        let pendingEdit = makeEditOverlay(
            editId: "edit-new",
            plaintext: "Edited later",
            timelineAt: 1_800_000_060
        )

        let cleared = MessageTimelineStore()
        _ = cleared.applyProjection(
            upserts: [],
            removals: [],
            editMutations: [editUpsert(pendingEdit)],
            anchoredToNewest: true,
            windowLimit: 10
        )
        cleared.clear()
        _ = cleared.applyProjection(
            upserts: [chatMessage(id: "target", body: "Original", timelineAt: 1_800_000_000)],
            removals: [],
            editMutations: [],
            anchoredToNewest: true,
            windowLimit: 10
        )
        let afterClear = try #require(cleared.lookup["target"])
        #expect(afterClear.body == "Original")
        #expect(!afterClear.isEdited)

        let removed = MessageTimelineStore()
        _ = removed.applyProjection(
            upserts: [],
            removals: [],
            editMutations: [editUpsert(pendingEdit)],
            anchoredToNewest: true,
            windowLimit: 10
        )
        _ = removed.applyProjection(
            upserts: [],
            removals: ["target"],
            editMutations: [],
            anchoredToNewest: true,
            windowLimit: 10
        )
        _ = removed.applyProjection(
            upserts: [chatMessage(id: "target", body: "Original", timelineAt: 1_800_000_000)],
            removals: [],
            editMutations: [],
            anchoredToNewest: true,
            windowLimit: 10
        )
        let afterRemoval = try #require(removed.lookup["target"])
        #expect(afterRemoval.body == "Original")
        #expect(!afterRemoval.isEdited)

        let invalidTarget = MessageTimelineStore()
        _ = invalidTarget.applyProjection(
            upserts: [],
            removals: [],
            editMutations: [editUpsert(pendingEdit)],
            anchoredToNewest: true,
            windowLimit: 10
        )
        _ = invalidTarget.applyProjection(
            upserts: [chatMessage(id: "target", sender: "mallory", body: "Original", timelineAt: 1_800_000_000)],
            removals: [],
            editMutations: [],
            anchoredToNewest: true,
            windowLimit: 10
        )
        let mismatched = try #require(invalidTarget.lookup["target"])
        #expect(mismatched.body == "Original")
        #expect(!mismatched.isEdited)

        let invalidated = MessageTimelineStore.loaded(with: [
            chatMessage(id: "target", body: "Original", timelineAt: 1_800_000_000)
        ])
        _ = invalidated.applyProjection(
            upserts: [],
            removals: [],
            editMutations: [editUpsert(pendingEdit)],
            anchoredToNewest: true,
            windowLimit: 10
        )
        let retractInvalid = invalidated.applyProjection(
            upserts: [],
            removals: [],
            editMutations: [editRetract("edit-new")],
            anchoredToNewest: true,
            windowLimit: 10
        )
        #expect(retractInvalid.didChange)
        let afterInvalidation = try #require(invalidated.lookup["target"])
        #expect(afterInvalidation.body == "Original")
        #expect(!afterInvalidation.isEdited)

        let trimmed = MessageTimelineStore.loaded(with: [
            chatMessage(id: "target", body: "Original", timelineAt: 0),
            chatMessage(id: "m1", timelineAt: 1),
        ])
        _ = trimmed.applyProjection(
            upserts: [],
            removals: [],
            editMutations: [
                editUpsert(makeEditOverlay(editId: "edit-new", plaintext: "Edited later", timelineAt: 2))
            ],
            anchoredToNewest: true,
            windowLimit: 2
        )
        #expect(trimmed.lookup["target"]?.body == "Edited later")
        _ = trimmed.applyProjection(
            upserts: [chatMessage(id: "m2", timelineAt: 2)],
            removals: [],
            editMutations: [],
            anchoredToNewest: true,
            windowLimit: 2
        )
        #expect(!trimmed.containsMessage(id: "target"))
        trimmed.replace(
            with: [
                chatMessage(id: "target", body: "Original", timelineAt: 0),
                chatMessage(id: "m1", timelineAt: 1),
            ],
            editMutations: []
        )
        let afterTrim = try #require(trimmed.lookup["target"])
        #expect(afterTrim.body == "Edited later")
        #expect(afterTrim.isEdited)
    }

    @MainActor
    @Test func messageTimelineStoreEditBodyNormalizationMatchesDisplayText() async throws {
        let unsupported = L10n.string("Unsupported message")
        let store = MessageTimelineStore.loaded(with: [
            chatMessage(id: "target", body: "Original", timelineAt: 1_800_000_000)
        ])
        _ = store.applyProjection(
            upserts: [],
            removals: [],
            editMutations: [
                editUpsert(
                    makeEditOverlay(editId: "edit-trim", plaintext: "  trimmed  ", timelineAt: 1_800_000_010)
                )
            ],
            anchoredToNewest: true,
            windowLimit: 10
        )
        #expect(store.lookup["target"]?.body == "trimmed")

        let whitespaceOnly = MessageTimelineStore.loaded(with: [
            chatMessage(id: "target", body: "Original", timelineAt: 1_800_000_000)
        ])
        _ = whitespaceOnly.applyProjection(
            upserts: [],
            removals: [],
            editMutations: [
                editUpsert(
                    makeEditOverlay(editId: "edit-empty", plaintext: "   ", timelineAt: 1_800_000_010)
                )
            ],
            anchoredToNewest: true,
            windowLimit: 10
        )
        #expect(whitespaceOnly.lookup["target"]?.body == unsupported)
        #expect(whitespaceOnly.lookup["target"]?.isEdited == true)
    }

    @MainActor
    @Test func workspaceChatSnapshotsDeduplicateDuplicateChatIds() async throws {
        // Regression for whitenoise-mac#309: full-list chat snapshots must not leave duplicate
        // ChatItem.id values in the observed arrays that feed SwiftUI ForEach and later
        // incremental upsert/remove paths. The snapshot boundary resolves duplicates last-wins.
        func chat(id: String, title: String) -> ChatItem {
            ChatItem(
                id: id,
                title: title,
                subtitle: "",
                preview: "",
                updatedAt: nil,
                avatarSeed: id,
                pictureURL: nil,
                unreadCount: 0
            )
        }

        let accountId = "account"
        let duplicates = [chat(id: "dup", title: "first"), chat(id: "dup", title: "second")]
        let state = WorkspaceState(
            chatsByAccount: [accountId: duplicates],
            localNotificationCenter: NoopLocalNotificationCenter(),
            appActivityProvider: { false },
            conversationWindowVisibilityProvider: { false }
        )

        #expect(state.chatsByAccount[accountId]?.map(\.title) == ["second"])
        #expect(state.chatLookupByAccount[accountId]?["dup"]?.title == "second")
        #expect(state.chatIndexByAccount[accountId]?["dup"] == 0)

        state.setChats(duplicates, forAccountId: accountId)
        #expect(state.chatsByAccount[accountId]?.map(\.title) == ["second"])
        #expect(state.chatLookupByAccount[accountId]?["dup"]?.title == "second")
        #expect(state.chatIndexByAccount[accountId]?["dup"] == 0)

        state.upsertChat(chat(id: "dup", title: "third"), forAccountId: accountId)
        #expect(state.chatsByAccount[accountId]?.map(\.title) == ["third"])
    }

    @MainActor
    @Test func groupDetailsSnapshotToleratesDuplicateMemberActionIds() async throws {
        // Regression for whitenoise-mac#309: groupDetailsSnapshot builds actionByMemberId from
        // FFI GroupMemberActionStateFfi.memberIdHex, which can repeat. The rebuild must not trap
        // and should apply the later action (last-wins).
        let memberIdHex = "member1234567890member1234567890member1234567890member1234"
        let group = AppGroupRecordFfi(
            groupIdHex: "group",
            endpoint: "",
            name: "Test Group",
            description: "",
            admins: [memberIdHex],
            relays: [],
            nostrGroupIdHex: "",
            avatarUrl: nil,
            avatarDim: nil,
            avatarThumbhash: nil,
            imageHashHex: nil,
            encryptedMedia: AppGroupEncryptedMediaComponentFfi(
                componentId: 0,
                component: "",
                required: false,
                mediaFormat: "",
                allowedLocatorKinds: [],
                defaultBlobEndpoints: []
            ),
            disappearingMessageSecs: 0,
            archived: false,
            pendingConfirmation: false,
            selfMembership: .member,
            welcomerAccountIdHex: nil,
            viaWelcomeMessageIdHex: nil
        )
        let details = GroupDetailsFfi(
            group: group,
            members: [
                GroupMemberDetailsFfi(
                    memberIdHex: memberIdHex,
                    account: "Member",
                    local: false,
                    isAdmin: true,
                    isSelf: false,
                    npub: "npub1member",
                    displayName: "Member"
                )
            ]
        )
        let managementState = GroupManagementStateFfi(
            myAccountIdHex: memberIdHex,
            isSelfAdmin: true,
            isLastAdmin: false,
            canInvite: true,
            canLeave: true,
            requiresSelfDemoteBeforeLeave: false,
            memberActions: [
                GroupMemberActionStateFfi(
                    memberIdHex: memberIdHex,
                    isSelf: false,
                    isAdmin: true,
                    canRemove: false,
                    canPromote: false,
                    canDemote: false
                ),
                GroupMemberActionStateFfi(
                    memberIdHex: memberIdHex,
                    isSelf: false,
                    isAdmin: true,
                    canRemove: true,
                    canPromote: true,
                    canDemote: true
                ),
            ]
        )

        let state = WorkspaceState(
            localNotificationCenter: NoopLocalNotificationCenter(),
            appActivityProvider: { false },
            conversationWindowVisibilityProvider: { false }
        )
        let snapshot = state.groupDetailsSnapshot(from: details, managementState: managementState)

        let member = try #require(snapshot.members.first { $0.id == memberIdHex })
        #expect(member.canRemove)
        #expect(member.canPromote)
        #expect(member.canDemote)
    }

    @MainActor
    @Test func groupDetailsSnapshotSanitizesPeerControlledNames() async throws {
        let rtlOverride = "\u{202E}"
        let ltrIsolate = "\u{2066}"
        let memberIdHex = "member1234567890member1234567890member1234567890member1234"
        let group = AppGroupRecordFfi(
            groupIdHex: "group",
            endpoint: "",
            name: "\(rtlOverride)Ops Team\(ltrIsolate)",
            description: "",
            admins: [memberIdHex],
            relays: [],
            nostrGroupIdHex: "",
            avatarUrl: nil,
            avatarDim: nil,
            avatarThumbhash: nil,
            imageHashHex: nil,
            encryptedMedia: AppGroupEncryptedMediaComponentFfi(
                componentId: 0,
                component: "",
                required: false,
                mediaFormat: "",
                allowedLocatorKinds: [],
                defaultBlobEndpoints: []
            ),
            disappearingMessageSecs: 0,
            archived: false,
            pendingConfirmation: false,
            selfMembership: .member,
            welcomerAccountIdHex: nil,
            viaWelcomeMessageIdHex: nil
        )
        let details = GroupDetailsFfi(
            group: group,
            members: [
                GroupMemberDetailsFfi(
                    memberIdHex: memberIdHex,
                    account: "\(rtlOverride)member@example.test\(ltrIsolate)",
                    local: false,
                    isAdmin: true,
                    isSelf: false,
                    npub: "npub1member",
                    displayName: "\(ltrIsolate)Trusted Admin\(rtlOverride)"
                )
            ]
        )
        let managementState = GroupManagementStateFfi(
            myAccountIdHex: memberIdHex,
            isSelfAdmin: true,
            isLastAdmin: false,
            canInvite: true,
            canLeave: true,
            requiresSelfDemoteBeforeLeave: false,
            memberActions: []
        )

        let state = WorkspaceState(
            localNotificationCenter: NoopLocalNotificationCenter(),
            appActivityProvider: { false },
            conversationWindowVisibilityProvider: { false }
        )
        let snapshot = state.groupDetailsSnapshot(from: details, managementState: managementState)
        let member = try #require(snapshot.members.first { $0.id == memberIdHex })

        #expect(snapshot.name == "Ops Team")
        #expect(member.displayName == "Trusted Admin")
        #expect(member.detailLabel == "member@example.test")
        #expect(!snapshot.name.unicodeScalars.contains { $0.properties.generalCategory == .format })
        #expect(!member.displayName.unicodeScalars.contains { $0.properties.generalCategory == .format })
        #expect(!member.detailLabel.unicodeScalars.contains { $0.properties.generalCategory == .format })
    }

    @MainActor
    @Test func groupDetailsSnapshotMapsSelfMembershipVariants() async throws {
        let variants: [(SelfMembershipFfi, ChatSelfMembership)] = [
            (.member, .member),
            (.left, .left),
            (.removed, .removed),
        ]
        let state = WorkspaceState(
            localNotificationCenter: NoopLocalNotificationCenter(),
            appActivityProvider: { false },
            conversationWindowVisibilityProvider: { false }
        )

        for (ffiMembership, expected) in variants {
            let group = AppGroupRecordFfi(
                groupIdHex: "group",
                endpoint: "",
                name: "Test Group",
                description: "",
                admins: [],
                relays: [],
                nostrGroupIdHex: "",
                avatarUrl: nil,
                avatarDim: nil,
                avatarThumbhash: nil,
                imageHashHex: nil,
                encryptedMedia: AppGroupEncryptedMediaComponentFfi(
                    componentId: 0,
                    component: "",
                    required: false,
                    mediaFormat: "",
                    allowedLocatorKinds: [],
                    defaultBlobEndpoints: []
                ),
                disappearingMessageSecs: 0,
                archived: false,
                pendingConfirmation: false,
                selfMembership: ffiMembership,
                welcomerAccountIdHex: nil,
                viaWelcomeMessageIdHex: nil
            )
            let managementState = GroupManagementStateFfi(
                myAccountIdHex: "self",
                isSelfAdmin: false,
                isLastAdmin: false,
                canInvite: false,
                canLeave: false,
                requiresSelfDemoteBeforeLeave: false,
                memberActions: []
            )

            let snapshot = state.groupDetailsSnapshot(
                from: GroupDetailsFfi(group: group, members: []),
                managementState: managementState
            )

            #expect(snapshot.selfMembership == expected)
        }
    }

    @Test func remoteImageSanitizedURLRejectsPrivateHosts() async throws {
        // The string entry point used by the UI must also reject internal destinations.
        #expect(RemoteImageURLPolicy.sanitizedURL(from: "https://192.168.1.1/x.png") == nil)
        #expect(RemoteImageURLPolicy.sanitizedURL(from: "https://127.0.0.1:8080/x.png") == nil)
        #expect(RemoteImageURLPolicy.sanitizedURL(from: "https://[::1]/x.png") == nil)
        #expect(RemoteImageURLPolicy.sanitizedURL(from: "https://localhost/x.png") == nil)
        #expect(RemoteImageURLPolicy.sanitizedURL(from: "https://localhost./x.png") == nil)
        #expect(RemoteImageURLPolicy.sanitizedURL(from: "https://profile.localhost/x.png") == nil)
        #expect(RemoteImageURLPolicy.sanitizedURL(from: "https://profile.localhost./x.png") == nil)
        #expect(RemoteImageURLPolicy.sanitizedURL(from: "https://printer.local./x.png") == nil)
        #expect(RemoteImageURLPolicy.sanitizedURL(from: "https://127.0.0.1./x.png") == nil)
        // whitenoise-mac#243: broadcast / multicast / reserved / CGNAT are non-public too,
        // including an obfuscated (decimal) broadcast literal to exercise the parser path.
        #expect(RemoteImageURLPolicy.sanitizedURL(from: "https://255.255.255.255/x.png") == nil)
        #expect(RemoteImageURLPolicy.sanitizedURL(from: "https://224.0.0.1/x.png") == nil)
        #expect(RemoteImageURLPolicy.sanitizedURL(from: "https://240.0.0.1/x.png") == nil)
        #expect(RemoteImageURLPolicy.sanitizedURL(from: "https://100.64.0.1/x.png") == nil)
        #expect(RemoteImageURLPolicy.sanitizedURL(from: "https://4294967295/x.png") == nil)
        // A public host still round-trips.
        #expect(
            RemoteImageURLPolicy.sanitizedURL(from: "https://cdn.example/p.png")?.absoluteString
                == "https://cdn.example/p.png")
    }

    @Test func remoteImagePolicyRejectsEmbeddedUserinfoHostConfusion() async throws {
        // Profile picture URLs are attacker-controlled Nostr metadata. Embedded userinfo can make
        // the URL read like a trusted host while URL parsing fetches from the attacker's host;
        // match MarkdownLinkPolicy and reject any user/password component before allowing a fetch.
        for raw in [
            "https://trusted.example@evil.example/x.png",
            "https://cdn.example@evil.example/avatar.png",
            "https://user:pass@evil.example/x.png",
            "https://:pass@evil.example/x.png",
            "https://user@evil.example/x.png",
        ] {
            let url = try #require(URL(string: raw))
            #expect(!RemoteImageURLPolicy.isAllowed(url), "expected rejection for \(raw)")
            #expect(RemoteImageURLPolicy.sanitizedURL(from: raw) == nil, "expected nil for \(raw)")
        }
    }

    @Test func remoteImageCollectorReturnsAllBytesUnderCap() async throws {
        // Several chunks spanning typical OS delivery sizes should round-trip byte-for-byte.
        let chunkSize = 64 * 1024
        let payload = (0..<(chunkSize * 2 + 123)).map { UInt8($0 & 0xFF) }
        var collector = CappedDataCollector(cap: Int64(payload.count) + 1)
        // Feed the payload in chunks the way URLSession would deliver it.
        var offset = 0
        while offset < payload.count {
            let end = min(offset + chunkSize, payload.count)
            let didAppend = collector.append(Data(payload[offset..<end]))
            #expect(didAppend)
            offset = end
        }
        #expect(!collector.exceededCap)
        #expect(Array(collector.data) == payload)
    }

    @Test func remoteImageCollectorAcceptsExactlyCapBytes() async throws {
        // Exactly `cap` bytes is allowed (the check rejects only when total exceeds cap).
        let payload = [UInt8](repeating: 0xAB, count: 64 * 1024 + 7)
        var collector = CappedDataCollector(cap: Int64(payload.count))
        let didAppend = collector.append(Data(payload))
        #expect(didAppend)
        #expect(!collector.exceededCap)
        #expect(collector.data.count == payload.count)
    }

    @Test func remoteImageCollectorRejectsOverCap() async throws {
        // One byte past the cap aborts the download (unbounded-response protection): the
        // over-cap chunk is rejected, the flag is set, and subsequent chunks are ignored.
        let cap = 64 * 1024
        var collector = CappedDataCollector(cap: Int64(cap))
        let didAppendInitialChunk = collector.append(Data([UInt8](repeating: 0x01, count: cap)))
        #expect(didAppendInitialChunk)
        let didAppendOverCapByte = collector.append(Data([0x02]))
        #expect(!didAppendOverCapByte)
        #expect(collector.exceededCap)
        // Further appends stay rejected and do not grow the buffer.
        let didAppendAfterCapExceeded = collector.append(Data([0x03, 0x04]))
        #expect(!didAppendAfterCapExceeded)
        #expect(collector.data.count == cap)
    }

    @Test func remoteImageCollectorHandlesEmptyResponse() async throws {
        let collector = CappedDataCollector(cap: 1024)
        #expect(collector.data.isEmpty)
        #expect(!collector.exceededCap)
    }

    @Test func remoteImageSanitizedURLRejectsUntrustedInput() async throws {
        // nil / empty / whitespace-only -> nil (no request issued).
        #expect(RemoteImageURLPolicy.sanitizedURL(from: nil) == nil)
        #expect(RemoteImageURLPolicy.sanitizedURL(from: "") == nil)
        #expect(RemoteImageURLPolicy.sanitizedURL(from: "   \n ") == nil)

        // Disallowed schemes -> nil.
        #expect(RemoteImageURLPolicy.sanitizedURL(from: "http://tracker.example/pixel.gif") == nil)
        #expect(RemoteImageURLPolicy.sanitizedURL(from: "javascript:alert(1)") == nil)

        // Allowed https with surrounding whitespace -> trimmed, valid URL.
        let sanitized = RemoteImageURLPolicy.sanitizedURL(from: "  https://cdn.example/p.png  ")
        #expect(sanitized?.absoluteString == "https://cdn.example/p.png")
    }

    @MainActor
    @Test func avatarModelsPrecomputeSanitizedPictureURLs() async throws {
        let account = AccountItem(
            id: "account",
            accountRef: "account",
            displayName: "Account",
            accountIdHex: "abc123",
            pictureURL: "  https://cdn.example/account.png  "
        )
        #expect(account.pictureURL == "  https://cdn.example/account.png  ")
        #expect(account.sanitizedPictureURL?.absoluteString == "https://cdn.example/account.png")

        let chat = ChatItem(
            id: "chat",
            title: "Chat",
            subtitle: "Group message",
            preview: "No messages yet",
            updatedAt: nil,
            avatarSeed: "chat",
            pictureURL: "https://0x7f000001/avatar.png",
            unreadCount: 0
        )
        #expect(chat.pictureURL == "https://0x7f000001/avatar.png")
        #expect(chat.sanitizedPictureURL == nil)

        let recipient = NewChatRecipient(
            sourceQuery: "npub1recipient",
            memberRef: "npub1recipient",
            accountIdHex: "def456",
            npub: "npub1recipient",
            displayName: "Recipient",
            pictureURL: "https://cdn.example/recipient.png"
        )
        #expect(recipient.sanitizedPictureURL?.absoluteString == "https://cdn.example/recipient.png")

        let snapshot = groupDetailsSnapshot(
            avatarURL: "  https://cdn.example/group.png  ",
            sanitizedAvatarURL: RemoteImageURLPolicy.sanitizedURL(
                from: "  https://cdn.example/group.png  ")
        )
        #expect(snapshot.avatarURL == "  https://cdn.example/group.png  ")
        #expect(snapshot.sanitizedAvatarURL?.absoluteString == "https://cdn.example/group.png")
    }

    @MainActor
    @Test func groupDetailsHeaderAvatarFallsBackToChatAvatarWhenSnapshotHasNone() async throws {
        let chat = ChatItem(
            id: "chat",
            title: "Chat",
            subtitle: "Group message",
            preview: "No messages yet",
            updatedAt: nil,
            avatarSeed: "chat",
            pictureURL: "https://cdn.example/chat.png",
            unreadCount: 0
        )
        let emptySnapshot = groupDetailsSnapshot(avatarURL: nil, sanitizedAvatarURL: nil)
        let snapshotWithAvatar = groupDetailsSnapshot(
            avatarURL: "https://cdn.example/group.png",
            sanitizedAvatarURL: RemoteImageURLPolicy.sanitizedURL(from: "https://cdn.example/group.png")
        )

        #expect(
            GroupDetailsHeaderAvatar.sanitizedURL(snapshot: nil, fallback: chat)?.absoluteString
                == "https://cdn.example/chat.png")
        #expect(
            GroupDetailsHeaderAvatar.sanitizedURL(snapshot: emptySnapshot, fallback: chat)?.absoluteString
                == "https://cdn.example/chat.png")
        #expect(
            GroupDetailsHeaderAvatar.sanitizedURL(snapshot: snapshotWithAvatar, fallback: chat)?.absoluteString
                == "https://cdn.example/group.png")
    }

    @MainActor
    @Test func profileDraftCachesSanitizedPictureURL() async throws {
        var draft = ProfileDraft(picture: "  https://cdn.example/profile.png  ")
        #expect(draft.sanitizedPictureURL?.absoluteString == "https://cdn.example/profile.png")

        draft.displayName = "Updated"
        #expect(draft.sanitizedPictureURL?.absoluteString == "https://cdn.example/profile.png")

        draft.picture = "https://127.0.0.1/profile.png"
        #expect(draft.sanitizedPictureURL == nil)
    }

    @Test func downsampledImageSizingCeilsAndBucketsRequestedPixels() async throws {
        #expect(DownsampledImageSizing.requestedPixelSize(0) == 1)
        #expect(DownsampledImageSizing.requestedPixelSize(63.1) == 64)
        #expect(
            DownsampledImageSizing.galleryPixelSize(
                for: CGSize(width: 100, height: 100),
                displayScale: 2
            ) == 256
        )
        #expect(
            DownsampledImageSizing.galleryPixelSize(
                for: CGSize(width: 321, height: 200),
                displayScale: 2
            ) == 768
        )
    }

    @Test func relayValidatorAcceptsSecureWssRelays() async throws {
        #expect(RelayURLValidator.classify("wss://relay.example.com") == .secure)
        #expect(RelayURLValidator.classify("wss://relay.us.whitenoise.chat") == .secure)
        #expect(RelayURLValidator.classify("WSS://Relay.Example.com") == .secure)
        #expect(RelayURLValidator.isAcceptable("wss://relay.example.com"))
        #expect(!RelayURLValidator.isInsecure("wss://relay.example.com"))
    }

    @Test func relayValidatorRejectsCleartextWsOnPublicHosts() async throws {
        #expect(RelayURLValidator.classify("ws://relay.example.com") == .insecureRejected)
        #expect(RelayURLValidator.classify("ws://192.168.1.10:7777") == .insecureRejected)
        #expect(RelayURLValidator.classify("ws://10.0.0.1") == .insecureRejected)
        #expect(!RelayURLValidator.isAcceptable("ws://relay.example.com"))
        // Rejected relays are not "insecure-but-allowed" — they simply cannot be saved.
        #expect(!RelayURLValidator.isInsecure("ws://relay.example.com"))
    }

    @Test func relayValidatorAllowsCleartextWsOnLoopbackForDev() async throws {
        for url in [
            "ws://localhost",
            "ws://localhost:7000",
            "ws://relay.localhost",
            "ws://127.0.0.1",
            "ws://127.0.0.1:8080/relay",
            "ws://127.1.2.3",
            "ws://[::1]:7000",
        ] {
            #expect(RelayURLValidator.classify(url) == .insecureLoopback, "expected loopback for \(url)")
            #expect(RelayURLValidator.isAcceptable(url), "expected acceptable for \(url)")
            #expect(RelayURLValidator.isInsecure(url), "expected insecure flag for \(url)")
        }
    }

    @Test func relayValidatorAllowsRootedFQDNLoopbackSpellings() async throws {
        for url in [
            "ws://localhost.",
            "ws://LOCALHOST.:7000",
            "ws://localhost..",
            "ws://relay.localhost.:7000",
            "ws://127.0.0.1.",
            "ws://127.0.0.1.:8080/relay",
            "ws://127.0.0.1..",
            "ws://127.1.2.3.",
        ] {
            #expect(RelayURLValidator.classify(url) == .insecureLoopback, "expected loopback for \(url)")
            #expect(RelayURLValidator.isAcceptable(url), "expected acceptable for \(url)")
            #expect(RelayURLValidator.isInsecure(url), "expected insecure flag for \(url)")
        }
    }

    @Test func relayValidatorAllowsNonCanonicalLoopbackSpellings() async throws {
        // Issue #112: loopback membership is decided by parsing the host as an
        // IP, so every equivalent spelling of the loopback address is accepted,
        // not just the two canonical literals previously hard-coded.
        for url in [
            // Expanded / non-compressed IPv6 loopback.
            "ws://[0:0:0:0:0:0:0:1]",
            "ws://[0:0:0:0:0:0:0:1]:7000",
            // Mixed-case hex with a partial zero-run — still ::1.
            "ws://[0:0:0:0:0:0:0:0001]",
            // IPv4-mapped IPv6 loopback.
            "ws://[::ffff:127.0.0.1]",
            "ws://[::ffff:127.0.0.1]:7000",
            "ws://[::ffff:127.1.2.3]",
            // Non-127.0.0.1 addresses inside 127.0.0.0/8 are still loopback.
            "ws://127.255.255.254",
        ] {
            #expect(RelayURLValidator.classify(url) == .insecureLoopback, "expected loopback for \(url)")
            #expect(RelayURLValidator.isAcceptable(url), "expected acceptable for \(url)")
            #expect(RelayURLValidator.isInsecure(url), "expected insecure flag for \(url)")
        }
    }

    @Test func relayValidatorRejectsNonLoopbackIPLiterals() async throws {
        // Issue #112: parsing must not over-accept. Non-loopback IP literals —
        // including IPv6 and IPv4-mapped IPv6 that point outside 127.0.0.0/8 —
        // remain rejected cleartext relays.
        for url in [
            "ws://[2001:db8::1]",  // public IPv6
            "ws://[::ffff:192.168.1.10]",  // IPv4-mapped, non-loopback
            "ws://[fe80::1]",  // link-local IPv6
            "ws://126.0.0.1",  // just outside 127.0.0.0/8
            "ws://128.0.0.1",  // just outside 127.0.0.0/8
        ] {
            #expect(RelayURLValidator.classify(url) == .insecureRejected, "expected rejection for \(url)")
            #expect(!RelayURLValidator.isAcceptable(url), "expected not acceptable for \(url)")
        }
    }

    @Test func relayValidatorRejectsNonRelaySchemesAndJunk() async throws {
        for url in ["", "   ", "https://relay.example.com", "relay.example.com", "wssx://foo", "ws://"] {
            #expect(!RelayURLValidator.isAcceptable(url), "expected rejection for \(String(reflecting: url))")
        }
        // Leading/trailing whitespace is trimmed before classification, so a
        // surrounded wss:// relay is still accepted as secure.
        #expect(RelayURLValidator.classify("  wss://relay.example.com  ") == .secure)
        #expect(RelayURLValidator.isAcceptable(" wss://relay.example.com "))
    }

    @Test func relayValidatorFlagsAllCleartextWsAsInsecureForUI() async throws {
        // Loopback dev relays are cleartext.
        #expect(RelayURLValidator.isCleartext("ws://127.0.0.1:7000"))
        #expect(RelayURLValidator.isCleartext("ws://localhost"))
        // Pre-existing public ws:// relays loaded from a saved list are also
        // cleartext and must be flagged, even though they cannot be saved again.
        #expect(RelayURLValidator.isCleartext("ws://relay.example.com"))
        #expect(RelayURLValidator.isCleartext("ws://192.168.1.10:7777"))
        // wss:// and junk are not cleartext.
        #expect(!RelayURLValidator.isCleartext("wss://relay.example.com"))
        #expect(!RelayURLValidator.isCleartext("https://relay.example.com"))
        #expect(!RelayURLValidator.isCleartext(""))
    }

    @Test func relayValidatorRejectsSchemeOnlyAndHostlessURLs() async throws {
        // Regression: a scheme prefix with no host must be malformed, not secure.
        // Previously `wss://` was accepted as `.secure` purely on its prefix.
        #expect(RelayURLValidator.classify("wss://") == .invalid)
        #expect(RelayURLValidator.classify("ws://") == .invalid)
        #expect(RelayURLValidator.classify("wss://  ") == .invalid)
        #expect(!RelayURLValidator.isAcceptable("wss://"))
        #expect(!RelayURLValidator.isInsecure("wss://"))
        #expect(!RelayURLValidator.isCleartext("wss://"))
    }

    @Test func relayValidatorRejectsSpoofedLoopbackHosts() async throws {
        // Hostnames that merely *contain* a loopback token must not be treated as loopback.
        #expect(RelayURLValidator.classify("ws://127.0.0.1.evil.com") == .insecureRejected)
        #expect(RelayURLValidator.classify("ws://127.0.0.1.evil.com.") == .insecureRejected)
        #expect(RelayURLValidator.classify("ws://localhost.evil.com") == .insecureRejected)
        #expect(RelayURLValidator.classify("ws://localhost.evil.com.") == .insecureRejected)
        #expect(RelayURLValidator.classify("ws://notlocalhost") == .insecureRejected)
        #expect(RelayURLValidator.classify("ws://127.0.0.256") == .insecureRejected)
    }

    @Test func relayValidatorRejectsEmbeddedUserinfoHostConfusion() async throws {
        // Issue #327: a relay's identity is its URL string. An entry like
        // `wss://relay.damus.io@evil-relay.example` parses with
        // host == "evil-relay.example" (user == "relay.damus.io"), so a human
        // scanning a relay list reads the trusted leading host while the client
        // connects to the attacker. Any userinfo makes the URL invalid before
        // scheme classification, so it can never be accepted or flagged secure.
        for url in [
            // Deceptive trusted-host-as-userinfo cases (the core attack).
            "wss://relay.damus.io@evil-relay.example",
            "wss://trusted@evil",
            "wss://relay.example.com@evil.com/relay",
            // Loopback host smuggled behind userinfo must not become loopback.
            "ws://localhost@evil.com",
            "ws://127.0.0.1@evil.com",
            // Explicit user:password userinfo variants.
            "wss://user:pass@evil.com",
            "wss://:pass@evil.com",
            "wss://user@relay.example.com",
        ] {
            #expect(RelayURLValidator.classify(url) == .invalid, "expected invalid for \(url)")
            #expect(!RelayURLValidator.isAcceptable(url), "expected not acceptable for \(url)")
            #expect(!RelayURLValidator.isInsecure(url), "expected no insecure flag for \(url)")
            #expect(!RelayURLValidator.isCleartext(url), "expected not cleartext for \(url)")
        }
    }

    @Test func markdownLinkPolicyAllowsOnlyWebAndNostrSchemes() async throws {
        let httpsURL = MarkdownLinkPolicy.sanitizedURL(from: "https://example.com/path")
        #expect(httpsURL?.absoluteString == "https://example.com/path")

        let httpURL = MarkdownLinkPolicy.sanitizedURL(from: " HTTP://example.com/path ")
        #expect(httpURL?.scheme?.lowercased() == "http")

        let nostrURL = MarkdownLinkPolicy.sanitizedURL(
            from: "nostr:npub1qqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqq0l5v8"
        )
        #expect(nostrURL?.scheme == "nostr")

        let nprofileURL = MarkdownLinkPolicy.sanitizedURL(from: "nostr:nprofile1alyce")
        #expect(nprofileURL?.absoluteString == "nostr:nprofile1alyce")
        #expect(MarkdownLinkPolicy.isResolvableProfileReference("npub1alyce"))
        #expect(MarkdownLinkPolicy.isResolvableProfileReference("nprofile1alyce"))
        #expect(MarkdownLinkPolicy.isProfileReferenceInput("nostr:nprofile1alyce"))
        #expect(!MarkdownLinkPolicy.isResolvableProfileReference("note1alyce"))

        for raw in [
            "",
            "   ",
            "https:example.com",
            "file:///Applications/Calculator.app",
            "smb://attacker/share",
            "mailto:peer@example.com",
            "javascript:alert(1)",
            "x-whatever://payload",
            "nostr:unknown1payload",
        ] {
            #expect(
                MarkdownLinkPolicy.sanitizedURL(from: raw) == nil,
                "expected rejection for \(String(reflecting: raw))"
            )
        }
    }

    @Test func markdownLinkPolicyRejectsEmbeddedUserinfoHostConfusion() async throws {
        // Peer Markdown links are user-visible strings. Embedded userinfo can make
        // the URL read like a trusted host while URL parsing sends the browser to
        // the attacker-controlled host, so match RelayURLValidator's policy and
        // reject any user/password component before exposing the link.
        for raw in [
            "https://relay.damus.io@evil.example/phish",
            "http://trusted.example@evil.example/path",
            "https://user:pass@evil.example/path",
            "https://:pass@evil.example/path",
            "https://user@evil.example/path",
        ] {
            let url = try #require(URL(string: raw))
            #expect(!MarkdownLinkPolicy.isAllowedExternalURL(url), "expected rejection for \(raw)")
            #expect(MarkdownLinkPolicy.sanitizedURL(from: raw) == nil, "expected nil for \(raw)")
        }
    }

    @Test func marmotProfileLinkAcceptsStrictProfileFormOnly() async throws {
        // Accepted: strict marmot://profile/<npub|nprofile>, query ignored, case-insensitive
        // scheme/host. These flow in from OS deep links and kit-emitted message autolinks.
        for raw in [
            "marmot://profile/npub1alyce",
            "marmot://profile/npub1alyce?from=qr",
            "marmot://profile/nprofile1alyce",
            "MARMOT://PROFILE/npub1alyce",
        ] {
            let url = try #require(URL(string: raw))
            #expect(
                MarmotProfileLink.profileReference(from: url)?.lowercased().hasPrefix("n") == true,
                "expected acceptance for \(String(reflecting: raw))"
            )
            #expect(MarkdownLinkPolicy.isInternalMarmotProfileURL(url))
            #expect(
                MarkdownLinkPolicy.sanitizedURL(from: raw) != nil,
                "expected sanitizedURL acceptance for \(String(reflecting: raw))"
            )
        }
        let plain = try #require(URL(string: "marmot://profile/npub1alyce"))
        #expect(MarmotProfileLink.profileReference(from: plain) == "npub1alyce")
        let withQuery = try #require(URL(string: "marmot://profile/npub1alyce?from=qr"))
        #expect(MarmotProfileLink.profileReference(from: withQuery) == "npub1alyce")

        // Rejected: every other marmot:// shape. The scheme is not exclusive to this app,
        // so inbound URLs are untrusted; nothing here may reach LaunchServices either.
        for raw in [
            "marmot://group/abc",
            "marmot://profile",
            "marmot://profile/",
            "marmot://profile/note1abc",
            "marmot://profile/npub1x/extra",
            "marmot://x-callback-url/run",
            "marmot://profile/../npub1alyce",
        ] {
            if let url = URL(string: raw) {
                #expect(
                    MarmotProfileLink.profileReference(from: url) == nil,
                    "expected rejection for \(String(reflecting: raw))"
                )
                #expect(!MarkdownLinkPolicy.isInternalMarmotProfileURL(url))
            }
            #expect(
                MarkdownLinkPolicy.sanitizedURL(from: raw) == nil,
                "expected sanitizedURL rejection for \(String(reflecting: raw))"
            )
        }

        // The retired darkmatter:// scheme is a clean break (mdk#725): no longer recognized.
        #expect(MarkdownLinkPolicy.sanitizedURL(from: "darkmatter://profile/npub1alyce") == nil)

        // QR payload emits the canonical link form and round-trips through the parser.
        let payload = MarmotProfileLink.qrPayload(npub: "npub1alyce")
        #expect(payload == "marmot://profile/npub1alyce?from=qr")
        let payloadURL = try #require(URL(string: payload))
        #expect(MarmotProfileLink.profileReference(from: payloadURL) == "npub1alyce")

        // Paste pre-check prefix helper.
        #expect(MarmotProfileLink.hasProfileLinkPrefix("  marmot://profile/npub1alyce?from=qr "))
        #expect(MarmotProfileLink.hasProfileLinkPrefix("MARMOT://PROFILE/npub1alyce"))
        #expect(!MarmotProfileLink.hasProfileLinkPrefix("darkmatter://profile/npub1alyce"))
        #expect(!MarmotProfileLink.hasProfileLinkPrefix("marmot://group/abc"))
    }

    @Test func profileReferenceGrammarRejectsEmbeddedHostPayloads() async throws {
        // A resolvable ref must stay inside the bech32 alphabet after its prefix. Prefix-only
        // matching let refs with an embedded `@domain` reach the NIP-05 resolver and beacon the
        // viewer's IP to an attacker-chosen host on click.
        for reference in [
            "npub1qqq@evil.example",
            "nprofile1qqq@evil.example",
            "npub1x.y",
            "npub1qqq:8080",
            "npub1qqq/path",
            "npub1qqq?name=x",
            "npub1qqq evil",
            "npub1bio",  // `b`, `i`, and `o` sit outside the bech32 alphabet
            "npub1",  // a bare prefix carries no payload
        ] {
            #expect(
                !MarkdownLinkPolicy.isResolvableProfileReference(reference),
                "expected rejection for \(String(reflecting: reference))"
            )
        }
        #expect(MarkdownLinkPolicy.isResolvableProfileReference("npub1alyce"))
        #expect(
            MarkdownLinkPolicy.isResolvableProfileReference(
                "npub1qqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqq0l5v8"
            )
        )

        // The nostr autolink form extracts the same ref and stays unresolvable.
        let nostrURL = try #require(URL(string: "nostr:npub1x.y"))
        let extracted = try #require(MarkdownLinkPolicy.nostrReference(from: nostrURL))
        #expect(!MarkdownLinkPolicy.isResolvableProfileReference(extracted))

        // The profile deep-link form is gated on the same grammar, including the
        // percent-encoded spelling that decodes back into an `@`.
        for raw in [
            "marmot://profile/npub1qqq@evil.example",
            "marmot://profile/npub1qqq%40evil.example",
            "marmot://profile/npub1x.y",
        ] {
            if let url = URL(string: raw) {
                #expect(
                    MarmotProfileLink.profileReference(from: url) == nil,
                    "expected rejection for \(String(reflecting: raw))"
                )
            }
            #expect(
                MarkdownLinkPolicy.sanitizedURL(from: raw) == nil,
                "expected sanitizedURL rejection for \(String(reflecting: raw))"
            )
        }
    }

    @Test func nostrMarkerStringsAreNeverNIP05Candidates() async throws {
        // `memberRefCandidate` refuses NIP-05 resolution for anything carrying a nostr marker,
        // so a ref like `nostr:npub1…@host` can only ever reach the authoritative FFI parse.
        for value in [
            "nostr:npub1qqq@evil.example",
            "npub1qqq@evil.example",
            "NPUB1QQQ@EVIL.EXAMPLE",
            "nprofile1qqq@evil.example",
            "marmot://profile/npub1qqq",
            "prefix nostr:npub1qqq suffix",
        ] {
            #expect(
                MarkdownLinkPolicy.containsNostrReferenceMarker(value),
                "expected marker in \(String(reflecting: value))"
            )
        }
        for value in ["alice@example.com", "npub@example.com", "note1qqq", ""] {
            #expect(
                !MarkdownLinkPolicy.containsNostrReferenceMarker(value),
                "expected no marker in \(String(reflecting: value))"
            )
        }
    }

    @Test func nip05IdentifierRestrictsLocalPartCharsetAndLength() async throws {
        // Local parts are the spec-legal lowercase set, accepted case-insensitively.
        let mixedCase = try #require(NIP05Identifier("Alice.Smith_9-a@Example.COM"))
        #expect(mixedCase.name == "alice.smith_9-a")
        #expect(mixedCase.domain == "example.com")

        for raw in [
            "nostr:npub1qqq@evil.example",  // `:` can no longer smuggle a full ref into the name
            "npub1qqq/x@evil.example",
            "name!bang@example.com",
            "na me@example.com",
            "átila@example.com",
            "@example.com",
            "name@",
            String(repeating: "a", count: 250) + "@example.com",  // over the local-part bound
        ] {
            #expect(NIP05Identifier(raw) == nil, "expected rejection for \(String(reflecting: raw))")
        }

        // A bare `npub1…@host` is still a charset-legal identifier, the marker guard above is
        // the layer that keeps it away from the resolver.
        #expect(NIP05Identifier("npub1qqq@evil.example") != nil)
    }

    @Test func nip05IdentifierRejectsReservedLocalhostNamespace() async throws {
        #expect(NIP05Identifier("alice@app.localhost") == nil)
        #expect(NIP05Identifier("alice@app.localhost.") == nil)
    }

    @Test func nip05RedirectPolicyCapsRedirectHopsPerTask() async throws {
        // Delegate methods are exercised directly, no task is ever resumed so nothing touches
        // the network.
        let policy = NIP05RedirectPolicy()
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let origin = try #require(URL(string: "https://identity.example/.well-known/nostr.json"))
        let response = try #require(
            HTTPURLResponse(url: origin, statusCode: 302, httpVersion: "HTTP/1.1", headerFields: nil)
        )
        let target = URLRequest(url: try #require(URL(string: "https://next.example/hop")))

        let task = session.dataTask(with: origin)
        var results: [URLRequest?] = []
        for _ in 0..<6 {
            policy.urlSession(session, task: task, willPerformHTTPRedirection: response, newRequest: target) {
                results.append($0)
            }
        }
        #expect(results.count == 6)
        #expect(results[4]?.url == target.url)  // five hops pass, matching the avatar downloader
        #expect(results[5] == nil)  // the sixth is cancelled

        // Budgets are per task — one looping lookup must not starve the next.
        let freshTask = session.dataTask(with: origin)
        var freshResult: URLRequest?
        policy.urlSession(session, task: freshTask, willPerformHTTPRedirection: response, newRequest: target) {
            freshResult = $0
        }
        #expect(freshResult?.url == target.url)

        // A disallowed redirect target is still refused on the first hop.
        let disallowed = URLRequest(url: try #require(URL(string: "http://next.example/hop")))
        let plainTask = session.dataTask(with: origin)
        var disallowedResult: URLRequest? = target
        policy.urlSession(
            session, task: plainTask, willPerformHTTPRedirection: response, newRequest: disallowed
        ) {
            disallowedResult = $0
        }
        #expect(disallowedResult == nil)
    }

    @Test func markdownLinkPolicyRejectsPrivateAndLoopbackHosts() async throws {
        // whitenoise-mac#249: peer-controlled Markdown links to literal private/loopback/
        // link-local destinations must be suppressed symmetrically with avatar image URLs,
        // even though the scheme is an otherwise-allowed http/https.
        for raw in [
            "http://192.168.0.1/admin/reboot",
            "https://[::1]:9000/",
            "http://127.0.0.1:8080/",
            "http://127.0.0.1.:8080/",
            "https://10.0.0.5/x",
            "http://169.254.169.254/latest/meta-data",
            "https://[fe80::1]/",
            "http://localhost/admin",
            "http://localhost./admin",
            "https://foo.localhost:8080/x",
            "https://foo.localhost.:8080/x",
            "https://printer.local/status",
            "https://printer.local./status",
            // Obfuscated loopback literal (decimal form of 127.0.0.1).
            "http://2130706433/",
        ] {
            #expect(
                MarkdownLinkPolicy.sanitizedURL(from: raw) == nil,
                "expected rejection for \(String(reflecting: raw))"
            )
        }

        // Public http/https hosts and internal nostr links still pass.
        #expect(MarkdownLinkPolicy.sanitizedURL(from: "https://example.com/path") != nil)
        #expect(MarkdownLinkPolicy.sanitizedURL(from: "http://cdn.example.com/a") != nil)
        #expect(MarkdownLinkPolicy.sanitizedURL(from: "nostr:nprofile1alyce") != nil)
    }

    @Test func remoteImagePolicyRejectsMulticastAndEmbeddedPrivateIPv6() async throws {
        for raw in [
            "https://[ff02::1]/x.png",  // multicast, mirroring the IPv4 `224.0.0.0/4` rejection
            "https://[ff05::1:3]/x.png",
            "https://[::ffff:0:c0a8:1]/x.png",  // translated prefix around 192.168.0.1
            "https://[::ffff:0:192.168.0.1]/x.png",
            "https://[64:ff9b::c0a8:1]/x.png",  // NAT64 well-known prefix around 192.168.0.1
            "https://[64:ff9b::192.168.0.1]/x.png",
            "https://[64:ff9b::7f00:1]/x.png",  // NAT64 around 127.0.0.1
            "https://[64:ff9b:1::]/x.png",  // RFC 8215 local-use translation prefix, low boundary
            "https://[64:ff9b:1::1]/x.png",
            "https://[64:ff9b:1:ffff:ffff:ffff:ffff:ffff]/x.png",  // RFC 8215 /48 high boundary
            "https://[::2]/x.png",  // IPv4-compatible 0.0.0.2, inside 0.0.0.0/8
            "https://[::ffff]/x.png",  // IPv4-compatible 0.0.255.255
            "https://[2001:db8::5]/x.png",  // documentation range 2001:db8::/32, non-routable
            "https://[2002:c0a8:0101::1]/x.png",  // 6to4 gateway 192.168.1.1
            "https://[2002:7f00:0001::]/x.png",  // 6to4 gateway 127.0.0.1
            "https://[2001:0:0808:0808:0:0:3f57:fefe]/x.png",  // Teredo client 192.168.1.1 (XOR obfuscated)
            "https://[2001:0:c0a8:0101:0:0:f7f7:f7f7]/x.png",  // Teredo server 192.168.1.1 (direct)
        ] {
            #expect(
                RemoteImageURLPolicy.sanitizedURL(from: raw) == nil,
                "expected rejection for \(String(reflecting: raw))"
            )
        }

        // Embedded-public NAT64 and plain public IPv6 destinations keep loading.
        #expect(RemoteImageURLPolicy.sanitizedURL(from: "https://[64:ff9b::808:808]/x.png") != nil)
        // Adjacent to the RFC 8215 /48.
        #expect(RemoteImageURLPolicy.sanitizedURL(from: "https://[64:ff9b:2::1]/x.png") != nil)
        #expect(RemoteImageURLPolicy.sanitizedURL(from: "https://[2606:4700:4700::1111]/x.png") != nil)
        // 6to4 and Teredo with embedded-public IPv4 are not blanket-rejected.
        #expect(RemoteImageURLPolicy.sanitizedURL(from: "https://[2002:0808:0808::1]/x.png") != nil)
        #expect(
            RemoteImageURLPolicy.sanitizedURL(from: "https://[2001:0:0808:0808:0:0:f7f7:f7f7]/x.png") != nil)
    }

    @Test func markdownDisplayStripsBidiControlsFromPeerControlledText() async throws {
        let rtlOverride = "\u{202E}"
        let ltrIsolate = "\u{2066}"
        let zwj = "\u{200D}"

        let spoofedLinkLabel = "\(rtlOverride)moc.elpmaxe//:sptth\(ltrIsolate)"
        let linkAttributed = MarkdownDisplayInlineBuilder.attributedString(
            from: [
                .link(
                    dest: "https://evil.example/phish",
                    title: nil,
                    children: [.text(content: spoofedLinkLabel)]
                )
            ],
            remainingDepth: 32
        )
        #expect(!containsBidiEmbeddingOrIsolate(String(linkAttributed.characters)))
        #expect(String(linkAttributed.characters) == "moc.elpmaxe//:sptth")
        #expect(links(in: linkAttributed).map(\.absoluteString) == ["https://evil.example/phish"])

        let spoofedAutolinkURL = "\(rtlOverride)https://example.com\(ltrIsolate)"
        let autolinkAttributed = MarkdownDisplayInlineBuilder.attributedString(
            from: [.autolink(url: spoofedAutolinkURL, kind: .uri)],
            remainingDepth: 32
        )
        #expect(!containsBidiEmbeddingOrIsolate(String(autolinkAttributed.characters)))
        #expect(String(autolinkAttributed.characters) == "https://example.com")
        let expectedAutolink = MarkdownLinkPolicy.sanitizedURL(from: spoofedAutolinkURL)
        #expect(links(in: autolinkAttributed) == (expectedAutolink.map { [$0] } ?? []))

        let familyEmoji = "👨\(zwj)👩\(zwj)👧"
        let plainAttributed = MarkdownDisplayInlineBuilder.attributedString(
            from: [.text(content: familyEmoji)],
            remainingDepth: 32
        )
        #expect(String(plainAttributed.characters) == familyEmoji)
        #expect(
            String(plainAttributed.characters).unicodeScalars.contains { $0.value == 0x200D }
        )

        let document = MarkdownDisplayDocument(
            document: MarkdownDocumentFfi(
                blocks: [
                    .codeBlock(
                        kind: .fenced,
                        info: "",
                        content: "\(rtlOverride)secret\(ltrIsolate)"
                    ),
                    .mathBlock(content: "\(rtlOverride)x^2\(ltrIsolate)"),
                ],
                truncated: false
            )
        )
        guard case .codeBlock(let codeContent) = document.blocks.first?.block else {
            Issue.record("expected a code block")
            return
        }
        #expect(codeContent == "secret")
        #expect(!containsBidiEmbeddingOrIsolate(codeContent))
        guard case .mathBlock(let mathContent) = document.blocks.last?.block else {
            Issue.record("expected a math block")
            return
        }
        #expect(mathContent == "x^2")
        #expect(!containsBidiEmbeddingOrIsolate(mathContent))
    }

    @Test func markdownInlineBuilderDropsUnsafeMarkdownLinks() async throws {
        let safe = MarkdownDisplayInlineBuilder.attributedString(
            from: [
                .link(
                    dest: "https://example.com/profile",
                    title: nil,
                    children: [.text(content: "safe")]
                )
            ], remainingDepth: 32)
        #expect(String(safe.characters) == "safe")
        #expect(links(in: safe).map(\.absoluteString) == ["https://example.com/profile"])

        let unsafe = MarkdownDisplayInlineBuilder.attributedString(
            from: [
                .link(
                    dest: "file:///Applications/Calculator.app",
                    title: nil,
                    children: [.text(content: "unsafe")]
                )
            ], remainingDepth: 32)
        #expect(String(unsafe.characters) == "unsafe")
        #expect(links(in: unsafe).isEmpty)

        let unsafeAutolink = MarkdownDisplayInlineBuilder.attributedString(
            from: [
                .autolink(url: "smb://attacker/share", kind: .uri)
            ], remainingDepth: 32)
        #expect(String(unsafeAutolink.characters) == "smb://attacker/share")
        #expect(links(in: unsafeAutolink).isEmpty)

        let hostConfusion = MarkdownDisplayInlineBuilder.attributedString(
            from: [
                .link(
                    dest: "https://relay.damus.io@evil.example/phish",
                    title: nil,
                    children: [.text(content: "spoof")]
                )
            ], remainingDepth: 32)
        #expect(String(hostConfusion.characters) == "spoof")
        #expect(links(in: hostConfusion).isEmpty)
    }

    @Test func markdownInlineBuilderKeepsNostrEntitiesInternal() async throws {
        let bech32 = "npub1qqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqq0l5v8"
        let attributed = MarkdownDisplayInlineBuilder.attributedString(
            from: [
                .nostrMention(entity: MarkdownNostrEntityFfi(hrp: .npub, bech32: bech32))
            ], remainingDepth: 32)
        #expect(links(in: attributed).map(\.absoluteString) == ["nostr:\(bech32)"])
    }

    @MainActor
    @Test func groupImagePreviewURLUsesOpenverseThumbnailOnly() async throws {
        // Regression for whitenoise-mac#315: search-result tiles must connect only to
        // the Openverse-proxied thumbnail, never to the arbitrary origin `imageURL`.
        // Any result without a usable thumbnail renders the placeholder (nil preview).
        let origin = "https://origin.example/photo.jpg"

        #expect(
            groupImageResult(imageURL: origin, thumbnailURL: "https://api.openverse.org/thumb.jpg").previewURL
                == URL(string: "https://api.openverse.org/thumb.jpg")
        )
        #expect(groupImageResult(imageURL: origin, thumbnailURL: nil).previewURL == nil)
        #expect(groupImageResult(imageURL: origin, thumbnailURL: "").previewURL == nil)
        #expect(groupImageResult(imageURL: origin, thumbnailURL: "   ").previewURL == nil)
    }

    @Test func markdownInlineBuilderOnlyUsesMentionSigilForProfileNostrEntities() async throws {
        let npub = "npub1qqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqzqujme"
        let nprofile = "nprofile1qqsqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqq8uzqt"
        let note = "note1zyg3zyg3zyg3zyg3zyg3zyg3zyg3zyg3zyg3zyg3zyg3zyg3zygsglnzgl"

        let cases: [(inline: MarkdownInlineFfi, displayText: String, reference: String)] = [
            (
                .nostrMention(entity: MarkdownNostrEntityFfi(hrp: .npub, bech32: npub)),
                "@npub1qqqqq...ujme",
                npub
            ),
            (
                .nostrUri(entity: MarkdownNostrEntityFfi(hrp: .nprofile, bech32: nprofile)),
                "@nprofile1q...uzqt",
                nprofile
            ),
            (
                .nostrMention(entity: MarkdownNostrEntityFfi(hrp: .note, bech32: note)),
                "note1zyg3z...nzgl",
                note
            ),
            (
                .nostrUri(entity: MarkdownNostrEntityFfi(hrp: .note, bech32: note)),
                "note1zyg3z...nzgl",
                note
            ),
        ]

        for testCase in cases {
            let attributed = MarkdownDisplayInlineBuilder.attributedString(
                from: [testCase.inline],
                remainingDepth: 32
            )
            #expect(String(attributed.characters) == testCase.displayText)
            #expect(links(in: attributed).map(\.absoluteString) == ["nostr:\(testCase.reference)"])
        }
    }

    @MainActor
    private func chatMessage(
        id: String,
        sender: String = "alice",
        body: String? = nil,
        timelineAt: UInt64
    ) -> MessageItem {
        MessageItem(
            id: id,
            senderAccountIdHex: sender,
            senderName: sender,
            body: body ?? (id == "target" ? "Original" : id),
            sentAt: Date(timeIntervalSince1970: TimeInterval(timelineAt)),
            timelineAt: timelineAt,
            isOutgoing: false
        )
    }

    private func makeEditOverlay(
        target: String = "target",
        editId: String,
        sender: String = "alice",
        plaintext: String,
        timelineAt: UInt64
    ) -> MessageEditOverlay {
        MessageEditOverlay(
            targetMessageIdHex: target,
            editMessageIdHex: editId,
            sender: sender,
            plaintext: plaintext,
            timelineAt: timelineAt
        )
    }

    private func editUpsert(_ overlay: MessageEditOverlay) -> MessageEditMutation {
        .upsert(overlay)
    }

    private func editRetract(_ editMessageIdHex: String) -> MessageEditMutation {
        .retract(editMessageIdHex: editMessageIdHex)
    }

    private func groupImageResult(imageURL: String, thumbnailURL: String?) -> GroupImageSearchResult {
        GroupImageSearchResult(
            id: "image-1",
            title: "Aurora",
            imageURL: imageURL,
            thumbnailURL: thumbnailURL,
            creator: nil,
            license: nil,
            attribution: nil,
            sourceURL: nil,
            width: nil,
            height: nil
        )
    }

    @MainActor
    private func mediaDownloadStore(
        plaintext: Data,
        fileName: String,
        payloadId: String
    ) -> MediaDownloadStateStore {
        let store = MediaDownloadStateStore()
        store.update(
            .loaded(
                MessageMediaDownload(
                    data: plaintext,
                    fileName: fileName,
                    mediaType: "image/png",
                    sizeBytes: UInt64(plaintext.count),
                    payloadId: payloadId
                )
            )
        )
        return store
    }

    private func mediaReference(fileName: String, mediaType: String) -> MediaAttachmentReferenceFfi {
        MediaAttachmentReferenceFfi(
            locators: [MediaLocatorFfi(kind: "blossom", value: "https://media.example/\(fileName)")],
            ciphertextSha256: "ciphertext-\(fileName)",
            plaintextSha256: "plaintext-\(fileName)",
            nonceHex: "00",
            fileName: fileName,
            mediaType: mediaType,
            version: "1",
            sourceEpoch: 1,
            dim: nil,
            thumbhash: nil
        )
    }

    private func containsBidiEmbeddingOrIsolate(_ text: String) -> Bool {
        text.unicodeScalars.contains { scalar in
            let value = scalar.value
            return (0x202A...0x202E).contains(value) || (0x2066...0x2069).contains(value)
        }
    }

    private func links(in attributed: AttributedString) -> [URL] {
        var result: [URL] = []
        for run in attributed.runs {
            if let link = run.link {
                result.append(link)
            }
        }
        return result
    }

    private func groupDetailsSnapshot(avatarURL: String?, sanitizedAvatarURL: URL?) -> GroupDetailsSnapshot {
        GroupDetailsSnapshot(
            groupIdHex: "group",
            endpoint: "",
            name: "Group",
            description: "",
            avatarURL: avatarURL,
            sanitizedAvatarURL: sanitizedAvatarURL,
            avatarDimension: nil,
            nostrGroupIdHex: "",
            relays: [],
            adminIds: [],
            archived: false,
            pendingConfirmation: false,
            selfMembership: .member,
            members: [],
            isSelfAdmin: false,
            isLastAdmin: false,
            canInvite: false,
            canLeave: true,
            requiresSelfDemoteBeforeLeave: false,
            disappearingMessageSecs: 0
        )
    }

    @MainActor
    @Test func hoverSelectionCoordinatorOnlyTogglesAffectedBubbles() async throws {
        let coordinator = ConversationHoverSelectionCoordinator()
        var firstSelectable = false
        var secondSelectable = false
        var thirdSelectable = false
        var firstChangeCount = 0
        var secondChangeCount = 0
        var thirdChangeCount = 0
        coordinator.register(
            messageID: "first",
            isSelectable: Binding(
                get: { firstSelectable },
                set: {
                    firstSelectable = $0
                    firstChangeCount += 1
                }
            )
        )
        coordinator.register(
            messageID: "second",
            isSelectable: Binding(
                get: { secondSelectable },
                set: {
                    secondSelectable = $0
                    secondChangeCount += 1
                }
            )
        )
        coordinator.register(
            messageID: "third",
            isSelectable: Binding(
                get: { thirdSelectable },
                set: {
                    thirdSelectable = $0
                    thirdChangeCount += 1
                }
            )
        )
        firstChangeCount = 0
        secondChangeCount = 0
        thirdChangeCount = 0

        coordinator.activate(messageID: "first")
        #expect(firstSelectable)
        #expect(!secondSelectable)
        #expect(!thirdSelectable)
        #expect(firstChangeCount == 1)
        #expect(secondChangeCount == 0)
        #expect(thirdChangeCount == 0)

        firstChangeCount = 0
        secondChangeCount = 0
        thirdChangeCount = 0
        coordinator.activate(messageID: "third")
        #expect(!firstSelectable)
        #expect(!secondSelectable)
        #expect(thirdSelectable)
        #expect(firstChangeCount == 1)
        #expect(secondChangeCount == 0)
        #expect(thirdChangeCount == 1)

        firstChangeCount = 0
        secondChangeCount = 0
        thirdChangeCount = 0
        coordinator.activate(messageID: "third")
        #expect(thirdSelectable)
        #expect(firstChangeCount == 0)
        #expect(secondChangeCount == 0)
        #expect(thirdChangeCount == 0)

        coordinator.reset()
        #expect(!firstSelectable)
        #expect(!secondSelectable)
        #expect(!thirdSelectable)
    }

    @MainActor
    @Test func hoverSelectionCoordinatorRegistersLateJoinerAsInactive() async throws {
        let coordinator = ConversationHoverSelectionCoordinator()
        var firstSelectable = false
        coordinator.register(
            messageID: "first",
            isSelectable: Binding(get: { firstSelectable }, set: { firstSelectable = $0 })
        )
        coordinator.activate(messageID: "first")

        var secondSelectable = false
        coordinator.register(
            messageID: "second",
            isSelectable: Binding(get: { secondSelectable }, set: { secondSelectable = $0 })
        )
        #expect(firstSelectable)
        #expect(!secondSelectable)
    }
}

private func mentionCandidate(id: String, displayName: String, npub: String) -> ComposerMentionCandidate {
    ComposerMentionCandidate(details: mentionMember(id: id, displayName: displayName, npub: npub))
}

private func mentionMember(
    id: String,
    displayName: String,
    npub: String,
    isSelf: Bool = false
) -> GroupMemberDetailsFfi {
    GroupMemberDetailsFfi(
        memberIdHex: id,
        account: id,
        local: isSelf,
        isAdmin: false,
        isSelf: isSelf,
        npub: npub,
        displayName: displayName
    )
}

@MainActor
private final class NoopLocalNotificationCenter: LocalNotificationCenter {
    func authorizationStatus() async -> LocalNotificationAuthorizationStatus {
        .notDetermined
    }

    func requestAuthorization() async throws -> LocalNotificationAuthorizationStatus {
        .notDetermined
    }

    func post(_ notification: LocalNotificationRequest) async throws {}

    func setResponseHandler(_ handler: @escaping @MainActor ([String: String]) -> Void) {}
}
