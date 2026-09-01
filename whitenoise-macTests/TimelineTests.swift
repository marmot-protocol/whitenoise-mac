//
//  TimelineTests.swift
//  whitenoise-macTests
//
//  The open conversation: reactions, message rendering and markdown, the timeline
//  window and its pagination, peer profiles, the composer and everything Send does.
//
//  Split out of `whitenoise_macTests.swift` verbatim: every test body below is the
//  one that lived in that file, moved rather than rewritten.
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

struct TimelineTests: WorkspaceTestSupport {
    @Test func quickReactionNormalizationPreservesComposedEmojiAndRepairsInvalidValues() {
        let normalized = QuickReactionSet.normalized([
            "  👨‍👩‍👧  ",
            "🇮🇹",
            "👍🏽",
            "A",
            "",
            "🇮🇹",
            "🧑🏾‍💻",
            "🎉",
            "🚀",
            "🥳",
        ])

        #expect(normalized == ["👨‍👩‍👧", "🇮🇹", "👍🏽", "🧑🏾‍💻", "🎉", "🚀"])
        #expect(normalized.count == QuickReactionSet.slotCount)
        #expect(Set(normalized).count == QuickReactionSet.slotCount)
    }

    @MainActor
    @Test func quickReactionStorePersistsMigratesRecoversAndResets() throws {
        let suiteName = "QuickReactionStoreTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let legacyKey = try #require(UserDefaultsQuickReactionStore.legacyStorageKeys.first)
        let legacyJSON = try JSONEncoder().encode(["👨‍👩‍👧", "🔥", "🔥", "bad"])
        defaults.set(legacyJSON, forKey: legacyKey)

        let store = UserDefaultsQuickReactionStore(defaults: defaults)
        let migrated = store.load()

        #expect(migrated == ["👨‍👩‍👧", "🔥", "❤️", "👍", "👎", "😂"])
        #expect(defaults.stringArray(forKey: UserDefaultsQuickReactionStore.storageKey) == migrated)
        #expect(defaults.object(forKey: legacyKey) == nil)

        defaults.set(["unexpected": true], forKey: UserDefaultsQuickReactionStore.storageKey)
        let recovered = store.load()

        #expect(recovered == ChatReactionDefaults.quick)
        #expect(defaults.stringArray(forKey: UserDefaultsQuickReactionStore.storageKey) == recovered)

        let configured = ["🔥", "🎉", "🚀", "🥳", "🤯", "🫡"]
        store.save(configured)
        #expect(UserDefaultsQuickReactionStore(defaults: defaults).load() == configured)

        store.reset()
        #expect(defaults.object(forKey: UserDefaultsQuickReactionStore.storageKey) == nil)
        #expect(store.load() == ChatReactionDefaults.quick)
    }

    @MainActor
    @Test func quickReactionEditsApplyLivePersistAndRestoreDefaults() {
        let configured = ["🔥", "🎉", "🚀", "🥳", "🤯", "🫡"]
        let store = InMemoryQuickReactionStore(configured)
        let state = WorkspaceState(quickReactionStore: store)

        #expect(state.quickReactions == configured)
        #expect(state.replaceQuickReaction(at: 0, with: "🧑🏾‍💻"))
        #expect(state.quickReactions[0] == "🧑🏾‍💻")
        #expect(store.savedValues.last == state.quickReactions)

        let saveCount = store.savedValues.count
        #expect(!state.replaceQuickReaction(at: 0, with: "🎉"))
        #expect(!state.replaceQuickReaction(at: 0, with: "   "))
        #expect(store.savedValues.count == saveCount)

        state.moveQuickReaction(at: 0, by: 1)
        #expect(state.quickReactions.prefix(2) == ["🎉", "🧑🏾‍💻"])
        #expect(store.savedValues.last == state.quickReactions)

        state.restoreDefaultQuickReactions()
        #expect(state.quickReactions == ChatReactionDefaults.quick)
        #expect(store.resetCallCount == 1)
    }

    @MainActor
    @Test func emojiRecentsDoNotReorderConfiguredQuickReactions() throws {
        let suiteName = "QuickReactionRecentsTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let configured = ["🔥", "🎉", "🚀", "🥳", "🤯", "🫡"]
        let store = InMemoryQuickReactionStore(configured)
        let state = WorkspaceState(quickReactionStore: store)

        let recents = ChatEmojiRecents.record("🇮🇹", defaults: defaults)

        #expect(recents.first == "🇮🇹")
        #expect(state.quickReactions == configured)
        #expect(store.savedValues.isEmpty)
    }

    /// Both quick-reaction surfaces — the hover popover and the right-click menu — offer the emojis
    /// the reader configured, never the built-in defaults.
    ///
    /// They answer the same gesture, and while each read the preference for itself one of them went
    /// on offering the defaults after the reader had chosen their own. They read one function now,
    /// and this drives it through a real workspace with a real store behind it.
    @MainActor
    @Test func everyQuickReactionSurfaceOffersTheConfiguredEmojis() async {
        let runtime = FakeMarmotRuntime(accounts: [desktopAccount()])
        let state = WorkspaceState(clientFactory: { runtime })
        await state.bootstrap()

        #expect(MessageQuickReactionSurface.emojis(in: state) == state.quickReactions)

        let configured = ["🐟", "🧀", "🫒", "🍋", "🥖", "🍇"]
        #expect(configured != ChatReactionDefaults.quick, "the fixture must differ from the defaults")
        state.quickReactions = configured

        #expect(
            MessageQuickReactionSurface.emojis(in: state) == configured,
            "a quick-reaction surface is still offering the built-in defaults"
        )
    }

    @Test func reactionChipRidesOnlyASurfaceWithAnEdge() {
        // A caption bubble and a bare media card both give the pill an edge to ride on.
        #expect(
            MessageReactionChipPlacement.value(usesSurface: true, usesStickerStyle: false)
                == .ridingSurfaceEdge
        )
        // A sticker is drawn with no surface behind it, so the pill sits below it.
        #expect(
            MessageReactionChipPlacement.value(usesSurface: true, usesStickerStyle: true) == .ownRow
        )
        // Nothing above the pill but a timestamp: the case that drew reactions over the time on an
        // image with no caption.
        #expect(
            MessageReactionChipPlacement.value(usesSurface: false, usesStickerStyle: false) == .ownRow
        )
    }

    @Test func reactionChipOverlapCancelsTheStackSpacingBeforeBiting() {
        // The pill's negative top padding has to eat the stack's own spacing first, or the overlap
        // it actually achieves is short by that spacing.
        #expect(
            MessageReactionChipPlacement.ridingSurfaceEdge.topPadding(contentSpacing: 6, overlap: 7)
                == -13
        )
        #expect(MessageReactionChipPlacement.ownRow.topPadding(contentSpacing: 6, overlap: 7) == 0)
        // The shipped overlap is the chip's own metric, not a number restated at the call site.
        #expect(
            MessageReactionChipPlacement.ridingSurfaceEdge.topPadding(contentSpacing: 6)
                == -(6 + MessageReactionChips.bubbleOverlap)
        )
    }

    @Test func reactionChipsDrawOnePillPerEmojiRatherThanOneMergedCluster() {
        // The tally arrives already grouped by emoji, and each group is its own pill: a row that
        // merges them (👍❤️😂 over a total of 4) says four people reacted without saying that two
        // of them agreed, which is the only thing the row is read for.
        let tally = [
            MessageReaction(emoji: "👍", count: 2, isOwn: true, senders: ["a", "b"]),
            MessageReaction(emoji: "❤️", count: 1, isOwn: false, senders: ["c"]),
            MessageReaction(emoji: "😂", count: 1, isOwn: false, senders: ["d"]),
        ]

        let row = MessageReactionChipRow.value(reactions: tally)

        #expect(row.visible.map(\.emoji) == ["👍", "❤️", "😂"])
        #expect(row.visible.map(\.count) == [2, 1, 1])
        // Own-ness is per pill, not per cluster: only the emoji you actually sent is selected.
        #expect(row.visible.map(\.isOwn) == [true, false, false])
        #expect(row.hiddenGroupCount == 0)
    }

    @Test func reactionChipsFoldEmojisPastTheCapIntoAnOverflowPill() {
        let tally = (0..<7).map { index in
            MessageReaction(emoji: "e\(index)", count: index + 1, isOwn: false, senders: ["a"])
        }

        let row = MessageReactionChipRow.value(reactions: tally)

        // The core's order is kept as given — `byEmoji` is deterministic, and a pill that sorted
        // itself by count would move under the pointer when someone else reacted.
        #expect(row.visible.map(\.emoji) == ["e0", "e1", "e2", "e3"])
        #expect(row.visible.count == MessageReactionChipRow.maxVisibleGroups)
        #expect(row.hiddenGroupCount == 3)

        // Exactly at the cap there is no overflow pill.
        #expect(MessageReactionChipRow.value(reactions: Array(tally.prefix(4))).hiddenGroupCount == 0)
        #expect(MessageReactionChipRow.value(reactions: []).visible.isEmpty)
    }

    @Test func reactionChipCountClampsSoOnePillCannotWidenTheRowWithoutBound() {
        #expect(MessageReactionChipRow.countLabel(for: 2) == "2")
        #expect(MessageReactionChipRow.countLabel(for: 99) == "99")
        #expect(MessageReactionChipRow.countLabel(for: 100) == "99+")
    }

    /// On a caption-less media row the pill rides the media card's bottom edge, not the timestamp.
    ///
    /// The chips are drawn with a negative top padding, so they ride up onto **whatever the row
    /// emitted immediately before them** — and a caption-less row's metadata is a bare 10pt line
    /// rather than a surface with an edge to spare. Emitted before the chips, it was what the pill
    /// overlapped, and the reactions sat on top of the time.
    @MainActor
    @Test func onACaptionLessMediaRowTheReactionPillsNeighbourIsTheMediaNotTheTimestamp() throws {
        let mediaOnly = MessageItem(
            id: "media-only",
            groupIdHex: "group",
            sourceMessageIdHex: "media-only-source",
            senderName: "Alice",
            body: "",
            sentAt: Date(timeIntervalSince1970: 1_800_000_000),
            isOutgoing: false,
            reactions: [MessageReaction(emoji: "👍", count: 1, isOwn: false, senders: ["a"])],
            mediaAttachments: [
                MessageMediaAttachment(
                    id: "media-only#0",
                    reference: mediaAttachmentReference(
                        sourceEpoch: 3,
                        mediaType: "image/png",
                        fileName: "photo.png",
                        plaintextSha256: hexSHA256(Data([0x01, 0x02]))
                    )
                )
            ]
        )

        #expect(!mediaOnly.hasBubbleContent, "the fixture is not the caption-less case this guards")

        let elements = MessageBubbleLayout.elements(for: mediaOnly, showsDebugMetadata: false)
        let chips = try #require(elements.firstIndex(of: .reactionChips))
        let metadata = try #require(elements.firstIndex(of: .standaloneMetadata))
        #expect(chips < metadata, "the pill would be pulled up over the timestamp")
        #expect(
            elements[chips - 1] == .visualMediaGrid,
            "the pill rides up onto \(elements[chips - 1]) rather than onto the media card"
        )

        // A captioned row keeps the bubble as the pill's neighbour and grows no standalone line.
        let captioned = MessageItem(
            id: "captioned",
            groupIdHex: "group",
            sourceMessageIdHex: "captioned-source",
            senderName: "Alice",
            body: "on the roof",
            sentAt: Date(timeIntervalSince1970: 1_800_000_000),
            isOutgoing: false,
            reactions: mediaOnly.reactions,
            mediaAttachments: mediaOnly.mediaAttachments
        )
        let captionedElements = MessageBubbleLayout.elements(for: captioned, showsDebugMetadata: false)
        let captionedChips = try #require(captionedElements.firstIndex(of: .reactionChips))
        #expect(captionedElements[captionedChips - 1] == .bubbleContent)
        #expect(!captionedElements.contains(.standaloneMetadata))

        // And the overlap itself is the placement helper's decision, not an inline ternary: a media
        // row has a surface to ride even with no caption on it.
        #expect(
            MessageReactionChipPlacement.value(usesSurface: true, usesStickerStyle: false)
                == .ridingSurfaceEdge
        )
    }

    @MainActor
    @Test func messageDisplayMetadataShowsTimeAndOnlyOutgoingStatus() async throws {
        let outgoing = MessageItem(
            id: "outgoing",
            sourceMessageIdHex: "outgoing-source",
            senderName: "Jeff",
            body: "On my way",
            sentAt: Date(timeIntervalSince1970: 1_800_000_000),
            isOutgoing: true
        )
        let incoming = MessageItem(
            id: "incoming",
            senderName: "NVK",
            body: "Synced here",
            sentAt: Date(timeIntervalSince1970: 1_800_000_060),
            isOutgoing: false
        )

        #expect(!outgoing.timeLabel.isEmpty)
        #expect(outgoing.statusLabel == "Sent")
        #expect(incoming.statusLabel == nil)
    }

    @MainActor
    @Test func undeliveredOutgoingMessageOffersRetry() async throws {
        let pending = MessageItem(
            id: "pending",
            groupIdHex: "group",
            sourceMessageIdHex: nil,
            senderName: "Jeff",
            body: "Offline message",
            sentAt: Date(timeIntervalSince1970: 1_800_000_000),
            isOutgoing: true
        )
        let delivered = MessageItem(
            id: "delivered",
            groupIdHex: "group",
            sourceMessageIdHex: "source-event",
            senderName: "Jeff",
            body: "Online message",
            sentAt: Date(timeIntervalSince1970: 1_800_000_001),
            isOutgoing: true
        )

        let sentAt = Date(timeIntervalSince1970: 1_800_000_000)
        let failed = sentAt.addingTimeInterval(MessageItem.pendingDeliveryGrace + 1)

        #expect(pending.isPendingDelivery)
        #expect(pending.canRetryDelivery(at: failed))
        #expect(pending.statusLabel == "Not delivered")
        #expect(!delivered.isPendingDelivery)
        #expect(!delivered.canRetryDelivery(at: failed))
        #expect(delivered.statusLabel == "Sent")

        // Retry is withheld while the bubble still reads "Sending": offering it there asks the
        // user to re-drive a first attempt the app has just told them is still going out.
        #expect(pending.deliveryIndicator(at: sentAt.addingTimeInterval(1)) == .sending)
        #expect(!pending.canRetryDelivery(at: sentAt.addingTimeInterval(1)))
    }

    @MainActor
    @Test func inFlightSendReadsAsSendingBeforeItReadsAsFailed() async throws {
        let sentAt = Date(timeIntervalSince1970: 1_800_000_000)
        let pending = MessageItem(
            id: "pending",
            groupIdHex: "group",
            sourceMessageIdHex: nil,
            senderName: "Jeff",
            body: "Photo",
            sentAt: sentAt,
            isOutgoing: true
        )

        // The publish round-trip is the whole point: a send that has only just left must not be
        // painted as a failure.
        #expect(pending.deliveryIndicator(at: sentAt) == .sending)
        #expect(pending.statusLabel(for: pending.deliveryIndicator(at: sentAt)) == "Sending")
        #expect(
            pending.deliveryIndicator(at: sentAt.addingTimeInterval(MessageItem.pendingDeliveryGrace - 1))
                == .sending)

        // Once the window closes the bubble escalates, keeping the retry affordance meaningful.
        let afterGrace = sentAt.addingTimeInterval(MessageItem.pendingDeliveryGrace + 1)
        #expect(pending.deliveryIndicator(at: afterGrace) == .failed)
        #expect(pending.statusLabel(for: pending.deliveryIndicator(at: afterGrace)) == "Not delivered")
        #expect(pending.metadataLabel(at: afterGrace).contains("Not delivered"))
    }

    @MainActor
    @Test func deliveryIndicatorDistinguishesDeliveredIncomingAndInvalidatedRows() async throws {
        let sentAt = Date(timeIntervalSince1970: 1_800_000_000)
        let delivered = MessageItem(
            id: "delivered",
            sourceMessageIdHex: "source-event",
            senderName: "Jeff",
            body: "Online message",
            sentAt: sentAt,
            isOutgoing: true
        )
        let incoming = MessageItem(
            id: "incoming",
            sourceMessageIdHex: "source-event",
            senderName: "NVK",
            body: "Hello",
            sentAt: sentAt,
            isOutgoing: false
        )
        let invalidated = MessageItem(
            id: "invalidated",
            sourceMessageIdHex: nil,
            senderName: "Jeff",
            body: "Lost the branch",
            sentAt: sentAt,
            invalidationStatus: "forked",
            isOutgoing: true
        )

        #expect(delivered.deliveryIndicator(at: sentAt) == .delivered)
        #expect(incoming.deliveryIndicator(at: sentAt) == .none)
        // Convergence already decided this one lost, so it fails on sight rather than waiting.
        #expect(invalidated.deliveryIndicator(at: sentAt) == .failed)
        #expect(invalidated.statusLabel(for: .failed) == "Did not reach group")
    }

    @MainActor
    @Test func pendingDeliveryGraceCountsFromSendTimeNotFromDisplay() async throws {
        let sentAt = Date(timeIntervalSince1970: 1_800_000_000)
        let pending = MessageItem(
            id: "pending",
            sourceMessageIdHex: nil,
            senderName: "Jeff",
            body: "Offline message",
            sentAt: sentAt,
            isOutgoing: true
        )
        let delivered = MessageItem(
            id: "delivered",
            sourceMessageIdHex: "source-event",
            senderName: "Jeff",
            body: "Online message",
            sentAt: sentAt,
            isOutgoing: true
        )

        let remaining = try #require(pending.pendingDeliveryGraceRemaining(at: sentAt))
        #expect(remaining == MessageItem.pendingDeliveryGrace)
        // A second-granular `sentAt` can round ahead of the wall clock; the wait never exceeds
        // the window.
        let skewed = try #require(pending.pendingDeliveryGraceRemaining(at: sentAt.addingTimeInterval(-5)))
        #expect(skewed == MessageItem.pendingDeliveryGrace)
        // A message left pending across a relaunch has already had its grace.
        #expect(pending.pendingDeliveryGraceRemaining(at: sentAt.addingTimeInterval(3_600)) == nil)
        #expect(delivered.pendingDeliveryGraceRemaining(at: sentAt) == nil)
    }

    @MainActor
    @Test func deliverySignatureIgnoresChangesThatCannotMoveDelivery() async throws {
        let sentAt = Date(timeIntervalSince1970: 1_800_000_000)
        let pending = MessageItem(
            id: "pending",
            sourceMessageIdHex: nil,
            senderName: "Jeff",
            body: "Photo",
            sentAt: sentAt,
            isOutgoing: true
        )
        let reacted = MessageItem(
            id: "pending",
            sourceMessageIdHex: nil,
            senderName: "Jeff",
            body: "Photo",
            sentAt: sentAt,
            isOutgoing: true,
            reactions: [MessageReaction(emoji: "🔥", count: 1, isOwn: true)]
        )
        let confirmed = MessageItem(
            id: "pending",
            sourceMessageIdHex: "source-event",
            senderName: "Jeff",
            body: "Photo",
            sentAt: sentAt,
            isOutgoing: true
        )

        // A reaction landing mid-flight must not restart the grace window.
        #expect(pending.deliverySignature == reacted.deliverySignature)
        #expect(pending.deliverySignature != confirmed.deliverySignature)
    }

    @MainActor
    @Test func messageMetadataCanShareTheFinalLineOfSimpleText() async throws {
        let sentAt = Date(timeIntervalSince1970: 1_800_000_000)
        let plain = MessageItem(
            id: "plain-inline",
            senderName: "Alice",
            body: "Short",
            sentAt: sentAt,
            isOutgoing: true
        )
        let paragraph = MessageItem(
            id: "paragraph-inline",
            senderName: "Alice",
            body: "Styled",
            contentMarkdown: MarkdownDocumentFfi(
                blocks: [.paragraph(inlines: [.strong(children: [.text(content: "Styled")])])],
                truncated: false
            ),
            sentAt: sentAt,
            isOutgoing: true
        )
        let structured = MessageItem(
            id: "structured-blocks",
            senderName: "Alice",
            body: "Heading\nBody",
            contentMarkdown: MarkdownDocumentFfi(
                blocks: [
                    .heading(level: 2, inlines: [.text(content: "Heading")]),
                    .paragraph(inlines: [.text(content: "Body")]),
                ],
                truncated: false
            ),
            sentAt: sentAt,
            isOutgoing: true
        )

        #expect(plain.supportsInlineMetadata)
        #expect(paragraph.supportsInlineMetadata)
        #expect(!structured.supportsInlineMetadata)
    }

    /// A mention is colored by the palette, not by which bubble it lands in — that is the property
    /// that let the fill-dependent chip go away. The row's attributed string is built once here,
    /// off-main and never rewritten during a body pass, so this also pins that a sent and a
    /// received copy of the same mention come out identical.
    @Test func mentionTakesTheMentionColorRegardlessOfBubbleDirection() {
        let npub = "npub1qqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqq0l5v8"
        let tokens = MarkdownDocumentFfi(
            blocks: [
                .paragraph(inlines: [
                    .nostrMention(entity: MarkdownNostrEntityFfi(hrp: .npub, bech32: npub))
                ])
            ],
            truncated: false
        )
        func mentionRun(isOutgoing: Bool) -> AttributedString.Runs.Element? {
            MessageItem(
                id: "mention-\(isOutgoing)",
                senderName: "Alice",
                body: "@Alex",
                contentMarkdown: tokens,
                mentionNames: [npub: "Alex"],
                sentAt: Date(timeIntervalSince1970: 1_700_000_000),
                isOutgoing: isOutgoing
            )
            .contentMarkdown?.inlineParagraph?.runs.first
        }

        for isOutgoing in [true, false] {
            let run = mentionRun(isOutgoing: isOutgoing)
            #expect(run?.foregroundColor == MentionTextPalette.foreground)
            #expect(run?.inlinePresentationIntent?.contains(.stronglyEmphasized) == true)
            // No background chip in either direction; the chip is what used to have to know the
            // fill, and reintroducing one is the regression this guards.
            #expect(run?.backgroundColor == nil)
        }
    }

    @Test func singleEmojiMessagesAreClassifiedForStickerPresentation() {
        let singleEmoji = [
            "😀",
            "  👍🏽\n",
            "🇮🇹",
            "1️⃣",
            "👨‍👩‍👧‍👦",
            "❤️",
        ]
        for candidate in singleEmoji {
            #expect(EmojiPresentation.singleEmoji(in: candidate) != nil)
        }

        let regularText = [
            "",
            "1",
            "A",
            "©",
            "😀😀",
            "Hello 😀",
        ]
        for candidate in regularText {
            #expect(EmojiPresentation.singleEmoji(in: candidate) == nil)
        }

        let message = MessageItem(
            id: "emoji",
            senderName: "Alice",
            body: "  👋🏽  ",
            sentAt: Date(timeIntervalSince1970: 1_800_000_000),
            isOutgoing: false
        )
        #expect(message.singleEmoji == "👋🏽")
    }

    @MainActor
    @Test func messageItemEqualityAndHashingIgnoreDerivedMarkdownAST() async throws {
        let sentAt = Date(timeIntervalSince1970: 1_700_000_000)
        let plain = MessageItem(
            id: "m1",
            senderName: "Alice",
            body: "Hello",
            contentMarkdown: nil,
            sentAt: sentAt,
            isOutgoing: false
        )
        let withMarkdown = MessageItem(
            id: "m1",
            senderName: "Alice",
            body: "Hello",
            contentMarkdown: MarkdownDocumentFfi(
                blocks: [.paragraph(inlines: [.text(content: "Hello")])],
                truncated: false
            ),
            sentAt: sentAt,
            isOutgoing: false
        )
        // `contentMarkdown` is a deterministic projection of the content-bearing fields,
        // so it is intentionally excluded from equality/hashing to keep timeline diffing
        // off the recursive AST. Items agreeing on those fields are equal regardless.
        #expect(plain == withMarkdown)
        #expect(plain.hashValue == withMarkdown.hashValue)

        let differentBody = MessageItem(
            id: "m1",
            senderName: "Alice",
            body: "Goodbye",
            sentAt: sentAt,
            isOutgoing: false
        )
        #expect(plain != differentBody)

        let differentSender = MessageItem(
            id: "m1",
            senderName: "Bob",
            body: "Hello",
            sentAt: sentAt,
            isOutgoing: false
        )
        #expect(plain != differentSender)
    }

    @MainActor
    @Test func markdownPlainTextFastPathKeepsEscapedAndPlaceholderContentCorrect() async throws {
        let plainTokens = MarkdownDocumentFfi(
            blocks: [.paragraph(inlines: [.text(content: "Hello")])],
            truncated: false
        )
        let escapedTokens = MarkdownDocumentFfi(
            blocks: [.paragraph(inlines: [.text(content: "*")])],
            truncated: false
        )
        let richTokens = MarkdownDocumentFfi(
            blocks: [.paragraph(inlines: [.strong(children: [.text(content: "Failed")])])],
            truncated: false
        )
        let page = TimelinePageFfi(
            messages: [
                timelineMessage(
                    id: "plain",
                    groupIdHex: "group",
                    sender: "alice",
                    plaintext: "Hello",
                    recordedAt: 1_800_000_000,
                    contentTokens: plainTokens
                ),
                timelineMessage(
                    id: "escaped",
                    groupIdHex: "group",
                    sender: "alice",
                    plaintext: "\\*",
                    recordedAt: 1_800_000_001,
                    contentTokens: escapedTokens
                ),
                timelineMessage(
                    id: "failed",
                    groupIdHex: "group",
                    sender: "alice",
                    plaintext: "**Failed**",
                    recordedAt: 1_800_000_002,
                    contentTokens: richTokens,
                    invalidationStatus: "signature-check-failed"
                ),
            ],
            hasMoreBefore: false,
            hasMoreAfter: false
        )

        let messages = MessageItem.timeline(from: page, activeAccountIdHex: "self")

        #expect(messages[0].body == "Hello")
        #expect(messages[0].contentMarkdown == nil)
        #expect(messages[1].body == "\\*")
        #expect(messages[1].contentMarkdown != nil)
        // An invalidated row keeps its own text and its own formatting — the failure is carried
        // by the delivery footer, not by replacing the body.
        #expect(messages[2].body == "**Failed**")
        #expect(messages[2].contentMarkdown != nil)
    }

    /// whitenoise-mac: a message that lost convergence used to be replaced by a
    /// "Message did not reach the group" tombstone, throwing away the one thing the reader
    /// needs — what it was that failed to send. It now renders like the iOS client: the real
    /// content, marked failed by the footer's error glyph.
    @MainActor
    @Test func invalidatedMessagesKeepTheirContentAndFailInTheFooter() async throws {
        let page = TimelinePageFfi(
            messages: [
                timelineMessage(
                    id: "outgoing-invalidated",
                    groupIdHex: "group",
                    sender: "self",
                    plaintext: "Meet at seven",
                    recordedAt: 1_800_000_000,
                    invalidationStatus: "LosingBranch"
                ),
                timelineMessage(
                    id: "incoming-invalidated",
                    groupIdHex: "group",
                    sender: "alice",
                    plaintext: "Bring the keys",
                    recordedAt: 1_800_000_001,
                    invalidationStatus: "LosingBranch"
                ),
            ],
            hasMoreBefore: false,
            hasMoreAfter: false
        )

        let messages = MessageItem.timeline(from: page, activeAccountIdHex: "self")
        let sentAt = Date(timeIntervalSince1970: 1_800_000_000)

        #expect(messages.map(\.body) == ["Meet at seven", "Bring the keys"])
        // Both directions fail on sight: convergence has already decided, so neither waits out
        // the pending-delivery grace window.
        #expect(messages.allSatisfy { $0.deliveryIndicator(at: sentAt) == .failed })
        #expect(messages.allSatisfy { $0.statusLabel(for: .failed) == "Did not reach group" })
        // Convergence-lost content is still actionable: it carries the user's own words and a
        // failure marker, so it gets the same menu every other row has rather than being a bubble
        // nothing can be done about.
        #expect(messages.allSatisfy { $0.supportsChatActions })
    }

    @MainActor
    @Test func timelineStoreFoldsKind1009EditsIntoTargetChatRows() async throws {
        let originalTokens = MarkdownDocumentFfi(
            blocks: [.paragraph(inlines: [.strong(children: [.text(content: "Original")])])],
            truncated: false
        )
        let page = TimelinePageFfi(
            messages: [
                timelineMessage(
                    id: "target",
                    groupIdHex: "group",
                    sender: "alice",
                    plaintext: "**Original**",
                    recordedAt: 1_800_000_000,
                    contentTokens: originalTokens
                ),
                timelineMessage(
                    id: "edit-old",
                    groupIdHex: "group",
                    sender: "alice",
                    plaintext: "Edited once",
                    kind: 1_009,
                    tags: [MessageTagFfi(values: ["e", "target"])],
                    recordedAt: 1_800_000_030
                ),
                timelineMessage(
                    id: "edit-new",
                    groupIdHex: "group",
                    sender: "alice",
                    plaintext: "Edited twice",
                    kind: 1_009,
                    tags: [MessageTagFfi(values: ["e", "target"])],
                    recordedAt: 1_800_000_060
                ),
            ],
            hasMoreBefore: false,
            hasMoreAfter: false
        )

        let messages = MessageItem.timeline(from: page, activeAccountIdHex: "self")
        #expect(messages.count == 1)
        #expect(messages[0].body == "**Original**")
        #expect(!messages[0].isEdited)

        let editMutations = MessageEditOverlay.mutations(from: page.messages)
        #expect(editMutations.filter { if case .upsert = $0 { true } else { false } }.count == 2)

        let store = MessageTimelineStore.loaded(with: messages)
        store.replace(with: messages, editMutations: editMutations)

        #expect(store.messages.count == 1)
        let message = try #require(store.messages.first)
        #expect(message.id == "target")
        #expect(message.timelineKind == 9)
        #expect(message.body == "Edited twice")
        #expect(message.isEdited)
        #expect(message.metadataLabel.contains("Edited"))
        #expect(message.contentMarkdown == nil)
    }

    @MainActor
    @Test func messageEditAcceptsNip10RelayHintedTargetTag() async throws {
        let editRecord = timelineMessage(
            id: "edit",
            groupIdHex: "group",
            sender: "alice",
            plaintext: "Edited",
            kind: 1_009,
            tags: [MessageTagFfi(values: ["e", "target", "wss://relay.example", "reply"])],
            recordedAt: 1_800_000_030
        )

        #expect(
            MessageEditOverlay.mutations(from: [editRecord]) == [
                .upsert(
                    MessageEditOverlay(
                        targetMessageIdHex: "target",
                        editMessageIdHex: "edit",
                        sender: "alice",
                        plaintext: "Edited",
                        timelineAt: 1_800_000_030
                    ))
            ])
    }

    @MainActor
    @Test func messageEditUsesFirstValidTargetWhenAdditionalETagsArePresent() async throws {
        let editRecord = timelineMessage(
            id: "edit",
            groupIdHex: "group",
            sender: "alice",
            plaintext: "Edited",
            kind: 1_009,
            tags: [
                MessageTagFfi(values: ["e", "target"]),
                MessageTagFfi(values: ["e", "reply-target", "wss://relay.example", "reply"]),
            ],
            recordedAt: 1_800_000_030
        )

        #expect(
            MessageEditOverlay.mutations(from: [editRecord]) == [
                .upsert(
                    MessageEditOverlay(
                        targetMessageIdHex: "target",
                        editMessageIdHex: "edit",
                        sender: "alice",
                        plaintext: "Edited",
                        timelineAt: 1_800_000_030
                    ))
            ])
    }

    @MainActor
    @Test func messageEditWithoutValidTargetRetractsCandidate() async throws {
        let missingTarget = timelineMessage(
            id: "missing-target",
            groupIdHex: "group",
            sender: "alice",
            plaintext: "Edited",
            kind: 1_009,
            recordedAt: 1_800_000_030
        )
        let blankTarget = timelineMessage(
            id: "blank-target",
            groupIdHex: "group",
            sender: "alice",
            plaintext: "Edited",
            kind: 1_009,
            tags: [MessageTagFfi(values: ["e", "   ", "wss://relay.example"])],
            recordedAt: 1_800_000_031
        )

        #expect(
            MessageEditOverlay.mutations(from: [missingTarget, blankTarget]) == [
                .retract(editMessageIdHex: "missing-target"),
                .retract(editMessageIdHex: "blank-target"),
            ])
    }

    @MainActor
    @Test func timelineStoreIgnoresKind1009EditsFromDifferentAuthors() async throws {
        let page = TimelinePageFfi(
            messages: [
                timelineMessage(
                    id: "target",
                    groupIdHex: "group",
                    sender: "alice",
                    plaintext: "Original",
                    recordedAt: 1_800_000_000
                ),
                timelineMessage(
                    id: "mallory-edit",
                    groupIdHex: "group",
                    sender: "mallory",
                    plaintext: "Forged edit",
                    kind: 1_009,
                    tags: [MessageTagFfi(values: ["e", "target"])],
                    recordedAt: 1_800_000_030
                ),
            ],
            hasMoreBefore: false,
            hasMoreAfter: false
        )

        let messages = MessageItem.timeline(from: page, activeAccountIdHex: "self")
        let editMutations = MessageEditOverlay.mutations(from: page.messages)
        let store = MessageTimelineStore.loaded(with: messages)
        store.replace(with: messages, editMutations: editMutations)

        #expect(store.messages.count == 1)
        let message = try #require(store.messages.first)
        #expect(message.id == "target")
        #expect(message.body == "Original")
        #expect(!message.isEdited)
        #expect(!message.metadataLabel.contains("Edited"))
    }

    @MainActor
    @Test func messageEditRecordInvalidationAndDeletionRetractCandidates() async throws {
        func editRecord(
            id: String,
            plaintext: String,
            recordedAt: UInt64,
            deleted: Bool = false,
            invalidationStatus: String? = nil
        ) -> TimelineMessageRecordFfi {
            timelineMessage(
                id: id,
                groupIdHex: "group",
                sender: "alice",
                plaintext: plaintext,
                kind: 1_009,
                tags: [MessageTagFfi(values: ["e", "target"])],
                recordedAt: recordedAt,
                deleted: deleted,
                invalidationStatus: invalidationStatus
            )
        }

        let oldEdit = editRecord(id: "edit-old", plaintext: "Older", recordedAt: 1_800_000_030)
        let newEdit = editRecord(id: "edit-new", plaintext: "Newer", recordedAt: 1_800_000_060)
        let store = MessageTimelineStore.loaded(with: [
            MessageItem(
                id: "target",
                groupIdHex: "group",
                senderAccountIdHex: "alice",
                senderName: "alice",
                body: "Original",
                sentAt: Date(timeIntervalSince1970: 1_800_000_000),
                timelineAt: 1_800_000_000,
                isOutgoing: false
            )
        ])

        _ = store.applyProjection(
            upserts: [],
            removals: [],
            editMutations: MessageEditOverlay.mutations(from: [oldEdit, newEdit]),
            anchoredToNewest: true,
            windowLimit: 10
        )
        #expect(store.lookup["target"]?.body == "Newer")

        let invalidatedNew = editRecord(
            id: "edit-new",
            plaintext: "Newer",
            recordedAt: 1_800_000_060,
            invalidationStatus: "losing-branch"
        )
        _ = store.applyProjection(
            upserts: [],
            removals: [],
            editMutations: MessageEditOverlay.mutations(from: [invalidatedNew]),
            anchoredToNewest: true,
            windowLimit: 10
        )
        #expect(store.lookup["target"]?.body == "Older")

        let deletedOld = editRecord(
            id: "edit-old",
            plaintext: "Older",
            recordedAt: 1_800_000_030,
            deleted: true
        )
        _ = store.applyProjection(
            upserts: [],
            removals: [],
            editMutations: MessageEditOverlay.mutations(from: [deletedOld]),
            anchoredToNewest: true,
            windowLimit: 10
        )
        let restored = try #require(store.lookup["target"])
        #expect(restored.body == "Original")
        #expect(!restored.isEdited)
    }

    @MainActor
    @Test func timelineProjectionAppliesStandaloneEditOverlayToExistingTarget() async throws {
        // Regression for whitenoise-mac#419: edit-only projection deltas must patch an existing
        // materialized target instead of mapping to an empty upsert list.
        let account = AccountSummaryFfi(
            label: "Desktop Account",
            accountIdHex: "abcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890",
            localSigning: true,
            externalSigning: false,
            signedOut: false,
            running: true
        )
        let accountItem = AccountItem(summary: account)
        let runtime = FakeMarmotRuntime(accounts: [account])
        let chat = ChatItem(
            id: "group",
            title: "Test Group",
            subtitle: "Group message",
            preview: "Original",
            updatedAt: nil,
            avatarSeed: "group",
            pictureURL: nil,
            unreadCount: 0
        )
        let state = WorkspaceState(
            accounts: [accountItem],
            chatsByAccount: [accountItem.id: [chat]],
            messagesByChat: [
                "group": [
                    MessageItem(
                        id: "target",
                        groupIdHex: "group",
                        senderAccountIdHex: "alice",
                        senderName: "alice",
                        body: "Original",
                        sentAt: Date(timeIntervalSince1970: 1_800_000_000),
                        timelineAt: 1_800_000_000,
                        isOutgoing: false
                    )
                ]
            ],
            appActivityProvider: { true },
            conversationWindowVisibilityProvider: { true },
            clientFactory: { runtime }
        )
        state.activeAccountId = accountItem.id
        state.selection = .chat("group")

        await state.applyTimelineProjection(
            TimelineProjectionUpdateFfi(
                groupIdHex: "group",
                messages: [],
                changes: [
                    .upsert(
                        trigger: .messageEditedOrReprojected,
                        message: timelineMessage(
                            id: "edit-new",
                            groupIdHex: "group",
                            sender: "alice",
                            plaintext: "Edited via projection",
                            kind: 1_009,
                            tags: [MessageTagFfi(values: ["e", "target"])],
                            recordedAt: 1_800_000_060
                        ))
                ],
                chatListRow: nil,
                chatListTrigger: .newLastMessage
            ),
            groupIdHex: "group",
            account: accountItem,
            client: runtime
        )

        let message = try #require(state.ensureMessageTimelineStore(for: "group").lookup["target"])
        #expect(message.body == "Edited via projection")
        #expect(message.isEdited)
        #expect(state.ensureMessageTimelineStore(for: "group").messages.count == 1)
    }

    @MainActor
    @Test func deeplyNestedMarkdownBlocksCollapseInsteadOfRecursing() async throws {
        // Regression for whitenoise-mac#231: contentTokens is parsed from untrusted peer
        // content. A block quote nested far beyond the Swift-side depth bound must collapse
        // the over-depth remainder to empty display rather than recursing the full attacker
        // chain (which can overflow the stack).
        let document = MarkdownDocumentFfi(
            blocks: [nestedBlockQuote(depth: 256, leaf: .paragraph(inlines: [.text(content: "deep")]))],
            truncated: false
        )

        let display = MarkdownDisplayDocument(document: document)

        // The display tree stops nesting at the bound, so the deepest preserved quote holds
        // no further blocks instead of the attacker's remaining 200+ levels.
        let preservedDepth = blockQuoteNestingDepth(display.blocks)
        #expect(preservedDepth <= 32)
        #expect(preservedDepth >= 1)
        #expect(display.truncated)
    }

    @MainActor
    @Test func deeplyNestedMarkdownInlinesCollapseInsteadOfRecursing() async throws {
        // Inline emphasis/strong/strikethrough/link/image-alt recurse proportionally to
        // attacker-chosen nesting. Past the bound the inline subtree must collapse to empty
        // safe display rather than recursing the full chain.
        let document = MarkdownDocumentFfi(
            blocks: [.paragraph(inlines: [nestedStrong(depth: 256, leaf: .text(content: "deep"))])],
            truncated: false
        )

        let display = MarkdownDisplayDocument(document: document)

        guard case .paragraph(let text) = display.blocks.first?.block else {
            Issue.record("expected a paragraph block")
            return
        }
        // The leaf text sits below the bound, so it is dropped entirely rather than the
        // renderer recursing through every wrapper to reach it.
        #expect(String(text.characters).isEmpty)
        #expect(display.truncated)
    }

    @MainActor
    @Test func deeplyNestedMarkdownListItemsMarkDocumentTruncated() async throws {
        let document = MarkdownDocumentFfi(
            blocks: [
                .listBlock(
                    kind: .bullet(marker: "-"),
                    tight: true,
                    items: [
                        MarkdownListItemFfi(
                            blocks: [
                                nestedBlockQuote(
                                    depth: 256,
                                    leaf: .paragraph(inlines: [.text(content: "deep")])
                                )
                            ],
                            checked: nil
                        )
                    ]
                )
            ],
            truncated: false
        )

        let display = MarkdownDisplayDocument(document: document)

        guard case .list(let items) = display.blocks.first?.block else {
            Issue.record("expected a list block")
            return
        }
        #expect(items.count == 1)
        #expect(display.truncated)
    }

    @MainActor
    @Test func deeplyNestedMarkdownTableCellsMarkDocumentTruncated() async throws {
        let document = MarkdownDocumentFfi(
            blocks: [
                .table(
                    alignments: [.left],
                    header: [
                        MarkdownTableCellFfi(
                            inlines: [nestedStrong(depth: 256, leaf: .text(content: "deep"))]
                        )
                    ],
                    rows: []
                )
            ],
            truncated: false
        )

        let display = MarkdownDisplayDocument(document: document)

        guard case .table(let header, _) = display.blocks.first?.block else {
            Issue.record("expected a table block")
            return
        }
        let headerCell = try #require(header.first)
        #expect(String(headerCell.text.characters).isEmpty)
        #expect(display.truncated)
    }

    @MainActor
    @Test func boundedNestedMarkdownStillStylesAndLinks() async throws {
        // Normal Markdown nesting (well within the bound) must keep its styles and links:
        // the depth guard only collapses the over-depth remainder.
        let document = MarkdownDocumentFfi(
            blocks: [
                nestedBlockQuote(
                    depth: 3,
                    leaf: .paragraph(inlines: [
                        .strong(children: [
                            .link(
                                dest: "https://example.com",
                                title: nil,
                                children: [.text(content: "link text")],
                                classification: .web
                            )
                        ])
                    ])
                )
            ],
            truncated: false
        )

        let display = MarkdownDisplayDocument(document: document)

        guard let paragraph = firstParagraph(in: display.blocks) else {
            Issue.record("expected a nested paragraph block")
            return
        }
        #expect(String(paragraph.characters) == "link text")
        let run = paragraph.runs.first
        #expect(run?.inlinePresentationIntent?.contains(.stronglyEmphasized) == true)
        #expect(run?.link == URL(string: "https://example.com"))
        #expect(!display.truncated)
    }

    @MainActor
    @Test func markdownDisplayPreservesCoreTruncationFlag() async throws {
        let display = MarkdownDisplayDocument(
            document: MarkdownDocumentFfi(blocks: [], truncated: true)
        )

        #expect(display.truncated)
    }

    @MainActor
    @Test func transcriptRowStackLayoutPerformanceGuard() async throws {
        let messages = performanceMessageItems(count: 160)
        let state = WorkspaceState(clientFactory: { FakeMarmotRuntime(accounts: []) })
        let warmHost = NSHostingView(rootView: TranscriptPerformanceRows(messages: messages).environment(state))
        warmHost.frame = NSRect(x: 0, y: 0, width: 760, height: 9_000)
        let warmSize = warmHost.fittingSize
        #expect(warmSize.height > 1_000)

        var accumulatedHeight: CGFloat = 0
        let layoutMilliseconds = measuredMilliseconds {
            for _ in 0..<3 {
                let host = NSHostingView(rootView: TranscriptPerformanceRows(messages: messages).environment(state))
                host.frame = NSRect(x: 0, y: 0, width: 760, height: 9_000)
                host.invalidateIntrinsicContentSize()
                accumulatedHeight += host.fittingSize.height
            }
        }

        #expect(accumulatedHeight > 3_000)
        print("PERF transcript_row_stack_layout_ms=\(formatMilliseconds(layoutMilliseconds)) rows=\(messages.count)")
        #expect(layoutMilliseconds < 4_000 * performanceSlack)
    }

    @MainActor
    @Test func timelineStoreProjectionApplyPerformanceGuard() async throws {
        let messages = performanceMessageItems(count: 200)
        let store = MessageTimelineStore.loaded(with: messages)
        let sentAt = Date(timeIntervalSince1970: 1_800_000_000)

        let projectionMilliseconds = measuredMilliseconds {
            for index in 0..<2_000 {
                let messageIndex = index % messages.count
                let updated = MessageItem(
                    id: "perf-\(messageIndex)",
                    groupIdHex: "perf-group",
                    senderAccountIdHex: messageIndex.isMultiple(of: 2) ? "self" : "alice",
                    senderName: messageIndex.isMultiple(of: 2) ? "Jeff" : "Alice",
                    body: "Edited projection body \(index)",
                    contentMarkdown: nil,
                    sentAt: sentAt.addingTimeInterval(TimeInterval(messageIndex)),
                    timelineAt: UInt64(1_800_000_000 + messageIndex),
                    isOutgoing: messageIndex.isMultiple(of: 2)
                )
                _ = store.applyProjection(
                    upserts: [updated],
                    removals: [],
                    anchoredToNewest: true,
                    windowLimit: WorkspaceState.timelineWindowLimit
                )
            }
        }

        print("PERF timeline_projection_apply_ms=\(formatMilliseconds(projectionMilliseconds)) updates=2000")
        #expect(store.messageIDs.count == 200)
        #expect(store.messages[199].body == "Edited projection body 1999")
        #expect(projectionMilliseconds < 1_500 * performanceSlack)
    }

    @MainActor
    @Test func messageActionEligibilityTracksOwnershipAndState() async throws {
        let sentAt = Date(timeIntervalSince1970: 1_800_000_000)
        let outgoing = MessageItem(
            id: "outgoing",
            senderName: "Jeff",
            body: "Ship it",
            sentAt: sentAt,
            isOutgoing: true
        )
        let incoming = MessageItem(
            id: "incoming",
            senderName: "Alice",
            body: "Looks good",
            sentAt: sentAt,
            isOutgoing: false
        )
        let deleted = MessageItem(
            id: "deleted",
            senderName: "Jeff",
            body: "Message deleted",
            sentAt: sentAt,
            isDeleted: true,
            isOutgoing: true
        )
        let failed = MessageItem(
            id: "failed",
            senderName: "Jeff",
            body: "Lost the branch",
            sentAt: sentAt,
            invalidationStatus: "signature-check-failed",
            isOutgoing: true
        )
        let systemNotice = MessageItem(
            id: "system",
            senderName: "System",
            body: "Member added",
            sentAt: sentAt,
            isOutgoing: false,
            presentation: .groupSystem
        )
        // Regression for whitenoise-mac#361: a media-only bubble (no caption, no reply
        // context) carries no bubble content, yet must still be reactable/replyable so the
        // hover bar and context menu surface those actions.
        let incomingMediaOnly = MessageItem(
            id: "incoming-media-only",
            senderName: "Alice",
            body: "",
            sentAt: sentAt,
            isOutgoing: false,
            mediaAttachments: [
                MessageMediaAttachment(
                    id: "photo",
                    reference: mediaAttachmentReference(mediaType: "image/png", fileName: "photo.png")
                )
            ]
        )

        #expect(outgoing.supportsChatActions)
        #expect(outgoing.canCopyText)
        #expect(outgoing.canReact)
        #expect(outgoing.canReply)
        #expect(outgoing.canDelete)

        #expect(incoming.supportsChatActions)
        #expect(incoming.canCopyText)
        #expect(incoming.canReact)
        #expect(incoming.canReply)
        #expect(!incoming.canDelete)

        #expect(!incomingMediaOnly.hasBubbleContent)
        #expect(incomingMediaOnly.supportsChatActions)
        #expect(!incomingMediaOnly.canCopyText)
        #expect(incomingMediaOnly.canReact)
        #expect(incomingMediaOnly.canReply)
        #expect(!incomingMediaOnly.canDelete)

        #expect(!deleted.supportsChatActions)
        #expect(!deleted.canCopyText)
        #expect(!deleted.canReact)
        #expect(!deleted.canReply)
        #expect(!deleted.canDelete)

        // An invalidated row keeps every action a live one has. It is drawn with its own content
        // and its own failure marker, so to the reader it is a failed message like any other, and
        // a failed message the app refuses to act on is a bubble the user is stuck with.
        #expect(failed.supportsChatActions)
        #expect(failed.canCopyText)
        #expect(failed.canReact)
        #expect(failed.canReply)
        #expect(failed.canDelete)
        // Including the one a failure actually asks for.
        #expect(failed.canRetryDelivery(at: sentAt))

        #expect(!systemNotice.supportsChatActions)
        #expect(systemNotice.canCopyText)
        #expect(!systemNotice.canReact)
        #expect(!systemNotice.canReply)
        #expect(!systemNotice.canDelete)
    }

    @MainActor
    @Test func timelineMappingClassifiesAgentAndGroupSystemRows() async throws {
        let page = TimelinePageFfi(
            messages: [
                timelineMessage(
                    id: "stream-start",
                    groupIdHex: "group",
                    sender: "agent",
                    plaintext: "",
                    kind: 1200,
                    tags: [
                        MessageTagFfi(values: ["stream", "abc"]),
                        MessageTagFfi(values: ["route", "quic"]),
                    ],
                    recordedAt: 1_700_000_000
                ),
                timelineMessage(
                    id: "activity",
                    groupIdHex: "group",
                    sender: "agent",
                    plaintext: #"{"v":1,"status":"thinking","text":"Thinking"}"#,
                    kind: 1201,
                    recordedAt: 1_700_000_001
                ),
                timelineMessage(
                    id: "operation",
                    groupIdHex: "group",
                    sender: "agent",
                    plaintext:
                        #"{"v":1,"event_type":"tool_call","status":"started","name":"search","preview":"glp-1"}"#,
                    kind: 1202,
                    recordedAt: 1_700_000_002
                ),
                timelineMessage(
                    id: "system",
                    groupIdHex: "group",
                    sender: "",
                    plaintext: #"{"v":1,"system_type":"group_renamed","text":"Group renamed"}"#,
                    kind: 1210,
                    recordedAt: 1_700_000_003
                ),
            ],
            hasMoreBefore: false,
            hasMoreAfter: false
        )

        let messages = MessageItem.timeline(
            from: page,
            activeAccountIdHex: "self"
        )

        #expect(
            messages.map(\.presentation) == [
                .agentStreamStart,
                .agentActivity,
                .agentOperation,
                .groupSystem,
            ])
        #expect(
            messages.map(\.body) == [
                "Agent started a live response",
                "Thinking",
                "glp-1",
                "Group renamed",
            ])
        #expect(messages.allSatisfy { !$0.supportsChatActions })
        #expect(messages.allSatisfy { $0.statusLabel == nil })
    }

    @MainActor
    @Test func timelineMappingRendersSystemEventsFromStructuredFields() async throws {
        let alice = String(repeating: "a", count: 64)
        let bob = String(repeating: "b", count: 64)
        let carol = String(repeating: "c", count: 64)
        let profiles = [
            alice: ChatPeerProfile(accountIdHex: alice, displayName: "Alice", pictureURL: nil),
            bob: ChatPeerProfile(accountIdHex: bob, displayName: "Bob", pictureURL: nil),
            carol: ChatPeerProfile(accountIdHex: carol, displayName: "Carol", pictureURL: nil),
        ]

        func systemMessage(
            _ id: String,
            systemType: String,
            text: String,
            actor: String? = nil,
            subject: String? = nil,
            name: String? = nil,
            oldName: String? = nil,
            oldRetentionSeconds: UInt64? = nil,
            newRetentionSeconds: UInt64? = nil,
            recordedAt: UInt64
        ) -> TimelineMessageRecordFfi {
            timelineMessage(
                id: id,
                groupIdHex: "group",
                sender: "",
                plaintext: "",
                kind: 1210,
                recordedAt: recordedAt,
                groupSystem: groupSystemEvent(
                    systemType: systemType,
                    text: text,
                    actorAccountIdHex: actor,
                    subjectAccountIdHex: subject,
                    name: name,
                    oldName: oldName,
                    oldRetentionSeconds: oldRetentionSeconds,
                    newRetentionSeconds: newRetentionSeconds
                )
            )
        }

        let page = TimelinePageFfi(
            messages: [
                systemMessage(
                    "member-added",
                    systemType: "member_added",
                    text: "Member added",
                    actor: alice,
                    subject: bob,
                    recordedAt: 1_700_000_000
                ),
                systemMessage(
                    "member-removed",
                    systemType: "member_removed",
                    text: "Member removed",
                    actor: alice,
                    subject: bob,
                    recordedAt: 1_700_000_001
                ),
                systemMessage(
                    "member-left",
                    systemType: "member_left",
                    text: "Member left",
                    subject: carol,
                    recordedAt: 1_700_000_002
                ),
                systemMessage(
                    "admin-added",
                    systemType: "admin_added",
                    text: "Admin added",
                    actor: alice,
                    subject: bob,
                    recordedAt: 1_700_000_003
                ),
                systemMessage(
                    "admin-added-self-without-actor",
                    systemType: "admin_added",
                    text: "Admin added",
                    subject: bob,
                    recordedAt: 1_700_000_004
                ),
                systemMessage(
                    "admin-removed",
                    systemType: "admin_removed",
                    text: "Admin removed",
                    actor: bob,
                    subject: carol,
                    recordedAt: 1_700_000_005
                ),
                systemMessage(
                    "group-renamed",
                    systemType: "group_renamed",
                    text: "Group renamed",
                    actor: alice,
                    name: "Team Two",
                    oldName: "Team One",
                    recordedAt: 1_700_000_006
                ),
                systemMessage(
                    "group-avatar-changed",
                    systemType: "group_avatar_changed",
                    text: "Group avatar changed",
                    actor: bob,
                    recordedAt: 1_700_000_007
                ),
                systemMessage(
                    "disappearing-timer-changed",
                    systemType: "disappearing_timer_changed",
                    text: "Disappearing timer changed",
                    actor: alice,
                    oldRetentionSeconds: 0,
                    newRetentionSeconds: 604_800,
                    recordedAt: 1_700_000_008
                ),
            ],
            hasMoreBefore: false,
            hasMoreAfter: false
        )

        let remoteMessages = MessageItem.timeline(
            from: page,
            activeAccountIdHex: "self",
            senderProfiles: profiles
        )
        let aliceLocalMessages = MessageItem.timeline(
            from: page,
            activeAccountIdHex: alice,
            senderProfiles: profiles
        )
        let bobLocalMessages = MessageItem.timeline(
            from: page,
            activeAccountIdHex: bob,
            senderProfiles: profiles
        )
        let remoteRenameBody =
            #"\#(isolated("Alice")) renamed the group from "\#(isolated("Team One"))" "#
            + #"to "\#(isolated("Team Two"))""#
        let aliceRenameBody =
            #"You renamed the group from "\#(isolated("Team One"))" "#
            + #"to "\#(isolated("Team Two"))""#

        #expect(
            remoteMessages.map(\.body) == [
                "\(isolated("Alice")) added \(isolated("Bob"))",
                "\(isolated("Alice")) removed \(isolated("Bob"))",
                "\(isolated("Carol")) left",
                "\(isolated("Alice")) made \(isolated("Bob")) an admin",
                "\(isolated("Bob")) was made an admin",
                "\(isolated("Bob")) removed \(isolated("Carol")) as admin",
                remoteRenameBody,
                "\(isolated("Bob")) changed the group avatar",
                "\(isolated("Alice")) changed disappearing messages from off to 1 week",
            ])
        #expect(aliceLocalMessages[0].body == "You added \(isolated("Bob"))")
        #expect(aliceLocalMessages[3].body == "You made \(isolated("Bob")) an admin")
        #expect(aliceLocalMessages[4].body == "\(isolated("Bob")) was made an admin")
        #expect(aliceLocalMessages[6].body == aliceRenameBody)
        #expect(aliceLocalMessages[8].body == "You changed disappearing messages from off to 1 week")
        #expect(bobLocalMessages[0].body == "\(isolated("Alice")) added you")
        #expect(bobLocalMessages[1].body == "You were removed from the group by \(isolated("Alice"))")
        #expect(bobLocalMessages[3].body == "\(isolated("Alice")) made you an admin")
        #expect(bobLocalMessages[4].body == "You were made an admin")
        #expect(bobLocalMessages[5].body == "You removed \(isolated("Carol")) as admin")
        #expect(bobLocalMessages[7].body == "You changed the group avatar")
    }

    @MainActor
    @Test func timelineMappingKeepsVerbAgreementForActorlessSelfSystemEvents() async throws {
        let bob = String(repeating: "b", count: 64)
        let profiles = [bob: ChatPeerProfile(accountIdHex: bob, displayName: "Bob", pictureURL: nil)]

        func selfEvent(_ id: String, systemType: String, text: String, recordedAt: UInt64)
            -> TimelineMessageRecordFfi
        {
            timelineMessage(
                id: id,
                groupIdHex: "group",
                sender: "",
                plaintext: "",
                kind: 1210,
                recordedAt: recordedAt,
                groupSystem: groupSystemEvent(
                    systemType: systemType,
                    text: text,
                    actorAccountIdHex: nil,
                    subjectAccountIdHex: bob
                )
            )
        }

        let page = TimelinePageFfi(
            messages: [
                selfEvent("added", systemType: "member_added", text: "Member added", recordedAt: 1),
                selfEvent(
                    "removed",
                    systemType: "member_removed",
                    text: "Member removed",
                    recordedAt: 2
                ),
                selfEvent(
                    "demoted",
                    systemType: "admin_removed",
                    text: "Admin removed",
                    recordedAt: 3
                ),
            ],
            hasMoreBefore: false,
            hasMoreAfter: false
        )

        // Without an actor the subject is the sentence subject, so "You" must take a
        // second-person verb: "You was removed" is what these events used to read.
        let localMessages = MessageItem.timeline(
            from: page,
            activeAccountIdHex: bob,
            senderProfiles: profiles
        )
        #expect(
            localMessages.map(\.body) == [
                "You were added",
                "You were removed",
                "You are no longer an admin",
            ])

        let remoteMessages = MessageItem.timeline(
            from: page,
            activeAccountIdHex: String(repeating: "a", count: 64),
            senderProfiles: profiles
        )
        #expect(
            remoteMessages.map(\.body) == [
                "\(isolated("Bob")) was added",
                "\(isolated("Bob")) was removed",
                "\(isolated("Bob")) is no longer an admin",
            ])
    }

    @MainActor
    @Test func timelineMappingPreservesRuntimeWindowOrder() async throws {
        // Regression for #7: the runtime page already carries the authoritative
        // timeline order, including any hidden same-second tie-break from storage.
        // The client mapper must not re-sort the page by second-granular
        // `timelineAt`, or subscription refreshes can reshuffle colliding rows.
        let page = TimelinePageFfi(
            messages: [
                timelineMessage(
                    id: "runtime-third",
                    groupIdHex: "group",
                    sender: "alice",
                    plaintext: "storage order 3",
                    recordedAt: 1_700_000_001
                ),
                timelineMessage(
                    id: "runtime-first",
                    groupIdHex: "group",
                    sender: "alice",
                    plaintext: "storage order 1",
                    recordedAt: 1_700_000_000
                ),
                timelineMessage(
                    id: "runtime-second",
                    groupIdHex: "group",
                    sender: "alice",
                    plaintext: "storage order 2",
                    recordedAt: 1_700_000_000
                ),
            ],
            hasMoreBefore: false,
            hasMoreAfter: false
        )

        let messages = MessageItem.timeline(
            from: page,
            activeAccountIdHex: "self"
        )

        #expect(
            messages.map(\.id) == [
                "runtime-third",
                "runtime-first",
                "runtime-second",
            ])
    }

    @MainActor
    @Test func loadingMessagesAttachesReactionsToTheirTargetMessage() async throws {
        let account = AccountSummaryFfi(
            label: "Desktop Account",
            accountIdHex: "abcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890",
            localSigning: true,
            externalSigning: false,
            signedOut: false,
            running: true
        )
        let runtime = FakeMarmotRuntime(accounts: [account])
        runtime.installGroup(messageGroup())
        runtime.installMessages(
            [
                appMessage(
                    id: "parent",
                    groupIdHex: "group",
                    sender: "alice1234567890alice1234567890alice1234567890alice1234567890",
                    plaintext: "The launch plan is ready.",
                    kind: 9,
                    recordedAt: 1_700_000_000
                ),
                appMessage(
                    id: "reaction",
                    direction: "outbound",
                    groupIdHex: "group",
                    sender: account.accountIdHex,
                    plaintext: "👍",
                    kind: 7,
                    tags: [MessageTagFfi(values: ["e", "parent"])],
                    recordedAt: 1_700_000_001
                ),
            ], groupIdHex: "group")
        let state = WorkspaceState(clientFactory: { runtime })

        await state.bootstrap()
        await state.loadMessages(groupIdHex: "group")

        #expect(state.messagesByChat["group"]?.count == 1)
        #expect(state.messagesByChat["group"]?.first?.body == "The launch plan is ready.")
        #expect(
            state.messagesByChat["group"]?.first?.reactions == [
                MessageReaction(
                    emoji: "👍",
                    count: 1,
                    isOwn: true,
                    ownReactionMessageId: "reaction",
                    senders: ["abcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890"]
                )
            ])
    }

    @MainActor
    @Test func loadingMessagesOmitsDeletedReactions() async throws {
        let account = AccountSummaryFfi(
            label: "Desktop Account",
            accountIdHex: "abcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890",
            localSigning: true,
            externalSigning: false,
            signedOut: false,
            running: true
        )
        let runtime = FakeMarmotRuntime(accounts: [account])
        let aliceId = "alice1234567890alice1234567890alice1234567890alice1234567890"
        runtime.installGroup(messageGroup())
        runtime.installProfile(
            accountIdHex: aliceId,
            profile: UserProfileMetadataFfi(
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
                    id: "parent",
                    groupIdHex: "group",
                    sender: aliceId,
                    plaintext: "The launch plan is ready.",
                    kind: 9,
                    recordedAt: 1_700_000_000
                ),
                appMessage(
                    id: "reaction",
                    direction: "outbound",
                    groupIdHex: "group",
                    sender: account.accountIdHex,
                    plaintext: "👍",
                    kind: 7,
                    tags: [MessageTagFfi(values: ["e", "parent"])],
                    recordedAt: 1_700_000_001
                ),
                appMessage(
                    id: "delete-reaction",
                    direction: "outbound",
                    groupIdHex: "group",
                    sender: account.accountIdHex,
                    plaintext: "",
                    kind: 5,
                    tags: [MessageTagFfi(values: ["e", "reaction"])],
                    recordedAt: 1_700_000_002
                ),
            ], groupIdHex: "group")
        let state = WorkspaceState(clientFactory: { runtime })

        await state.bootstrap()
        await state.loadMessages(groupIdHex: "group")

        #expect(state.messagesByChat["group"]?.count == 1)
        #expect(state.messagesByChat["group"]?.first?.reactions.isEmpty == true)
    }

    @MainActor
    @Test func loadingMessagesAddsReplyContextToReplyMessages() async throws {
        let account = AccountSummaryFfi(
            label: "Desktop Account",
            accountIdHex: "abcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890",
            localSigning: true,
            externalSigning: false,
            signedOut: false,
            running: true
        )
        let runtime = FakeMarmotRuntime(accounts: [account])
        let aliceId = "alice1234567890alice1234567890alice1234567890alice1234567890"
        runtime.installGroup(messageGroup())
        runtime.installProfile(
            accountIdHex: aliceId,
            profile: UserProfileMetadataFfi(
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
                    id: "parent",
                    groupIdHex: "group",
                    sender: aliceId,
                    plaintext: "The launch plan is ready.",
                    kind: 9,
                    recordedAt: 1_700_000_000
                ),
                appMessage(
                    id: "reply",
                    direction: "outbound",
                    groupIdHex: "group",
                    sender: account.accountIdHex,
                    plaintext: "Looks good to me.",
                    kind: 9,
                    tags: [
                        MessageTagFfi(values: ["e", "parent"]),
                        MessageTagFfi(values: ["q", "parent"]),
                    ],
                    recordedAt: 1_700_000_001
                ),
            ], groupIdHex: "group")
        let state = WorkspaceState(clientFactory: { runtime })

        await state.bootstrap()
        await state.loadMessages(groupIdHex: "group")

        let messages = state.messagesByChat["group"] ?? []
        #expect(messages.map(\.id) == ["parent", "reply"])
        #expect(
            messages.last?.replyContext
                == MessageReplyContext(
                    targetMessageId: "parent",
                    senderName: "Alice",
                    body: "The launch plan is ready."
                ))
    }

    @MainActor
    @Test func timelineProjectionChangesUpdateVisibleMessages() async throws {
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
        runtime.installMessages(
            [
                appMessage(
                    id: "stale",
                    groupIdHex: "direct-group",
                    sender: "alice1234567890alice1234567890alice1234567890alice1234567890",
                    plaintext: "This should disappear.",
                    kind: 9,
                    recordedAt: 1_700_000_000
                )
            ], groupIdHex: "direct-group")
        let projected = timelineMessage(
            id: "stream",
            groupIdHex: "direct-group",
            sender: account.accountIdHex,
            plaintext: "Streaming…",
            recordedAt: 1_700_000_010,
            agentTextStreamJson: #"{"stream_id":"stream"}"#
        )
        let streamingChatRow = chatListRow(
            groupIdHex: "direct-group",
            title: "Alice",
            preview: "Streaming…",
            sender: account.accountIdHex,
            timelineAt: 1_700_000_010
        )
        runtime.installTimelineUpdates(
            [
                .projection(
                    update: RuntimeProjectionUpdateFfi(
                        accountIdHex: account.accountIdHex,
                        accountLabel: account.label,
                        update: TimelineProjectionUpdateFfi(
                            groupIdHex: "direct-group",
                            messages: [],
                            changes: [
                                .remove(messageIdHex: "stale", reason: .noLongerMatchesQuery),
                                .upsert(trigger: .agentStreamStarted, message: projected),
                            ],
                            chatListRow: streamingChatRow,
                            chatListTrigger: .newLastMessage
                        )
                    ))
            ], groupIdHex: "direct-group")
        runtime.installChatListUpdates([
            .row(trigger: .newLastMessage, row: streamingChatRow)
        ])
        let state = WorkspaceState(clientFactory: { runtime })

        await state.bootstrap()
        await state.loadMessages(groupIdHex: "direct-group")
        let didApplyProjection = await waitFor {
            state.messagesByChat["direct-group"]?.map(\.id) == ["stream"]
        }

        #expect(didApplyProjection)
        #expect(state.messagesByChat["direct-group"]?.first?.body == "Streaming…")
        // The sidebar preview is driven by the chat-list subscription, not the timeline
        // window (covered by chatListUsesSubscriptionSnapshotAndTypedDeltas).
    }

    @MainActor
    @Test func selectedMessagesObservationIgnoresUnselectedChatMutations() async throws {
        // Regression for #176: observing the visible transcript must not subscribe the
        // conversation view to the whole messagesByChat dictionary. A background-chat
        // timeline delta should leave the selected transcript's observation token alone,
        // while a selected-chat replacement must still invalidate it.
        let account = AccountItem.samples[0]
        let selectedChat = ChatItem.samples[0]
        let backgroundChat = ChatItem.samples[1]
        let selectedMessage = MessageItem(
            id: "selected-1",
            groupIdHex: selectedChat.id,
            senderName: "Alice",
            body: "Visible",
            sentAt: Date(timeIntervalSince1970: 1_700_000_000),
            isOutgoing: false
        )
        let backgroundMessage = MessageItem(
            id: "background-1",
            groupIdHex: backgroundChat.id,
            senderName: "Bob",
            body: "Background",
            sentAt: Date(timeIntervalSince1970: 1_700_000_001),
            isOutgoing: false
        )
        let state = WorkspaceState(
            accounts: [account],
            chatsByAccount: [account.id: [selectedChat, backgroundChat]],
            messagesByChat: [
                selectedChat.id: [selectedMessage],
                backgroundChat.id: [backgroundMessage],
            ],
            clientFactory: { FakeMarmotRuntime(accounts: []) }
        )
        state.activeAccountId = account.id
        state.selection = .chat(selectedChat.id)

        #expect(state.selectedMessages.map(\.id) == ["selected-1"])

        let backgroundInvalidated = ObservationInvalidationFlag()
        withObservationTracking {
            _ = state.selectedMessages.map(\.id)
        } onChange: {
            backgroundInvalidated.markInvalidated()
        }

        let backgroundUpdatedMessage = MessageItem(
            id: "background-2",
            groupIdHex: backgroundChat.id,
            senderName: "Bob",
            body: "Background update",
            sentAt: Date(timeIntervalSince1970: 1_700_000_002),
            isOutgoing: false
        )
        let backgroundTimelineStore = state.ensureMessageTimelineStore(for: backgroundChat.id)
        state.cachedMessageChatIds.insert(backgroundChat.id)
        backgroundTimelineStore.replace(with: [backgroundUpdatedMessage])

        #expect(!backgroundInvalidated.value)
        #expect(backgroundTimelineStore.messages.map(\.id) == ["background-2"])
        #expect(state.selectedMessages.map(\.id) == ["selected-1"])

        let selectedInvalidated = ObservationInvalidationFlag()
        withObservationTracking {
            _ = state.selectedMessages.map(\.id)
        } onChange: {
            selectedInvalidated.markInvalidated()
        }

        state.replaceMessages(
            [
                MessageItem(
                    id: "selected-2",
                    groupIdHex: selectedChat.id,
                    senderName: "Alice",
                    body: "Visible update",
                    sentAt: Date(timeIntervalSince1970: 1_700_000_003),
                    isOutgoing: false
                )
            ],
            groupIdHex: selectedChat.id
        )

        #expect(selectedInvalidated.value)
        #expect(state.selectedMessages.map(\.id) == ["selected-2"])
    }

    @MainActor
    @Test func timelineMessageResolvesFromStoreLookup() async throws {
        // The per-chat id → message lookup lives on `MessageTimelineStore` (not a parallel
        // `messageLookupByChat` dict); `timelineMessage(groupIdHex:messageId:)` resolves through
        // it and stays in sync across window replacements.
        let account = AccountItem.samples[0]
        let chat = ChatItem.samples[0]
        let first = MessageItem(
            id: "m1",
            groupIdHex: chat.id,
            senderName: "Alice",
            body: "First",
            sentAt: Date(timeIntervalSince1970: 1_700_000_000),
            isOutgoing: false
        )
        let state = WorkspaceState(
            accounts: [account],
            chatsByAccount: [account.id: [chat]],
            messagesByChat: [chat.id: [first]],
            clientFactory: { FakeMarmotRuntime(accounts: []) }
        )
        state.activeAccountId = account.id
        state.selection = .chat(chat.id)

        #expect(state.timelineMessage(groupIdHex: chat.id, messageId: "m1")?.body == "First")
        #expect(state.timelineMessage(groupIdHex: chat.id, messageId: "missing") == nil)

        let second = MessageItem(
            id: "m2",
            groupIdHex: chat.id,
            senderName: "Alice",
            body: "Second",
            sentAt: Date(timeIntervalSince1970: 1_700_000_001),
            isOutgoing: false
        )
        state.replaceMessages([second], groupIdHex: chat.id)
        #expect(state.timelineMessage(groupIdHex: chat.id, messageId: "m2")?.body == "Second")
        #expect(state.timelineMessage(groupIdHex: chat.id, messageId: "m1") == nil)
    }

    @MainActor
    @Test func selectedMessageIDsCacheStaysInSyncAcrossTimelineMutations() async throws {
        // Regression for #44: selectedMessageIDs is served from the selected timeline
        // store's cached id array. Verify the cached ids always equal the live message ids
        // before and after the timeline window is replaced via a projection.
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
        // Keep the live projection from racing ahead of the post-load cache assertion below.
        runtime.timelineUpdateDelayNanoseconds = 100_000_000
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
                    id: "m1",
                    groupIdHex: "direct-group",
                    sender: aliceId,
                    plaintext: "First.",
                    kind: 9,
                    recordedAt: 1_700_000_000
                ),
                appMessage(
                    id: "m2",
                    groupIdHex: "direct-group",
                    sender: aliceId,
                    plaintext: "Second.",
                    kind: 9,
                    recordedAt: 1_700_000_001
                ),
            ], groupIdHex: "direct-group")
        let projected = timelineMessage(
            id: "stream",
            groupIdHex: "direct-group",
            sender: account.accountIdHex,
            plaintext: "Streaming…",
            recordedAt: 1_700_000_010,
            agentTextStreamJson: #"{"stream_id":"stream"}"#
        )
        let streamingChatRow = chatListRow(
            groupIdHex: "direct-group",
            title: "Alice",
            preview: "Streaming…",
            sender: account.accountIdHex,
            timelineAt: 1_700_000_010
        )
        runtime.installTimelineUpdates(
            [
                .projection(
                    update: RuntimeProjectionUpdateFfi(
                        accountIdHex: account.accountIdHex,
                        accountLabel: account.label,
                        update: TimelineProjectionUpdateFfi(
                            groupIdHex: "direct-group",
                            messages: [],
                            changes: [
                                .remove(messageIdHex: "m1", reason: .noLongerMatchesQuery),
                                .upsert(trigger: .agentStreamStarted, message: projected),
                            ],
                            chatListRow: streamingChatRow,
                            chatListTrigger: .newLastMessage
                        )
                    ))
            ], groupIdHex: "direct-group")
        runtime.installChatListUpdates([
            .row(trigger: .newLastMessage, row: streamingChatRow)
        ])
        // Deliver the queued projection on a delay so the pre-projection assertions below run
        // deterministically against the initial window. Without this the listener can apply the
        // projection (`-m1, +stream`) before the synchronous `["m1", "m2"]` check, flaking the
        // test on faster/loaded CI runners.
        runtime.timelineUpdateDelayNanoseconds = 300_000_000
        let state = WorkspaceState(clientFactory: { runtime })

        await state.bootstrap()
        await state.loadMessages(groupIdHex: "direct-group")

        // Cache matches the live ids after initial load.
        #expect(state.selectedMessageIDs == state.selectedMessages.map(\.id))
        #expect(state.selectedMessageIDs == ["m1", "m2"])

        let didApplyProjection = await waitFor {
            state.messagesByChat["direct-group"]?.map(\.id) == ["m2", "stream"]
        }
        #expect(didApplyProjection)

        // Cache stays in sync after the projection mutates the window.
        #expect(state.selectedMessageIDs == state.selectedMessages.map(\.id))
        #expect(state.selectedMessageIDs == ["m2", "stream"])
    }

    @Test func failedReadMarkerRollbackUsesLastConfirmedMarker() {
        let committed = ReadMarker(
            sentAt: Date(timeIntervalSince1970: 1_700_000_000),
            messageId: "m0"
        )
        let firstAttempt = ReadMarker(
            sentAt: Date(timeIntervalSince1970: 1_700_000_010),
            messageId: "m1"
        )
        let secondAttempt = ReadMarker(
            sentAt: Date(timeIntervalSince1970: 1_700_000_020),
            messageId: "m2"
        )

        #expect(
            ReadMarker.afterFailedOptimisticAdvance(
                current: secondAttempt,
                attempted: firstAttempt,
                confirmed: committed
            ) == secondAttempt
        )
        #expect(
            ReadMarker.afterFailedOptimisticAdvance(
                current: secondAttempt,
                attempted: secondAttempt,
                confirmed: committed
            ) == committed
        )
        #expect(
            ReadMarker.afterFailedOptimisticAdvance(
                current: nil,
                attempted: firstAttempt,
                confirmed: committed
            ) == nil
        )
        #expect(
            ReadMarker.afterFailedOptimisticAdvance(
                current: firstAttempt,
                attempted: firstAttempt,
                confirmed: nil
            ) == nil
        )
    }

    @Test func successfulReadMarkerCommitAdvancesConfirmedMarkerAndPreservesNewerOptimisticSlot() {
        let committed = ReadMarker(
            sentAt: Date(timeIntervalSince1970: 1_700_000_000),
            messageId: "m0"
        )
        let firstAttempt = ReadMarker(
            sentAt: Date(timeIntervalSince1970: 1_700_000_010),
            messageId: "m1"
        )
        let secondAttempt = ReadMarker(
            sentAt: Date(timeIntervalSince1970: 1_700_000_020),
            messageId: "m2"
        )

        let restoredAfterNewerFailure = ReadMarker.afterSuccessfulCommit(
            current: committed,
            confirmed: committed,
            attempted: firstAttempt
        )
        #expect(restoredAfterNewerFailure.current == firstAttempt)
        #expect(restoredAfterNewerFailure.confirmed == firstAttempt)

        let newerStillInFlight = ReadMarker.afterSuccessfulCommit(
            current: secondAttempt,
            confirmed: committed,
            attempted: firstAttempt
        )
        #expect(newerStillInFlight.current == secondAttempt)
        #expect(newerStillInFlight.confirmed == firstAttempt)

        let olderSuccessAfterNewerCommit = ReadMarker.afterSuccessfulCommit(
            current: secondAttempt,
            confirmed: secondAttempt,
            attempted: firstAttempt
        )
        #expect(olderSuccessAfterNewerCommit.current == secondAttempt)
        #expect(olderSuccessAfterNewerCommit.confirmed == secondAttempt)
    }

    @MainActor
    @Test func failedReadMarkerAfterNavigationRollsBackAndCanRetry() async throws {
        let account = desktopAccount()
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
        let state = WorkspaceState(
            appActivityProvider: { true },
            conversationWindowVisibilityProvider: { true },
            clientFactory: { runtime }
        )

        await state.bootstrap()
        state.replaceMessages(
            [
                MessageItem(
                    id: "latest",
                    groupIdHex: "direct-group",
                    senderName: "Alice",
                    body: "Latest message",
                    sentAt: Date(timeIntervalSince1970: 1_700_000_010),
                    isOutgoing: false
                )
            ],
            groupIdHex: "direct-group"
        )
        let activeAccount = try #require(state.activeAccount)
        runtime.markTimelineMessageReadGateEnabled = true
        runtime.markTimelineMessageReadError = NSError(
            domain: "test.read-marker",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "read marker failed"]
        )
        async let firstMark: Void = state.markLatestVisibleMessageRead(
            groupIdHex: "direct-group",
            account: activeAccount,
            client: runtime
        )
        let didReachReadMarker = await waitFor { runtime.didReachMarkTimelineMessageReadGate }
        #expect(didReachReadMarker)

        state.selection = .settings(.overview)
        runtime.releaseMarkTimelineMessageReadGate()
        _ = await firstMark

        #expect(state.lastMarkedReadMarkers["direct-group"] == nil)
        #expect(state.lastConfirmedReadMarkers["direct-group"] == nil)
        #expect(state.backgroundStatus != "read marker failed")

        runtime.markTimelineMessageReadGateEnabled = false
        runtime.markTimelineMessageReadError = nil
        state.selection = .chat("direct-group")
        await state.markLatestVisibleMessageRead(
            groupIdHex: "direct-group",
            account: activeAccount,
            client: runtime
        )

        #expect(runtime.markedReadMessageIds == ["latest", "latest"])
        #expect(state.lastConfirmedReadMarkers["direct-group"]?.messageId == "latest")
    }

    @MainActor
    @Test func successfulReadMarkerAfterNavigationStillConfirmsPerGroupState() async throws {
        let account = desktopAccount()
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
        let state = WorkspaceState(
            appActivityProvider: { true },
            conversationWindowVisibilityProvider: { true },
            clientFactory: { runtime }
        )

        await state.bootstrap()
        state.replaceMessages(
            [
                MessageItem(
                    id: "latest",
                    groupIdHex: "direct-group",
                    senderName: "Alice",
                    body: "Latest message",
                    sentAt: Date(timeIntervalSince1970: 1_700_000_010),
                    isOutgoing: false
                )
            ],
            groupIdHex: "direct-group"
        )
        let activeAccount = try #require(state.activeAccount)
        runtime.markTimelineMessageReadGateEnabled = true
        async let firstMark: Void = state.markLatestVisibleMessageRead(
            groupIdHex: "direct-group",
            account: activeAccount,
            client: runtime
        )
        let didReachReadMarker = await waitFor { runtime.didReachMarkTimelineMessageReadGate }
        #expect(didReachReadMarker)

        state.selection = .settings(.overview)
        runtime.releaseMarkTimelineMessageReadGate()
        _ = await firstMark

        #expect(state.lastMarkedReadMarkers["direct-group"]?.messageId == "latest")
        #expect(state.lastConfirmedReadMarkers["direct-group"]?.messageId == "latest")
    }

    @MainActor
    @Test func olderTimelineProjectionDeltaDoesNotMoveReadMarkerBackward() async throws {
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
                    id: "older",
                    groupIdHex: "direct-group",
                    sender: aliceId,
                    plaintext: "Earlier message",
                    kind: 9,
                    recordedAt: 1_700_000_000
                ),
                appMessage(
                    id: "latest",
                    groupIdHex: "direct-group",
                    sender: aliceId,
                    plaintext: "Latest message",
                    kind: 9,
                    recordedAt: 1_700_000_010
                ),
            ], groupIdHex: "direct-group")
        let reprojectedOlder = timelineMessage(
            id: "older",
            groupIdHex: "direct-group",
            sender: aliceId,
            plaintext: "Earlier message edited by projection",
            recordedAt: 1_700_000_000
        )
        runtime.installTimelineUpdates(
            [
                .projection(
                    update: RuntimeProjectionUpdateFfi(
                        accountIdHex: account.accountIdHex,
                        accountLabel: account.label,
                        update: TimelineProjectionUpdateFfi(
                            groupIdHex: "direct-group",
                            messages: [],
                            changes: [
                                .upsert(trigger: .reactionAdded, message: reprojectedOlder)
                            ],
                            chatListRow: nil,
                            chatListTrigger: .unreadChanged
                        )
                    ))
            ], groupIdHex: "direct-group")
        let state = WorkspaceState(
            appActivityProvider: { true },
            conversationWindowVisibilityProvider: { true },
            clientFactory: { runtime }
        )

        await state.bootstrap()
        await state.loadMessages(groupIdHex: "direct-group")
        let didApplyProjection = await waitFor {
            state.messagesByChat["direct-group"]?.first(where: { $0.id == "older" })?.body
                == "Earlier message edited by projection"
        }

        #expect(didApplyProjection)
        #expect(runtime.markedReadMessageIds == ["latest"])
    }

    @MainActor
    @Test func selectedChatDoesNotMarkReadWhileAppIsInactive() async throws {
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
                    id: "latest",
                    groupIdHex: "direct-group",
                    sender: aliceId,
                    plaintext: "Latest message",
                    kind: 9,
                    recordedAt: 1_700_000_010
                )
            ], groupIdHex: "direct-group")
        // App is backgrounded: a selected chat must NOT advance the read marker just
        // because a message is visible in the timeline window.
        let state = WorkspaceState(appActivityProvider: { false }, clientFactory: { runtime })

        await state.bootstrap()
        await state.loadMessages(groupIdHex: "direct-group")

        #expect(state.messagesByChat["direct-group"]?.count == 1)
        #expect(runtime.markedReadMessageIds.isEmpty)
    }

    @MainActor
    @Test func selectedChatDoesNotMarkReadWhileConversationWindowIsHidden() async throws {
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
                    id: "latest",
                    groupIdHex: "direct-group",
                    sender: aliceId,
                    plaintext: "Latest message",
                    kind: 9,
                    recordedAt: 1_700_000_010
                )
            ], groupIdHex: "direct-group")
        // The app process can stay active while its only window is minimized or has no
        // key window; a selected chat is still not visible in that state.
        let state = WorkspaceState(
            appActivityProvider: { true },
            conversationWindowVisibilityProvider: { false },
            clientFactory: { runtime }
        )

        await state.bootstrap()
        await state.loadMessages(groupIdHex: "direct-group")

        #expect(state.messagesByChat["direct-group"]?.count == 1)
        #expect(runtime.markedReadMessageIds.isEmpty)
    }

    @MainActor
    @Test func regainingFocusFlushesDeferredReadMarking() async throws {
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
                    id: "latest",
                    groupIdHex: "direct-group",
                    sender: aliceId,
                    plaintext: "Latest message",
                    kind: 9,
                    recordedAt: 1_700_000_010
                )
            ], groupIdHex: "direct-group")
        // Start inactive so the initial open defers marking, then flip to active and
        // simulate the app regaining focus.
        let isActive = MutableFlag(false)
        let state = WorkspaceState(
            appActivityProvider: { isActive.value },
            conversationWindowVisibilityProvider: { true },
            clientFactory: { runtime }
        )

        await state.bootstrap()
        await state.loadMessages(groupIdHex: "direct-group")
        #expect(runtime.markedReadMessageIds.isEmpty)

        isActive.value = true
        await state.handleConversationVisibilityChange()

        #expect(runtime.markedReadMessageIds == ["latest"])
    }

    @MainActor
    @Test func restoringConversationWindowFlushesDeferredReadMarking() async throws {
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
                    id: "latest",
                    groupIdHex: "direct-group",
                    sender: aliceId,
                    plaintext: "Latest message",
                    kind: 9,
                    recordedAt: 1_700_000_010
                )
            ], groupIdHex: "direct-group")
        let isWindowVisible = MutableFlag(false)
        let state = WorkspaceState(
            appActivityProvider: { true },
            conversationWindowVisibilityProvider: { isWindowVisible.value },
            clientFactory: { runtime }
        )

        await state.bootstrap()
        await state.loadMessages(groupIdHex: "direct-group")
        #expect(runtime.markedReadMessageIds.isEmpty)

        isWindowVisible.value = true
        await state.handleConversationVisibilityChange()

        #expect(runtime.markedReadMessageIds == ["latest"])
    }

    @MainActor
    @Test func bootstrapSelectsMostRecentChatAndLoadsTimeline() async throws {
        let account = AccountSummaryFfi(
            label: "Desktop Account",
            accountIdHex: "abcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890",
            localSigning: true,
            externalSigning: false,
            signedOut: false,
            running: true
        )
        let runtime = FakeMarmotRuntime(accounts: [account])
        runtime.installGroups([messageGroup(), directGroup()])
        runtime.installMessages(
            [
                appMessage(
                    id: "group-old",
                    groupIdHex: "group",
                    sender: account.accountIdHex,
                    plaintext: "Older group message",
                    kind: 9,
                    recordedAt: 1_700_000_000
                )
            ], groupIdHex: "group")
        runtime.installMessages(
            [
                appMessage(
                    id: "direct-new",
                    groupIdHex: "direct-group",
                    sender: account.accountIdHex,
                    plaintext: "Newest direct message",
                    kind: 9,
                    recordedAt: 1_700_000_100
                )
            ], groupIdHex: "direct-group")
        let state = WorkspaceState(clientFactory: { runtime })

        await state.bootstrap()
        let didLoadMostRecent = await waitFor {
            state.selection == .chat("direct-group")
                && state.messagesByChat["direct-group"]?.map(\.id) == ["direct-new"]
        }

        #expect(didLoadMostRecent)
        #expect(runtime.timelineSubscriptionCount == 1)
    }

    @MainActor
    @Test func selectingChatsKeepsOnlyCurrentTranscriptInMemory() async throws {
        let account = AccountSummaryFfi(
            label: "Desktop Account",
            accountIdHex: "abcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890",
            localSigning: true,
            externalSigning: false,
            signedOut: false,
            running: true
        )
        let runtime = FakeMarmotRuntime(accounts: [account])
        runtime.installGroups([messageGroup(), directGroup()])
        runtime.installMessages(
            [
                appMessage(
                    id: "group-message",
                    groupIdHex: "group",
                    sender: account.accountIdHex,
                    plaintext: "Group cache candidate",
                    kind: 9,
                    recordedAt: 1_700_000_000
                )
            ], groupIdHex: "group")
        runtime.installMessages(
            [
                appMessage(
                    id: "direct-message",
                    groupIdHex: "direct-group",
                    sender: account.accountIdHex,
                    plaintext: "Direct cache candidate",
                    kind: 9,
                    recordedAt: 1_700_000_010
                )
            ], groupIdHex: "direct-group")
        let state = WorkspaceState(clientFactory: { runtime })

        await state.bootstrap()
        guard let group = state.activeChats.first(where: { $0.id == "group" }),
            let direct = state.activeChats.first(where: { $0.id == "direct-group" })
        else {
            Issue.record("Expected both test chats")
            return
        }

        state.selectChat(group)
        let didLoadGroup = await waitFor {
            state.messagesByChat["group"]?.map(\.id) == ["group-message"]
        }
        #expect(didLoadGroup)
        #expect(Set(state.messagesByChat.keys) == ["group"])

        state.selectChat(direct)
        let didLoadDirect = await waitFor {
            state.messagesByChat["direct-group"]?.map(\.id) == ["direct-message"]
        }
        #expect(didLoadDirect)
        #expect(Set(state.messagesByChat.keys) == ["direct-group"])
    }

    @MainActor
    @Test func selectingUncachedChatTracksInitialTimelineLoadUntilSnapshotApplies() async throws {
        let account = AccountSummaryFfi(
            label: "Desktop Account",
            accountIdHex: "abcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890",
            localSigning: true,
            externalSigning: false,
            signedOut: false,
            running: true
        )
        let runtime = FakeMarmotRuntime(accounts: [account])
        runtime.installGroups([messageGroup(), directGroup()])
        runtime.installMessages(
            [
                appMessage(
                    id: "group-message",
                    groupIdHex: "group",
                    sender: account.accountIdHex,
                    plaintext: "Group history should not look empty while loading",
                    kind: 9,
                    recordedAt: 1_700_000_000
                )
            ], groupIdHex: "group")
        runtime.installMessages(
            [
                appMessage(
                    id: "direct-message",
                    groupIdHex: "direct-group",
                    sender: account.accountIdHex,
                    plaintext: "Most recent chat loads during bootstrap",
                    kind: 9,
                    recordedAt: 1_700_000_010
                )
            ], groupIdHex: "direct-group")
        let state = WorkspaceState(clientFactory: { runtime })

        await state.bootstrap()
        #expect(state.selection == .chat("direct-group"))
        #expect(state.messagesByChat["group"] == nil)
        guard let group = state.activeChats.first(where: { $0.id == "group" }) else {
            Issue.record("Expected group chat")
            return
        }

        runtime.timelineSubscriptionDelayNanoseconds = 50_000_000
        state.selectChat(group)

        #expect(state.selectedTimelineIsLoadingInitialPage)
        #expect(state.selectedMessages.isEmpty)
        #expect(state.messagesByChat["group"] == nil)

        let didLoadGroup = await waitFor {
            state.messagesByChat["group"]?.map(\.id) == ["group-message"]
        }
        #expect(didLoadGroup)
        #expect(!state.selectedTimelineIsLoadingInitialPage)
        #expect(state.selectedMessages.map(\.id) == ["group-message"])
    }

    @MainActor
    @Test func concurrentSameChatTimelineLoadsShareInFlightSubscription() async throws {
        let accountSummary = AccountSummaryFfi(
            label: "Desktop Account",
            accountIdHex: "abcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890",
            localSigning: true,
            externalSigning: false,
            signedOut: false,
            running: true
        )
        let account = AccountItem(
            id: accountSummary.label,
            accountRef: accountSummary.label,
            displayName: accountSummary.label,
            accountIdHex: accountSummary.accountIdHex
        )
        let chat = ChatItem(
            row: chatListRow(
                groupIdHex: "group",
                title: "General",
                preview: "Initial message",
                sender: accountSummary.accountIdHex,
                timelineAt: 1_700_000_000
            ),
            activeAccountIdHex: accountSummary.accountIdHex
        )
        let runtime = FakeMarmotRuntime(accounts: [accountSummary])
        runtime.installGroup(messageGroup())
        runtime.installMessages(
            [
                appMessage(
                    id: "message",
                    groupIdHex: "group",
                    sender: accountSummary.accountIdHex,
                    plaintext: "Initial message",
                    kind: 9,
                    recordedAt: 1_700_000_000
                )
            ],
            groupIdHex: "group"
        )
        runtime.timelineSubscriptionDelayNanoseconds = 50_000_000
        let state = WorkspaceState(
            accounts: [account],
            chatsByAccount: [account.id: [chat]],
            clientFactory: { runtime }
        )
        state.activeAccountId = account.id
        state.selection = .chat(chat.id)
        state.client = runtime

        async let firstLoad: Void = state.loadMessages(groupIdHex: chat.id)
        let didStartFirstLoad = await waitFor {
            runtime.timelineSubscriptionCount == 1
        }
        #expect(didStartFirstLoad)
        async let duplicateLoad: Void = state.loadMessages(groupIdHex: chat.id)

        _ = await (firstLoad, duplicateLoad)

        #expect(runtime.timelineSubscriptionCount == 1)
        #expect(state.messagesByChat[chat.id]?.map(\.id) == ["message"])
        #expect(!state.selectedTimelineIsLoadingInitialPage)
    }

    @MainActor
    @Test func switchedAccountTimelineLoadDoesNotJoinStaleSameGroupLoad() async throws {
        // The load coalescing key must include account ownership. Two local identities can share
        // the same MLS group id; after switching accounts, the new account must not await the
        // old account's still-in-flight subscription and return without opening its own timeline.
        let primarySummary = AccountSummaryFfi(
            label: "Primary Account",
            accountIdHex: "abcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890",
            localSigning: true,
            externalSigning: false,
            signedOut: false,
            running: true
        )
        let backupSummary = AccountSummaryFfi(
            label: "Backup Account",
            accountIdHex: "1111111111111111111111111111111111111111111111111111111111111111",
            localSigning: true,
            externalSigning: false,
            signedOut: false,
            running: true
        )
        let primaryAccount = AccountItem(
            id: primarySummary.label,
            accountRef: primarySummary.label,
            displayName: primarySummary.label,
            accountIdHex: primarySummary.accountIdHex
        )
        let backupAccount = AccountItem(
            id: backupSummary.label,
            accountRef: backupSummary.label,
            displayName: backupSummary.label,
            accountIdHex: backupSummary.accountIdHex
        )
        let sharedGroup = "group"
        let primaryChat = ChatItem(
            row: chatListRow(
                groupIdHex: sharedGroup,
                title: "Shared Group",
                preview: "Primary message",
                sender: primarySummary.accountIdHex,
                timelineAt: 1_700_000_000
            ),
            activeAccountIdHex: primarySummary.accountIdHex
        )
        let backupChat = ChatItem(
            row: chatListRow(
                groupIdHex: sharedGroup,
                title: "Shared Group",
                preview: "Backup message",
                sender: backupSummary.accountIdHex,
                timelineAt: 1_700_000_010
            ),
            activeAccountIdHex: backupSummary.accountIdHex
        )
        let runtime = FakeMarmotRuntime(accounts: [primarySummary, backupSummary])
        runtime.installGroup(messageGroup())
        runtime.installMessages(
            [
                appMessage(
                    id: "backup-message",
                    groupIdHex: sharedGroup,
                    sender: backupSummary.accountIdHex,
                    plaintext: "Backup account history",
                    kind: 9,
                    recordedAt: 1_700_000_010
                )
            ],
            groupIdHex: sharedGroup
        )
        runtime.timelineSubscriptionDelayNanoseconds = 50_000_000
        let state = WorkspaceState(
            accounts: [primaryAccount, backupAccount],
            chatsByAccount: [
                primaryAccount.id: [primaryChat],
                backupAccount.id: [backupChat],
            ],
            clientFactory: { runtime }
        )
        state.activeAccountId = primaryAccount.id
        state.selection = .chat(sharedGroup)
        state.client = runtime

        async let stalePrimaryLoad: Void = state.loadMessages(groupIdHex: sharedGroup)
        let didStartPrimaryLoad = await waitFor {
            runtime.timelineSubscriptionCount == 1
        }
        #expect(didStartPrimaryLoad)

        state.prepareForActiveAccountSwitch(to: backupAccount, preservingMessageCacheFor: nil)
        state.selection = .chat(sharedGroup)
        await state.loadMessages(groupIdHex: sharedGroup)
        _ = await stalePrimaryLoad

        #expect(runtime.timelineSubscriptionAccountRefs == [primaryAccount.accountRef, backupAccount.accountRef])
        #expect(state.messagesByChat[sharedGroup]?.map(\.id) == ["backup-message"])
    }

    @MainActor
    @Test func initialTimelineLoadClearsWhenRuntimeIsUnavailable() async throws {
        let account = AccountItem(
            id: "Desktop Account",
            accountRef: "Desktop Account",
            displayName: "Desktop Account",
            accountIdHex: "abcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890"
        )
        let chat = ChatItem(
            id: "group",
            title: "General",
            subtitle: "Group chat",
            preview: "",
            updatedAt: nil,
            avatarSeed: "group",
            pictureURL: nil,
            unreadCount: 0
        )
        UserDefaults.standard.set(account.id, forKey: "whitenoise.mac.activeAccountId")
        let state = WorkspaceState(
            accounts: [account],
            chatsByAccount: [account.id: [chat]],
            clientFactory: { FakeMarmotRuntime(accounts: []) }
        )

        state.selectChat(chat)

        #expect(state.selectedTimelineIsLoadingInitialPage)
        await state.loadMessages(groupIdHex: chat.id)
        #expect(!state.selectedTimelineIsLoadingInitialPage)
        #expect(state.messagesByChat["group"] == nil)
    }

    @MainActor
    @Test func loadingOlderMessagesExtendsWindowViaSubscription() async throws {
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
        let baseTime: UInt64 = 1_700_000_000
        runtime.installMessages(
            (0..<105).map { index in
                appMessage(
                    id: String(format: "message-%03d", index),
                    groupIdHex: "direct-group",
                    sender: aliceId,
                    plaintext: "Message \(index)",
                    kind: 9,
                    recordedAt: baseTime + UInt64(index)
                )
            },
            groupIdHex: "direct-group"
        )
        let state = WorkspaceState(clientFactory: { runtime })

        await state.bootstrap()
        await state.loadMessages(groupIdHex: "direct-group")
        #expect(state.messagesByChat["direct-group"]?.count == 100)
        #expect(state.messagesByChat["direct-group"]?.first?.id == "message-005")
        #expect(state.selectedTimelinePaging.hasMoreBefore)

        await state.loadOlderMessages(groupIdHex: "direct-group")

        let loadedIds = state.messagesByChat["direct-group"]?.map(\.id) ?? []
        #expect(loadedIds.count == 105)
        #expect(loadedIds.first == "message-000")
        #expect(loadedIds.last == "message-104")
        #expect(!state.selectedTimelinePaging.hasMoreBefore)
        #expect(runtime.lastTimelineSubscription?.paginateBackwardsCount == 1)
        #expect(runtime.timelineSubscriptionCount == 1)
    }

    @MainActor
    @Test func loadingOlderMessagesStopsPaginatingAtOldest() async throws {
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
        let baseTime: UInt64 = 1_700_000_000
        runtime.installMessages(
            (0..<101).map { index in
                appMessage(
                    id: String(format: "message-%03d", index),
                    groupIdHex: "direct-group",
                    sender: aliceId,
                    plaintext: "Message \(index)",
                    kind: 9,
                    recordedAt: baseTime + UInt64(index)
                )
            },
            groupIdHex: "direct-group"
        )
        let state = WorkspaceState(clientFactory: { runtime })

        await state.bootstrap()
        await state.loadMessages(groupIdHex: "direct-group")
        #expect(state.selectedTimelinePaging.hasMoreBefore)

        await state.loadOlderMessages(groupIdHex: "direct-group")
        await state.loadOlderMessages(groupIdHex: "direct-group")

        // The subscription owns the cursor: the first scroll-up reaches the oldest message,
        // and the second is a no-op (guarded by hasMoreBefore), so it never re-paginates.
        #expect(runtime.lastTimelineSubscription?.paginateBackwardsCount == 1)
        #expect(state.messagesByChat["direct-group"]?.first?.id == "message-000")
        #expect(state.messagesByChat["direct-group"]?.count == 101)
        #expect(!state.selectedTimelinePaging.hasMoreBefore)
    }

    @MainActor
    @Test func timelineWindowCapsScrollbackAndPagesForwardAgain() async throws {
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
        let baseTime: UInt64 = 1_700_000_000
        runtime.installMessages(
            (0..<450).map { index in
                appMessage(
                    id: String(format: "message-%03d", index),
                    groupIdHex: "direct-group",
                    sender: aliceId,
                    plaintext: "Message \(index)",
                    kind: 9,
                    recordedAt: baseTime + UInt64(index)
                )
            },
            groupIdHex: "direct-group"
        )
        let state = WorkspaceState(clientFactory: { runtime })

        await state.bootstrap()
        await state.loadMessages(groupIdHex: "direct-group")
        await state.loadOlderMessages(groupIdHex: "direct-group")
        await state.loadOlderMessages(groupIdHex: "direct-group")
        await state.loadOlderMessages(groupIdHex: "direct-group")

        // The runtime caps the materialized window at MAX_TIMELINE_LIMIT (200); scrolling
        // back trims the newest rows, so the window slides instead of growing unbounded.
        #expect(state.messagesByChat["direct-group"]?.count == 200)
        #expect(state.messagesByChat["direct-group"]?.first?.id == "message-050")
        #expect(state.messagesByChat["direct-group"]?.last?.id == "message-249")
        #expect(state.selectedTimelinePaging.hasMoreBefore)
        #expect(state.selectedTimelinePaging.hasMoreAfter)

        await state.loadNewerMessages(groupIdHex: "direct-group")

        // Paging forward slides the window toward the head, trimming the oldest rows.
        #expect(state.messagesByChat["direct-group"]?.count == 200)
        #expect(state.messagesByChat["direct-group"]?.first?.id == "message-150")
        #expect(state.messagesByChat["direct-group"]?.last?.id == "message-349")
        #expect(state.selectedTimelinePaging.hasMoreBefore)
        #expect(state.selectedTimelinePaging.hasMoreAfter)
        #expect(runtime.lastTimelineSubscription?.paginateForwardsCount == 1)
    }

    @MainActor
    @Test func staleTimelinePaginationDoesNotClobberReplacementSubscriptionWindow() async throws {
        // Issue #529: `loadOlderMessages` / `loadNewerMessages` capture the active subscription,
        // await pagination, then must re-check subscription identity. A mid-paginate listener
        // reconnect for the same account/group replaces `activeTimelineSubscription` without
        // changing selection; the stale page must not overwrite the replacement window.
        let account = desktopAccount()
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
        let baseTime: UInt64 = 1_700_000_000
        runtime.installMessages(
            (0..<105).map { index in
                appMessage(
                    id: String(format: "message-%03d", index),
                    groupIdHex: "direct-group",
                    sender: aliceId,
                    plaintext: "Message \(index)",
                    kind: 9,
                    recordedAt: baseTime + UInt64(index)
                )
            },
            groupIdHex: "direct-group"
        )
        let state = WorkspaceState(clientFactory: { runtime })

        await state.bootstrap()
        await state.loadMessages(groupIdHex: "direct-group")
        let activeAccount = try #require(state.activeAccount)
        let staleSubscription = try #require(state.activeTimelineSubscription as? FakeTimelineMessagesSubscription)
        #expect(state.messagesByChat["direct-group"]?.first?.id == "message-005")
        #expect(state.selectedTimelinePaging.hasMoreBefore)

        staleSubscription.paginationGateEnabled = true
        async let staleBack: Void = state.loadOlderMessages(groupIdHex: "direct-group")
        let didSuspendBack = await waitFor {
            state.selectedTimelinePaging.isLoadingBefore && staleSubscription.didReachPaginationGate
        }
        guard didSuspendBack else {
            staleSubscription.paginationGateEnabled = false
            staleSubscription.releasePaginationGate()
            _ = await staleBack
            Issue.record("Expected backwards pagination to reach the test gate")
            return
        }

        let replacementBackMessages = (0..<105).map { index in
            timelineMessage(
                id: String(format: "fresh-back-%03d", index),
                groupIdHex: "direct-group",
                sender: aliceId,
                plaintext: "Fresh back \(index)",
                recordedAt: baseTime + UInt64(index)
            )
        }
        let replacementBack = FakeTimelineMessagesSubscription(
            messages: replacementBackMessages,
            limit: 100,
            windowCap: 200
        )
        state.activeTimelineSubscription = replacementBack
        state.activeTimelineGroupId = "direct-group"
        await state.applyTimelineWindow(
            replacementBack.snapshot() ?? emptyTimelinePage(),
            groupIdHex: "direct-group",
            account: activeAccount,
            client: runtime,
            owner: .subscription(replacementBack)
        )
        #expect(state.messagesByChat["direct-group"]?.first?.id == "fresh-back-005")
        #expect(state.messagesByChat["direct-group"]?.last?.id == "fresh-back-104")

        staleSubscription.releasePaginationGate()
        _ = await staleBack

        #expect(state.messagesByChat["direct-group"]?.first?.id == "fresh-back-005")
        #expect(state.messagesByChat["direct-group"]?.last?.id == "fresh-back-104")
        #expect(state.selectedTimelinePaging.hasMoreBefore)

        let replacementFwdMessages = (0..<450).map { index in
            timelineMessage(
                id: String(format: "fresh-fwd-%03d", index),
                groupIdHex: "direct-group",
                sender: aliceId,
                plaintext: "Fresh fwd \(index)",
                recordedAt: baseTime + UInt64(index)
            )
        }
        let replacementFwd = FakeTimelineMessagesSubscription(
            messages: replacementFwdMessages,
            limit: 100,
            windowCap: 200
        )
        _ = try await replacementFwd.paginateBackwards(count: 100)
        _ = try await replacementFwd.paginateBackwards(count: 100)
        _ = try await replacementFwd.paginateBackwards(count: 100)
        let scrolledBackWindow = try #require(replacementFwd.snapshot())
        #expect(scrolledBackWindow.hasMoreAfter)

        state.activeTimelineSubscription = replacementFwd
        state.activeTimelineGroupId = "direct-group"
        await state.applyTimelineWindow(
            scrolledBackWindow,
            groupIdHex: "direct-group",
            account: activeAccount,
            client: runtime,
            owner: .subscription(replacementFwd)
        )
        let scrolledBackFirst = try #require(state.messagesByChat["direct-group"]?.first?.id)
        #expect(state.selectedTimelinePaging.hasMoreAfter)

        replacementFwd.paginationGateEnabled = true
        async let staleForward: Void = state.loadNewerMessages(groupIdHex: "direct-group")
        let didSuspendForward = await waitFor {
            state.selectedTimelinePaging.isLoadingAfter && replacementFwd.didReachPaginationGate
        }
        guard didSuspendForward else {
            replacementFwd.paginationGateEnabled = false
            replacementFwd.releasePaginationGate()
            _ = await staleForward
            Issue.record("Expected forwards pagination to reach the test gate")
            return
        }

        let replacementForwardMessages = (0..<450).map { index in
            timelineMessage(
                id: String(format: "fresh-forward-%03d", index),
                groupIdHex: "direct-group",
                sender: aliceId,
                plaintext: "Fresh forward \(index)",
                recordedAt: baseTime + UInt64(index)
            )
        }
        let replacementForward = FakeTimelineMessagesSubscription(
            messages: replacementForwardMessages,
            limit: 100,
            windowCap: 200
        )
        _ = try? await replacementForward.paginateBackwards(count: 100)
        _ = try? await replacementForward.paginateBackwards(count: 100)
        let replacementForwardWindow = replacementForward.snapshot() ?? emptyTimelinePage()

        state.activeTimelineSubscription = replacementForward
        state.activeTimelineGroupId = "direct-group"
        await state.applyTimelineWindow(
            replacementForwardWindow,
            groupIdHex: "direct-group",
            account: activeAccount,
            client: runtime,
            owner: .subscription(replacementForward)
        )
        let replacementForwardFirst = state.messagesByChat["direct-group"]?.first?.id
        let replacementForwardLast = state.messagesByChat["direct-group"]?.last?.id
        #expect(replacementForwardFirst != nil)
        #expect(replacementForwardLast != nil)
        #expect(replacementForwardFirst != scrolledBackFirst)

        replacementFwd.releasePaginationGate()
        _ = await staleForward

        #expect(state.messagesByChat["direct-group"]?.first?.id == replacementForwardFirst)
        #expect(state.messagesByChat["direct-group"]?.last?.id == replacementForwardLast)
        #expect(state.messagesByChat["direct-group"]?.first?.id != scrolledBackFirst)
    }

    @MainActor
    @Test func staleTimelinePaginationApplyDoesNotClobberReplacementSubscriptionWindow() async throws {
        // Issue #529 follow-up: the subscription identity guard must survive `applyTimelineWindow`
        // suspension during sender resolution and off-main mapping, not only the paginate await.
        let account = desktopAccount()
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
        let baseTime: UInt64 = 1_700_000_000
        runtime.installMessages(
            (0..<105).map { index in
                appMessage(
                    id: String(format: "message-%03d", index),
                    groupIdHex: "direct-group",
                    sender: aliceId,
                    plaintext: "Message \(index)",
                    kind: 9,
                    recordedAt: baseTime + UInt64(index)
                )
            },
            groupIdHex: "direct-group"
        )
        let state = WorkspaceState(clientFactory: { runtime })

        await state.bootstrap()
        await state.loadMessages(groupIdHex: "direct-group")
        let activeAccount = try #require(state.activeAccount)
        #expect(state.messagesByChat["direct-group"]?.first?.id == "message-005")
        #expect(state.selectedTimelinePaging.hasMoreBefore)

        state.timelineApplyMapGateEnabled = true
        async let staleBack: Void = state.loadOlderMessages(groupIdHex: "direct-group")
        let didSuspendApply = await waitFor {
            state.selectedTimelinePaging.isLoadingBefore && state.didReachTimelineApplyMapGate
        }
        guard didSuspendApply else {
            state.timelineApplyMapGateEnabled = false
            state.releaseTimelineApplyMapGate()
            _ = await staleBack
            Issue.record("Expected backwards pagination apply to reach the map gate")
            return
        }

        let replacementMessages = (0..<105).map { index in
            timelineMessage(
                id: String(format: "fresh-apply-%03d", index),
                groupIdHex: "direct-group",
                sender: aliceId,
                plaintext: "Fresh apply \(index)",
                recordedAt: baseTime + UInt64(index)
            )
        }
        let replacement = FakeTimelineMessagesSubscription(
            messages: replacementMessages,
            limit: 100,
            windowCap: 200
        )
        state.activeTimelineSubscription = replacement
        state.activeTimelineGroupId = "direct-group"
        await state.applyTimelineWindow(
            replacement.snapshot() ?? emptyTimelinePage(),
            groupIdHex: "direct-group",
            account: activeAccount,
            client: runtime,
            owner: .subscription(replacement)
        )
        #expect(state.messagesByChat["direct-group"]?.first?.id == "fresh-apply-005")
        #expect(state.messagesByChat["direct-group"]?.last?.id == "fresh-apply-104")

        state.releaseTimelineApplyMapGate()
        _ = await staleBack

        #expect(state.messagesByChat["direct-group"]?.first?.id == "fresh-apply-005")
        #expect(state.messagesByChat["direct-group"]?.last?.id == "fresh-apply-104")
        #expect(state.selectedTimelinePaging.hasMoreBefore)
    }

    @MainActor
    @Test func staleTimelineLivePageApplyDoesNotClobberReplacementSubscriptionWindow() async throws {
        // Issue #557: non-pagination window applies (live `.page`, reconnect snapshot, initial
        // load) must carry ownership through `applyTimelineWindow` and re-check after suspension,
        // matching pagination (#529). A superseded listener's `.page` apply must not overwrite a
        // replacement subscription for the same account/chat.
        let account = desktopAccount()
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
        let baseTime: UInt64 = 1_700_000_000
        runtime.installMessages(
            (0..<105).map { index in
                appMessage(
                    id: String(format: "message-%03d", index),
                    groupIdHex: "direct-group",
                    sender: aliceId,
                    plaintext: "Message \(index)",
                    kind: 9,
                    recordedAt: baseTime + UInt64(index)
                )
            },
            groupIdHex: "direct-group"
        )
        let state = WorkspaceState(clientFactory: { runtime })

        await state.bootstrap()
        await state.loadMessages(groupIdHex: "direct-group")
        let activeAccount = try #require(state.activeAccount)
        let staleSubscription = try #require(state.activeTimelineSubscription as? FakeTimelineMessagesSubscription)
        #expect(state.messagesByChat["direct-group"]?.first?.id == "message-005")
        #expect(state.selectedTimelinePaging.hasMoreBefore)

        let stalePage = staleSubscription.snapshot() ?? emptyTimelinePage()

        state.timelineApplyMapGateEnabled = true
        async let stalePageApply: Void = state.applyTimelineSubscriptionUpdate(
            .page(page: stalePage),
            groupIdHex: "direct-group",
            account: activeAccount,
            client: runtime,
            subscription: staleSubscription
        )
        let didSuspendApply = await waitFor {
            state.didReachTimelineApplyMapGate
        }
        guard didSuspendApply else {
            state.timelineApplyMapGateEnabled = false
            state.releaseTimelineApplyMapGate()
            _ = await stalePageApply
            Issue.record("Expected live `.page` apply to reach the map gate")
            return
        }

        let replacementMessages = (0..<105).map { index in
            timelineMessage(
                id: String(format: "fresh-page-%03d", index),
                groupIdHex: "direct-group",
                sender: aliceId,
                plaintext: "Fresh page \(index)",
                recordedAt: baseTime + UInt64(index)
            )
        }
        let replacement = FakeTimelineMessagesSubscription(
            messages: replacementMessages,
            limit: 100,
            windowCap: 200
        )
        state.activeTimelineSubscription = replacement
        state.activeTimelineGroupId = "direct-group"
        await state.applyTimelineWindow(
            replacement.snapshot() ?? emptyTimelinePage(),
            groupIdHex: "direct-group",
            account: activeAccount,
            client: runtime,
            owner: .subscription(replacement)
        )
        #expect(state.messagesByChat["direct-group"]?.first?.id == "fresh-page-005")
        #expect(state.messagesByChat["direct-group"]?.last?.id == "fresh-page-104")

        state.releaseTimelineApplyMapGate()
        _ = await stalePageApply

        #expect(state.messagesByChat["direct-group"]?.first?.id == "fresh-page-005")
        #expect(state.messagesByChat["direct-group"]?.last?.id == "fresh-page-104")
        #expect(state.selectedTimelinePaging.hasMoreBefore)
    }

    @MainActor
    @Test func stalePostSendRefreshDoesNotClobberReplacementSubscriptionWindow() async throws {
        // Issue #572: a point-in-time post-send query must retain ownership through mapping.
        // A replacement listener for the same account/chat can otherwise apply B, only for the
        // older refresh A to resume and overwrite it because selection itself did not change.
        let account = desktopAccount()
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
                    plaintext: "Initial",
                    kind: 9,
                    recordedAt: 1_700_000_000
                )
            ],
            groupIdHex: "direct-group"
        )
        let state = WorkspaceState(clientFactory: { runtime })

        await state.bootstrap()
        await state.loadMessages(groupIdHex: "direct-group")
        let activeAccount = try #require(state.activeAccount)
        #expect(state.activeTimelineSubscription != nil)

        runtime.installMessages(
            [
                appMessage(
                    id: "stale-refresh",
                    groupIdHex: "direct-group",
                    sender: aliceId,
                    plaintext: "Stale refresh",
                    kind: 9,
                    recordedAt: 1_700_000_001
                )
            ],
            groupIdHex: "direct-group"
        )
        state.timelineApplyMapGateEnabled = true
        async let staleRefresh: Void = state.refreshSelectedTimelineAfterSend(
            groupIdHex: "direct-group",
            account: activeAccount,
            client: runtime
        )
        let didSuspendRefresh = await waitFor {
            state.didReachTimelineApplyMapGate
        }
        guard didSuspendRefresh else {
            state.timelineApplyMapGateEnabled = false
            state.releaseTimelineApplyMapGate()
            _ = await staleRefresh
            Issue.record("Expected post-send refresh to reach the map gate")
            return
        }

        let replacement = FakeTimelineMessagesSubscription(
            messages: [
                timelineMessage(
                    id: "replacement",
                    groupIdHex: "direct-group",
                    sender: aliceId,
                    plaintext: "Replacement",
                    recordedAt: 1_700_000_002
                )
            ],
            limit: 100,
            windowCap: 200
        )
        state.activeTimelineSubscription = replacement
        state.activeTimelineGroupId = "direct-group"
        await state.applyTimelineWindow(
            replacement.snapshot() ?? emptyTimelinePage(),
            groupIdHex: "direct-group",
            account: activeAccount,
            client: runtime,
            owner: .subscription(replacement)
        )
        #expect(state.messagesByChat["direct-group"]?.map(\.id) == ["replacement"])

        state.releaseTimelineApplyMapGate()
        _ = await staleRefresh

        #expect(state.messagesByChat["direct-group"]?.map(\.id) == ["replacement"])
    }

    @MainActor
    @Test func staleTimelineLiveProjectionApplyDoesNotClobberReplacementSubscriptionWindow() async throws {
        // Issue #571: live `.projection` applies must carry subscription ownership and re-check
        // after suspension, matching `.page` (#557) and pagination (#529). A superseded listener's
        // in-flight projection must not mutate a replacement subscription's authoritative window.
        let account = desktopAccount()
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
        let baseTime: UInt64 = 1_700_000_000
        runtime.installMessages(
            (0..<105).map { index in
                appMessage(
                    id: String(format: "message-%03d", index),
                    groupIdHex: "direct-group",
                    sender: aliceId,
                    plaintext: "Message \(index)",
                    kind: 9,
                    recordedAt: baseTime + UInt64(index)
                )
            },
            groupIdHex: "direct-group"
        )
        let state = WorkspaceState(clientFactory: { runtime })

        await state.bootstrap()
        await state.loadMessages(groupIdHex: "direct-group")
        let activeAccount = try #require(state.activeAccount)
        let staleSubscription = try #require(state.activeTimelineSubscription as? FakeTimelineMessagesSubscription)
        #expect(state.messagesByChat["direct-group"]?.first?.id == "message-005")
        #expect(state.messagesByChat["direct-group"]?.last?.id == "message-104")

        let staleProjection = TimelineProjectionUpdateFfi(
            groupIdHex: "direct-group",
            messages: [],
            changes: [
                .upsert(
                    trigger: .newMessage,
                    message: timelineMessage(
                        id: "message-104",
                        groupIdHex: "direct-group",
                        sender: aliceId,
                        plaintext: "Stale projection regression",
                        recordedAt: baseTime + 104
                    ))
            ],
            chatListRow: nil,
            chatListTrigger: .newLastMessage
        )

        state.timelineApplyMapGateEnabled = true
        async let staleProjectionApply: Void = state.applyTimelineSubscriptionUpdate(
            .projection(
                update: RuntimeProjectionUpdateFfi(
                    accountIdHex: account.accountIdHex,
                    accountLabel: account.label,
                    update: staleProjection
                )),
            groupIdHex: "direct-group",
            account: activeAccount,
            client: runtime,
            subscription: staleSubscription
        )
        let didSuspendApply = await waitFor {
            state.didReachTimelineApplyMapGate
        }
        guard didSuspendApply else {
            state.timelineApplyMapGateEnabled = false
            state.releaseTimelineApplyMapGate()
            _ = await staleProjectionApply
            Issue.record("Expected live `.projection` apply to reach the map gate")
            return
        }

        let replacementMessages = (0..<105).map { index in
            timelineMessage(
                id: String(format: "fresh-projection-%03d", index),
                groupIdHex: "direct-group",
                sender: aliceId,
                plaintext: "Fresh projection \(index)",
                recordedAt: baseTime + UInt64(index)
            )
        }
        let replacement = FakeTimelineMessagesSubscription(
            messages: replacementMessages,
            limit: 100,
            windowCap: 200
        )
        state.activeTimelineSubscription = replacement
        state.activeTimelineGroupId = "direct-group"
        await state.applyTimelineWindow(
            replacement.snapshot() ?? emptyTimelinePage(),
            groupIdHex: "direct-group",
            account: activeAccount,
            client: runtime,
            owner: .subscription(replacement)
        )
        #expect(state.messagesByChat["direct-group"]?.first?.id == "fresh-projection-005")
        #expect(state.messagesByChat["direct-group"]?.last?.id == "fresh-projection-104")
        #expect(state.messagesByChat["direct-group"]?.count == 100)

        state.releaseTimelineApplyMapGate()
        _ = await staleProjectionApply

        #expect(state.messagesByChat["direct-group"]?.first?.id == "fresh-projection-005")
        #expect(state.messagesByChat["direct-group"]?.last?.id == "fresh-projection-104")
        #expect(state.messagesByChat["direct-group"]?.count == 100)
        #expect(state.messagesByChat["direct-group"]?.contains { $0.id == "message-104" } == false)
        #expect(state.selectedTimelinePaging.hasMoreBefore)
    }

    @MainActor
    @Test func staleTimelineInitialLoadApplyDoesNotClobberReplacementLoadWindow() async throws {
        // Issue #557: initial-load window applies must re-check load-generation ownership after
        // suspension, matching subscription pagination/live paths (#529). A superseded initial load
        // must not overwrite a replacement load for the same account/chat.
        let account = desktopAccount()
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
        let baseTime: UInt64 = 1_700_000_000
        runtime.installMessages(
            (0..<105).map { index in
                appMessage(
                    id: String(format: "message-%03d", index),
                    groupIdHex: "direct-group",
                    sender: aliceId,
                    plaintext: "Message \(index)",
                    kind: 9,
                    recordedAt: baseTime + UInt64(index)
                )
            },
            groupIdHex: "direct-group"
        )
        let state = WorkspaceState(clientFactory: { runtime })

        await state.bootstrap()
        await state.loadMessages(groupIdHex: "direct-group")
        #expect(state.messagesByChat["direct-group"]?.first?.id == "message-005")
        let directChat = try #require(state.activeChats.first(where: { $0.id == "direct-group" }))

        state.stopTimelineListener()
        state.messageTimelineStores["direct-group"]?.clear()

        state.timelineApplyMapGateEnabled = true
        async let staleInitialLoad: Void = state.loadMessages(groupIdHex: "direct-group")
        let didSuspendApply = await waitFor {
            state.didReachTimelineApplyMapGate
        }
        guard didSuspendApply else {
            state.timelineApplyMapGateEnabled = false
            state.releaseTimelineApplyMapGate()
            _ = await staleInitialLoad
            Issue.record("Expected initial-load apply to reach the map gate")
            return
        }

        // Production leave/re-enter: Settings tears down the in-flight owner, then selecting the
        // same chat starts a replacement load instead of joining the suspended initial load.
        state.showSettings()
        runtime.installMessages(
            (0..<105).map { index in
                appMessage(
                    id: String(format: "fresh-load-%03d", index),
                    groupIdHex: "direct-group",
                    sender: aliceId,
                    plaintext: "Fresh load \(index)",
                    kind: 9,
                    recordedAt: baseTime + UInt64(index)
                )
            },
            groupIdHex: "direct-group"
        )
        state.selectChat(directChat)
        let didLoadReplacement = await waitFor {
            state.messagesByChat["direct-group"]?.first?.id == "fresh-load-005"
        }
        guard didLoadReplacement else {
            state.timelineApplyMapGateEnabled = false
            state.releaseTimelineApplyMapGate()
            _ = await staleInitialLoad
            Issue.record("Expected replacement initial load to materialize via selectChat")
            return
        }
        let replacementSubscription = try #require(state.activeTimelineSubscription)
        #expect(state.messagesByChat["direct-group"]?.last?.id == "fresh-load-104")

        state.releaseTimelineApplyMapGate()
        _ = await staleInitialLoad

        #expect(state.activeTimelineSubscription === replacementSubscription)
        #expect(state.messagesByChat["direct-group"]?.first?.id == "fresh-load-005")
        #expect(state.messagesByChat["direct-group"]?.last?.id == "fresh-load-104")
        #expect(state.selectedTimelinePaging.hasMoreBefore)
    }

    @MainActor
    @Test func staleTimelinePaginationErrorDoesNotSurfaceAfterSubscriptionReplacement() async throws {
        let account = desktopAccount()
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
        let baseTime: UInt64 = 1_700_000_000
        runtime.installMessages(
            (0..<105).map { index in
                appMessage(
                    id: String(format: "message-%03d", index),
                    groupIdHex: "direct-group",
                    sender: aliceId,
                    plaintext: "Message \(index)",
                    kind: 9,
                    recordedAt: baseTime + UInt64(index)
                )
            },
            groupIdHex: "direct-group"
        )
        let state = WorkspaceState(clientFactory: { runtime })

        await state.bootstrap()
        await state.loadMessages(groupIdHex: "direct-group")
        let activeAccount = try #require(state.activeAccount)
        let staleSubscription = try #require(state.activeTimelineSubscription as? FakeTimelineMessagesSubscription)
        state.lastError = nil

        staleSubscription.paginationGateEnabled = true
        staleSubscription.throwsAfterPaginationGate = true
        async let staleBack: Void = state.loadOlderMessages(groupIdHex: "direct-group")
        let didSuspendBack = await waitFor {
            state.selectedTimelinePaging.isLoadingBefore && staleSubscription.didReachPaginationGate
        }
        guard didSuspendBack else {
            staleSubscription.paginationGateEnabled = false
            staleSubscription.throwsAfterPaginationGate = false
            staleSubscription.releasePaginationGate()
            _ = await staleBack
            Issue.record("Expected backwards pagination to reach the test gate")
            return
        }

        let replacement = FakeTimelineMessagesSubscription(
            messages: [
                timelineMessage(
                    id: "fresh-error-000",
                    groupIdHex: "direct-group",
                    sender: aliceId,
                    plaintext: "Fresh error",
                    recordedAt: baseTime
                )
            ],
            limit: 100,
            windowCap: 200
        )
        state.activeTimelineSubscription = replacement
        state.activeTimelineGroupId = "direct-group"
        await state.applyTimelineWindow(
            replacement.snapshot() ?? emptyTimelinePage(),
            groupIdHex: "direct-group",
            account: activeAccount,
            client: runtime,
            owner: .subscription(replacement)
        )

        staleSubscription.releasePaginationGate()
        _ = await staleBack

        #expect(state.lastError == nil)
        #expect(state.messagesByChat["direct-group"]?.first?.id == "fresh-error-000")
    }

    @Test func newerTimelinePagingRestoresAnchorInsteadOfScrollingToBottom() {
        let historicalPaging = TimelinePagingState(
            hasMoreBefore: true,
            hasMoreAfter: true,
            isLoadingBefore: false,
            isLoadingAfter: false
        )
        let liveEdgePaging = TimelinePagingState(
            hasMoreBefore: true,
            hasMoreAfter: false,
            isLoadingBefore: false,
            isLoadingAfter: false
        )

        #expect(
            timelineNewestMessageScrollAction(
                messageIDs: ["message-150", "message-249", "message-349"],
                newMessageIsOutgoing: false,
                paging: historicalPaging,
                pendingPrependAnchorId: nil,
                pendingAppendAnchorId: "message-249",
                newMessageId: "message-349",
                isPinnedToBottom: false
            ) == .restorePendingAppendAnchor("message-249"))
        #expect(
            timelineNewestMessageScrollAction(
                messageIDs: ["message-350", "message-449"],
                newMessageIsOutgoing: false,
                paging: historicalPaging,
                pendingPrependAnchorId: nil,
                pendingAppendAnchorId: "message-249",
                newMessageId: "message-449",
                isPinnedToBottom: false
            ) == .clearPendingAppendAnchor)
        #expect(
            timelineNewestMessageScrollAction(
                messageIDs: ["message-350", "message-449"],
                newMessageIsOutgoing: false,
                paging: historicalPaging,
                pendingPrependAnchorId: nil,
                pendingAppendAnchorId: nil,
                newMessageId: "message-449",
                isPinnedToBottom: true
            ) == .none)
        #expect(
            timelineNewestMessageScrollAction(
                messageIDs: ["message-350", "message-449"],
                newMessageIsOutgoing: false,
                paging: liveEdgePaging,
                pendingPrependAnchorId: nil,
                pendingAppendAnchorId: nil,
                newMessageId: "message-449",
                isPinnedToBottom: true
            ) == .scrollToBottom)
    }

    @Test func newestMessageAutoScrollUsesBottomProximityNotOlderHistoryAvailability() {
        let longLiveEdgePaging = TimelinePagingState(
            hasMoreBefore: true,
            hasMoreAfter: false,
            isLoadingBefore: false,
            isLoadingAfter: false
        )
        let detachedHistoryPaging = TimelinePagingState(
            hasMoreBefore: true,
            hasMoreAfter: true,
            isLoadingBefore: false,
            isLoadingAfter: false
        )

        #expect(
            timelineNewestMessageScrollAction(
                messageIDs: ["message-001", "message-101"],
                newMessageIsOutgoing: false,
                paging: longLiveEdgePaging,
                pendingPrependAnchorId: nil,
                pendingAppendAnchorId: nil,
                newMessageId: "message-101",
                isPinnedToBottom: true
            ) == .scrollToBottom)
        #expect(
            timelineNewestMessageScrollAction(
                messageIDs: ["message-001", "message-101"],
                newMessageIsOutgoing: false,
                paging: longLiveEdgePaging,
                pendingPrependAnchorId: nil,
                pendingAppendAnchorId: nil,
                newMessageId: "message-101",
                isPinnedToBottom: false
            ) == .none)
        #expect(
            timelineNewestMessageScrollAction(
                messageIDs: ["message-001", "message-101"],
                newMessageIsOutgoing: true,
                paging: longLiveEdgePaging,
                pendingPrependAnchorId: nil,
                pendingAppendAnchorId: nil,
                newMessageId: "message-101",
                isPinnedToBottom: false
            ) == .scrollToBottom)
        #expect(
            timelineNewestMessageScrollAction(
                messageIDs: ["message-001", "message-101"],
                newMessageIsOutgoing: false,
                paging: detachedHistoryPaging,
                pendingPrependAnchorId: nil,
                pendingAppendAnchorId: nil,
                newMessageId: "message-101",
                isPinnedToBottom: true
            ) == .none)
        #expect(
            timelineNewestMessageScrollAction(
                messageIDs: ["message-001", "message-101"],
                newMessageIsOutgoing: false,
                paging: longLiveEdgePaging,
                pendingPrependAnchorId: "message-000",
                pendingAppendAnchorId: nil,
                newMessageId: "message-101",
                isPinnedToBottom: true
            ) == .none)
    }

    @MainActor
    @Test func latestSubscriptionPageDoesNotReplaceHistoricalTimelineWindow() async throws {
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
        runtime.timelineUpdateDelayNanoseconds = 300_000_000
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
        let baseTime: UInt64 = 1_700_000_000
        let messages = (0..<450).map { index in
            appMessage(
                id: String(format: "message-%03d", index),
                groupIdHex: "direct-group",
                sender: aliceId,
                plaintext: "Message \(index)",
                kind: 9,
                recordedAt: baseTime + UInt64(index)
            )
        }
        runtime.installMessages(messages, groupIdHex: "direct-group")
        runtime.installTimelineUpdates(
            [
                .page(
                    page: TimelinePageFfi(
                        messages: (350..<450).map { index in
                            timelineMessage(
                                id: String(format: "message-%03d", index),
                                groupIdHex: "direct-group",
                                sender: aliceId,
                                plaintext: "Live latest \(index)",
                                recordedAt: baseTime + UInt64(index)
                            )
                        },
                        hasMoreBefore: true,
                        hasMoreAfter: false
                    ))
            ], groupIdHex: "direct-group")
        let state = WorkspaceState(
            appActivityProvider: { true },
            conversationWindowVisibilityProvider: { true },
            clientFactory: { runtime }
        )

        await state.bootstrap()
        await state.loadMessages(groupIdHex: "direct-group")
        await state.loadOlderMessages(groupIdHex: "direct-group")
        await state.loadOlderMessages(groupIdHex: "direct-group")
        await state.loadOlderMessages(groupIdHex: "direct-group")
        try? await Task.sleep(nanoseconds: 500_000_000)

        let loadedIds = state.messagesByChat["direct-group"]?.map(\.id) ?? []
        #expect(loadedIds.count == 200)
        #expect(loadedIds.first == "message-050")
        #expect(loadedIds.last == "message-249")
        #expect(state.selectedTimelinePaging.hasMoreAfter)
        #expect(runtime.markedReadMessageIds == ["message-449"])
    }

    @MainActor
    @Test func projectionUpdateOnlyMutatesVisibleHistoricalMessages() async throws {
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
        runtime.timelineUpdateDelayNanoseconds = 300_000_000
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
        let baseTime: UInt64 = 1_700_000_000
        runtime.installMessages(
            (0..<450).map { index in
                appMessage(
                    id: String(format: "message-%03d", index),
                    groupIdHex: "direct-group",
                    sender: aliceId,
                    plaintext: "Message \(index)",
                    kind: 9,
                    recordedAt: baseTime + UInt64(index)
                )
            },
            groupIdHex: "direct-group"
        )
        let visibleUpdate = timelineMessage(
            id: "message-120",
            groupIdHex: "direct-group",
            sender: aliceId,
            plaintext: "Visible message updated by projection",
            recordedAt: baseTime + 120
        )
        let offscreenLatest = timelineMessage(
            id: "message-500",
            groupIdHex: "direct-group",
            sender: aliceId,
            plaintext: "Offscreen latest message",
            recordedAt: baseTime + 500
        )
        runtime.installTimelineUpdates(
            [
                .projection(
                    update: RuntimeProjectionUpdateFfi(
                        accountIdHex: account.accountIdHex,
                        accountLabel: account.label,
                        update: TimelineProjectionUpdateFfi(
                            groupIdHex: "direct-group",
                            messages: [visibleUpdate, offscreenLatest],
                            changes: [
                                .upsert(trigger: .reactionAdded, message: visibleUpdate),
                                .upsert(trigger: .newMessage, message: offscreenLatest),
                            ],
                            chatListRow: chatListRow(
                                groupIdHex: "direct-group",
                                title: "Alice",
                                preview: "Offscreen latest message",
                                sender: aliceId,
                                timelineAt: baseTime + 500
                            ),
                            chatListTrigger: .newLastMessage
                        )
                    ))
            ], groupIdHex: "direct-group")
        let state = WorkspaceState(
            appActivityProvider: { true },
            conversationWindowVisibilityProvider: { true },
            clientFactory: { runtime }
        )

        await state.bootstrap()
        await state.loadMessages(groupIdHex: "direct-group")
        await state.loadOlderMessages(groupIdHex: "direct-group")
        await state.loadOlderMessages(groupIdHex: "direct-group")
        await state.loadOlderMessages(groupIdHex: "direct-group")
        try? await Task.sleep(nanoseconds: 500_000_000)

        let loadedMessages = state.messagesByChat["direct-group"] ?? []
        #expect(loadedMessages.count == 200)
        #expect(loadedMessages.map(\.id).first == "message-050")
        #expect(loadedMessages.map(\.id).last == "message-249")
        #expect(
            loadedMessages.first(where: { $0.id == "message-120" })?.body == "Visible message updated by projection")
        #expect(!loadedMessages.contains { $0.id == "message-500" })
        #expect(state.selectedTimelinePaging.hasMoreAfter)
        #expect(runtime.markedReadMessageIds == ["message-449"])
    }

    @MainActor
    @Test func timelinePagingRefreshesAnUnnameableSenderOncePerGateWindow() async throws {
        // Paging must not put a relay round-trip on every page. It is no longer "no refresh
        // at all": a sender the local directory cannot name is now fetched from the relays
        // (otherwise their npub is all we would ever show). The guard that replaces it is
        // `PeerProfileRefreshGate` — in-flight dedup plus a backoff ladder — so two pages
        // covering the same unresolved sender cost one fetch, not two.
        let account = AccountSummaryFfi(
            label: "Desktop Account",
            accountIdHex: "abcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890",
            localSigning: true,
            externalSigning: false,
            signedOut: false,
            running: true
        )
        let aliceId = "alice1234567890alice1234567890alice1234567890alice1234567890"
        let bobId = "bob1234567890bob1234567890bob1234567890bob1234567890bob1"
        let runtime = FakeMarmotRuntime(accounts: [account])
        runtime.accountIdsMissingProfiles.insert(bobId)
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
        let baseTime: UInt64 = 1_700_000_000
        runtime.installMessages(
            (0..<105).map { index in
                appMessage(
                    id: String(format: "message-%03d", index),
                    groupIdHex: "direct-group",
                    sender: bobId,
                    plaintext: "Message \(index)",
                    kind: 9,
                    recordedAt: baseTime + UInt64(index)
                )
            },
            groupIdHex: "direct-group"
        )
        let state = WorkspaceState(clientFactory: { runtime })

        // Deliberately no `clearRefreshedProfileIds()` here: opening the conversation is part
        // of bootstrap, so the fetch under test happens before this point and clearing would
        // erase the very evidence the assertions need.
        await state.bootstrap()
        await state.loadMessages(groupIdHex: "direct-group")
        await state.loadOlderMessages(groupIdHex: "direct-group")
        // Drain deterministically instead of racing the queue task against the assertions.
        await state.settlePeerProfileRefreshQueueForTesting()

        // Bob has no published profile, so he is fetched — once in total, across the initial
        // open and both page loads, because the gate dedupes and then backs off.
        #expect(runtime.refreshedProfileIds.filter { $0 == bobId }.count == 1)
        // Alice is already nameable from the local directory, so she costs no relay hop at
        // all: the queue resolves locally first and only falls through on a miss.
        #expect(!runtime.refreshedProfileIds.contains(aliceId))
        #expect(state.messagesByChat["direct-group"]?.first?.id == "message-000")
    }

    @MainActor
    @Test func incompletePeerProfileLookupIsNotPinnedForTheSession() async throws {
        // Regression for #8: an incomplete first sender-profile lookup (relay has not
        // propagated the profile yet, or the lookup failed) must not be cached as a
        // terminal answer. A later pass that has the data available must re-resolve and
        // pick up the real name instead of leaving the contact pinned to its hex fallback.
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
        // Blank group-member display name so the only name source is the profile lookup,
        // and mark alice's profile as not-yet-available for the first pass.
        runtime.installDirectGroup(
            directGroup(),
            selfAccountIdHex: account.accountIdHex,
            otherAccountIdHex: aliceId,
            otherDisplayName: "",
            otherProfile: UserProfileMetadataFfi(
                name: nil,
                displayName: nil,
                about: nil,
                picture: nil,
                nip05: nil,
                lud16: nil
            )
        )
        runtime.accountIdsMissingProfiles.insert(aliceId)
        let baseTime: UInt64 = 1_700_000_000
        runtime.installMessages(
            (0..<150).map { index in
                appMessage(
                    id: String(format: "message-%03d", index),
                    groupIdHex: "direct-group",
                    sender: aliceId,
                    plaintext: "Message \(index)",
                    kind: 9,
                    recordedAt: baseTime + UInt64(index)
                )
            },
            groupIdHex: "direct-group"
        )
        let state = WorkspaceState(clientFactory: { runtime })

        await state.bootstrap()
        await state.loadMessages(groupIdHex: "direct-group")

        let firstPass = state.messagesByChat["direct-group"] ?? []
        let firstAliceName = firstPass.first?.senderName
        // The relay had not propagated the profile, so the contact falls back to a
        // shortened hex id rather than a real display name.
        #expect(firstAliceName != "Alice Cooper")
        #expect(firstAliceName == DisplayText.short(aliceId))

        // The profile becomes available; a subsequent render must re-resolve it.
        runtime.accountIdsMissingProfiles.remove(aliceId)
        runtime.installProfile(
            accountIdHex: aliceId,
            profile: UserProfileMetadataFfi(
                name: "alice",
                displayName: "Alice Cooper",
                about: nil,
                picture: nil,
                nip05: nil,
                lud16: nil
            )
        )
        await state.loadOlderMessages(groupIdHex: "direct-group")

        let secondPass = state.messagesByChat["direct-group"] ?? []
        #expect(secondPass.first?.senderName == "Alice Cooper")
    }

    @MainActor
    @Test func lateArrivingPeerMetadataRelabelsAlreadyRenderedMessages() async throws {
        // The headline fix. `MessageItem.senderName` is baked at projection time and the live
        // delta path re-maps only *changed* records, so before this a name that landed after a
        // message was rendered could never reach it — the npub stayed on every old message for
        // the life of the conversation. A resolved profile now replays the open window through
        // the authoritative snapshot, so every row re-resolves its sender.
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
        // Blank roster name and no profile: the npub fallback is the only name available.
        runtime.installDirectGroup(
            directGroup(),
            selfAccountIdHex: account.accountIdHex,
            otherAccountIdHex: aliceId,
            otherDisplayName: "",
            otherProfile: UserProfileMetadataFfi(
                name: nil,
                displayName: nil,
                about: nil,
                picture: nil,
                nip05: nil,
                lud16: nil
            )
        )
        runtime.accountIdsMissingProfiles.insert(aliceId)
        let baseTime: UInt64 = 1_700_000_000
        runtime.installMessages(
            (0..<40).map { index in
                appMessage(
                    id: String(format: "message-%03d", index),
                    groupIdHex: "direct-group",
                    sender: aliceId,
                    plaintext: "Message \(index)",
                    kind: 9,
                    recordedAt: baseTime + UInt64(index)
                )
            },
            groupIdHex: "direct-group"
        )
        let clock = MutableClock(now: Date(timeIntervalSince1970: 2_000_000_000))
        let state = WorkspaceState(nowProvider: { clock.now }, clientFactory: { runtime })

        await state.bootstrap()
        await state.loadMessages(groupIdHex: "direct-group")
        await state.settlePeerProfileRefreshQueueForTesting()

        // Nothing was published yet, so the whole transcript is stuck on the npub fallback.
        let beforeMetadata = state.messagesByChat["direct-group"] ?? []
        #expect(beforeMetadata.count == 40)
        #expect(beforeMetadata.allSatisfy { $0.senderName == DisplayText.short(aliceId) })
        // The relays were asked, which is what eventually makes the metadata available.
        #expect(runtime.refreshedProfileIds.contains(aliceId))

        // Alice's kind:0 lands. Advance past the gate's first backoff rung so the peer is
        // admitted again, exactly as it would be on any later projection pass.
        runtime.accountIdsMissingProfiles.remove(aliceId)
        runtime.installProfile(
            accountIdHex: aliceId,
            profile: UserProfileMetadataFfi(
                name: "alice",
                displayName: "Alice Cooper",
                about: nil,
                picture: "https://example.com/alice.png",
                nip05: nil,
                lud16: nil
            )
        )
        clock.now = clock.now.addingTimeInterval(PeerProfileRefreshGate.retryCooldown + 1)
        state.requestPeerProfileRefresh([aliceId])
        await state.settlePeerProfileRefreshQueueForTesting()
        await state.runPeerProfileReprojectionForTesting()

        // Every message relabels in place — including the oldest, which no delta would revisit.
        let afterMetadata = state.messagesByChat["direct-group"] ?? []
        #expect(afterMetadata.allSatisfy { $0.senderName == "Alice Cooper" })
        #expect(afterMetadata.first?.senderName == "Alice Cooper")
        // The window is replayed, not reloaded: same rows, same order, same bounds.
        #expect(afterMetadata.map(\.id) == beforeMetadata.map(\.id))
        // The sidebar row for the direct chat picks the peer up too.
        #expect(state.activeChats.first?.title == "Alice Cooper")
        #expect(state.activeChats.first?.pictureURL == "https://example.com/alice.png")
    }

    /// A mention is baked into the bubble's attributed string when the window is projected, so
    /// nicknaming someone the open conversation mentions has to reach rows already on screen.
    /// Every earlier message has to change, including ones no live delta would ever revisit, and
    /// clearing the nickname has to give the published name back.
    @MainActor
    @Test func nicknamingAMentionedMemberRepaintsTheOpenTranscript() async throws {
        let account = AccountSummaryFfi(
            label: "Desktop Account",
            accountIdHex: "abcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890",
            localSigning: true,
            externalSigning: false,
            signedOut: false,
            running: true
        )
        let aliceId = "alice1234567890alice1234567890alice1234567890alice1234567890"
        let aliceNpub = "npub1alyce"
        let runtime = FakeMarmotRuntime(accounts: [account])
        runtime.installDirectGroup(
            directGroup(),
            selfAccountIdHex: account.accountIdHex,
            otherAccountIdHex: aliceId,
            otherDisplayName: "Alice Cooper",
            otherProfile: UserProfileMetadataFfi(
                name: "alice",
                displayName: "Alice Cooper",
                about: nil,
                picture: nil,
                nip05: nil,
                lud16: nil
            )
        )
        let mentionTokens = MarkdownDocumentFfi(
            blocks: [
                .paragraph(inlines: [
                    .text(content: "ping "),
                    .nostrMention(entity: MarkdownNostrEntityFfi(hrp: .npub, bech32: aliceNpub)),
                ])
            ],
            truncated: false
        )
        let baseTime: UInt64 = 1_700_000_000
        runtime.installMessages(
            (0..<3).map { index in
                appMessage(
                    id: "message-\(index)",
                    groupIdHex: "direct-group",
                    sender: aliceId,
                    plaintext: "ping @\(aliceNpub)",
                    contentTokens: mentionTokens,
                    kind: 9,
                    recordedAt: baseTime + UInt64(index)
                )
            },
            groupIdHex: "direct-group"
        )
        let nicknames = isolatedContactNicknameStore()
        defer { try? FileManager.default.removeItem(at: nicknames.directoryURL) }
        let state = WorkspaceState(contactNicknameStore: nicknames.store, clientFactory: { runtime })

        await state.bootstrap()
        await state.loadMessages(groupIdHex: "direct-group")

        func renderedMentions() -> [String] {
            (state.messagesByChat["direct-group"] ?? []).map { message in
                message.contentMarkdown?.inlineParagraph.map { String($0.characters) } ?? ""
            }
        }

        #expect(renderedMentions() == Array(repeating: "ping @Alice Cooper", count: 3))
        let projectedIds = (state.messagesByChat["direct-group"] ?? []).map(\.id)

        state.setContactNickname("Mum", forContactAccountIdHex: aliceId)

        #expect(renderedMentions() == Array(repeating: "ping @Mum", count: 3))
        // Relabeled, not reloaded: the same rows in the same order.
        #expect((state.messagesByChat["direct-group"] ?? []).map(\.id) == projectedIds)

        state.setContactNickname(nil, forContactAccountIdHex: aliceId)

        #expect(renderedMentions() == Array(repeating: "ping @Alice Cooper", count: 3))
    }

    /// The regression behind "I renamed a member, came back to the chat, and the old mentions still
    /// showed the old name; it only fixed itself after I navigated away and back".
    ///
    /// A rename must reach the mentions in a materialized window with no live timeline
    /// subscription to snapshot — the state between a listener teardown and its next subscribe,
    /// during a reconnect, or whenever the runtime has no window to hand back. The transcript is
    /// still on screen throughout, and re-selecting the conversation (which re-projects from
    /// scratch) is exactly the workaround this test forbids. It also has to be free of FFI: the
    /// rows are rewritten in place, not re-fetched.
    @MainActor
    @Test func nicknamingAMentionedGroupMemberRelabelsWithoutReplayingTheWindow() async throws {
        let account = AccountSummaryFfi(
            label: "Desktop Account",
            accountIdHex: "abcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890",
            localSigning: true,
            externalSigning: false,
            signedOut: false,
            running: true
        )
        let aliceId = "alice1234567890alice1234567890alice1234567890alice1234567890"
        let bobId = "bob1234567890bob1234567890bob1234567890bob1234567890bob1"
        let runtime = FakeMarmotRuntime(accounts: [account])
        runtime.installGroupDetails(groupDetailsFixture(selfAccountIdHex: account.accountIdHex))
        let mentionTokens = MarkdownDocumentFfi(
            blocks: [
                .paragraph(inlines: [
                    .text(content: "ping "),
                    .nostrMention(entity: MarkdownNostrEntityFfi(hrp: .npub, bech32: "npub1alyce")),
                ])
            ],
            truncated: false
        )
        let baseTime: UInt64 = 1_700_000_000
        runtime.installMessages(
            (0..<3).map { index in
                appMessage(
                    id: "message-\(index)",
                    groupIdHex: "group",
                    sender: bobId,
                    plaintext: "ping @npub1alyce",
                    contentTokens: mentionTokens,
                    kind: 9,
                    recordedAt: baseTime + UInt64(index)
                )
            },
            groupIdHex: "group"
        )
        let nicknames = isolatedContactNicknameStore()
        defer { try? FileManager.default.removeItem(at: nicknames.directoryURL) }
        let state = WorkspaceState(contactNicknameStore: nicknames.store, clientFactory: { runtime })

        await state.bootstrap()
        await state.loadMessages(groupIdHex: "group")

        func renderedMentions() -> [String] {
            (state.messagesByChat["group"] ?? []).map { message in
                message.contentMarkdown?.inlineParagraph.map { String($0.characters) } ?? ""
            }
        }

        #expect(renderedMentions() == Array(repeating: "ping @Alice", count: 3))
        let projectedIds = (state.messagesByChat["group"] ?? []).map(\.id)

        // The transcript stays on screen, but there is no subscription left to snapshot.
        state.stopTimelineListener()
        #expect(state.activeTimelineSubscription == nil)
        runtime.clearSyncCallThreadRecords()
        runtime.clearTimelineMessageQueries()
        let buildsBefore = state.messageTimelineStores["group"]?.displayItemsBuildCount ?? 0

        state.setContactNickname("Mum", forContactAccountIdHex: aliceId)

        // Landed on the gesture, with no window fetched and no re-anchoring of the window.
        #expect(renderedMentions() == Array(repeating: "ping @Mum", count: 3))
        #expect((state.messagesByChat["group"] ?? []).map(\.id) == projectedIds)
        #expect(runtime.syncCallThreadRecord("timelineMessagesSubscription.snapshot").isEmpty)
        #expect(runtime.timelineMessageQueries.isEmpty)
        #expect(state.messageTimelineStores["group"]?.displayItemsBuildCount == buildsBefore + 1)

        // The mention keeps everything the projection gave it besides the label: it is still a
        // tappable `nostr:` reference to the same person, still emphasized, still colored.
        let relabeled = try #require((state.messagesByChat["group"] ?? []).first?.contentMarkdown?.inlineParagraph)
        let mentionRun = relabeled.runs.first { $0.link != nil }
        #expect(mentionRun?.link == MarkdownLinkPolicy.nostrURL(for: "npub1alyce"))
        #expect(mentionRun?.inlinePresentationIntent?.contains(.stronglyEmphasized) == true)
        #expect(mentionRun?.foregroundColor == MentionTextPalette.foreground)

        // Renaming somebody this conversation neither mentions nor lists must not touch a row.
        let buildsAfterRename = state.messageTimelineStores["group"]?.displayItemsBuildCount ?? 0
        state.setContactNickname("Carol", forContactAccountIdHex: String(repeating: "c0", count: 32))
        #expect(state.messageTimelineStores["group"]?.displayItemsBuildCount == buildsAfterRename)

        // Renaming the *sender* relabels their name above the bubble (`relabelTimelineSenders`)
        // and must leave the mention inside it alone.
        state.setContactNickname("Bobby", forContactAccountIdHex: bobId)
        #expect(renderedMentions() == Array(repeating: "ping @Mum", count: 3))
        #expect((state.messagesByChat["group"] ?? []).allSatisfy { $0.senderName == "Bobby" })

        // Clearing hands the label back to the name the member published.
        state.setContactNickname(nil, forContactAccountIdHex: aliceId)
        #expect(renderedMentions() == Array(repeating: "ping @Alice", count: 3))
    }

    /// The in-place relabel has to agree with what a full re-projection of the same window would
    /// produce, or the label would flip back on the next delta. Renaming with no subscription and
    /// then re-projecting the window must land on the same text.
    @MainActor
    @Test func mentionRelabelMatchesTheNextReprojectionOfTheWindow() async throws {
        let account = AccountSummaryFfi(
            label: "Desktop Account",
            accountIdHex: "abcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890",
            localSigning: true,
            externalSigning: false,
            signedOut: false,
            running: true
        )
        let aliceId = "alice1234567890alice1234567890alice1234567890alice1234567890"
        let bobId = "bob1234567890bob1234567890bob1234567890bob1234567890bob1"
        let runtime = FakeMarmotRuntime(accounts: [account])
        runtime.installGroupDetails(groupDetailsFixture(selfAccountIdHex: account.accountIdHex))
        let mentionTokens = MarkdownDocumentFfi(
            blocks: [
                .paragraph(inlines: [
                    .text(content: "ping "),
                    .nostrMention(entity: MarkdownNostrEntityFfi(hrp: .npub, bech32: "npub1alyce")),
                ])
            ],
            truncated: false
        )
        runtime.installMessages(
            [
                appMessage(
                    id: "message-0",
                    groupIdHex: "group",
                    sender: bobId,
                    plaintext: "ping @npub1alyce",
                    contentTokens: mentionTokens,
                    kind: 9,
                    recordedAt: 1_700_000_000
                )
            ],
            groupIdHex: "group"
        )
        let nicknames = isolatedContactNicknameStore()
        defer { try? FileManager.default.removeItem(at: nicknames.directoryURL) }
        let state = WorkspaceState(contactNicknameStore: nicknames.store, clientFactory: { runtime })

        await state.bootstrap()
        await state.loadMessages(groupIdHex: "group")

        func renderedMention() -> String? {
            (state.messagesByChat["group"] ?? []).first?.contentMarkdown?.inlineParagraph
                .map { String($0.characters) }
        }

        state.stopTimelineListener()
        state.setContactNickname("Mum", forContactAccountIdHex: aliceId)
        let afterRelabel = renderedMention()
        #expect(afterRelabel == "ping @Mum")

        await state.loadMessages(groupIdHex: "group")
        #expect(renderedMention() == afterRelabel)
    }

    @MainActor
    @Test func steadyStatePeerProfileRefreshMakesNoRequestsAcrossWindowsAndDeltas() async throws {
        // The render/projection paths call `requestPeerProfileRefresh` unconditionally, so the
        // completeness short-circuit is what keeps them affordable. With every sender already
        // nameable, repeated windows and live deltas must admit nothing at all.
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
                displayName: "Alice Cooper",
                about: nil,
                picture: nil,
                nip05: nil,
                lud16: nil
            )
        )
        let baseTime: UInt64 = 1_700_000_000
        runtime.installMessages(
            (0..<30).map { index in
                appMessage(
                    id: String(format: "message-%03d", index),
                    groupIdHex: "direct-group",
                    sender: aliceId,
                    plaintext: "Message \(index)",
                    kind: 9,
                    recordedAt: baseTime + UInt64(index)
                )
            },
            groupIdHex: "direct-group"
        )
        let state = WorkspaceState(clientFactory: { runtime })

        await state.bootstrap()
        await state.loadMessages(groupIdHex: "direct-group")
        await state.settlePeerProfileRefreshQueueForTesting()

        let settledRequestCount = state.peerProfileRefreshRequestCount
        await state.loadOlderMessages(groupIdHex: "direct-group")
        await state.loadMessages(groupIdHex: "direct-group")
        await state.settlePeerProfileRefreshQueueForTesting()

        #expect(state.peerProfileRefreshRequestCount == settledRequestCount)
        #expect(!runtime.refreshedProfileIds.contains(aliceId))
        #expect(state.messagesByChat["direct-group"]?.first?.senderName == "Alice Cooper")
    }

    @MainActor
    @Test func reactionAuthorProfilesAreRequestedFromTheProjectionNotTheRenderPath() async throws {
        // `reactionReactorDisplay` runs inside a SwiftUI view body, once per reactor per render
        // pass, so it must stay a pure read. The request for a reactor who never sent a message
        // is issued from `messageSenderProfiles` instead — once per window/delta.
        let account = AccountSummaryFfi(
            label: "Desktop Account",
            accountIdHex: "abcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890",
            localSigning: true,
            externalSigning: false,
            signedOut: false,
            running: true
        )
        let aliceId = "alice1234567890alice1234567890alice1234567890alice1234567890"
        let reactorId = "carol1234567890carol1234567890carol1234567890carol1234567890"
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
        // Carol only ever reacts — she is not in `senderIds`, so before this she was never
        // resolved at all and her row was stuck on the npub no matter how long you waited.
        runtime.accountIdsMissingProfiles.insert(reactorId)
        let baseTime: UInt64 = 1_700_000_000
        runtime.installMessages(
            [
                appMessage(
                    id: "message-000",
                    groupIdHex: "direct-group",
                    sender: aliceId,
                    plaintext: "Hello",
                    kind: 9,
                    recordedAt: baseTime
                ),
                appMessage(
                    id: "reaction-000",
                    groupIdHex: "direct-group",
                    sender: reactorId,
                    plaintext: "👍",
                    kind: 7,
                    tags: [MessageTagFfi(values: ["e", "message-000"])],
                    recordedAt: baseTime + 1
                ),
            ],
            groupIdHex: "direct-group"
        )
        let state = WorkspaceState(clientFactory: { runtime })

        await state.bootstrap()
        await state.loadMessages(groupIdHex: "direct-group")
        await state.settlePeerProfileRefreshQueueForTesting()

        // The projection path asked for the reactor.
        #expect(runtime.refreshedProfileIds.contains(reactorId))

        // Rendering her row asks for nothing: no admission, no queue, no relay hop.
        let requestsBeforeRender = state.peerProfileRefreshRequestCount
        let reactor = state.reactionReactorDisplay(accountIdHex: reactorId)
        #expect(state.peerProfileRefreshRequestCount == requestsBeforeRender)
        #expect(state.queuedPeerProfileRefreshIds.isEmpty)
        #expect(reactor.accountIdHex == reactorId)
    }

    @MainActor
    @Test func peerProfileResolutionsWithinTheDebounceWindowCostOneReprojection() async throws {
        // A roster resolving one member at a time must repaint once, not once per member.
        let account = AccountSummaryFfi(
            label: "Desktop Account",
            accountIdHex: "abcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890",
            localSigning: true,
            externalSigning: false,
            signedOut: false,
            running: true
        )
        let runtime = FakeMarmotRuntime(accounts: [account])
        let state = WorkspaceState(clientFactory: { runtime })
        await state.bootstrap()

        let baseline = state.peerProfileReprojectionCount
        state.schedulePeerProfileReprojection(ids: ["peer-a"])
        state.schedulePeerProfileReprojection(ids: ["peer-b"])
        state.schedulePeerProfileReprojection(ids: ["peer-c"])
        // Three bumps, one coalesced pass — and the generation still moves once per resolution
        // so view-level observers see each change.
        #expect(state.peerProfileGeneration >= 3)

        await state.runPeerProfileReprojectionForTesting()
        #expect(state.peerProfileReprojectionCount == baseline + 1)
        #expect(state.pendingPeerProfileReprojectionIds.isEmpty)
    }

    @MainActor
    @Test func resolvingAPeerTheOpenWindowNeverNamesSkipsTheTranscriptReplay() async throws {
        // Most refresh requests come from rosters and reaction lists, not from anyone the open
        // transcript labels: a 40-member group whose members have never posted, or reactors
        // whose rows read `peerProfileFFICache` directly and repaint on their own. Replaying
        // the window for those re-maps and re-diffs every row to produce identical output —
        // once per debounce window for the whole length of a drain.
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
            otherDisplayName: "Alice Cooper",
            otherProfile: UserProfileMetadataFfi(
                name: "alice",
                displayName: "Alice Cooper",
                about: nil,
                picture: nil,
                nip05: nil,
                lud16: nil
            )
        )
        runtime.installMessages(
            (0..<10).map { index in
                appMessage(
                    id: String(format: "message-%03d", index),
                    groupIdHex: "direct-group",
                    sender: aliceId,
                    plaintext: "Message \(index)",
                    kind: 9,
                    recordedAt: 1_700_000_000 + UInt64(index)
                )
            },
            groupIdHex: "direct-group"
        )
        let state = WorkspaceState(clientFactory: { runtime })
        await state.bootstrap()
        await state.loadMessages(groupIdHex: "direct-group")
        await state.settlePeerProfileRefreshQueueForTesting()

        // `snapshot()` is the first thing the transcript replay does, so counting it is a
        // direct witness for whether the window was replayed at all.
        let replaysBefore = runtime.syncCallThreadRecord("timelineMessagesSubscription.snapshot").count

        // A peer nobody in this window is labelled from.
        state.schedulePeerProfileReprojection(ids: ["bob12345678901234567890bob12345678901234567890bob1234567890"])
        await state.runPeerProfileReprojectionForTesting()
        let replaysAfterUnrelatedPeer =
            runtime.syncCallThreadRecord("timelineMessagesSubscription.snapshot").count
        #expect(replaysAfterUnrelatedPeer == replaysBefore)

        // The sender the window *does* name still replays — the guard scopes the work, it
        // does not withhold the fix.
        state.schedulePeerProfileReprojection(ids: [aliceId])
        await state.runPeerProfileReprojectionForTesting()
        let replaysAfterWindowSender =
            runtime.syncCallThreadRecord("timelineMessagesSubscription.snapshot").count
        #expect(replaysAfterWindowSender > replaysAfterUnrelatedPeer)
    }

    @MainActor
    @Test func clearingANicknameReArmsTheMetadataFetchTheCooldownWasHoldingOff() async throws {
        // Clearing a nickname hands the label back to whatever the peer published, so a missing
        // kind:0 starts mattering again at exactly that moment. The gate may be sitting on a
        // cooldown for this id — possibly the long one applied *because* it was nicknamed — and
        // without dropping that admission state the row keeps the npub until the cooldown ends.
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
            otherDisplayName: "",
            otherProfile: UserProfileMetadataFfi(
                name: nil,
                displayName: nil,
                about: nil,
                picture: nil,
                nip05: nil,
                lud16: nil
            )
        )
        runtime.accountIdsMissingProfiles.insert(aliceId)
        let state = WorkspaceState(clientFactory: { runtime })
        await state.bootstrap()
        await state.settlePeerProfileRefreshQueueForTesting()

        state.setContactNickname("Ali", forContactAccountIdHex: aliceId)
        #expect(state.activeChats.first?.title == "Ali")

        // Alice publishes while the nickname is in place, and the gate is holding a cooldown
        // from the run that already failed for her.
        runtime.accountIdsMissingProfiles.remove(aliceId)
        runtime.installProfile(
            accountIdHex: aliceId,
            profile: UserProfileMetadataFfi(
                name: "alice",
                displayName: "Alice Cooper",
                about: nil,
                picture: nil,
                nip05: nil,
                lud16: nil
            )
        )
        let requestsBefore = state.peerProfileRefreshRequestCount
        state.setContactNickname(nil, forContactAccountIdHex: aliceId)
        #expect(state.peerProfileRefreshRequestCount > requestsBefore)

        await state.settlePeerProfileRefreshQueueForTesting()
        await state.runPeerProfileReprojectionForTesting()

        // The row lands on the published name rather than sitting on the fallback.
        #expect(state.activeChats.first?.title == "Alice Cooper")
    }

    @MainActor
    @Test func peerProfileRefreshFetchesFromSeedAndAccountNip65Relays() async throws {
        // Seed relays alone miss a peer who publishes only to their own NIP-65 write relays.
        let account = AccountSummaryFfi(
            label: "Desktop Account",
            accountIdHex: "abcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890",
            localSigning: true,
            externalSigning: false,
            signedOut: false,
            running: true
        )
        let bobId = "bob1234567890bob1234567890bob1234567890bob1234567890bob1"
        let runtime = FakeMarmotRuntime(accounts: [account])
        runtime.installAccountNip65Relays(["wss://alice.relay.example"])
        runtime.accountIdsMissingProfiles.insert(bobId)
        let state = WorkspaceState(clientFactory: { runtime })

        await state.bootstrap()
        state.requestPeerProfileRefresh([bobId])
        await state.settlePeerProfileRefreshQueueForTesting()

        let relays = runtime.lastProfileRefreshRelays
        #expect(relays.contains("wss://alice.relay.example"))
        #expect(MarmotClient.seedRelays.allSatisfy { relays.contains($0) })
        // Deduped: the seed relays also appear in the account's bootstrap list.
        #expect(relays.count == Set(relays).count)
    }

    @MainActor
    @Test func editingRelaysRebuildsThePeerProfileLookupUnion() async throws {
        // `peerProfileLookupRelays(for:)` memoizes the seed + NIP-65 union for the session, so
        // editing relays in Settings would otherwise keep searching the pre-edit set for peer
        // kind:0 until the next account switch.
        let account = AccountSummaryFfi(
            label: "Desktop Account",
            accountIdHex: "abcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890",
            localSigning: true,
            externalSigning: false,
            signedOut: false,
            running: true
        )
        let bobId = "bob1234567890bob1234567890bob1234567890bob1234567890bob1"
        let carolId = "caro1234567890caro1234567890caro1234567890caro1234567890caro"
        let runtime = FakeMarmotRuntime(accounts: [account])
        runtime.installAccountNip65Relays(["wss://old.relay.example"])
        runtime.accountIdsMissingProfiles.insert(bobId)
        runtime.accountIdsMissingProfiles.insert(carolId)
        let state = WorkspaceState(clientFactory: { runtime })

        await state.bootstrap()
        state.requestPeerProfileRefresh([bobId])
        await state.settlePeerProfileRefreshQueueForTesting()
        #expect(runtime.lastProfileRefreshRelays.contains("wss://old.relay.example"))

        // The user edits their profile relay set in Settings: adds one, drops the old one.
        await state.addRelay("wss://new.relay.example", roles: [.profile])
        await state.setRelayRole(.profile, isEnabled: false, forRelay: "wss://old.relay.example")

        state.requestPeerProfileRefresh([carolId])
        await state.settlePeerProfileRefreshQueueForTesting()

        let relays = runtime.lastProfileRefreshRelays
        #expect(relays.contains("wss://new.relay.example"))
        #expect(!relays.contains("wss://old.relay.example"))
        // The seed relays are still folded in, and the union is still deduped.
        #expect(MarmotClient.seedRelays.allSatisfy { relays.contains($0) })
        #expect(relays.count == Set(relays).count)
    }

    @MainActor
    @Test func anAbortedRefreshHandsBackItsGateSlotInsteadOfStrandingThePeer() async throws {
        // `tryStart` marks the id in flight, and the abort paths in `refreshPeerProfile` return
        // without recording an outcome. Leaving the slot held would make the gate refuse that
        // id for the life of the process — the peer's name could never resolve again.
        //
        // Reachable: `restoreOrSelectFirstAccount` and the preferred-account login path both
        // move `activeAccountId` without going through `resetActiveAccountUIState`, so they
        // never call `clearPeerProfileRefreshState` to sweep the slot on their way past.
        let first = AccountSummaryFfi(
            label: "First Account",
            accountIdHex: "abcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890",
            localSigning: true,
            externalSigning: false,
            signedOut: false,
            running: true
        )
        let second = AccountSummaryFfi(
            label: "Second Account",
            accountIdHex: "1234567890abcdef1234567890abcdef1234567890abcdef1234567890abcd",
            localSigning: true,
            externalSigning: false,
            signedOut: false,
            running: true
        )
        let bobId = "bob1234567890bob1234567890bob1234567890bob1234567890bob1"
        let runtime = FakeMarmotRuntime(accounts: [first, second])
        runtime.accountIdsMissingProfiles.insert(bobId)
        // Hold the attempt inside the relay round-trip so the account can move underneath it.
        runtime.profileRefreshDelaysByAccountId[bobId] = 400_000_000
        let state = WorkspaceState(clientFactory: { runtime })
        await state.bootstrap()

        let startingAccountId = try #require(state.activeAccountId)
        state.requestPeerProfileRefresh([bobId])
        // Let the queue task get as far as the suspended `refreshProfile`.
        try await Task.sleep(nanoseconds: 80_000_000)
        #expect(state.peerProfileRefreshGate.inFlightCountForTesting == 1)

        // Exactly what `restoreOrSelectFirstAccount` does — move the active account without
        // going anywhere near `clearPeerProfileRefreshState`.
        let otherAccountId = try #require(state.accounts.first { $0.id != startingAccountId }?.id)
        state.activeAccountId = otherAccountId

        await state.settlePeerProfileRefreshQueueForTesting()

        // The aborted attempt handed its slot back rather than stranding the peer.
        #expect(state.peerProfileRefreshGate.inFlightCountForTesting == 0)

        // Proof that it is really usable again: with the account restored, the same peer is
        // admitted and actually fetched instead of being refused for the rest of the session.
        state.activeAccountId = startingAccountId
        runtime.clearRefreshedProfileIds()
        runtime.profileRefreshDelaysByAccountId[bobId] = nil
        state.requestPeerProfileRefresh([bobId])
        await state.settlePeerProfileRefreshQueueForTesting()

        #expect(runtime.refreshedProfileIds.contains(bobId))
    }

    @MainActor
    @Test func peerProfileRefreshStateIsDroppedOnAccountSwitch() async throws {
        // Admission cooldowns, the queue, and the relay-set cache are all scoped to the active
        // account's directory view, exactly like `peerProfileFFICache` (#8/#9).
        let first = AccountSummaryFfi(
            label: "First Account",
            accountIdHex: "abcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890",
            localSigning: true,
            externalSigning: false,
            signedOut: false,
            running: true
        )
        let second = AccountSummaryFfi(
            label: "Second Account",
            accountIdHex: "fedcba0987654321fedcba0987654321fedcba0987654321fedcba0987654321",
            localSigning: true,
            externalSigning: false,
            signedOut: false,
            running: true
        )
        let bobId = "bob1234567890bob1234567890bob1234567890bob1234567890bob1"
        let runtime = FakeMarmotRuntime(accounts: [first, second])
        runtime.accountIdsMissingProfiles.insert(bobId)
        let state = WorkspaceState(clientFactory: { runtime })

        await state.bootstrap()
        state.requestPeerProfileRefresh([bobId])
        #expect(!state.queuedPeerProfileRefreshIds.isEmpty || state.peerProfileRefreshTask != nil)

        guard let secondAccount = state.accounts.first(where: { $0.accountIdHex == second.accountIdHex }) else {
            Issue.record("second account missing")
            return
        }
        state.prepareForActiveAccountSwitch(to: secondAccount, preservingMessageCacheFor: nil)

        #expect(state.queuedPeerProfileRefreshIds.isEmpty)
        #expect(state.peerProfileRefreshTask == nil)
        #expect(state.peerProfileFFICache.isEmpty)
        // The cooldown from the previous account must not suppress the new account's first ask.
        var gate = state.peerProfileRefreshGate
        let admittedUnderNewAccount = gate.tryStart(bobId, now: Date(timeIntervalSince1970: 1_000))
        #expect(admittedUnderNewAccount)

        // The switch cancels any in-flight re-projection debounce. Releasing that slot on
        // cancellation is what keeps re-projection alive: a wedged slot would make the
        // `peerProfileReprojectionTask == nil` guard swallow every later resolution.
        state.schedulePeerProfileReprojection(ids: ["peer-after-switch"])
        #expect(state.peerProfileReprojectionTask != nil)
    }

    @MainActor
    @Test func completePeerProfileIsRefreshedAfterCacheTTLExpires() async throws {
        // Regression for #8: a complete sender-profile lookup is cached, but the cache is
        // not a permanent "seen" flag. Once the TTL elapses the profile is re-resolved so
        // a contact's later display-name change is picked up within the same session.
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
            otherDisplayName: "",
            otherProfile: UserProfileMetadataFfi(
                name: nil,
                displayName: nil,
                about: nil,
                picture: nil,
                nip05: nil,
                lud16: nil
            )
        )
        runtime.installProfile(
            accountIdHex: aliceId,
            profile: UserProfileMetadataFfi(
                name: "alice",
                displayName: "Alice",
                about: nil,
                picture: nil,
                nip05: nil,
                lud16: nil
            )
        )
        let baseTime: UInt64 = 1_700_000_000
        runtime.installMessages(
            (0..<350).map { index in
                appMessage(
                    id: String(format: "message-%03d", index),
                    groupIdHex: "direct-group",
                    sender: aliceId,
                    plaintext: "Message \(index)",
                    kind: 9,
                    recordedAt: baseTime + UInt64(index)
                )
            },
            groupIdHex: "direct-group"
        )
        // Drive the cache clock from the test so TTL expiry is deterministic.
        let clock = MutableClock(now: Date(timeIntervalSince1970: 2_000_000_000))
        let state = WorkspaceState(nowProvider: { clock.now }, clientFactory: { runtime })

        await state.bootstrap()
        await state.loadMessages(groupIdHex: "direct-group")
        #expect(state.messagesByChat["direct-group"]?.first?.senderName == "Alice")

        // Alice renames herself. A render inside the TTL keeps the cached name.
        runtime.installProfile(
            accountIdHex: aliceId,
            profile: UserProfileMetadataFfi(
                name: "alice",
                displayName: "Alice Renamed",
                about: nil,
                picture: nil,
                nip05: nil,
                lud16: nil
            )
        )
        clock.now = clock.now.addingTimeInterval(60)
        await state.loadOlderMessages(groupIdHex: "direct-group")
        #expect(state.messagesByChat["direct-group"]?.first?.senderName == "Alice")

        // Once the TTL elapses, the next render re-resolves and reflects the new name.
        clock.now = clock.now.addingTimeInterval(600)
        await state.loadOlderMessages(groupIdHex: "direct-group")
        #expect(state.messagesByChat["direct-group"]?.first?.senderName == "Alice Renamed")
    }

    @MainActor
    @Test func freshlyResolvedPeerProfileIsStampedAfterTheFfiBatch() async throws {
        // Regression for #181: `messageSenderProfiles` must stamp newly-resolved cache
        // entries with a timestamp sampled *after* the off-main resolution batch, not
        // before it. Sampling before means a slow batch (cold cache, relay-backed
        // directory lookups) is charged against the entry's TTL the instant it is written.
        // In the pathological case where one batch exceeds the 300 s TTL, a pre-batch stamp
        // makes the entry stale on arrival, forcing an immediate re-resolution and defeating
        // the cache. The fix keeps a freshly-resolved entry fresh.
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
        runtime.installProfile(
            accountIdHex: aliceId,
            profile: UserProfileMetadataFfi(
                name: "alice",
                displayName: "Alice",
                about: nil,
                picture: nil,
                nip05: nil,
                lud16: nil
            )
        )
        let baseTime: UInt64 = 1_700_000_000
        runtime.installMessages(
            (0..<350).map { index in
                appMessage(
                    id: String(format: "message-%03d", index),
                    groupIdHex: "direct-group",
                    sender: aliceId,
                    plaintext: "Message \(index)",
                    kind: 9,
                    recordedAt: baseTime + UInt64(index)
                )
            },
            groupIdHex: "direct-group"
        )

        // Drive the cache clock from the test via a thread-safe clock so the off-main batch
        // hook can advance it. Model a pathologically slow batch: the single timeline-sender
        // resolution burns more wall-clock time than the whole 300 s TTL. A pre-batch stamp
        // would be born already-expired; a post-batch stamp survives.
        let clock = ConcurrentClock(now: Date(timeIntervalSince1970: 2_000_000_000))
        let slowBatchSeconds = WorkspaceState.peerProfileCacheTTL + 100
        let state = WorkspaceState(nowProvider: { clock.now }, clientFactory: { runtime })

        await state.bootstrap()
        // Bootstrap enriches the direct-chat row through `resolvedPeerFFI`; clear that cache
        // entry so this regression exercises `messageSenderProfiles` itself. Page an older
        // timeline window after clearing the cache: reloading the already-open conversation
        // can reuse the current window and avoid the sender-profile path entirely.
        state.peerProfileFFICache.removeAll()
        runtime.onUserProfileLookup = { [clock] _ in
            clock.advance(by: slowBatchSeconds)
        }
        await state.loadOlderMessages(groupIdHex: "direct-group")
        #expect(state.messagesByChat["direct-group"]?.first?.senderName == "Alice")

        // The entry must be stamped at (or after) the moment resolution finished, i.e. after
        // the clock was advanced by the slow batch — never with the pre-batch timestamp.
        let resolvedAt = try #require(state.peerProfileFFICache[aliceId]?.resolvedAt)
        #expect(resolvedAt.timeIntervalSince1970 >= 2_000_000_000 + slowBatchSeconds)

        // The cache is no longer warming, so further passes don't advance the clock. With a
        // correct post-batch stamp the entry is still fresh, so no re-resolution occurs.
        runtime.onUserProfileLookup = nil
        let userProfileCallsAfterFirstResolve = runtime.userProfileCallCount
        await state.loadOlderMessages(groupIdHex: "direct-group")
        #expect(state.messagesByChat["direct-group"]?.first?.senderName == "Alice")
        #expect(runtime.userProfileCallCount == userProfileCallsAfterFirstResolve)
    }

    @MainActor
    @Test func messageActionsDoNotRestartLiveSubscriptions() async throws {
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
        let state = WorkspaceState(clientFactory: { runtime })
        let message = MessageItem(
            id: "parent",
            senderName: "Desktop Account",
            body: "The launch plan is ready.",
            sentAt: Date(timeIntervalSince1970: 1_700_000_000),
            isOutgoing: true
        )

        await state.bootstrap()
        await state.loadMessages(groupIdHex: "direct-group")
        let chatListSubscriptionCount = runtime.chatListSubscriptionCount
        let timelineSubscriptionCount = runtime.timelineSubscriptionCount

        await state.react(to: message, emoji: "👍")
        await state.deleteForEveryone(message)

        #expect(runtime.chatListSubscriptionCount == chatListSubscriptionCount)
        #expect(runtime.timelineSubscriptionCount == timelineSubscriptionCount)
    }

    @MainActor
    @Test func replyingToMessageSendsDraftAsReplyAndClearsReplyTarget() async throws {
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
        let state = WorkspaceState(clientFactory: { runtime })

        await state.bootstrap()
        state.startReply(
            to: MessageItem(
                id: "parent",
                senderName: "Alice",
                body: "The launch plan is ready.",
                sentAt: Date(timeIntervalSince1970: 1_700_000_000),
                isOutgoing: false
            ))
        state.draftText = "Looks good to me."
        await state.sendDraft()
        await Self.settleOutgoingTextSends(state)

        #expect(
            runtime.repliedMessage
                == SentReply(
                    groupIdHex: "direct-group",
                    targetMessageId: "parent",
                    text: "Looks good to me."
                ))
        #expect(state.replyDraftContext == nil)
        #expect(state.draftText.isEmpty)
    }

    @MainActor
    @Test func editingMessageUsesComposerAndRestoresPreservedDraft() async throws {
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
        let state = WorkspaceState(clientFactory: { runtime })
        await state.bootstrap()
        let preservedReplyTarget = MessageItem(
            id: "reply-target",
            senderName: "Alice",
            body: "Keep this reply queued.",
            sentAt: Date(timeIntervalSince1970: 1_699_999_900),
            isOutgoing: false
        )
        state.startReply(to: preservedReplyTarget)
        state.draftText = "Preserved draft"
        state.startEditingMessage(
            MessageItem(
                id: "message-to-edit",
                senderName: "You",
                body: "Original text",
                sentAt: Date(timeIntervalSince1970: 1_700_000_000),
                isOutgoing: true
            ))

        #expect(state.editingMessageContext?.targetMessageId == "message-to-edit")
        #expect(state.draftText == "Original text")
        #expect(state.replyDraftContext == nil)

        state.startEditingMessage(
            MessageItem(
                id: "replacement-edit",
                senderName: "You",
                body: "Do not replace the active edit",
                sentAt: Date(timeIntervalSince1970: 1_700_000_100),
                isOutgoing: true
            ))

        #expect(state.editingMessageContext?.targetMessageId == "message-to-edit")
        #expect(state.draftText == "Original text")

        state.draftText = "Updated text"
        await state.sendDraft()

        #expect(
            runtime.editedMessage
                == EditedMessage(
                    groupIdHex: "direct-group",
                    targetMessageId: "message-to-edit",
                    content: "Updated text"
                ))
        #expect(state.editingMessageContext == nil)
        #expect(state.draftText == "Preserved draft")
        #expect(state.replyDraftContext?.targetMessageId == preservedReplyTarget.id)
    }

    @MainActor
    @Test func cancellingMessageEditRestoresPreservedReplyAndDraft() async throws {
        let account = desktopAccount()
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
        let state = WorkspaceState(clientFactory: { runtime })
        await state.bootstrap()

        let replyTarget = MessageItem(
            id: "reply-target",
            senderName: "Alice",
            body: "Reply later",
            sentAt: Date(timeIntervalSince1970: 1_700_000_000),
            isOutgoing: false
        )
        state.startReply(to: replyTarget)
        state.draftText = "Unsent draft"
        state.startEditingMessage(
            MessageItem(
                id: "message-to-edit",
                senderName: "You",
                body: "Original text",
                sentAt: Date(timeIntervalSince1970: 1_700_000_100),
                isOutgoing: true
            ))

        state.cancelEditingMessage()

        #expect(state.editingMessageContext == nil)
        #expect(state.draftText == "Unsent draft")
        #expect(state.replyDraftContext?.targetMessageId == replyTarget.id)
    }

    @MainActor
    @Test func replyContextAndPendingMediaAreMutuallyExclusive() async throws {
        // Issue #399: FFI media uploads carry no reply target. The composer must never
        // keep both a visible reply banner and pending media, regardless of which one
        // the user starts first, because sendDraft() can only route to one send path.
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
        let state = WorkspaceState(clientFactory: { runtime })
        let attachment = PendingMediaAttachment(
            fileName: "notes.txt",
            mediaType: "text/plain",
            data: Data("hello media".utf8),
            dim: nil
        )
        let parent = MessageItem(
            id: "parent",
            senderName: "Alice",
            body: "The launch plan is ready.",
            sentAt: Date(timeIntervalSince1970: 1_700_000_000),
            isOutgoing: false
        )

        await state.bootstrap()
        guard let draftKey = state.selectedComposerDraftKey else {
            Issue.record("Expected a composer draft key")
            return
        }

        state.startReply(to: parent)
        state.appendPendingMediaAttachment(attachment, for: draftKey)
        state.draftText = "Photo caption"

        #expect(state.replyDraftContext == nil)
        #expect(state.pendingMediaAttachments.count == 1)

        await Self.settleComposerMediaUploads(state)
        await state.sendDraft()
        await Self.settlePendingOutgoingMediaSends(state)

        // Staging uploaded the blob; sending only published the reference it produced.
        #expect(runtime.uploadMediaCallCount == 1)
        #expect(runtime.sendMediaAttachmentsCallCount == 1)
        #expect(runtime.replyToMessageCallCount == 0)
        #expect(runtime.repliedMessage == nil)
        #expect(runtime.sentMediaAttachments.last?.caption == "Photo caption")
        #expect(state.pendingMediaAttachments.isEmpty)

        state.appendPendingMediaAttachment(attachment, for: draftKey)
        #expect(state.pendingMediaAttachments.count == 1)

        state.startReply(to: parent)
        state.draftText = "Text reply only"

        #expect(state.pendingMediaAttachments.isEmpty)
        #expect(state.replyDraftContext?.targetMessageId == "parent")

        await state.sendDraft()
        await Self.settleOutgoingTextSends(state)

        // The second staging kicked off its own upload, but starting a reply dropped the
        // attachment, so nothing new was published as media.
        #expect(runtime.sendMediaAttachmentsCallCount == 1)
        #expect(runtime.replyToMessageCallCount == 1)
        #expect(
            runtime.repliedMessage
                == SentReply(
                    groupIdHex: "direct-group",
                    targetMessageId: "parent",
                    text: "Text reply only"
                ))
    }

    @MainActor
    @Test func messageActionsPublishReactionAndDelete() async throws {
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
        let state = WorkspaceState(clientFactory: { runtime })
        let message = MessageItem(
            id: "parent",
            senderName: "Desktop Account",
            body: "The launch plan is ready.",
            sentAt: Date(timeIntervalSince1970: 1_700_000_000),
            isOutgoing: true
        )

        await state.bootstrap()
        await state.react(to: message, emoji: "👍")
        await state.deleteForEveryone(message)

        #expect(
            runtime.reactedMessage
                == SentReaction(
                    groupIdHex: "direct-group",
                    targetMessageId: "parent",
                    emoji: "👍"
                ))
        #expect(
            runtime.deletedMessage
                == DeletedMessage(
                    groupIdHex: "direct-group",
                    targetMessageId: "parent"
                ))
    }

    @MainActor
    @Test func mediaAttachmentEnablesSendAndUploadsWithCaption() async throws {
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
        let state = WorkspaceState(clientFactory: { runtime })
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let attachmentURL = directory.appendingPathComponent("notes.txt")
        try Data("hello media".utf8).write(to: attachmentURL)

        await state.bootstrap()
        await state.addMediaAttachments(from: [attachmentURL])
        state.draftText = "Project notes"

        #expect(state.pendingMediaAttachments.count == 1)

        // Staging uploads the plaintext without publishing anything, and Send is live from the
        // moment the attachment is staged rather than from the moment the upload lands.
        #expect(state.canSend)

        await Self.yieldUntil { runtime.uploadMediaCallCount == 1 }
        #expect(runtime.uploadMediaCallCount == 1)
        #expect(runtime.uploadedMedia?.groupIdHex == "direct-group")
        #expect(runtime.uploadedMedia?.request.send == false)
        #expect(runtime.uploadedMedia?.request.caption == nil)
        #expect(runtime.uploadedMedia?.request.attachments.first?.fileName == "notes.txt")
        #expect(runtime.uploadedMedia?.request.attachments.first?.mediaType == "text/plain")
        #expect(runtime.uploadedMedia?.request.attachments.first?.plaintext == Data("hello media".utf8))

        await Self.settleComposerMediaUploads(state)
        #expect(state.canSend)

        await state.sendDraft()
        await Self.settlePendingOutgoingMediaSends(state)

        // The send publishes the staged reference; it does not upload again.
        #expect(runtime.uploadMediaCallCount == 1)
        #expect(runtime.sendTextCallCount == 0)
        #expect(runtime.sendMediaAttachmentsCallCount == 1)
        #expect(runtime.sentMediaAttachments.last?.groupIdHex == "direct-group")
        #expect(runtime.sentMediaAttachments.last?.caption == "Project notes")
        #expect(runtime.sentMediaAttachments.last?.fileNames == ["notes.txt"])
        #expect(state.pendingMediaAttachments.isEmpty)
        #expect(state.draftText.isEmpty)
    }

    @MainActor
    @Test func stagedImageTracksUploadStateUntilComposerClears() async throws {
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
        let state = WorkspaceState(clientFactory: { runtime })
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let imageURL = directory.appendingPathComponent("screenshot.png")
        try Self.testPNGData(width: 40, height: 28).write(to: imageURL)

        await state.bootstrap()
        // Hold the upload so the in-flight state is observable rather than a race.
        await runtime.uploadReleaseGate.hold("screenshot.png")
        await state.addMediaAttachments(from: [imageURL])
        let attachment = try #require(state.pendingMediaAttachments.first)
        #expect(attachment.kind == .image)

        #expect(state.pendingMediaUploadStates[attachment.id] == .uploading)
        // An unfinished upload no longer disables Send: it only decides whether the message spends
        // its first moments as a loading bubble.
        #expect(state.canSend)

        await runtime.uploadReleaseGate.release("screenshot.png")
        await Self.settleComposerMediaUploads(state)

        #expect(state.pendingMediaUploadStates[attachment.id]?.isUploaded == true)
        #expect(state.canSend)

        await state.sendDraft()
        #expect(state.pendingMediaUploadStates.isEmpty)
        #expect(state.pendingMediaAttachments.isEmpty)
        await Self.settlePendingOutgoingMediaSends(state)
        #expect(state.pendingOutgoingMediaMessagesByConversation.isEmpty)
    }

    @MainActor
    @Test func stagedAttachmentsUploadIndependentlyAndPublishInComposerOrder() async throws {
        // Uploads finish in whatever order Blossom returns them, but the published `imeta` order is
        // the message's reading order — it must come from the composer, never from completion
        // order. Release the second attachment first to prove the two are decoupled.
        let account = desktopAccount()
        let runtime = FakeMarmotRuntime(accounts: [account])
        runtime.installGroup(messageGroup())
        let state = WorkspaceState(clientFactory: { runtime })
        await state.bootstrap()
        let draftKey = try #require(state.selectedComposerDraftKey)

        await runtime.uploadReleaseGate.hold("first.txt", "second.txt")
        for fileName in ["first.txt", "second.txt"] {
            state.appendPendingMediaAttachment(
                PendingMediaAttachment(
                    fileName: fileName,
                    mediaType: "text/plain",
                    data: Data(fileName.utf8),
                    dim: nil
                ),
                for: draftKey
            )
        }

        // One upload call per attachment, each carrying exactly its own file.
        await Self.yieldUntil { runtime.uploadMediaCallCount == 2 }
        #expect(runtime.uploadMediaCallCount == 2)
        #expect(runtime.uploadedMediaRequests.allSatisfy { $0.request.attachments.count == 1 })
        #expect(runtime.uploadedMediaRequests.allSatisfy { $0.request.send == false })

        // Let the *second* attachment land first. One of the two is now uploaded, and Send stays
        // available either way.
        await runtime.uploadReleaseGate.release("second.txt")
        await Self.yieldUntil { state.pendingMediaUploadStates.values.contains(where: \.isUploaded) }
        #expect(state.pendingMediaUploadStates.values.count(where: \.isUploaded) == 1)
        #expect(state.canSend)

        await runtime.uploadReleaseGate.release("first.txt")
        await Self.settleComposerMediaUploads(state)
        #expect(state.canSend)

        await state.sendDraft()
        await Self.settlePendingOutgoingMediaSends(state)

        #expect(runtime.sendMediaAttachmentsCallCount == 1)
        #expect(runtime.sentMediaAttachments.last?.fileNames == ["first.txt", "second.txt"])
        #expect(runtime.sentMediaAttachments.last?.caption == nil)
    }

    /// A finished recording as `finishVoiceRecording()` stages it.
    private func recordedVoiceMessage(fileName: String = "voice-note.m4a") -> PendingMediaAttachment {
        PendingMediaAttachment(
            fileName: fileName,
            mediaType: "audio/mp4",
            data: Data("recorded audio".utf8),
            dim: nil,
            durationSeconds: 4,
            waveformSamples: [0.2, 0.7, 0.4],
            isVoiceMessage: true
        )
    }

    @MainActor
    @Test func stagedRecordingTakesTheComposerOverInsteadOfJoiningTheMediaStrip() async throws {
        // A recording is a whole message, not an attachment: it stands alone in the composer, and
        // nothing else can be staged next to it until it is sent or discarded.
        let account = desktopAccount()
        let runtime = FakeMarmotRuntime(accounts: [account])
        runtime.installGroup(messageGroup())
        let state = WorkspaceState(clientFactory: { runtime })
        await state.bootstrap()
        let draftKey = try #require(state.selectedComposerDraftKey)

        let photo = PendingMediaAttachment(
            fileName: "photo.png",
            mediaType: "image/png",
            data: Data("photo".utf8),
            dim: "10x10"
        )
        state.appendPendingMediaAttachment(photo, for: draftKey)
        #expect(state.stagedVoiceMessage == nil)

        // With a photo staged the mic is off — recording would have to discard it.
        #expect(!state.canRecordVoiceMessage)
        await state.startVoiceRecording()
        #expect(!state.isRecordingVoiceMessage)
        #expect(state.lastError == L10n.string("A voice message is sent on its own"))
        state.lastError = nil

        let recording = recordedVoiceMessage()
        state.appendPendingMediaAttachment(recording, for: draftKey)

        #expect(state.stagedVoiceMessage?.id == recording.id)
        #expect(state.pendingMediaAttachments.map(\.id) == [recording.id])
        #expect(state.pendingMediaUploadStates[photo.id] == nil)

        // Every other staging path is refused while the recording is staged.
        #expect(!state.canBeginMediaAttachmentSelection())
        #expect(state.lastError == L10n.string("A voice message is sent on its own"))
        #expect(state.pendingMediaAttachments.map(\.id) == [recording.id])
    }

    @MainActor
    @Test func recordingIsRefusedWhileTheComposerHoldsText() async throws {
        let account = desktopAccount()
        let runtime = FakeMarmotRuntime(accounts: [account])
        runtime.installGroup(messageGroup())
        let state = WorkspaceState(clientFactory: { runtime })
        await state.bootstrap()

        #expect(state.canRecordVoiceMessage)

        state.draftText = "half-written message"
        #expect(!state.canRecordVoiceMessage)

        await state.startVoiceRecording()

        // The typed text survives: the recording never started rather than replacing it.
        #expect(!state.isRecordingVoiceMessage)
        #expect(state.voiceRecorder == nil)
        #expect(state.draftText == "half-written message")
        #expect(state.lastError == L10n.string("A voice message is sent on its own"))
    }

    @MainActor
    @Test func stagedRecordingSendsAsAudioOnly() async throws {
        let account = desktopAccount()
        let runtime = FakeMarmotRuntime(accounts: [account])
        runtime.installGroup(messageGroup())
        let state = WorkspaceState(clientFactory: { runtime })
        await state.bootstrap()
        let draftKey = try #require(state.selectedComposerDraftKey)

        state.appendPendingMediaAttachment(recordedVoiceMessage(), for: draftKey)
        await Self.settleComposerMediaUploads(state)
        #expect(state.canSend)

        await state.sendDraft()
        // The composer is free the moment Send is pressed; the publish finishes behind it.
        #expect(state.stagedVoiceMessage == nil)
        #expect(state.pendingMediaAttachments.isEmpty)
        await Self.settlePendingOutgoingMediaSends(state)

        #expect(runtime.sendMediaAttachmentsCallCount == 1)
        #expect(runtime.sentMediaAttachments.last?.fileNames == ["voice-note.m4a"])
        #expect(runtime.sentMediaAttachments.last?.caption == nil)
    }

    @MainActor
    @Test func sendingScrollsTheTranscriptToTheLiveEdgeFromThePressItself() async throws {
        // The transcript jumps to the bottom off this generation rather than off the message the
        // send produces. A recording is the case that needs it: its pending bubble is appended
        // below the timeline window, so nothing about `messageIDs` moves when Send is pressed, and
        // a send made while the user was reading history stayed off the bottom edge until the
        // publish landed seconds later.
        let account = desktopAccount()
        let runtime = FakeMarmotRuntime(accounts: [account])
        runtime.installGroup(messageGroup())
        let state = WorkspaceState(clientFactory: { runtime })
        await state.bootstrap()
        let draftKey = try #require(state.selectedComposerDraftKey)
        let beforeAnySend = state.outgoingSendScrollGeneration

        // An empty composer sends nothing, so it must not move the transcript either.
        await state.sendDraft()
        #expect(state.outgoingSendScrollGeneration == beforeAnySend)

        state.appendPendingMediaAttachment(recordedVoiceMessage(), for: draftKey)
        await Self.settleComposerMediaUploads(state)
        await state.sendDraft()
        let afterRecording = state.outgoingSendScrollGeneration
        #expect(afterRecording == beforeAnySend &+ 1)
        await Self.settlePendingOutgoingMediaSends(state)
        #expect(runtime.sendMediaAttachmentsCallCount == 1)

        state.draftText = "and one typed after it"
        await state.sendDraft()
        #expect(state.outgoingSendScrollGeneration == afterRecording &+ 1)
        await Self.settleOutgoingTextSends(state)
        #expect(runtime.publishedTexts.map(\.text) == ["and one typed after it"])
    }

    @MainActor
    @Test func editingAMessageLeavesTheTranscriptWhereItIs() async throws {
        // An edit rewrites a row in place — possibly one well up in the history the user is
        // reading — so it is the one composer send that must not scroll to the live edge.
        let account = desktopAccount()
        let runtime = FakeMarmotRuntime(accounts: [account])
        runtime.installGroup(messageGroup())
        let state = WorkspaceState(clientFactory: { runtime })
        await state.bootstrap()
        let beforeEdit = state.outgoingSendScrollGeneration

        state.startEditingMessage(
            MessageItem(
                id: "message-to-edit",
                senderName: "You",
                body: "Original text",
                sentAt: Date(timeIntervalSince1970: 1_700_000_000),
                isOutgoing: true
            ))
        state.draftText = "Updated text"
        await state.sendDraft()

        #expect(runtime.editedMessage?.targetMessageId == "message-to-edit")
        #expect(state.outgoingSendScrollGeneration == beforeEdit)
    }

    @MainActor
    @Test func recordingSentBeforeItsUploadLandsFreesTheComposerToRecordAgain() async throws {
        // Where "a recording is a whole message" meets the hybrid send: the recording keeps
        // uploading from its own bubble, and because the composer empties on the press, the user
        // can start the next recording immediately instead of waiting for Blossom.
        let account = desktopAccount()
        let runtime = FakeMarmotRuntime(accounts: [account])
        runtime.installGroup(messageGroup())
        let state = WorkspaceState(clientFactory: { runtime })
        await state.bootstrap()
        let draftKey = try #require(state.selectedComposerDraftKey)

        await runtime.uploadReleaseGate.hold("voice-note.m4a")
        state.appendPendingMediaAttachment(recordedVoiceMessage(), for: draftKey)
        #expect(state.pendingMediaUploadStates.values.contains(.uploading))
        #expect(state.canSend)

        await state.sendDraft()

        // Composer handed back straight away — including the "record from an empty composer"
        // gate, which the in-flight message no longer occupies.
        #expect(state.stagedVoiceMessage == nil)
        #expect(state.canRecordVoiceMessage)
        #expect(runtime.sendMediaAttachmentsCallCount == 0)
        let pending = try #require(state.selectedPendingOutgoingMediaMessages.first)
        #expect(pending.state == .uploading)
        #expect(pending.attachments.first?.isVoiceMessage == true)
        // Audio goes out on its own, so the bubble carries no caption to render either.
        #expect(pending.caption.isEmpty)

        await runtime.uploadReleaseGate.release("voice-note.m4a")
        await Self.settlePendingOutgoingMediaSends(state)

        #expect(runtime.sendMediaAttachmentsCallCount == 1)
        #expect(runtime.sentMediaAttachments.last?.fileNames == ["voice-note.m4a"])
        #expect(runtime.sentMediaAttachments.last?.caption == nil)
        #expect(state.selectedPendingOutgoingMediaMessages.isEmpty)
    }

    @MainActor
    @Test func pendingBubbleGivesWayTheMomentItsPublishedRowLands() async throws {
        // The core commits an own send locally *inside* `sendMediaAttachments`, so the real row can
        // reach the transcript through the timeline subscription while the relay round-trip is
        // still in flight. The pending bubble is only dropped once that call returns, so for the
        // length of the publish the same voice note rendered twice — one loading bubble stacked
        // under the real one. Matching on the uploaded blob's plaintext digest retires the
        // placeholder as soon as the row it became is on screen.
        let account = desktopAccount()
        let runtime = FakeMarmotRuntime(accounts: [account])
        runtime.installGroup(messageGroup())
        let state = WorkspaceState(clientFactory: { runtime })
        await state.bootstrap()
        let draftKey = try #require(state.selectedComposerDraftKey)

        let recording = recordedVoiceMessage()
        state.appendPendingMediaAttachment(recording, for: draftKey)
        await Self.settleComposerMediaUploads(state)

        // Arm the gate only now, so it holds the publish rather than the upload.
        runtime.messageActionGateEnabled = true
        await state.sendDraft()
        await Self.waitUntil { runtime.didReachMessageActionGate }
        #expect(state.selectedPendingOutgoingMediaMessages.map(\.state) == [.publishing])

        runtime.installTimelinePage(
            TimelinePageFfi(
                messages: [
                    timelineMessage(
                        id: "published-voice",
                        direction: "outbound",
                        groupIdHex: "group",
                        sender: account.accountIdHex,
                        plaintext: "",
                        recordedAt: 1_700_000_000,
                        media: [
                            mediaAttachmentReference(
                                mediaType: "audio/mp4",
                                fileName: "voice-note.m4a",
                                plaintextSha256: hexSHA256(recording.data)
                            )
                        ]
                    )
                ],
                hasMoreBefore: false,
                hasMoreAfter: false
            ),
            groupIdHex: "group"
        )
        let activeAccount = try #require(state.activeAccount)
        await state.refreshSelectedTimelineAfterSend(
            groupIdHex: "group",
            account: activeAccount,
            client: runtime
        )

        // One bubble, not two: the real row is on screen and the loading one is already gone, even
        // though the publish has not returned yet.
        #expect(state.selectedMessages.map(\.id) == ["published-voice"])
        #expect(state.selectedPendingOutgoingMediaMessages.isEmpty)
        // Hidden, not cancelled — the send still owns the message until its publish returns, which
        // is what lets a failure put the bubble back with its retry actions.
        #expect(state.pendingOutgoingMediaMessagesByConversation[draftKey]?.count == 1)

        runtime.releaseMessageActionGate()
        await Self.settlePendingOutgoingMediaSends(state)
        #expect(state.pendingOutgoingMediaMessagesByConversation.isEmpty)
    }

    @MainActor
    @Test func aPublishedOwnMediaRowRendersItsImageOnTheFirstFrame() async throws {
        // The bubble the send hands over already shows the picked image, so the row that replaces it
        // must show it too — immediately. Seeding only the encrypted disk cache was not enough: that
        // read is asynchronous (open the container, decrypt, verify the digest), so the published row
        // came up on a spinner and the sender watched their own photo blink from loaded back to
        // loading as the placeholder gave way to the real row.
        let account = desktopAccount()
        let runtime = FakeMarmotRuntime(accounts: [account])
        runtime.installGroup(messageGroup())
        let state = WorkspaceState(clientFactory: { runtime })
        await state.bootstrap()
        let draftKey = try #require(state.selectedComposerDraftKey)

        let photo = PendingMediaAttachment(
            fileName: "photo.png",
            mediaType: "image/png",
            data: Data("photo bytes".utf8),
            dim: "120x80"
        )
        state.appendPendingMediaAttachment(photo, for: draftKey)
        await Self.settleComposerMediaUploads(state)

        // Arm the gate only now, so it holds the publish rather than the upload.
        runtime.messageActionGateEnabled = true
        await state.sendDraft()
        await Self.waitUntil { runtime.didReachMessageActionGate }

        // The row the core commits locally inside the publish carries the reference the send just
        // published, which is what the held plaintext is keyed by.
        let publishedReference = try #require(runtime.sentMediaAttachments.last?.attachments.first)
        runtime.installTimelinePage(
            TimelinePageFfi(
                messages: [
                    timelineMessage(
                        id: "published-photo",
                        direction: "outbound",
                        groupIdHex: "group",
                        sender: account.accountIdHex,
                        plaintext: "",
                        recordedAt: 1_700_000_000,
                        media: [publishedReference]
                    )
                ],
                hasMoreBefore: false,
                hasMoreAfter: false
            ),
            groupIdHex: "group"
        )
        let activeAccount = try #require(state.activeAccount)
        await state.refreshSelectedTimelineAfterSend(
            groupIdHex: "group",
            account: activeAccount,
            client: runtime
        )

        let row = try #require(state.selectedMessages.first)
        let attachment = try #require(row.mediaAttachments.first)
        let downloadState = state.mediaDownloadStateStore(for: row, attachment: attachment)
        guard case .loaded(let download) = downloadState.state else {
            Issue.record("own send's published row must start loaded, not \(downloadState.state)")
            return
        }
        #expect(download.data == photo.data)
        #expect(download.fileName == "photo.png")
        // Nothing left to fetch: the bytes never went round-trip, so no spinner and no download.
        #expect(!downloadState.shouldStartAutomaticDownload)

        runtime.releaseMessageActionGate()
        await Self.settlePendingOutgoingMediaSends(state)

        // The plaintext is the outgoing message's own, so retiring the send lets it go — and the row
        // keeps rendering from the payload it was already handed.
        #expect(state.pendingOutgoingMediaMessagesByConversation.isEmpty)
        guard case .loaded = downloadState.state else {
            Issue.record("retiring the send must not walk its published row back to loading")
            return
        }
    }

    @MainActor
    @Test func aStagedAttachmentCarriesTheDigestItsPublishedReferenceIsKeyedBy() async throws {
        // What lets a published row find the plaintext the send is still holding: the digest the
        // composer stamped on the staged attachment is the same `plaintextSha256` the core puts in the
        // reference it publishes. Nothing else ties the two together, and a divergence would not fail
        // anywhere else — it would quietly put the spinner back.
        let account = desktopAccount()
        let runtime = FakeMarmotRuntime(accounts: [account])
        runtime.installGroup(messageGroup())
        let state = WorkspaceState(clientFactory: { runtime })
        await state.bootstrap()
        let draftKey = try #require(state.selectedComposerDraftKey)

        let photo = PendingMediaAttachment(
            fileName: "photo.png",
            mediaType: "image/png",
            data: Data("photo bytes".utf8),
            dim: "120x80"
        )
        state.appendPendingMediaAttachment(photo, for: draftKey)
        await Self.settleComposerMediaUploads(state)
        await state.sendDraft()
        await Self.settlePendingOutgoingMediaSends(state)

        let publishedReference = try #require(runtime.sentMediaAttachments.last?.attachments.first)
        #expect(photo.plaintextSHA256 == publishedReference.plaintextSha256.lowercased())
        // And it is the digest the disk cache verifies a plaintext it read back against.
        #expect(photo.plaintextSHA256 == MessageMediaDiskCacheKey.plaintextDigest(for: photo.data))
    }

    @MainActor
    @Test func thePlaceholderIsRetiredOnlyOnceTheWindowThatReplacesItIsBack() async throws {
        // The placeholder used to be dropped before the post-send re-window, which on the path where
        // no projection delta has arrived yet left a frame with neither row in it: the bubble the
        // user was looking at disappeared and the published one had not been windowed. Retiring it
        // after the window comes back means something is always on screen for the message.
        let account = desktopAccount()
        let runtime = FakeMarmotRuntime(accounts: [account])
        runtime.installGroup(messageGroup())
        let state = WorkspaceState(clientFactory: { runtime })
        await state.bootstrap()
        let draftKey = try #require(state.selectedComposerDraftKey)

        state.appendPendingMediaAttachment(
            PendingMediaAttachment(
                fileName: "photo.png",
                mediaType: "image/png",
                data: Data("photo bytes".utf8),
                dim: "120x80"
            ),
            for: draftKey
        )
        await Self.settleComposerMediaUploads(state)
        runtime.messageActionGateEnabled = true
        await state.sendDraft()
        await Self.waitUntil { runtime.didReachMessageActionGate }

        let publishedReference = try #require(runtime.sentMediaAttachments.last?.attachments.first)
        let publishedPage = TimelinePageFfi(
            messages: [
                timelineMessage(
                    id: "published-photo",
                    direction: "outbound",
                    groupIdHex: "group",
                    sender: account.accountIdHex,
                    plaintext: "",
                    recordedAt: 1_700_000_000,
                    media: [publishedReference]
                )
            ],
            hasMoreBefore: false,
            hasMoreAfter: false
        )
        // Hold the re-window itself, so the assertion lands in the gap the old order left open.
        let windowGate = BlockingFfiGate()
        windowGate.isEnabled = true
        runtime.timelineMessagesHandler = { _ in
            windowGate.passIfArmed()
            return publishedPage
        }

        runtime.releaseMessageActionGate()
        await Self.waitUntil { windowGate.didReach }

        #expect(!state.selectedMessages.contains { $0.id == "published-photo" })
        #expect(state.selectedPendingOutgoingMediaMessages.count == 1)

        windowGate.release()
        await Self.settlePendingOutgoingMediaSends(state)

        #expect(state.selectedMessages.map(\.id) == ["published-photo"])
        #expect(state.selectedPendingOutgoingMediaMessages.isEmpty)
        #expect(state.pendingOutgoingMediaMessagesByConversation.isEmpty)
    }

    @MainActor
    @Test func pendingBubbleStaysUpWhileADifferentAudioIsPublished() async throws {
        // The suppression is keyed on the blob the message actually uploaded. A neighbouring audio
        // row in the same transcript must not retire a bubble whose own publish is still climbing.
        let account = desktopAccount()
        let runtime = FakeMarmotRuntime(accounts: [account])
        runtime.installGroup(messageGroup())
        let state = WorkspaceState(clientFactory: { runtime })
        await state.bootstrap()
        let draftKey = try #require(state.selectedComposerDraftKey)

        state.appendPendingMediaAttachment(recordedVoiceMessage(), for: draftKey)
        await Self.settleComposerMediaUploads(state)
        runtime.messageActionGateEnabled = true
        await state.sendDraft()
        await Self.waitUntil { runtime.didReachMessageActionGate }

        runtime.installTimelinePage(
            TimelinePageFfi(
                messages: [
                    timelineMessage(
                        id: "someone-elses-voice",
                        groupIdHex: "group",
                        sender: "alice1234567890alice1234567890alice1234567890alice1234567890",
                        plaintext: "",
                        recordedAt: 1_700_000_000,
                        media: [
                            mediaAttachmentReference(
                                mediaType: "audio/mp4",
                                fileName: "other.m4a",
                                plaintextSha256: hexSHA256(Data("someone else".utf8))
                            )
                        ]
                    )
                ],
                hasMoreBefore: false,
                hasMoreAfter: false
            ),
            groupIdHex: "group"
        )
        let activeAccount = try #require(state.activeAccount)
        await state.refreshSelectedTimelineAfterSend(
            groupIdHex: "group",
            account: activeAccount,
            client: runtime
        )

        #expect(state.selectedPendingOutgoingMediaMessages.map(\.state) == [.publishing])

        runtime.releaseMessageActionGate()
        await Self.settlePendingOutgoingMediaSends(state)
    }

    @Test func onlyAnAudioOnlyMessageCarriesItsLoadingStateInsideTheRow() {
        // The inline spinner lives in the well the play button lands in, which only exists on an
        // audio row. A message that also carries tiles or a document row has no such well, so it
        // keeps the centered overlay — and a message that had both would show one Send press two
        // loading indicators.
        let voice = PendingMediaAttachment(
            fileName: "voice-note.m4a",
            mediaType: "audio/mp4",
            data: Data("recorded audio".utf8),
            dim: nil,
            durationSeconds: 4,
            waveformSamples: [0.2, 0.7, 0.4],
            isVoiceMessage: true
        )
        let photo = PendingMediaAttachment(
            fileName: "photo.png",
            mediaType: "image/png",
            data: Data("png".utf8),
            dim: "120x80"
        )

        #expect(
            PendingOutgoingMediaMessage(attachments: [voice], caption: "")
                .inlineLoadingAudioAttachment == voice
        )
        #expect(
            PendingOutgoingMediaMessage(attachments: [voice, photo], caption: "")
                .inlineLoadingAudioAttachment == nil
        )
        #expect(
            PendingOutgoingMediaMessage(attachments: [photo], caption: "")
                .inlineLoadingAudioAttachment == nil
        )
    }

    @MainActor
    @Test func discardingAStagedRecordingCancelsItsUpload() async throws {
        // The trash can has to reach the in-flight upload too, or the blob keeps climbing to
        // Blossom for a recording the user just threw away.
        let account = desktopAccount()
        let runtime = FakeMarmotRuntime(accounts: [account])
        runtime.installGroup(messageGroup())
        let state = WorkspaceState(clientFactory: { runtime })
        await state.bootstrap()
        let draftKey = try #require(state.selectedComposerDraftKey)

        let recording = recordedVoiceMessage()
        await runtime.uploadReleaseGate.hold("voice-note.m4a")
        state.appendPendingMediaAttachment(recording, for: draftKey)
        #expect(state.pendingMediaUploadStates[recording.id] == .uploading)

        state.discardStagedVoiceMessage()

        #expect(state.stagedVoiceMessage == nil)
        #expect(state.pendingMediaAttachments.isEmpty)
        #expect(state.pendingMediaUploadStates[recording.id] == nil)
        #expect(!state.canSend)

        await runtime.uploadReleaseGate.release("voice-note.m4a")
        await Self.settleComposerMediaUploads(state)

        // The released upload has nowhere to land: the composer stays empty.
        #expect(state.pendingMediaAttachments.isEmpty)
        #expect(state.pendingMediaUploadStates.isEmpty)

        await state.sendDraft()
        #expect(runtime.sendMediaAttachmentsCallCount == 0)
    }

    @MainActor
    @Test func stagingARecordingDropsAnActiveReplyLikeEveryOtherAttachment() async throws {
        // A reply banner is not draft content, so it never blocks the mic — but reply and pending
        // media are mutually exclusive (#399) because outgoing media carries no reply target. The
        // recording path is one more staging path and honours that the same way the paperclip does,
        // rather than leaving a banner promising a reply the send cannot make.
        let account = desktopAccount()
        let runtime = FakeMarmotRuntime(accounts: [account])
        runtime.installGroup(messageGroup())
        let state = WorkspaceState(clientFactory: { runtime })
        await state.bootstrap()
        let draftKey = try #require(state.selectedComposerDraftKey)

        state.startReply(
            to: MessageItem(
                id: "parent",
                senderName: "Alice",
                body: "How did the launch go?",
                sentAt: Date(timeIntervalSince1970: 1_700_000_000),
                isOutgoing: false
            ))
        #expect(state.replyDraftContext?.targetMessageId == "parent")
        #expect(state.canRecordVoiceMessage)

        state.appendPendingMediaAttachment(recordedVoiceMessage(), for: draftKey)

        #expect(state.stagedVoiceMessage != nil)
        #expect(state.replyDraftContext == nil)

        await Self.settleComposerMediaUploads(state)
        await state.sendDraft()
        await Self.settlePendingOutgoingMediaSends(state)

        #expect(runtime.replyToMessageCallCount == 0)
        #expect(runtime.sendMediaAttachmentsCallCount == 1)
        #expect(runtime.sentMediaAttachments.last?.fileNames == ["voice-note.m4a"])
    }

    @MainActor
    @Test func stagedVoiceNoteUploadsLikeAnyOtherAttachment() async throws {
        // Upload feedback used to be image-only, so a voice note or a document showed no progress
        // at all. Every attachment kind now reports one, which is what lets a Send pressed
        // mid-upload know what it still has to wait for.
        let account = desktopAccount()
        let runtime = FakeMarmotRuntime(accounts: [account])
        runtime.installGroup(messageGroup())
        let state = WorkspaceState(clientFactory: { runtime })
        await state.bootstrap()
        let draftKey = try #require(state.selectedComposerDraftKey)

        let voiceNote = PendingMediaAttachment(
            fileName: "voice.m4a",
            mediaType: "audio/mp4",
            data: Data("voice".utf8),
            dim: nil,
            durationSeconds: 3
        )
        #expect(voiceNote.kind == .audio)

        await runtime.uploadReleaseGate.hold("voice.m4a")
        state.appendPendingMediaAttachment(voiceNote, for: draftKey)

        #expect(state.pendingMediaUploadStates[voiceNote.id] == .uploading)
        #expect(state.canSend)

        await runtime.uploadReleaseGate.release("voice.m4a")
        await Self.settleComposerMediaUploads(state)

        #expect(state.pendingMediaUploadStates[voiceNote.id]?.isUploaded == true)
        #expect(state.canSend)
    }

    @MainActor
    @Test func failedStagedUploadIsRetryableWithoutLosingTheDraft() async throws {
        let account = desktopAccount()
        let runtime = FakeMarmotRuntime(accounts: [account])
        runtime.installGroup(messageGroup())
        let state = WorkspaceState(clientFactory: { runtime })
        await state.bootstrap()
        let draftKey = try #require(state.selectedComposerDraftKey)

        runtime.uploadMediaFailingFileNames = ["notes.txt"]
        let attachment = PendingMediaAttachment(
            fileName: "notes.txt",
            mediaType: "text/plain",
            data: Data("hello media".utf8),
            dim: nil
        )
        state.appendPendingMediaAttachment(attachment, for: draftKey)
        state.draftText = "Project notes"

        for _ in 0..<1_000 where state.pendingMediaUploadStates[attachment.id] != .failed {
            await Task.yield()
        }

        // A failed upload keeps the attachment and the text: the user retries, they do not retype.
        #expect(state.pendingMediaUploadStates[attachment.id] == .failed)
        #expect(state.pendingMediaAttachments.count == 1)
        #expect(state.draftText == "Project notes")
        // The failure belongs to the attachment, not to the composer: Send stays available and
        // would re-upload it as part of sending.
        #expect(state.canSend)

        state.retryPendingMediaUpload(attachment.id)
        await Self.settleComposerMediaUploads(state)

        #expect(runtime.uploadMediaCallCount == 2)
        #expect(state.canSend)

        await state.sendDraft()
        await Self.settlePendingOutgoingMediaSends(state)
        #expect(runtime.sentMediaAttachments.last?.fileNames == ["notes.txt"])
        #expect(state.pendingMediaAttachments.isEmpty)
    }

    @MainActor
    @Test func stagedUploadWithoutAReferenceFailsInsteadOfSpinningForever() async throws {
        // A result that reports success but carries no attachment used to hit the same silent
        // `return` as cancellation, so the tile stayed `.uploading` with no retry — and a send
        // that adopted it would now wait on a reference that never arrives.
        let account = desktopAccount()
        let runtime = FakeMarmotRuntime(accounts: [account])
        runtime.installGroup(messageGroup())
        let state = WorkspaceState(clientFactory: { runtime })
        await state.bootstrap()
        let draftKey = try #require(state.selectedComposerDraftKey)

        runtime.uploadMediaEmptyResultFileNames = ["notes.txt"]
        let attachment = PendingMediaAttachment(
            fileName: "notes.txt",
            mediaType: "text/plain",
            data: Data("hello media".utf8),
            dim: nil
        )
        state.appendPendingMediaAttachment(attachment, for: draftKey)
        state.draftText = "Project notes"

        await Self.yieldUntil { state.pendingMediaUploadStates[attachment.id] == .failed }

        #expect(state.pendingMediaUploadStates[attachment.id] == .failed)
        // The attachment and the text survive, so the failure is recoverable by retrying.
        #expect(state.pendingMediaAttachments.count == 1)
        #expect(state.draftText == "Project notes")

        runtime.uploadMediaEmptyResultFileNames = []
        state.retryPendingMediaUpload(attachment.id)
        await Self.settleComposerMediaUploads(state)

        #expect(state.pendingMediaUploadStates[attachment.id]?.isUploaded == true)
        #expect(state.canSend)
    }

    @MainActor
    @Test func uploadFinishingAfterRemovalDoesNotResurrectTheAttachment() async throws {
        // Issue #245 discipline applied to the upload result: the user can remove a tile (or leave
        // the conversation) while its upload is in flight, and the late result must not write back.
        let account = desktopAccount()
        let runtime = FakeMarmotRuntime(accounts: [account])
        runtime.installGroups([messageGroup(), directGroup()])
        let state = WorkspaceState(clientFactory: { runtime })
        await state.bootstrap()
        // Pin the staging chat explicitly: the default selection is the other one, and switching
        // to a chat that is already selected would prove nothing.
        state.selectChat(try #require(state.activeChats.first { $0.id == "group" }))
        let draftKey = try #require(state.selectedComposerDraftKey)
        #expect(draftKey.chatId == "group")

        await runtime.uploadReleaseGate.hold("removed.txt", "abandoned.txt")
        let removed = PendingMediaAttachment(
            fileName: "removed.txt",
            mediaType: "text/plain",
            data: Data("removed".utf8),
            dim: nil
        )
        state.appendPendingMediaAttachment(removed, for: draftKey)
        state.removePendingMediaAttachment(removed.id)

        let abandoned = PendingMediaAttachment(
            fileName: "abandoned.txt",
            mediaType: "text/plain",
            data: Data("abandoned".utf8),
            dim: nil
        )
        state.appendPendingMediaAttachment(abandoned, for: draftKey)
        let otherChat = try #require(state.activeChats.first { $0.id == "direct-group" })
        state.selectChat(otherChat)

        await runtime.uploadReleaseGate.release("removed.txt")
        await runtime.uploadReleaseGate.release("abandoned.txt")
        for _ in 0..<1_000 {
            await Task.yield()
        }

        #expect(state.pendingMediaUploadStatesByConversation[draftKey]?[removed.id] == nil)
        #expect(state.pendingMediaAttachmentsByConversation[draftKey]?.contains(removed) != true)
        // The abandoned attachment is still staged in the chat it was staged in — switching away
        // does not discard a draft — but nothing leaked into the newly selected conversation.
        #expect(state.pendingMediaAttachments.isEmpty)
        #expect(state.pendingMediaUploadStates.isEmpty)
    }

    @MainActor
    @Test func failedPublishParksTheMessageAsAFailedBubbleThatCanBeRetried() async throws {
        // A failed publish no longer rewinds the composer: the message has left it, so the failure
        // belongs to the bubble the user is looking at, complete with its own retry.
        let account = desktopAccount()
        let runtime = FakeMarmotRuntime(accounts: [account])
        runtime.installGroup(messageGroup())
        let state = WorkspaceState(clientFactory: { runtime })
        await state.bootstrap()
        let draftKey = try #require(state.selectedComposerDraftKey)

        let attachment = PendingMediaAttachment(
            fileName: "notes.txt",
            mediaType: "text/plain",
            data: Data("hello media".utf8),
            dim: nil
        )
        state.appendPendingMediaAttachment(attachment, for: draftKey)
        await Self.settleComposerMediaUploads(state)

        state.draftText = "Project notes"
        runtime.sendMediaAttachmentsError = FakeMarmotRuntimeError.mediaUploadFailed
        await state.sendDraft()
        await Self.settlePendingOutgoingMediaSends(state)

        #expect(runtime.sendMediaAttachmentsCallCount == 1)
        // The composer stays empty — the attachments and caption are held by the failed bubble.
        #expect(state.pendingMediaAttachments.isEmpty)
        #expect(state.draftText.isEmpty)
        let failed = try #require(state.selectedPendingOutgoingMediaMessages.first)
        #expect(failed.state == .failed)
        #expect(failed.attachments == [attachment])
        #expect(failed.caption == "Project notes")

        runtime.sendMediaAttachmentsError = nil
        state.retryPendingOutgoingMediaMessage(failed.id)
        await Self.settlePendingOutgoingMediaSends(state)

        // The retry re-uploads rather than trusting a reference whose failure it cannot see.
        #expect(runtime.uploadMediaCallCount == 2)
        #expect(runtime.sendMediaAttachmentsCallCount == 2)
        #expect(state.selectedPendingOutgoingMediaMessages.isEmpty)
    }

    @MainActor
    @Test func failedOutgoingMediaBubbleOffersRetryAndRemoveInItsOverflowMenu() async throws {
        // The staged-media bubble used to carry its recovery as a link row under itself and had no
        // ⋯ control at all, so it was the one failed row in the transcript whose actions lived
        // somewhere other than the overflow menu every other row uses.
        let account = desktopAccount()
        let runtime = FakeMarmotRuntime(accounts: [account])
        runtime.installGroup(messageGroup())
        let state = WorkspaceState(clientFactory: { runtime })
        await state.bootstrap()
        let draftKey = try #require(state.selectedComposerDraftKey)

        state.appendPendingMediaAttachment(
            PendingMediaAttachment(
                fileName: "notes.txt",
                mediaType: "text/plain",
                data: Data("hello media".utf8),
                dim: nil
            ),
            for: draftKey
        )
        await Self.settleComposerMediaUploads(state)

        runtime.sendMediaAttachmentsError = FakeMarmotRuntimeError.mediaUploadFailed
        await state.sendDraft()
        await Self.settlePendingOutgoingMediaSends(state)

        let failed = try #require(state.selectedPendingOutgoingMediaMessages.first)
        let actions = MessageRowAction.all(for: failed, workspace: state)
        #expect(actions.map(\.kind) == [.retry, .delete])
        // "Remove", not "Delete": nothing has been committed anywhere yet.
        #expect(actions.map(\.title) == [L10n.string("Retry"), L10n.string("Remove")])
        #expect(actions.last?.role == .destructive)

        runtime.sendMediaAttachmentsError = nil
        try #require(actions.first { $0.kind == .retry }).run()
        await Self.settlePendingOutgoingMediaSends(state)

        #expect(runtime.sendMediaAttachmentsCallCount == 2)
        #expect(state.selectedPendingOutgoingMediaMessages.isEmpty)
    }

    @MainActor
    @Test func outgoingMediaBubbleOverflowMenuIsEmptyWhileTheSendIsStillGoingOut() async throws {
        // Nothing to retry and nothing to remove until it has failed: the core has no cancellation
        // story for a publish in flight, so both actions would be a lie.
        let account = desktopAccount()
        let runtime = FakeMarmotRuntime(accounts: [account])
        runtime.installGroup(messageGroup())
        let state = WorkspaceState(clientFactory: { runtime })
        await state.bootstrap()

        let sending = PendingOutgoingMediaMessage(
            attachments: [
                PendingMediaAttachment(
                    fileName: "notes.txt",
                    mediaType: "text/plain",
                    data: Data("hello media".utf8),
                    dim: nil
                )
            ],
            caption: "",
            state: .uploading
        )

        #expect(MessageRowAction.all(for: sending, workspace: state).isEmpty)
    }

    @MainActor
    @Test func failedOutgoingMediaBubbleRoutesRemoveThroughTheOverflowMenu() async throws {
        let account = desktopAccount()
        let runtime = FakeMarmotRuntime(accounts: [account])
        runtime.installGroup(messageGroup())
        let state = WorkspaceState(clientFactory: { runtime })
        await state.bootstrap()
        let draftKey = try #require(state.selectedComposerDraftKey)

        state.appendPendingMediaAttachment(
            PendingMediaAttachment(
                fileName: "notes.txt",
                mediaType: "text/plain",
                data: Data("hello media".utf8),
                dim: nil
            ),
            for: draftKey
        )
        await Self.settleComposerMediaUploads(state)

        runtime.sendMediaAttachmentsError = FakeMarmotRuntimeError.mediaUploadFailed
        await state.sendDraft()
        await Self.settlePendingOutgoingMediaSends(state)

        let failed = try #require(state.selectedPendingOutgoingMediaMessages.first)
        var dismissed = false
        let actions = MessageRowAction.all(for: failed, workspace: state) { dismissed = true }
        try #require(actions.first { $0.kind == .delete }).run()

        #expect(dismissed)
        #expect(state.selectedPendingOutgoingMediaMessages.isEmpty)
        #expect(state.pendingOutgoingMediaMessagesByConversation.isEmpty)
    }

    /// A failed media send offers its recovery twice on purpose — the link row under the bubble,
    /// where the failure already is, and the ⋯ menu every other row uses.
    ///
    /// Retry only under the bubble: Remove is destructive and belongs in the menu with the other
    /// destructive actions, which is the regression this guards. The bubble had only the link row
    /// for as long as it existed, so a reader who wanted the failed send gone had nowhere to go.
    @MainActor
    @Test func aFailedMediaSendOffersRetryUnderTheBubbleAndRemovalOnlyInItsMenu() async throws {
        let runtime = FakeMarmotRuntime(accounts: [desktopAccount()])
        runtime.installGroup(messageGroup())
        let state = WorkspaceState(clientFactory: { runtime })
        await state.bootstrap()

        let attachment = PendingMediaAttachment(
            fileName: "photo.png",
            mediaType: "image/png",
            data: Data([0x01]),
            dim: nil
        )
        let failed = PendingOutgoingMediaMessage(
            id: UUID(),
            attachments: [attachment],
            caption: "",
            state: .failed
        )

        let menu = MessageRowAction.all(for: failed, workspace: state)
        #expect(menu.map(\.kind).contains(.retry))
        #expect(
            menu.map(\.kind).contains(.delete),
            "removal is the action the bubble's own link row does not offer, so the menu has to"
        )

        // The ⋯ is there to be reached for on a failed row, and on nothing else: a send still on its
        // way out has nothing to retry and no cancellation story in the core.
        #expect(
            PendingOutgoingMessageRecovery.showsOverflowControl(
                hasFailed: true, isHovering: true, isMenuPresented: false))
        #expect(
            PendingOutgoingMessageRecovery.showsOverflowControl(
                hasFailed: true, isHovering: false, isMenuPresented: true),
            "the control cannot vanish out from under an open menu")
        #expect(
            !PendingOutgoingMessageRecovery.showsOverflowControl(
                hasFailed: true, isHovering: false, isMenuPresented: false))
        #expect(
            !PendingOutgoingMessageRecovery.showsOverflowControl(
                hasFailed: false, isHovering: true, isMenuPresented: false),
            "a send still in flight would offer two actions that do nothing")

        // And a send in flight carries no menu at all, rather than an empty one.
        let inFlight = PendingOutgoingMediaMessage(
            id: UUID(),
            attachments: [attachment],
            caption: "",
            state: .uploading
        )
        #expect(MessageRowAction.all(for: inFlight, workspace: state).isEmpty)
    }

    @MainActor
    @Test func invalidatedRowGetsTheSameOverflowMenuAsALiveOne() async throws {
        // An invalidated row used to have no ⋯ at all — `supportsChatActions` refused everything,
        // so a bubble wearing the same red failure marker as any other failed send offered nothing,
        // not even Delete. It now carries the whole menu, retry included: it is drawn with the
        // user's own words, and a failure the app declines to act on is a bubble they are stuck
        // with.
        let account = desktopAccount()
        let runtime = FakeMarmotRuntime(accounts: [account])
        runtime.installGroup(messageGroup())
        let state = WorkspaceState(clientFactory: { runtime })
        await state.bootstrap()

        func message(id: String, invalidated: Bool) -> MessageItem {
            MessageItem(
                id: id,
                groupIdHex: "group",
                sourceMessageIdHex: "source-\(id)",
                senderAccountIdHex: account.accountIdHex,
                senderName: "Desktop Account",
                body: "Meet at seven",
                sentAt: .now,
                invalidationStatus: invalidated ? "LosingBranch" : nil,
                isOutgoing: true
            )
        }

        let invalidated = message(id: "invalidated", invalidated: true)
        let live = message(id: "live", invalidated: false)

        #expect(invalidated.supportsChatActions)
        #expect(invalidated.canRetryDelivery(at: .now))

        let invalidatedKinds = MessageRowAction.all(for: invalidated, workspace: state).map(\.kind)
        #expect(invalidatedKinds.first == .retry)
        // Everything a delivered row offers, and nothing withheld: the only difference between the
        // two lists is the retry a failure earns.
        #expect(
            invalidatedKinds.filter { $0 != .retry }
                == MessageRowAction.all(for: live, workspace: state).map(\.kind)
        )

        // The destructive action is a real one, not a local-only consolation.
        #expect(state.messageDeletionCapability(invalidated).canDeleteForEveryone)
    }

    @MainActor
    @Test func invalidatedRowRetryReDrivesConvergenceLikeAnyOtherFailedSend() async throws {
        let account = desktopAccount()
        let runtime = FakeMarmotRuntime(accounts: [account])
        runtime.installGroup(messageGroup())
        let state = WorkspaceState(clientFactory: { runtime })
        await state.bootstrap()

        let invalidated = MessageItem(
            id: "invalidated",
            groupIdHex: "group",
            sourceMessageIdHex: "source-event",
            senderAccountIdHex: account.accountIdHex,
            senderName: "Desktop Account",
            body: "Meet at seven",
            sentAt: .now,
            invalidationStatus: "LosingBranch",
            isOutgoing: true
        )

        let retry = try #require(
            MessageRowAction.all(for: invalidated, workspace: state).first { $0.kind == .retry }
        )
        retry.run()
        await Self.waitUntil { runtime.retryGroupConvergenceCallCount == 1 }

        #expect(runtime.retryGroupConvergenceCallCount == 1)

        // An *incoming* invalidated row wears the same marker but is nobody's send to re-drive.
        let incoming = MessageItem(
            id: "incoming-invalidated",
            groupIdHex: "group",
            sourceMessageIdHex: "source-incoming",
            senderAccountIdHex: "alice1234567890alice1234567890alice1234567890alice1234567890alic",
            senderName: "Alice",
            body: "Bring the keys",
            sentAt: .now,
            invalidationStatus: "LosingBranch",
            isOutgoing: false
        )
        #expect(!incoming.canRetryDelivery(at: .now))
        #expect(!MessageRowAction.all(for: incoming, workspace: state).contains { $0.kind == .retry })
    }

    @MainActor
    @Test func retryPutsTheRowBackToSendingInsteadOfHangingAProgressLineUnderIt() async throws {
        // A retry is a send going out again, so the row wears what a first attempt wears: the clock
        // in the bubble's own footer. It used to keep the failure marker and grow a "Retrying…"
        // line underneath instead, which is the one piece of the failure story rendered outside the
        // bubble. The recovery row rides on the same marker, so it stands down with it.
        let account = desktopAccount()
        let runtime = FakeMarmotRuntime(accounts: [account])
        runtime.installGroup(messageGroup())
        let state = WorkspaceState(clientFactory: { runtime })
        await state.bootstrap()

        let sentAt = Date.now.addingTimeInterval(-(MessageItem.pendingDeliveryGrace + 1))
        let failed = MessageItem(
            id: "failed",
            groupIdHex: "group",
            sourceMessageIdHex: nil,
            senderAccountIdHex: account.accountIdHex,
            senderName: "Desktop Account",
            body: "Say something while I work",
            sentAt: sentAt,
            isOutgoing: true
        )
        let delivered = MessageItem(
            id: "delivered",
            groupIdHex: "group",
            sourceMessageIdHex: "source-event",
            senderAccountIdHex: account.accountIdHex,
            senderName: "Desktop Account",
            body: "This one landed",
            sentAt: sentAt,
            isOutgoing: true
        )

        #expect(state.deliveryIndicator(for: failed, at: .now) == .failed)

        runtime.messageActionGateEnabled = true
        let retry = Task { await state.retryDelivery(of: failed) }
        await Self.waitUntil { runtime.didReachMessageActionGate }

        #expect(state.deliveryIndicator(for: failed, at: .now) == .sending)
        // Group-scoped, like the core call it wraps: a second failed row in the same chat is being
        // carried by this same retry and goes back to "Sending" with it.
        let sibling = MessageItem(
            id: "sibling",
            groupIdHex: "group",
            sourceMessageIdHex: nil,
            senderAccountIdHex: account.accountIdHex,
            senderName: "Desktop Account",
            body: "Me too",
            sentAt: sentAt,
            isOutgoing: true
        )
        #expect(state.deliveryIndicator(for: sibling, at: .now) == .sending)
        // A row that was never failed is untouched — the retry does not repaint the whole chat.
        #expect(state.deliveryIndicator(for: delivered, at: .now) == .delivered)

        runtime.releaseMessageActionGate()
        await retry.value

        // The row is still unconfirmed once the window closes, so the failure marker comes back
        // with its recovery row rather than the bubble being left on a clock forever.
        #expect(state.deliveryIndicator(for: failed, at: .now) == .failed)
    }

    @MainActor
    @Test func retriedOutgoingMediaBubbleStillOffersItsOverflowMenuAfterFailingAgain() async throws {
        // The reported shape of the bug: the ⋯ was missing on a message that had already been
        // retried, not only on one that had just failed. A retry walks the bubble back through
        // `.uploading`, so the menu has to come back with the failure rather than being a
        // first-failure-only affordance.
        let account = desktopAccount()
        let runtime = FakeMarmotRuntime(accounts: [account])
        runtime.installGroup(messageGroup())
        let state = WorkspaceState(clientFactory: { runtime })
        await state.bootstrap()
        let draftKey = try #require(state.selectedComposerDraftKey)

        state.appendPendingMediaAttachment(
            PendingMediaAttachment(
                fileName: "notes.txt",
                mediaType: "text/plain",
                data: Data("hello media".utf8),
                dim: nil
            ),
            for: draftKey
        )
        await Self.settleComposerMediaUploads(state)

        runtime.sendMediaAttachmentsError = FakeMarmotRuntimeError.mediaUploadFailed
        await state.sendDraft()
        await Self.settlePendingOutgoingMediaSends(state)

        let failed = try #require(state.selectedPendingOutgoingMediaMessages.first)

        // Two failed retries, not one: the menu must survive every trip through `.uploading`, not
        // just the first.
        for _ in 0..<2 {
            let retry = try #require(
                MessageRowAction.all(for: failed, workspace: state).first { $0.kind == .retry }
            )
            retry.run()
            await Self.settlePendingOutgoingMediaSends(state)

            let retried = try #require(state.selectedPendingOutgoingMediaMessages.first)
            #expect(retried.state == .failed)
            #expect(MessageRowAction.all(for: retried, workspace: state).map(\.kind) == [.retry, .delete])
        }

        #expect(runtime.sendMediaAttachmentsCallCount == 3)
    }

    @MainActor
    @Test func failedOutgoingMediaMessageCanBeDiscarded() async throws {
        let account = desktopAccount()
        let runtime = FakeMarmotRuntime(accounts: [account])
        runtime.installGroup(messageGroup())
        let state = WorkspaceState(clientFactory: { runtime })
        await state.bootstrap()
        let draftKey = try #require(state.selectedComposerDraftKey)

        state.appendPendingMediaAttachment(
            PendingMediaAttachment(
                fileName: "notes.txt",
                mediaType: "text/plain",
                data: Data("hello media".utf8),
                dim: nil
            ),
            for: draftKey
        )
        await Self.settleComposerMediaUploads(state)

        runtime.sendMediaAttachmentsError = FakeMarmotRuntimeError.mediaUploadFailed
        await state.sendDraft()
        await Self.settlePendingOutgoingMediaSends(state)

        let failed = try #require(state.selectedPendingOutgoingMediaMessages.first)
        state.discardPendingOutgoingMediaMessage(failed.id)

        #expect(state.selectedPendingOutgoingMediaMessages.isEmpty)
        #expect(state.pendingOutgoingMediaMessagesByConversation.isEmpty)
    }

    @MainActor
    @Test func composerEmptiesBeforeThePublishReturns() async throws {
        // Send hands the message off and returns, so the thumbnails must not sit in the composer
        // for the length of the relay round-trip looking like nothing happened.
        let account = desktopAccount()
        let runtime = FakeMarmotRuntime(accounts: [account])
        runtime.installGroup(messageGroup())
        let state = WorkspaceState(clientFactory: { runtime })
        await state.bootstrap()
        let draftKey = try #require(state.selectedComposerDraftKey)

        state.appendPendingMediaAttachment(
            PendingMediaAttachment(
                fileName: "notes.txt",
                mediaType: "text/plain",
                data: Data("hello media".utf8),
                dim: nil
            ),
            for: draftKey
        )
        state.draftText = "Project notes"
        await Self.settleComposerMediaUploads(state)

        // Arm the gate only now: staging would otherwise block on it too.
        runtime.messageActionGateEnabled = true
        await state.sendDraft()

        // The composer is already empty and Send is usable again, with the publish still gated.
        #expect(state.pendingMediaAttachments.isEmpty)
        #expect(state.pendingMediaUploadStates.isEmpty)
        #expect(state.draftText.isEmpty)
        #expect(!state.isSending)
        await Self.waitUntil { runtime.didReachMessageActionGate }
        #expect(runtime.sendMediaAttachmentsCallCount == 1)
        #expect(state.selectedPendingOutgoingMediaMessages.map(\.state) == [.publishing])

        runtime.releaseMessageActionGate()
        await Self.settlePendingOutgoingMediaSends(state)

        #expect(state.pendingMediaAttachments.isEmpty)
        #expect(state.draftText.isEmpty)
        #expect(state.selectedPendingOutgoingMediaMessages.isEmpty)
    }

    @MainActor
    @Test func textComposerEmptiesBeforeThePublishReturns() async throws {
        // A plain text send must empty the composer on hand-off, exactly like the media path.
        // Holding the text for the length of the relay round-trip left it sitting in the input
        // beside the bubble it had already become — the same content visible twice.
        let account = desktopAccount()
        let runtime = FakeMarmotRuntime(accounts: [account])
        runtime.installGroup(messageGroup())
        let state = WorkspaceState(clientFactory: { runtime })
        await state.bootstrap()

        state.draftText = "Project notes"
        runtime.messageActionGateEnabled = true
        await state.sendDraft()

        // Send returned with the publish still gated: the input is empty and the button is back.
        #expect(state.draftText.isEmpty)
        #expect(!state.isSending)
        await Self.waitUntil { runtime.didReachMessageActionGate }

        runtime.releaseMessageActionGate()
        await Self.settleOutgoingTextSends(state)

        #expect(runtime.sentText == SentText(groupIdHex: "group", text: "Project notes"))
        #expect(state.draftText.isEmpty)
    }

    @MainActor
    @Test func replyComposerEmptiesBeforeThePublishReturns() async throws {
        // Same hand-off for the reply path: the quoted-reply bar goes with the text.
        let account = desktopAccount()
        let runtime = FakeMarmotRuntime(accounts: [account])
        runtime.installGroup(messageGroup())
        let state = WorkspaceState(clientFactory: { runtime })
        await state.bootstrap()

        state.replyDraftContext = MessageReplyContext(
            targetMessageId: "parent",
            senderName: "Alice",
            body: "The launch plan is ready."
        )
        state.draftText = "Looks good to me."
        runtime.messageActionGateEnabled = true
        await state.sendDraft()

        #expect(state.draftText.isEmpty)
        #expect(state.replyDraftContext == nil)
        #expect(!state.isSending)
        await Self.waitUntil { runtime.didReachMessageActionGate }

        runtime.releaseMessageActionGate()
        await Self.settleOutgoingTextSends(state)

        #expect(
            runtime.repliedMessage
                == SentReply(groupIdHex: "group", targetMessageId: "parent", text: "Looks good to me.")
        )
        #expect(state.draftText.isEmpty)
    }

    @MainActor
    @Test func sendStaysAvailableWhileTheTextMessageIsStillPublishing() async throws {
        // Send must not sit in its loading state for the length of the relay round-trip. Once the
        // message has left the composer it is a bubble carrying its own delivery state, so the
        // button comes back and the user can write and send the next message behind it — the same
        // hybrid media already gets (#710). Repro: hold the publish at the FFI gate and use the
        // composer normally behind it.
        let account = desktopAccount()
        let runtime = FakeMarmotRuntime(accounts: [account])
        runtime.installGroup(messageGroup())
        let state = WorkspaceState(clientFactory: { runtime })
        await state.bootstrap()

        state.draftText = "first message"
        runtime.messageActionGateEnabled = true
        await state.sendDraft()
        await Self.waitUntil { runtime.didReachMessageActionGate }

        // The first message has not published yet, and the composer is already usable again.
        #expect(runtime.publishedTexts.isEmpty)
        #expect(!state.isSending)
        #expect(state.canRecordVoiceMessage)

        state.draftText = "second message"
        #expect(state.canSend)
        await state.sendDraft()
        #expect(state.draftText.isEmpty)
        #expect(!state.isSending)

        runtime.releaseMessageActionGate()
        await Self.settleOutgoingTextSends(state)

        // Both went out, and in the order Send was pressed — the second waits on the first rather
        // than overtaking it through the gate.
        #expect(runtime.sendTextCallCount == 2)
        #expect(runtime.publishedTexts.map(\.text) == ["first message", "second message"])
    }

    @MainActor
    @Test func failedTextSendKeepsTheMessageInAFailedBubble() async throws {
        // Emptying on hand-off must not cost the user their text when the publish fails. The text
        // stays in the transcript as a failed row that owns its retry — not back in the composer,
        // which is a slot the next message may already have taken.
        let account = desktopAccount()
        let runtime = FakeMarmotRuntime(accounts: [account])
        // Details, not a bare group: `canonicalizeMentions` bails on an empty roster, so with only
        // `installGroup` the mention below would be inert and the text would reach the row exactly
        // as typed — passing for the wrong reason.
        runtime.installGroupDetails(groupDetailsFixture(selfAccountIdHex: account.accountIdHex))
        let state = WorkspaceState(clientFactory: { runtime })
        await state.bootstrap()
        state.ensureMentionRosterLoaded()
        let didWarmRoster = await waitFor { !state.mentionRoster().isEmpty }
        #expect(didWarmRoster)

        state.replyDraftContext = MessageReplyContext(
            targetMessageId: "parent",
            senderName: "Alice",
            body: "The launch plan is ready."
        )
        state.draftText = "@Alice ping"
        state.composerMentionSelections = [
            ComposerMentionSelection(
                range: NSRange(location: 0, length: 6),
                displayText: "@Alice",
                npub: "npub1alyce"
            )
        ]
        runtime.replyToMessageError = NSError(
            domain: "test.reply",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "relay unreachable"]
        )
        await state.sendDraft()
        await Self.settleOutgoingTextSends(state)

        let failed = try #require(state.selectedPendingOutgoingTextMessages.first)
        #expect(failed.state == .failed)
        // The wire form, not what was typed: the bubble reads npubs back as names through
        // `MentionDisplayResolver`, which only works because this is what the row carries.
        #expect(failed.text == "@npub1alyce ping")
        // Carried so the retry re-sends it as the reply it was, not as a loose message.
        #expect(failed.replyContext?.targetMessageId == "parent")
        #expect(state.lastError == "relay unreachable")
        // The composer stays free: the failure has a home of its own now, so nothing is pushed back
        // into an input the user may already be typing their next message into.
        #expect(state.draftText.isEmpty)
        #expect(state.composerMentionSelections.isEmpty)
        #expect(state.replyDraftContext == nil)

        // Retry re-publishes that same row rather than minting a second one, and re-publishes the
        // canonicalized text — the composer that could have re-derived it is already empty.
        runtime.replyToMessageError = nil
        state.retryPendingOutgoingTextMessage(failed.id)
        await Self.settlePendingOutgoingTextSends(state)
        #expect(state.selectedPendingOutgoingTextMessages.isEmpty)
        #expect(runtime.repliedMessage?.text == "@npub1alyce ping")
    }

    @MainActor
    @Test func retryingAFailedTextSendTwiceInOneTurnPublishesOnce() async throws {
        // Both presses land in a single main-actor turn, which is the whole point: the row only
        // left `.failed` inside the publishing task, a hop later, so a second press read the same
        // failed row and started a second round-trip. Cancelling the first task did not stop it
        // either — nothing on that path consults the flag until after the send has gone out.
        let account = desktopAccount()
        let runtime = FakeMarmotRuntime(accounts: [account])
        runtime.installGroup(messageGroup())
        let state = WorkspaceState(clientFactory: { runtime })
        await state.bootstrap()

        runtime.sendTextError = NSError(
            domain: "test.send",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "relay unreachable"]
        )
        state.draftText = "ping"
        await state.sendDraft()
        await Self.settleOutgoingTextSends(state)

        let failed = try #require(state.selectedPendingOutgoingTextMessages.first)
        #expect(failed.state == .failed)
        #expect(runtime.sendTextCallCount == 1)

        runtime.sendTextError = nil
        state.retryPendingOutgoingTextMessage(failed.id)
        state.retryPendingOutgoingTextMessage(failed.id)
        // Read before any suspension point, so this is the synchronous transition itself and not
        // the task's: leaving `.failed` here is what makes the guard a single-flight lock.
        #expect(state.selectedPendingOutgoingTextMessages.first?.state == .publishing)

        await Self.settlePendingOutgoingTextSends(state)
        // The failed attempt plus one retry. Counted at the top of the fake's `sendText`, ahead of
        // its own error, so a second retry that got as far as the core would be visible here.
        #expect(runtime.sendTextCallCount == 2)
        #expect(state.selectedPendingOutgoingTextMessages.isEmpty)
    }

    @MainActor
    @Test func textSendQueuedBehindAStuckSendIsVisibleWhileItWaits() async throws {
        // The reported bug: with the relay unreachable, the first send sits in its round-trip for as
        // long as the timeout lasts. The composer emptied on the Send press and the core has not been
        // called for the second message, so it used to be in neither place — the user watched their
        // message disappear. It is now a queued row in the transcript for that whole window.
        let account = desktopAccount()
        let runtime = FakeMarmotRuntime(accounts: [account])
        runtime.installGroup(messageGroup())
        let state = WorkspaceState(clientFactory: { runtime })
        await state.bootstrap()

        runtime.sendTextError = NSError(
            domain: "test.send",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "relay unreachable"]
        )
        runtime.messageActionGateEnabled = true
        state.draftText = "first message"
        await state.sendDraft()
        await Self.waitUntil { runtime.didReachMessageActionGate }

        state.draftText = "second message"
        await state.sendDraft()
        state.draftText = "third message"
        await state.sendDraft()

        // Both later messages are on screen, in the order Send was pressed, while the first is still
        // stuck in the core.
        #expect(state.draftText.isEmpty)
        #expect(
            state.selectedPendingOutgoingTextMessages.map(\.text)
                == ["first message", "second message", "third message"]
        )
        #expect(state.selectedPendingOutgoingTextMessages.map(\.state) == [.publishing, .queued, .queued])

        runtime.releaseMessageActionGate()
        await Self.settleOutgoingTextSends(state)

        // Nothing was dropped: every message that failed still holds its text and its own retry.
        // The old restore refilled the composer from the *first* failure and then discarded the rest
        // as "the composer is not empty".
        #expect(
            state.selectedPendingOutgoingTextMessages.map(\.text)
                == ["first message", "second message", "third message"]
        )
        #expect(state.selectedPendingOutgoingTextMessages.allSatisfy { $0.state == .failed })
        #expect(state.lastError == "relay unreachable")
    }

    @MainActor
    @Test func pendingTextAndMediaRowsInterleaveInTheOrderTheyWereSent() async throws {
        // The two pending lists wait on different things but share one stretch of transcript. Given
        // a `ForEach` each, every text row would sort ahead of every media row — a photo sent before
        // a sentence would appear after it.
        let account = desktopAccount()
        let runtime = FakeMarmotRuntime(accounts: [account])
        runtime.installGroup(messageGroup())
        let state = WorkspaceState(clientFactory: { runtime })
        await state.bootstrap()
        let draftKey = try #require(state.selectedComposerDraftKey)

        let start = Date()
        func attachment(_ name: String) -> PendingMediaAttachment {
            PendingMediaAttachment(
                fileName: name,
                mediaType: "text/plain",
                data: Data(name.utf8),
                dim: nil
            )
        }

        state.pendingOutgoingTextMessagesByConversation[draftKey] = [
            PendingOutgoingTextMessage(text: "first", createdAt: start),
            PendingOutgoingTextMessage(text: "third", createdAt: start.addingTimeInterval(2)),
        ]
        state.pendingOutgoingMediaMessagesByConversation[draftKey] = [
            PendingOutgoingMediaMessage(
                attachments: [attachment("second.txt")],
                caption: "second",
                createdAt: start.addingTimeInterval(1)
            ),
            PendingOutgoingMediaMessage(
                attachments: [attachment("fourth.txt")],
                caption: "fourth",
                createdAt: start.addingTimeInterval(3)
            ),
        ]

        let rows = state.selectedPendingOutgoingMessageRows
        let labels = rows.map { row in
            switch row {
            case .text(let message): message.text
            case .media(let message): message.caption
            }
        }
        #expect(labels == ["first", "second", "third", "fourth"])
    }

    @MainActor
    @Test func queuedTextSendsStillPublishInTheOrderSendWasPressed() async throws {
        // Parking the messages must not cost the ordering the chain existed for.
        let account = desktopAccount()
        let runtime = FakeMarmotRuntime(accounts: [account])
        runtime.installGroup(messageGroup())
        let state = WorkspaceState(clientFactory: { runtime })
        await state.bootstrap()

        runtime.messageActionGateEnabled = true
        state.draftText = "first message"
        await state.sendDraft()
        await Self.waitUntil { runtime.didReachMessageActionGate }
        state.draftText = "second message"
        await state.sendDraft()

        runtime.releaseMessageActionGate()
        await Self.settleOutgoingTextSends(state)

        #expect(runtime.publishedTexts.map(\.text) == ["first message", "second message"])
        // Each row retires as its publish lands, so the tail empties on its own.
        #expect(state.selectedPendingOutgoingTextMessages.isEmpty)
    }

    @MainActor
    @Test func aPublishingTextRowIsWithheldOnceItsOwnRowArrives() async throws {
        // The core commits an own send locally *inside* the publish call, so the real row can reach
        // the transcript while the relay round-trip is still going. Both rendering would show the
        // same sentence twice — and the count is taken before the publish so an identical message
        // already in the conversation cannot pass for this one's arrival.
        let account = desktopAccount()
        let runtime = FakeMarmotRuntime(accounts: [account])
        runtime.installGroup(messageGroup())
        let state = WorkspaceState(clientFactory: { runtime })
        await state.bootstrap()
        let draftKey = try #require(state.selectedComposerDraftKey)
        let chatId = draftKey.chatId

        func ownRow(id: String, body: String) -> MessageItem {
            MessageItem(
                id: id,
                groupIdHex: chatId,
                sourceMessageIdHex: "source-\(id)",
                senderAccountIdHex: account.accountIdHex,
                senderName: "Desktop Account",
                body: body,
                sentAt: .now,
                isOutgoing: true
            )
        }

        // An identical message the conversation already contained.
        state.messageTimelineStores[chatId]?.replace(with: [ownRow(id: "old", body: "ok")])

        runtime.messageActionGateEnabled = true
        state.draftText = "ok"
        await state.sendDraft()
        await Self.waitUntil { runtime.didReachMessageActionGate }

        // Still shown: the row on screen is the *earlier* "ok", not this send's.
        #expect(state.selectedPendingOutgoingTextMessages.map(\.state) == [.publishing])

        // The local projection for this send lands mid-round-trip.
        state.messageTimelineStores[chatId]?
            .replace(with: [ownRow(id: "old", body: "ok"), ownRow(id: "new", body: "ok")])
        #expect(state.selectedPendingOutgoingTextMessages.isEmpty)

        runtime.releaseMessageActionGate()
        await Self.settleOutgoingTextSends(state)
    }

    @MainActor
    @Test func sendIsAvailableAgainImmediatelyWhileTheAttachmentIsStillUploading() async throws {
        // The point of the hybrid: staging starts the upload, but a Send pressed before it lands
        // still goes through — the composer empties, the wait moves to a loading bubble, and the
        // user can immediately type and send the next message.
        let account = desktopAccount()
        let runtime = FakeMarmotRuntime(accounts: [account])
        runtime.installGroup(messageGroup())
        let state = WorkspaceState(clientFactory: { runtime })
        await state.bootstrap()
        let draftKey = try #require(state.selectedComposerDraftKey)

        await runtime.uploadReleaseGate.hold("slow.txt")
        state.appendPendingMediaAttachment(
            PendingMediaAttachment(
                fileName: "slow.txt",
                mediaType: "text/plain",
                data: Data("slow".utf8),
                dim: nil
            ),
            for: draftKey
        )
        state.draftText = "Look at this"
        #expect(state.canSend)

        await state.sendDraft()

        // Composer free, message parked, upload still held — and nothing published yet.
        #expect(state.pendingMediaAttachments.isEmpty)
        #expect(state.draftText.isEmpty)
        #expect(state.selectedPendingOutgoingMediaMessages.map(\.state) == [.uploading])
        #expect(runtime.sendMediaAttachmentsCallCount == 0)

        // The next message does not have to wait behind it.
        state.draftText = "And this"
        #expect(state.canSend)
        await state.sendDraft()
        await Self.settleOutgoingTextSends(state)
        #expect(runtime.sendTextCallCount == 1)

        // Releasing the upload lets the parked message finish on its own, carrying its caption.
        await runtime.uploadReleaseGate.release("slow.txt")
        await Self.settlePendingOutgoingMediaSends(state)

        #expect(runtime.uploadMediaCallCount == 1)
        #expect(runtime.sentMediaAttachments.last?.fileNames == ["slow.txt"])
        #expect(runtime.sentMediaAttachments.last?.caption == "Look at this")
        #expect(state.selectedPendingOutgoingMediaMessages.isEmpty)
    }

    @MainActor
    @Test func messagesSentBackToBackPublishInThePressedOrder() async throws {
        // Two messages sent moments apart must arrive in that order even when the second one's
        // upload finishes first — the publish chain, not Blossom, decides the reading order.
        let account = desktopAccount()
        let runtime = FakeMarmotRuntime(accounts: [account])
        runtime.installGroup(messageGroup())
        let state = WorkspaceState(clientFactory: { runtime })
        await state.bootstrap()
        let draftKey = try #require(state.selectedComposerDraftKey)

        await runtime.uploadReleaseGate.hold("first.txt", "second.txt")
        for fileName in ["first.txt", "second.txt"] {
            state.appendPendingMediaAttachment(
                PendingMediaAttachment(
                    fileName: fileName,
                    mediaType: "text/plain",
                    data: Data(fileName.utf8),
                    dim: nil
                ),
                for: draftKey
            )
            await state.sendDraft()
            // Send empties the composer, so the next iteration starts from a clean strip.
            #expect(state.pendingMediaAttachments.isEmpty)
        }
        #expect(state.selectedPendingOutgoingMediaMessages.count == 2)

        await runtime.uploadReleaseGate.release("second.txt")
        await runtime.uploadReleaseGate.release("first.txt")
        await Self.settlePendingOutgoingMediaSends(state)

        #expect(runtime.sentMediaAttachments.map(\.fileNames) == [["first.txt"], ["second.txt"]])
    }

    @MainActor
    @Test func clearingComposerDraftsCancelsStagedUploads() async throws {
        // Chat deletion, account removal and logout all drop drafts wholesale. The stage-time
        // uploads used to keep running against a composer that no longer exists, and their entries
        // were never reclaimed from `pendingMediaUploadTasks`.
        let account = desktopAccount()
        let runtime = FakeMarmotRuntime(accounts: [account])
        runtime.installGroup(messageGroup())
        let state = WorkspaceState(clientFactory: { runtime })
        await state.bootstrap()
        let draftKey = try #require(state.selectedComposerDraftKey)

        func stageHeldAttachment(_ fileName: String) async -> PendingMediaAttachment {
            await runtime.uploadReleaseGate.hold(fileName)
            let attachment = PendingMediaAttachment(
                fileName: fileName,
                mediaType: "text/plain",
                data: Data(fileName.utf8),
                dim: nil
            )
            state.appendPendingMediaAttachment(attachment, for: draftKey)
            return attachment
        }

        let perChat = await stageHeldAttachment("per-chat.txt")
        #expect(state.pendingMediaUploadTasks[perChat.id] != nil)
        state.clearComposerDrafts(for: [draftKey.chatId], accountId: draftKey.accountId)
        #expect(state.pendingMediaUploadTasks.isEmpty)

        let perAccount = await stageHeldAttachment("per-account.txt")
        #expect(state.pendingMediaUploadTasks[perAccount.id] != nil)
        state.clearComposerDrafts(forAccountId: draftKey.accountId)
        #expect(state.pendingMediaUploadTasks.isEmpty)

        let all = await stageHeldAttachment("all.txt")
        #expect(state.pendingMediaUploadTasks[all.id] != nil)
        state.clearAllComposerDrafts()
        #expect(state.pendingMediaUploadTasks.isEmpty)

        for fileName in ["per-chat.txt", "per-account.txt", "all.txt"] {
            await runtime.uploadReleaseGate.release(fileName)
        }
    }

    @MainActor
    @Test func attachmentStagedDuringSendSurvivesTheComposerClear() async throws {
        // The remove button is hidden while `isSending`, but *adding* is only gated on the draft key
        // and the free slot count — paste, drop and the importer all still work mid-publish. Clearing
        // the whole draft entry after the send therefore used to discard an attachment the user
        // staged while the publish was in flight, with no trace that it had ever been added.
        let account = desktopAccount()
        let runtime = FakeMarmotRuntime(accounts: [account])
        runtime.installGroup(messageGroup())
        let state = WorkspaceState(clientFactory: { runtime })
        await state.bootstrap()
        let draftKey = try #require(state.selectedComposerDraftKey)

        state.appendPendingMediaAttachment(
            PendingMediaAttachment(
                fileName: "sent.txt",
                mediaType: "text/plain",
                data: Data("sent".utf8),
                dim: nil
            ),
            for: draftKey
        )
        await Self.settleComposerMediaUploads(state)

        // Arm the gate only now: staging would otherwise block on it too.
        runtime.messageActionGateEnabled = true
        await state.sendDraft()
        await Self.waitUntil { runtime.didReachMessageActionGate }
        #expect(state.pendingMediaAttachments.isEmpty)

        let staged = PendingMediaAttachment(
            fileName: "staged.txt",
            mediaType: "text/plain",
            data: Data("staged".utf8),
            dim: nil
        )
        state.appendPendingMediaAttachment(staged, for: draftKey)
        #expect(state.pendingMediaAttachments.map(\.fileName) == ["staged.txt"])

        runtime.releaseMessageActionGate()
        await Self.settlePendingOutgoingMediaSends(state)

        // The publish carried only what Send snapshotted, and the late arrival is still staged.
        #expect(runtime.sentMediaAttachments.last?.fileNames == ["sent.txt"])
        #expect(state.pendingMediaAttachments.map(\.fileName) == ["staged.txt"])
        #expect(state.pendingMediaUploadStates[staged.id] != nil)
    }

    @MainActor
    @Test func failedSendDoesNotDisturbAttachmentsStagedMeanwhile() async throws {
        // The composer moved on the moment Send was pressed, so a publish that fails afterwards
        // must land entirely on its own bubble — never reach back into a strip the user has since
        // refilled.
        let account = desktopAccount()
        let runtime = FakeMarmotRuntime(accounts: [account])
        runtime.installGroup(messageGroup())
        let state = WorkspaceState(clientFactory: { runtime })
        await state.bootstrap()
        let draftKey = try #require(state.selectedComposerDraftKey)

        let sent = PendingMediaAttachment(
            fileName: "sent.txt",
            mediaType: "text/plain",
            data: Data("sent".utf8),
            dim: nil
        )
        state.appendPendingMediaAttachment(sent, for: draftKey)
        state.draftText = "Project notes"
        await Self.settleComposerMediaUploads(state)

        runtime.sendMediaAttachmentsError = FakeMarmotRuntimeError.mediaUploadFailed
        runtime.messageActionGateEnabled = true
        await state.sendDraft()
        await Self.waitUntil { runtime.didReachMessageActionGate }

        let staged = PendingMediaAttachment(
            fileName: "staged.txt",
            mediaType: "text/plain",
            data: Data("staged".utf8),
            dim: nil
        )
        state.appendPendingMediaAttachment(staged, for: draftKey)
        state.draftText = "Second draft"

        runtime.releaseMessageActionGate()
        await Self.settlePendingOutgoingMediaSends(state)

        #expect(state.selectedPendingOutgoingMediaMessages.map(\.state) == [.failed])
        #expect(state.selectedPendingOutgoingMediaMessages.first?.attachments == [sent])
        #expect(state.pendingMediaAttachments.map(\.fileName) == ["staged.txt"])
        #expect(state.pendingMediaUploadStates[staged.id] != nil)
        #expect(state.draftText == "Second draft")
    }

    @MainActor
    @Test func outgoingMediaRendersFromCacheWithoutDownloadingItBack() async throws {
        // The sender is holding the plaintext it just published, so its own bubble has no reason to
        // fetch the blob back from Blossom and decrypt it. Before this was cached at send time the
        // bubble sat in `.loading` and needed a manual retry once the media index caught up.
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("whitenoise-media-cache-tests-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: root) }

        let account = desktopAccount()
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
        // The projected message carries whichever reference was actually published, so the bubble
        // looks the attachment up by the same key the send path cached it under.
        runtime.timelineMessagesHandler = { [weak runtime] _ in
            guard let reference = runtime?.sentMediaAttachments.last?.attachments.first else {
                return TimelinePageFfi(messages: [], hasMoreBefore: false, hasMoreAfter: false)
            }
            return TimelinePageFfi(
                messages: [
                    timelineMessage(
                        id: "media",
                        direction: "outbound",
                        groupIdHex: "direct-group",
                        sender: account.accountIdHex,
                        plaintext: "Project notes",
                        recordedAt: 1_700_000_010,
                        mediaJson: mediaJson(for: reference)
                    )
                ],
                hasMoreBefore: false,
                hasMoreAfter: false
            )
        }

        let plaintext = Data("hello media".utf8)
        let state = WorkspaceState(
            mediaDiskCache: messageMediaDiskCache(root: root),
            clientFactory: { runtime }
        )
        await state.bootstrap()
        let draftKey = try #require(state.selectedComposerDraftKey)
        state.appendPendingMediaAttachment(
            PendingMediaAttachment(fileName: "notes.txt", mediaType: "text/plain", data: plaintext, dim: nil),
            for: draftKey
        )
        state.draftText = "Project notes"
        await Self.settleComposerMediaUploads(state)
        await state.sendDraft()
        await Self.settlePendingOutgoingMediaSends(state)

        let message = try #require(state.messagesByChat["direct-group"]?.first)
        let attachment = try #require(message.mediaAttachments.first)

        await state.loadMediaAttachment(attachment, for: message)

        guard case .loaded(let download) = state.mediaDownloadState(for: message, attachment: attachment) else {
            Issue.record("Expected the outgoing attachment to load straight from the cache")
            return
        }
        #expect(download.data == plaintext)
        #expect(download.fileName == "notes.txt")
        #expect(runtime.downloadMediaCallCount == 0)
    }

    @MainActor
    @Test func pastedImageAttachmentAppendsToComposer() async throws {
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
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("whitenoise-macTests.\(UUID().uuidString)"))
        pasteboard.clearContents()
        defer { pasteboard.clearContents() }
        let item = NSPasteboardItem()
        #expect(item.setData(try Self.testPNGData(width: 36, height: 24), forType: .png))
        #expect(pasteboard.writeObjects([item]))
        let state = WorkspaceState(clientFactory: { runtime })

        await state.bootstrap()
        await state.addPastedMediaAttachments(from: pasteboard)

        let attachment = try #require(state.pendingMediaAttachments.first)
        #expect(state.pendingMediaAttachments.count == 1)
        #expect(attachment.kind == .image)
        #expect(attachment.mediaType == "image/jpeg")
        #expect(attachment.dim == "36x24")
        #expect(attachment.fileName.hasPrefix("pasted-image-"))
        #expect(attachment.fileName.hasSuffix(".jpg"))

        // A pasted image is sendable straight away; its upload catches up in the bubble.
        #expect(state.canSend)
        await Self.settleComposerMediaUploads(state)
        #expect(state.canSend)
    }

    @MainActor
    @Test func pastedImageFileURLAppendsToComposerInsteadOfPathText() async throws {
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
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let imageURL = directory.appendingPathComponent("screenshot.png")
        try Self.testPNGData(width: 40, height: 28).write(to: imageURL)
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("whitenoise-macTests.\(UUID().uuidString)"))
        pasteboard.clearContents()
        defer { pasteboard.clearContents() }
        let item = NSPasteboardItem()
        #expect(item.setString(imageURL.absoluteString, forType: .fileURL))
        #expect(item.setString(imageURL.path, forType: .string))
        #expect(pasteboard.writeObjects([item]))
        let state = WorkspaceState(clientFactory: { runtime })

        await state.bootstrap()
        await state.addPastedMediaAttachments(from: pasteboard)

        let attachment = try #require(state.pendingMediaAttachments.first)
        #expect(state.pendingMediaAttachments.count == 1)
        #expect(attachment.kind == .image)
        #expect(attachment.mediaType == "image/jpeg")
        #expect(attachment.dim == "40x28")
        #expect(attachment.fileName == "screenshot.png.jpg")
        #expect(state.draftText.isEmpty)
    }

    @MainActor
    @Test func endedMembershipDisablesSendingWhileChatStaysListed() async throws {
        // A group the local account was removed from stays in the chat list so the
        // history remains readable, but the core rejects sends to it
        // (`invalid_transition`), so both `canSend` and `sendDraft` must gate on it.
        let account = AccountSummaryFfi(
            label: "Desktop Account",
            accountIdHex: "abcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890",
            localSigning: true,
            externalSigning: false,
            signedOut: false,
            running: true
        )
        let runtime = FakeMarmotRuntime(accounts: [account])
        var removedGroup = messageGroup()
        removedGroup.selfMembership = .removed
        runtime.installGroups([removedGroup])
        let state = WorkspaceState(clientFactory: { runtime })

        await state.bootstrap()

        let chat = try #require(state.selectedChat)
        #expect(chat.id == "group")
        #expect(chat.selfMembership == .removed)
        #expect(chat.isNoLongerMember)

        state.draftText = "still there?"
        #expect(!state.canSend)

        await state.sendDraft()

        #expect(runtime.sendTextCallCount == 0)
        #expect(state.draftText == "still there?")

        // Attachments arriving via drag-and-drop / file import bypass the hidden
        // composer, so the state-level gate must refuse them too — otherwise they
        // accumulate invisibly behind the membership-ended notice.
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let attachmentURL = directory.appendingPathComponent("notes.txt")
        try Data("dropped file".utf8).write(to: attachmentURL)

        await state.addMediaAttachments(from: [attachmentURL])

        #expect(state.pendingMediaAttachments.isEmpty)
        #expect(!state.canSend)

        let pasteboard = NSPasteboard(name: NSPasteboard.Name("whitenoise-macTests.\(UUID().uuidString)"))
        pasteboard.clearContents()
        defer { pasteboard.clearContents() }
        let item = NSPasteboardItem()
        #expect(item.setData(try Self.testPNGData(width: 16, height: 16), forType: .png))
        #expect(pasteboard.writeObjects([item]))

        await state.addPastedMediaAttachments(from: pasteboard)

        #expect(state.pendingMediaAttachments.isEmpty)
        #expect(!state.canSend)
    }

    @MainActor
    @Test func preparedMediaAttachmentIsDiscardedWhenSelectionChangesDuringPrep() async throws {
        // Issue #245: media/voice prep captures the composer draft key before an async prep
        // step. If the user switches chats while prep is in flight, the finished attachment
        // must be discarded rather than filed under the chat they just left. The append is
        // gated by `appendPendingMediaAttachmentIfSelectionUnchanged`, which discards when the
        // live selection no longer matches the captured key.
        let account = AccountSummaryFfi(
            label: "Desktop Account",
            accountIdHex: "abcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890",
            localSigning: true,
            externalSigning: false,
            signedOut: false,
            running: true
        )
        let runtime = FakeMarmotRuntime(accounts: [account])
        runtime.installGroups([messageGroup(), directGroup()])
        let state = WorkspaceState(clientFactory: { runtime })
        await state.bootstrap()

        guard let chatA = state.activeChats.first(where: { $0.id == "group" }),
            let chatB = state.activeChats.first(where: { $0.id == "direct-group" })
        else {
            Issue.record("Expected both test chats")
            return
        }

        state.selectChat(chatA)
        guard let staleKey = state.selectedComposerDraftKey else {
            Issue.record("Expected a composer draft key for chat A")
            return
        }

        let attachment = PendingMediaAttachment(
            fileName: "notes.txt",
            mediaType: "text/plain",
            data: Data("hello media".utf8),
            dim: nil
        )

        // Simulate the user switching to chat B while prep is in flight, then the prep
        // completing with chat A's captured key.
        state.selectChat(chatB)
        let appended = state.appendPendingMediaAttachmentIfSelectionUnchanged(attachment, for: staleKey)

        #expect(!appended)
        // Nothing lands in the chat the user left, nor in the chat they are now viewing.
        #expect(state.pendingMediaAttachmentsByConversation[staleKey] == nil)
        #expect(state.pendingMediaAttachments.isEmpty)

        // Sanity check the positive path: with selection unchanged the attachment is appended.
        state.selectChat(chatA)
        let appendedAgain = state.appendPendingMediaAttachmentIfSelectionUnchanged(attachment, for: staleKey)
        #expect(appendedAgain)
        #expect(state.pendingMediaAttachments.map(\.fileName) == ["notes.txt"])
    }

    @MainActor
    @Test func mediaSendRefreshesSelectedTimelineImmediately() async throws {
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
        let reference = mediaAttachmentReference(mediaType: "text/plain", fileName: "notes.txt")
        runtime.timelineMessagesHandler = { query in
            return TimelinePageFfi(
                messages: [
                    timelineMessage(
                        id: "media",
                        direction: "outbound",
                        groupIdHex: "direct-group",
                        sender: account.accountIdHex,
                        plaintext: "Project notes",
                        recordedAt: 1_700_000_010,
                        mediaJson: mediaJson(for: reference)
                    )
                ],
                hasMoreBefore: false,
                hasMoreAfter: false
            )
        }
        let state = WorkspaceState(clientFactory: { runtime })
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let attachmentURL = directory.appendingPathComponent("notes.txt")
        try Data("hello media".utf8).write(to: attachmentURL)

        await state.bootstrap()
        await state.addMediaAttachments(from: [attachmentURL])
        state.draftText = "Project notes"
        await Self.settleComposerMediaUploads(state)
        await state.sendDraft()
        await Self.settlePendingOutgoingMediaSends(state)

        #expect(runtime.uploadMediaCallCount == 1)
        #expect(runtime.sendMediaAttachmentsCallCount == 1)
        #expect(runtime.timelineMessageQueries.last?.groupIdHex == "direct-group")
        #expect(state.messagesByChat["direct-group"]?.map(\.id) == ["media"])
        #expect(state.messagesByChat["direct-group"]?.first?.mediaAttachments.count == 1)
        #expect(state.messagesByChat["direct-group"]?.first?.body == "Project notes")
    }

    @MainActor
    @Test func sendDraftDropsOverlappingDuplicateInvocation() async throws {
        // Issue #78: sendDraft() must guard against reentrancy. Send hands the publish off and
        // returns, so the disabled-button window is gone entirely — what stops a second invocation
        // delivered by Return auto-repeat or a double event is that the composer was emptied
        // synchronously on hand-off (`!isSending` covers the narrower window before that lands).
        // Repro: hold the publish at the FFI gate, fire an overlapping second send, then release.
        // Only one text must be sent.
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
        let state = WorkspaceState(clientFactory: { runtime })

        await state.bootstrap()
        state.draftText = "only once"

        // Arm the gate so the handed-off publish suspends inside sendText().
        runtime.messageActionGateEnabled = true
        await state.sendDraft()
        await Self.waitUntil { runtime.didReachMessageActionGate }

        // Overlapping second invocation, with the first message still unpublished: it must find
        // the composer already empty and return without reaching the FFI.
        await state.sendDraft()
        #expect(runtime.sendTextCallCount == 1)

        // Release the gate and let the publish finish.
        runtime.releaseMessageActionGate()
        await Self.settleOutgoingTextSends(state)

        #expect(runtime.sendTextCallCount == 1)
        #expect(runtime.sentText == SentText(groupIdHex: "direct-group", text: "only once"))
        #expect(state.draftText.isEmpty)
        #expect(state.isSending == false)
    }

    @MainActor
    @Test func retryDeliveryUsesConvergenceWithoutResendingText() async throws {
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
        let state = WorkspaceState(clientFactory: { runtime })
        await state.bootstrap()

        // Sent far enough back that the row has already stopped reading as "Sending" — retry is
        // gated on the grace window having passed, so a fixed literal date would decide the
        // outcome by whichever side of it the test host's clock happens to be on.
        let pending = MessageItem(
            id: "pending",
            groupIdHex: "direct-group",
            sourceMessageIdHex: nil,
            senderAccountIdHex: account.accountIdHex,
            senderName: "Desktop Account",
            body: "Do not duplicate me",
            sentAt: .now.addingTimeInterval(-(MessageItem.pendingDeliveryGrace + 1)),
            isOutgoing: true
        )
        await state.retryDelivery(of: pending)

        #expect(runtime.retryGroupConvergenceCallCount == 1)
        #expect(runtime.retriedGroupIdHex == "direct-group")
        #expect(runtime.sendTextCallCount == 0)
        #expect(state.inFlightMessageRetryScopes.isEmpty)
    }

    @MainActor
    @Test func retryDeliveryIsRefusedWhileTheSendIsStillInsideItsGraceWindow() async throws {
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
        let state = WorkspaceState(clientFactory: { runtime })
        await state.bootstrap()

        // A send this young still shows the clock glyph, so neither the bubble's recovery row nor
        // the context menu offers Retry — and the workspace refuses it if one somehow fires.
        let justSent = MessageItem(
            id: "just-sent",
            groupIdHex: "direct-group",
            sourceMessageIdHex: nil,
            senderAccountIdHex: account.accountIdHex,
            senderName: "Desktop Account",
            body: "Still on its way",
            sentAt: .now,
            isOutgoing: true
        )
        await state.retryDelivery(of: justSent)

        #expect(runtime.retryGroupConvergenceCallCount == 0)
    }

    @MainActor
    @Test func retryDeliveryMarksTheConversationRetryingWhileTheConvergenceRuns() async throws {
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
        let state = WorkspaceState(clientFactory: { runtime })
        await state.bootstrap()

        let pending = MessageItem(
            id: "pending",
            groupIdHex: "direct-group",
            sourceMessageIdHex: nil,
            senderAccountIdHex: account.accountIdHex,
            senderName: "Desktop Account",
            body: "Say something while I work",
            sentAt: .now.addingTimeInterval(-(MessageItem.pendingDeliveryGrace + 1)),
            isOutgoing: true
        )

        #expect(MessageRowAction.all(for: pending, workspace: state).contains { $0.kind == .retry })

        // Hold the convergence at the FFI gate: this is the window the bubble spends showing
        // "Retrying…" instead of its Retry/Delete row, and it is the only feedback the click gets.
        runtime.messageActionGateEnabled = true
        let retry = Task { await state.retryDelivery(of: pending) }
        await Self.waitUntil { runtime.didReachMessageActionGate }

        #expect(state.isRetryingDelivery(of: pending))

        // The context menu and hover overflow drop Retry for that window too, rather than offering
        // a click `retryDelivery` would refuse.
        #expect(!MessageRowAction.all(for: pending, workspace: state).contains { $0.kind == .retry })

        // Group-scoped, like the core call it wraps: a second failed row in the same chat is being
        // carried by this same retry and says so.
        let sibling = MessageItem(
            id: "sibling",
            groupIdHex: "direct-group",
            sourceMessageIdHex: nil,
            senderAccountIdHex: account.accountIdHex,
            senderName: "Desktop Account",
            body: "Me too",
            sentAt: .now.addingTimeInterval(-(MessageItem.pendingDeliveryGrace + 1)),
            isOutgoing: true
        )
        #expect(state.isRetryingDelivery(of: sibling))

        // A second click during that window must not mint a second convergence.
        await state.retryDelivery(of: sibling)
        #expect(runtime.retryGroupConvergenceCallCount == 1)

        runtime.releaseMessageActionGate()
        await retry.value

        #expect(!state.isRetryingDelivery(of: pending))
        #expect(runtime.retryGroupConvergenceCallCount == 1)
        // Retry comes back once the window closes — the in-flight scope was what withheld it, not
        // the row losing its claim to a retry.
        #expect(MessageRowAction.all(for: pending, workspace: state).contains { $0.kind == .retry })
    }

    @MainActor
    @Test func sendDraftClearsOnlyTheSendingChatWhenSelectionChangesDuringSend() async throws {
        // Issue #239: sendDraft() captures the composer draft key on entry, then awaits the FFI
        // send. The post-send clears (draftText/replyDraftContext) must target that captured key,
        // not the *live* selection — otherwise switching chats while the send is in flight wipes
        // the newly selected conversation's composer state instead of the one we sent from.
        // Repro: draft + reply in chat A, hold its send in-flight at the FFI gate, switch to chat
        // B and draft/reply there, release the gate. Only chat A's composer state must be cleared.
        let account = AccountSummaryFfi(
            label: "Desktop Account",
            accountIdHex: "abcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890",
            localSigning: true,
            externalSigning: false,
            signedOut: false,
            running: true
        )
        let runtime = FakeMarmotRuntime(accounts: [account])
        runtime.installGroups([messageGroup(), directGroup()])
        let state = WorkspaceState(clientFactory: { runtime })
        await state.bootstrap()

        guard let chatA = state.activeChats.first(where: { $0.id == "group" }),
            let chatB = state.activeChats.first(where: { $0.id == "direct-group" })
        else {
            Issue.record("Expected both test chats")
            return
        }

        // Compose a draft + reply context in chat A, then send it.
        state.selectChat(chatA)
        guard let chatAKey = state.selectedComposerDraftKey else {
            Issue.record("Expected a composer draft key for chat A")
            return
        }
        state.draftText = "from chat A"
        state.replyDraftContext = MessageReplyContext(
            targetMessageId: "parent-a",
            senderName: "Alice",
            body: "original A"
        )

        // Arm the gate so the handed-off publish suspends inside the reply FFI call.
        runtime.messageActionGateEnabled = true
        await state.sendDraft()
        await Self.waitUntil { runtime.didReachMessageActionGate }

        // The user switches to chat B while the send is in flight and composes there.
        state.selectChat(chatB)
        guard let chatBKey = state.selectedComposerDraftKey else {
            Issue.record("Expected a composer draft key for chat B")
            return
        }
        state.draftText = "from chat B"
        state.replyDraftContext = MessageReplyContext(
            targetMessageId: "parent-b",
            senderName: "Bob",
            body: "original B"
        )

        // Release the gate and let the send finish while chat B is selected.
        runtime.releaseMessageActionGate()
        await Self.settleOutgoingTextSends(state)

        // Chat A carried a reply context, so the send routed through replyToMessage.
        #expect(runtime.replyToMessageCallCount == 1)
        #expect(
            runtime.repliedMessage
                == SentReply(groupIdHex: "group", targetMessageId: "parent-a", text: "from chat A")
        )

        // Chat A (the sending chat) is cleared; chat B (the live selection) is untouched.
        #expect(state.draftTextByConversation[chatAKey] == nil)
        #expect(state.replyDraftContextByConversation[chatAKey] == nil)
        #expect(state.draftTextByConversation[chatBKey] == "from chat B")
        #expect(state.replyDraftContextByConversation[chatBKey]?.targetMessageId == "parent-b")
        // And, from chat B's perspective, its composer still reads back its own draft/reply.
        #expect(state.draftText == "from chat B")
        #expect(state.replyDraftContext?.targetMessageId == "parent-b")
    }

    @MainActor
    @Test func reactDropsOverlappingDuplicateButAllowsDifferentEmoji() async throws {
        // Issue #78: react(to:emoji:) must drop a duplicate of the *same* in-flight reaction
        // (same target + emoji) while still allowing a different emoji on the same message.
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
        let state = WorkspaceState(clientFactory: { runtime })
        let message = MessageItem(
            id: "parent",
            senderName: "Desktop Account",
            body: "The launch plan is ready.",
            sentAt: Date(timeIntervalSince1970: 1_700_000_000),
            isOutgoing: true
        )

        await state.bootstrap()

        // Hold the first react in-flight at the FFI gate.
        runtime.messageActionGateEnabled = true
        async let firstReact: Void = state.react(to: message, emoji: "👍")
        while !runtime.didReachMessageActionGate {
            await Task.yield()
        }

        // Duplicate same-emoji react is dropped by the per-target guard.
        await state.react(to: message, emoji: "👍")
        #expect(runtime.reactToMessageCallCount == 1)

        // A different emoji on the same message is a legitimate, distinct action and is allowed.
        await state.react(to: message, emoji: "🎉")
        #expect(runtime.reactToMessageCallCount == 2)

        runtime.releaseMessageActionGate()
        await firstReact

        #expect(runtime.reactToMessageCallCount == 2)
    }

    @MainActor
    @Test func deleteMessageDropsOverlappingDuplicateInvocation() async throws {
        // Issue #78: deleteMessage(_:) must drop a repeated delete of the same in-flight message.
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
        let state = WorkspaceState(clientFactory: { runtime })
        let message = MessageItem(
            id: "parent",
            senderName: "Desktop Account",
            body: "The launch plan is ready.",
            sentAt: Date(timeIntervalSince1970: 1_700_000_000),
            isOutgoing: true
        )

        await state.bootstrap()

        runtime.messageActionGateEnabled = true
        async let firstDelete: Void = state.deleteForEveryone(message)
        while !runtime.didReachMessageActionGate {
            await Task.yield()
        }

        // Overlapping repeated delete of the same message is dropped by the per-target guard.
        await state.deleteForEveryone(message)
        #expect(runtime.deleteMessageCallCount == 1)

        runtime.releaseMessageActionGate()
        await firstDelete

        #expect(runtime.deleteMessageCallCount == 1)
    }

    @MainActor
    @Test func incomingMessageDeleteActionDoesNotPublishDeletion() async throws {
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
        let state = WorkspaceState(clientFactory: { runtime })
        let message = MessageItem(
            id: "incoming-parent",
            senderName: "Alice",
            body: "The launch plan is ready.",
            sentAt: Date(timeIntervalSince1970: 1_700_000_000),
            isOutgoing: false
        )

        await state.bootstrap()
        await state.deleteForEveryone(message)

        #expect(runtime.deletedMessage == nil)
    }

    @MainActor
    @Test func scopedDeletionTargetKeepsOriginatingConversationAfterChatSwitch() async throws {
        let account = desktopAccount()
        let runtime = FakeMarmotRuntime(accounts: [account])
        runtime.installGroups([messageGroup(), directGroup()])
        let state = WorkspaceState(clientFactory: { runtime })
        await state.bootstrap()

        let groupChat = try #require(state.activeChats.first { $0.id == "group" })
        let directChat = try #require(state.activeChats.first { $0.id == "direct-group" })
        state.selectChat(groupChat)
        let message = MessageItem(
            id: "scoped-delete",
            senderName: "Desktop Account",
            body: "Delete from the original group",
            sentAt: Date(timeIntervalSince1970: 1_700_000_000),
            isOutgoing: true
        )
        let target = try #require(state.messageDeletionTarget(for: message))

        state.selectChat(directChat)
        await state.deleteForEveryone(target)

        #expect(
            runtime.deletedMessage
                == DeletedMessage(groupIdHex: groupChat.id, targetMessageId: message.id)
        )
    }

    @MainActor
    @Test func deleteForMeHidesLocallyAndPublishesNothing() async throws {
        let account = desktopAccount()
        let runtime = FakeMarmotRuntime(accounts: [account])
        runtime.installGroupDetails(
            groupDetailsFixture(selfAccountIdHex: account.accountIdHex, selfIsAdmin: false)
        )
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("whitenoise-hidden-message-tests-\(UUID().uuidString)", isDirectory: true)
        let hiddenMessageStore = HiddenMessageFileStore(directoryURL: directory)
        defer { try? FileManager.default.removeItem(at: directory) }
        // Snapshot the shared defaults so the test never wipes real hidden-message state.
        let hiddenDefaultsKey = WorkspaceState.hiddenMessagesDefaultsKey
        let priorHidden = UserDefaults.standard.dictionary(forKey: hiddenDefaultsKey)
        defer {
            if let priorHidden {
                UserDefaults.standard.set(priorHidden, forKey: hiddenDefaultsKey)
            } else {
                UserDefaults.standard.removeObject(forKey: hiddenDefaultsKey)
            }
        }
        let state = WorkspaceState(hiddenMessageStore: hiddenMessageStore, clientFactory: { runtime })
        state.clearAllHiddenMessages()
        let message = MessageItem(
            id: "hide-on-this-device",
            senderName: "Alice",
            body: "Hide this just for me",
            sentAt: Date(timeIntervalSince1970: 1_700_000_000),
            isOutgoing: false
        )

        await state.bootstrap()
        let chat = try #require(state.selectedChat)
        await state.refreshConversationMetadata(for: chat)
        let accountId = try #require(state.activeAccountId)

        // A regular member may hide any message for themselves but not for everyone.
        let capability = state.messageDeletionCapability(message)
        #expect(capability.canDeleteForMe)
        #expect(!capability.canDeleteForEveryone)

        state.deleteForMe(message)

        // Publishes nothing, records the hide, and filters it from a full window replace so it
        // stays gone across reprojection and restart.
        #expect(runtime.deletedMessage == nil)
        #expect(state.hiddenMessageIds(accountId: accountId, groupIdHex: chat.id).contains(message.id))
        #expect(state.filterHiddenMessages([message], groupIdHex: chat.id).isEmpty)
        #expect(
            try hiddenMessageStore.loadAll()[
                HiddenMessageScope(accountId: accountId, groupIdHex: chat.id)
            ] == [message.id]
        )
        #expect(UserDefaults.standard.object(forKey: hiddenDefaultsKey) == nil)
    }

    @MainActor
    @Test func legacyHiddenMessagesMigrateToProtectedStore() async throws {
        let account = desktopAccount()
        let runtime = FakeMarmotRuntime(accounts: [account])
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("whitenoise-hidden-message-migration-\(UUID().uuidString)", isDirectory: true)
        let hiddenMessageStore = HiddenMessageFileStore(directoryURL: directory)
        defer { try? FileManager.default.removeItem(at: directory) }

        let hiddenDefaultsKey = WorkspaceState.hiddenMessagesDefaultsKey
        let priorHidden = UserDefaults.standard.dictionary(forKey: hiddenDefaultsKey)
        defer {
            if let priorHidden {
                UserDefaults.standard.set(priorHidden, forKey: hiddenDefaultsKey)
            } else {
                UserDefaults.standard.removeObject(forKey: hiddenDefaultsKey)
            }
        }
        let scope = HiddenMessageScope(accountId: account.accountIdHex, groupIdHex: "group")
        UserDefaults.standard.set(
            ["\(scope.accountId)\u{1F}\(scope.groupIdHex)": ["legacy-hidden"]],
            forKey: hiddenDefaultsKey
        )

        let state = WorkspaceState(hiddenMessageStore: hiddenMessageStore, clientFactory: { runtime })
        await state.bootstrap()

        #expect(state.hiddenMessageIds(accountId: scope.accountId, groupIdHex: scope.groupIdHex) == ["legacy-hidden"])
        #expect(try hiddenMessageStore.loadAll()[scope] == ["legacy-hidden"])
        #expect(UserDefaults.standard.object(forKey: hiddenDefaultsKey) == nil)
    }

    @MainActor
    @Test func groupAdminCanDeleteIncomingMessage() async throws {
        let account = desktopAccount()
        let runtime = FakeMarmotRuntime(accounts: [account])
        runtime.installGroupDetails(
            groupDetailsFixture(selfAccountIdHex: account.accountIdHex, selfIsAdmin: true)
        )
        let state = WorkspaceState(clientFactory: { runtime })
        let message = MessageItem(
            id: "incoming-group-message",
            senderName: "Alice",
            body: "Remove this from the group",
            sentAt: Date(timeIntervalSince1970: 1_700_000_000),
            isOutgoing: false
        )

        await state.bootstrap()
        let chat = try #require(state.selectedChat)
        await state.refreshConversationMetadata(for: chat)

        #expect(state.canDeleteMessage(message))
        await state.deleteForEveryone(message)
        #expect(
            runtime.deletedMessage
                == DeletedMessage(
                    groupIdHex: chat.id,
                    targetMessageId: message.id
                ))
    }

    @MainActor
    @Test func newerFailedConversationMetadataRefreshInvalidatesHeldOlderResult() async throws {
        let account = desktopAccount()
        let runtime = FakeMarmotRuntime(accounts: [account])
        runtime.installGroupDetails(
            groupDetailsFixture(selfAccountIdHex: account.accountIdHex, selfIsAdmin: true)
        )
        let state = WorkspaceState(clientFactory: { runtime })

        await state.bootstrap()
        let chat = try #require(state.selectedChat)
        await state.refreshConversationMetadata(for: chat)
        #expect(state.conversationMetadataByChat[chat.id]?.isSelfAdmin == true)

        runtime.groupDetailsGateEnabled = true
        async let olderRefresh: Void = state.refreshConversationMetadata(for: chat)
        while !runtime.didReachGroupDetailsGate {
            await Task.yield()
        }

        runtime.groupDetailsFailureGroupIds.insert(chat.id)
        await state.refreshConversationMetadata(for: chat)
        #expect(state.conversationMetadataByChat[chat.id] == nil)

        runtime.releaseGroupDetailsGate()
        _ = await olderRefresh

        #expect(state.conversationMetadataByChat[chat.id] == nil)
    }

    @MainActor
    @Test func teardownInvalidatesHeldConversationMetadataRefreshAfterSameAccountReturns() async throws {
        let account = desktopAccount()
        let runtime = FakeMarmotRuntime(accounts: [account])
        runtime.installGroupDetails(groupDetailsFixture(selfAccountIdHex: account.accountIdHex))
        let state = WorkspaceState(clientFactory: { runtime })

        await state.bootstrap()
        let chat = try #require(state.selectedChat)
        let accountId = try #require(state.activeAccountId)
        state.conversationMetadataGenerationByChat[chat.id] = 0

        runtime.groupDetailsGateEnabled = true
        async let staleRefresh: Void = state.refreshConversationMetadata(for: chat)
        while !runtime.didReachGroupDetailsGate {
            await Task.yield()
        }

        state.resetActiveAccountUIState()
        state.activeAccountId = nil

        var currentDetails = groupDetailsFixture(
            selfAccountIdHex: account.accountIdHex,
            selfIsAdmin: false
        )
        currentDetails.group.disappearingMessageSecs = 120
        runtime.installGroupDetails(currentDetails)
        state.activeAccountId = accountId
        await state.refreshConversationMetadata(for: chat)

        let currentMetadata = try #require(state.conversationMetadataByChat[chat.id])
        #expect(currentMetadata.disappearingMessageSecs == 120)
        #expect(!currentMetadata.isSelfAdmin)

        runtime.releaseGroupDetailsGate()
        _ = await staleRefresh

        // A pre-teardown request must not regain ownership when the generation dictionary is
        // rebuilt for the same account and group. See #628 adversarial review.
        #expect(state.conversationMetadataByChat[chat.id] == currentMetadata)
    }

    @MainActor
    @Test func removedChatMetadataTeardownRejectsHeldRefreshAfterGroupIdReuse() async throws {
        let account = desktopAccount()
        let runtime = FakeMarmotRuntime(accounts: [account])
        runtime.installGroupDetails(
            groupDetailsFixture(selfAccountIdHex: account.accountIdHex, selfIsAdmin: true)
        )
        let state = WorkspaceState(clientFactory: { runtime })

        await state.bootstrap()
        let chat = try #require(state.selectedChat)
        let accountId = try #require(state.activeAccountId)
        state.conversationMetadataByChat[chat.id] = ConversationMetadata(
            memberCount: 99,
            disappearingMessageSecs: 30,
            isSelfAdmin: true
        )

        runtime.groupDetailsGateEnabled = true
        async let staleRefresh: Void = state.refreshConversationMetadata(for: chat)
        while !runtime.didReachGroupDetailsGate {
            await Task.yield()
        }

        state.teardownRemovedChatPerChatState(groupIdHex: chat.id, accountId: accountId)
        #expect(state.conversationMetadataByChat[chat.id] == nil)
        #expect(state.conversationMetadataGenerationByChat[chat.id] == nil)

        var rejoinedDetails = groupDetailsFixture(
            selfAccountIdHex: account.accountIdHex,
            selfIsAdmin: false
        )
        rejoinedDetails.group.disappearingMessageSecs = 120
        runtime.installGroupDetails(rejoinedDetails)
        await state.refreshConversationMetadata(for: chat)

        let rejoinedMetadata = try #require(state.conversationMetadataByChat[chat.id])
        #expect(rejoinedMetadata.disappearingMessageSecs == 120)
        #expect(!rejoinedMetadata.isSelfAdmin)

        runtime.releaseGroupDetailsGate()
        _ = await staleRefresh

        #expect(state.conversationMetadataByChat[chat.id] == rejoinedMetadata)
    }

    @MainActor
    @Test func messageActionsRemoveOwnReactionByDeletingReactionEvent() async throws {
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
        let state = WorkspaceState(clientFactory: { runtime })
        let ownReaction = MessageReaction(
            emoji: "👍",
            count: 1,
            isOwn: true,
            ownReactionMessageId: "reaction-event"
        )
        let message = MessageItem(
            id: "parent",
            senderName: "Alice",
            body: "The launch plan is ready.",
            sentAt: Date(timeIntervalSince1970: 1_700_000_000),
            isOutgoing: false,
            reactions: [ownReaction]
        )

        await state.bootstrap()
        await state.removeReaction(ownReaction, from: message)

        #expect(
            runtime.deletedMessage
                == DeletedMessage(
                    groupIdHex: "direct-group",
                    targetMessageId: "reaction-event"
                ))
        #expect(runtime.reactedMessage == nil)
    }

    @Test func reactionRemovalCapabilityFollowsReactionEventId() throws {
        let ownSummaryWithoutEventId = MessageReaction(
            emoji: "👍",
            count: 1,
            isOwn: true
        )
        let userReactionWithEventId = MessageReaction(
            emoji: "👍",
            count: 1,
            isOwn: false,
            ownReactionMessageId: "reaction-event"
        )

        #expect(!ownSummaryWithoutEventId.canRemoveOwnReaction)
        #expect(userReactionWithEventId.canRemoveOwnReaction)
    }

    @MainActor
    @Test func copyingMessageTextUsesConfiguredClipboardWriter() async throws {
        var copiedText = ""
        var copiedConcealed = false
        let state = WorkspaceState(copyTextHandler: {
            copiedText = $0
            copiedConcealed = $1
        })

        state.copyText(
            of: MessageItem(
                id: "message",
                senderName: "Alice",
                body: "Copy this",
                sentAt: Date(timeIntervalSince1970: 1_700_000_000),
                isOutgoing: false
            ))

        #expect(copiedText == "Copy this")
        // Decrypted message bodies are private content and must be marked concealed so
        // clipboard managers / Universal Clipboard treat them as transient.
        #expect(copiedConcealed)
    }

    @MainActor
    @Test func copyingTextDefaultsToConcealed() async throws {
        var copiedConcealed = false
        let state = WorkspaceState(copyTextHandler: { _, concealed in copiedConcealed = concealed })

        state.copyText("anything-copied-from-this-app")

        #expect(copiedConcealed)
    }

    @MainActor
    @Test func deletedAndFailedMessageTextDoesNotCopyPlaceholder() async throws {
        var copiedText = "initial"
        let state = WorkspaceState(copyTextHandler: { text, _ in copiedText = text })
        let sentAt = Date(timeIntervalSince1970: 1_700_000_000)

        state.copyText(
            of: MessageItem(
                id: "deleted",
                senderName: "Alice",
                body: "Message deleted",
                sentAt: sentAt,
                isDeleted: true,
                isOutgoing: false
            ))
        #expect(copiedText == "initial")

        // An invalidated row is not a placeholder — its body is what the sender actually wrote, so
        // it copies like any other message.
        state.copyText(
            of: MessageItem(
                id: "failed",
                senderName: "Alice",
                body: "Lost the branch",
                sentAt: sentAt,
                invalidationStatus: "signature-check-failed",
                isOutgoing: true
            ))

        #expect(copiedText == "Lost the branch")
    }

    @MainActor
    @Test func copyingPlainSettingsTextUsesConfiguredClipboardWriter() async throws {
        var copiedText = ""
        let state = WorkspaceState(copyTextHandler: { text, _ in copiedText = text })

        state.copyText("public-key-value")

        #expect(copiedText == "public-key-value")
    }

    @MainActor
    @Test func copyConfirmationShowsThenClearsItself() async throws {
        let confirmation = CopyConfirmation(duration: .milliseconds(30))

        #expect(!confirmation.isConfirming)
        confirmation.confirm()
        // macOS gives no system-level copy confirmation, so the checkmark is the only signal the
        // user gets that the click landed — it has to be up immediately, not after an await.
        #expect(confirmation.isConfirming)

        try await Task.sleep(for: .milliseconds(300))

        #expect(!confirmation.isConfirming)
    }

    @MainActor
    @Test func repeatedCopyRestartsTheConfirmationWindow() async throws {
        let confirmation = CopyConfirmation(duration: .milliseconds(200))

        confirmation.confirm()
        try await Task.sleep(for: .milliseconds(120))
        // Second copy mid-window: the first reset must not fire and blank the confirmation while
        // the user is still looking at the result of the newer copy.
        confirmation.confirm()
        try await Task.sleep(for: .milliseconds(120))

        #expect(confirmation.isConfirming)
    }

    @Test func conversationTranscriptExportWritesEveryPagedEventChronologically() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("whitenoise-transcript-export-tests-\(UUID().uuidString)", isDirectory: true)
        let scratchDirectory = root.appendingPathComponent("scratch", isDirectory: true)
        let destination = root.appendingPathComponent("complete-transcript.json")
        try fileManager.createDirectory(at: scratchDirectory, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: root) }

        let runtime = FakeMarmotRuntime(accounts: [desktopAccount()])
        runtime.installMessages(
            (0..<1_005).map { index in
                appMessage(
                    id: String(format: "%064x", index + 1),
                    groupIdHex: "group",
                    sender: String(repeating: "a", count: 64),
                    plaintext: "message \(index)",
                    kind: 9,
                    recordedAt: UInt64(index + 1)
                )
            },
            groupIdHex: "group"
        )

        let result = try ConversationTranscriptExport.export(
            client: runtime,
            accountRef: "Desktop Account",
            groupIdHex: "group",
            groupName: "Test Group",
            to: destination,
            exportedAt: Date(timeIntervalSince1970: 1_700_000_000),
            fileManager: fileManager,
            scratchDirectory: scratchDirectory
        )

        let json = try #require(
            JSONSerialization.jsonObject(with: Data(contentsOf: destination)) as? [String: Any]
        )
        let events = try #require(json["events"] as? [[String: Any]])
        #expect(result.eventCount == 1_005)
        #expect(json["event_count"] as? Int == 1_005)
        #expect(events.count == 1_005)
        #expect(events.first?["content"] as? String == "message 0")
        #expect(events.last?["content"] as? String == "message 1004")
        #expect(events.compactMap { $0["index"] as? Int } == Array(0..<1_005))
        #expect(runtime.timelineMessageQueries.count >= 6)
        #expect(try fileManager.contentsOfDirectory(atPath: scratchDirectory.path).isEmpty)
    }

    @Test func conversationTranscriptExportPreservesDocumentAndEventSchema() throws {
        let files = try transcriptExportTestFiles()
        defer { try? FileManager.default.removeItem(at: files.root) }
        let firstId = String(repeating: "1", count: 64)
        let secondId = String(repeating: "2", count: 64)
        let records = [
            timelineMessage(
                id: firstId,
                groupIdHex: "group",
                sender: String(repeating: "b", count: 64),
                plaintext: "started",
                kind: 1311,
                tags: [MessageTagFfi(values: ["stream", "abcd"])],
                recordedAt: 1,
                agentTextStreamJson: #"{"status":"started"}"#
            ),
            timelineMessage(
                id: secondId,
                groupIdHex: "group",
                sender: String(repeating: "a", count: 64),
                plaintext: "final answer",
                kind: 9,
                tags: [MessageTagFfi(values: ["stream", "abcd"])],
                recordedAt: 2,
                agentTextStreamJson: #"{"status":"finalized"}"#
            ),
        ]
        let runtime = FakeMarmotRuntime(accounts: [desktopAccount()])
        runtime.timelineMessagesHandler = { _ in
            TimelinePageFfi(messages: records, hasMoreBefore: false, hasMoreAfter: false)
        }

        _ = try ConversationTranscriptExport.export(
            client: runtime,
            accountRef: "Desktop Account",
            groupIdHex: "group",
            groupName: "Hermes 2",
            to: files.destination,
            exportedAt: Date(timeIntervalSince1970: 1_700_000_000),
            scratchDirectory: files.scratch
        )

        let json = try #require(
            JSONSerialization.jsonObject(with: Data(contentsOf: files.destination)) as? [String: Any]
        )
        let events = try #require(json["events"] as? [[String: Any]])
        #expect(json["v"] as? Int == 1)
        #expect(json["exported_at"] as? String == "2023-11-14T22:13:20Z")
        #expect(json["group_id_hex"] as? String == "group")
        #expect(json["group_name"] as? String == "Hermes 2")
        #expect(json["event_count"] as? Int == 2)
        #expect(events.compactMap { $0["message_id_hex"] as? String } == [firstId, secondId])
        #expect(events[0]["kind"] as? Int == 1311)
        #expect(events[1]["content"] as? String == "final answer")
        #expect(events[1]["agent_text_stream_json"] as? String == #"{"status":"finalized"}"#)
    }

    @Test func conversationTranscriptExportDeduplicatesAcrossPageBoundaries() throws {
        let files = try transcriptExportTestFiles()
        defer { try? FileManager.default.removeItem(at: files.root) }
        let oldest = timelineMessage(
            id: String(repeating: "1", count: 64),
            groupIdHex: "group",
            sender: String(repeating: "a", count: 64),
            plaintext: "oldest",
            recordedAt: 1
        )
        let boundary = timelineMessage(
            id: String(repeating: "2", count: 64),
            groupIdHex: "group",
            sender: String(repeating: "a", count: 64),
            plaintext: "boundary",
            recordedAt: 2
        )
        let newest = timelineMessage(
            id: String(repeating: "3", count: 64),
            groupIdHex: "group",
            sender: String(repeating: "a", count: 64),
            plaintext: "newest",
            recordedAt: 3
        )
        let runtime = FakeMarmotRuntime(accounts: [desktopAccount()])
        runtime.timelineMessagesHandler = { query in
            if query.before == nil {
                return TimelinePageFfi(
                    messages: [newest, boundary], hasMoreBefore: true, hasMoreAfter: false)
            }
            return TimelinePageFfi(
                messages: [boundary, oldest], hasMoreBefore: false, hasMoreAfter: true)
        }

        let result = try ConversationTranscriptExport.export(
            client: runtime,
            accountRef: "Desktop Account",
            groupIdHex: "group",
            groupName: "Test Group",
            to: files.destination,
            scratchDirectory: files.scratch
        )

        let json = try #require(
            JSONSerialization.jsonObject(with: Data(contentsOf: files.destination)) as? [String: Any]
        )
        let events = try #require(json["events"] as? [[String: Any]])
        #expect(result.eventCount == 3)
        #expect(events.compactMap { $0["content"] as? String } == ["oldest", "boundary", "newest"])
        #expect(events.compactMap { $0["index"] as? Int } == [0, 1, 2])
    }

    @Test func conversationTranscriptExportFailsWhenEmptyPageReportsMoreHistory() throws {
        // Regression for #139: an empty page returned with `hasMoreBefore == true` cannot
        // advance the `before` cursor, so the export must fail loudly rather than silently
        // truncating older history. The first page returns one message with more before it,
        // then the second page comes back empty while still claiming more history exists.
        let runtime = FakeMarmotRuntime(accounts: [desktopAccount()])
        let firstId = String(repeating: "1", count: 64)
        runtime.timelineMessagesHandler = { query in
            if query.before == nil {
                return TimelinePageFfi(
                    messages: [
                        timelineMessage(
                            id: firstId,
                            groupIdHex: "group",
                            sender: String(repeating: "a", count: 64),
                            plaintext: "newest",
                            recordedAt: 10
                        )
                    ],
                    hasMoreBefore: true,
                    hasMoreAfter: false
                )
            }
            return TimelinePageFfi(messages: [], hasMoreBefore: true, hasMoreAfter: false)
        }

        let files = try transcriptExportTestFiles()
        defer { try? FileManager.default.removeItem(at: files.root) }
        #expect(throws: ConversationTranscriptExport.ExportError.self) {
            try ConversationTranscriptExport.export(
                client: runtime,
                accountRef: "Desktop Account",
                groupIdHex: "group",
                groupName: "Test Group",
                to: files.destination,
                scratchDirectory: files.scratch
            )
        }
        #expect(!FileManager.default.fileExists(atPath: files.destination.path))
        #expect(try FileManager.default.contentsOfDirectory(atPath: files.scratch.path).isEmpty)
    }

    @Test func conversationTranscriptExportFailsWhenNonEmptyPageDoesNotAdvanceCursor() throws {
        // Regression for the sibling of #139: a *non-empty* page whose oldest message equals
        // the current `before` cursor while `hasMoreBefore == true` also cannot advance, so the
        // export must fail loudly rather than silently truncating older history. The first page
        // returns one message with more before it; the second page returns that same message
        // (same `timelineAt` + `messageIdHex`) while still claiming more history exists.
        let runtime = FakeMarmotRuntime(accounts: [desktopAccount()])
        let firstId = String(repeating: "1", count: 64)
        let boundary = timelineMessage(
            id: firstId,
            groupIdHex: "group",
            sender: String(repeating: "a", count: 64),
            plaintext: "newest",
            recordedAt: 10
        )
        // Every page returns only the boundary message, so after the first page the oldest
        // message always equals the current cursor and the loop can never make progress.
        runtime.timelineMessagesHandler = { _ in
            TimelinePageFfi(messages: [boundary], hasMoreBefore: true, hasMoreAfter: false)
        }

        let files = try transcriptExportTestFiles()
        defer { try? FileManager.default.removeItem(at: files.root) }
        #expect(throws: ConversationTranscriptExport.ExportError.self) {
            try ConversationTranscriptExport.export(
                client: runtime,
                accountRef: "Desktop Account",
                groupIdHex: "group",
                groupName: "Test Group",
                to: files.destination,
                scratchDirectory: files.scratch
            )
        }
        #expect(!FileManager.default.fileExists(atPath: files.destination.path))
        #expect(try FileManager.default.contentsOfDirectory(atPath: files.scratch.path).isEmpty)
    }

    @Test func conversationTranscriptExportStopsCleanlyWhenEmptyPageHasNoMoreHistory() throws {
        // The companion to the regression above: an empty page with `hasMoreBefore == false`
        // is genuinely done and must terminate the loop without throwing.
        let runtime = FakeMarmotRuntime(accounts: [desktopAccount()])
        runtime.timelineMessagesHandler = { _ in
            TimelinePageFfi(messages: [], hasMoreBefore: false, hasMoreAfter: false)
        }

        let files = try transcriptExportTestFiles()
        defer { try? FileManager.default.removeItem(at: files.root) }
        let result = try ConversationTranscriptExport.export(
            client: runtime,
            accountRef: "Desktop Account",
            groupIdHex: "group",
            groupName: "Empty Group",
            to: files.destination,
            scratchDirectory: files.scratch
        )
        let json = try #require(
            JSONSerialization.jsonObject(with: Data(contentsOf: files.destination)) as? [String: Any]
        )
        #expect(result.eventCount == 0)
        #expect(json["event_count"] as? Int == 0)
        #expect((json["events"] as? [Any])?.isEmpty == true)
    }

    @Test func conversationTranscriptExportCancelsBeforeFetchingNextPage() async throws {
        let files = try transcriptExportTestFiles()
        defer { try? FileManager.default.removeItem(at: files.root) }
        let runtime = FakeMarmotRuntime(accounts: [desktopAccount()])
        let firstId = String(repeating: "1", count: 64)
        let firstPageEntered = DispatchSemaphore(value: 0)
        let releaseFirstPage = DispatchSemaphore(value: 0)
        runtime.timelineMessagesHandler = { query in
            if query.before == nil {
                firstPageEntered.signal()
                _ = releaseFirstPage.wait(timeout: .now() + 5)
                return TimelinePageFfi(
                    messages: [
                        timelineMessage(
                            id: firstId,
                            groupIdHex: "group",
                            sender: String(repeating: "a", count: 64),
                            plaintext: "newest",
                            recordedAt: 10
                        )
                    ],
                    hasMoreBefore: true,
                    hasMoreAfter: false
                )
            }
            return TimelinePageFfi(messages: [], hasMoreBefore: false, hasMoreAfter: false)
        }

        let exportTask = Task.detached { () throws -> Void in
            _ = try ConversationTranscriptExport.export(
                client: runtime,
                accountRef: "Desktop Account",
                groupIdHex: "group",
                groupName: "Test Group",
                to: files.destination,
                scratchDirectory: files.scratch
            )
        }
        #expect(await waitForSemaphore(firstPageEntered, timeout: .now() + 2) == .success)

        exportTask.cancel()
        releaseFirstPage.signal()

        do {
            try await exportTask.value
            Issue.record("Expected transcript export to throw CancellationError after cancellation")
        } catch is CancellationError {
            // Expected: cancellation should stop the pagination walk before the next FFI page.
        } catch {
            Issue.record("Expected CancellationError, got \(error)")
        }
        #expect(runtime.timelineMessageQueries.count == 1)
        #expect(!FileManager.default.fileExists(atPath: files.destination.path))
        #expect(try FileManager.default.contentsOfDirectory(atPath: files.scratch.path).isEmpty)
    }

    @Test func conversationTranscriptExportCancelsAndCleansHighVolumeSpool() throws {
        let files = try transcriptExportTestFiles()
        defer { try? FileManager.default.removeItem(at: files.root) }
        let runtime = FakeMarmotRuntime(accounts: [desktopAccount()])
        let pageLimit = Int(ConversationTranscriptExport.pageLimit)
        let highVolumePageCount = 25
        let messageCount = pageLimit * highVolumePageCount
        let naturalExhaustionQueryCount = (messageCount + pageLimit - 1) / pageLimit
        let cancellationQueryCount = naturalExhaustionQueryCount - 1
        runtime.installMessages(
            (0..<messageCount).map { index in
                appMessage(
                    id: String(format: "%064x", index + 1),
                    groupIdHex: "group",
                    sender: String(repeating: "a", count: 64),
                    plaintext: "message \(index)",
                    kind: 9,
                    recordedAt: UInt64(index + 1)
                )
            },
            groupIdHex: "group"
        )

        #expect(throws: CancellationError.self) {
            _ = try ConversationTranscriptExport.export(
                client: runtime,
                accountRef: "Desktop Account",
                groupIdHex: "group",
                groupName: "Large Group",
                to: files.destination,
                scratchDirectory: files.scratch,
                checkCancellation: {
                    if runtime.timelineMessageQueries.count >= cancellationQueryCount {
                        throw CancellationError()
                    }
                }
            )
        }

        #expect(runtime.timelineMessageQueries.count == cancellationQueryCount)
        #expect(!FileManager.default.fileExists(atPath: files.destination.path))
        #expect(try FileManager.default.contentsOfDirectory(atPath: files.scratch.path).isEmpty)
    }

    @Test func conversationTranscriptExportSurfacesFileCreationFailureAndCleansScratch() throws {
        let files = try transcriptExportTestFiles()
        defer { try? FileManager.default.removeItem(at: files.root) }
        let missingDestination = files.root
            .appendingPathComponent("missing", isDirectory: true)
            .appendingPathComponent("transcript.json")
        let runtime = FakeMarmotRuntime(accounts: [desktopAccount()])
        runtime.timelineMessagesHandler = { _ in
            TimelinePageFfi(messages: [], hasMoreBefore: false, hasMoreAfter: false)
        }

        #expect(throws: ConversationTranscriptExport.ExportError.self) {
            try ConversationTranscriptExport.export(
                client: runtime,
                accountRef: "Desktop Account",
                groupIdHex: "group",
                groupName: "Test Group",
                to: missingDestination,
                scratchDirectory: files.scratch
            )
        }
        #expect(!FileManager.default.fileExists(atPath: missingDestination.path))
        #expect(try FileManager.default.contentsOfDirectory(atPath: files.scratch.path).isEmpty)
    }

    @Test func conversationTranscriptExportDoesNotStageBesideSelectedDestination() throws {
        let files = try transcriptExportTestFiles()
        defer { try? FileManager.default.removeItem(at: files.root) }
        try Data("existing transcript".utf8).write(to: files.destination)
        let runtime = FakeMarmotRuntime(accounts: [desktopAccount()])
        runtime.timelineMessagesHandler = { _ in
            TimelinePageFfi(messages: [], hasMoreBefore: false, hasMoreAfter: false)
        }

        _ = try ConversationTranscriptExport.export(
            client: runtime,
            accountRef: "Desktop Account",
            groupIdHex: "group",
            groupName: "Test Group",
            to: files.destination,
            scratchDirectory: files.scratch,
            checkCancellation: {
                let names = try FileManager.default.contentsOfDirectory(atPath: files.root.path)
                if names.contains(where: { $0.hasSuffix(".partial") }) {
                    throw CancellationError()
                }
            }
        )
        let json = try #require(
            JSONSerialization.jsonObject(with: Data(contentsOf: files.destination)) as? [String: Any]
        )
        #expect(json["event_count"] as? Int == 0)
        #expect(
            try FileManager.default.contentsOfDirectory(atPath: files.root.path).sorted()
                == [files.destination.lastPathComponent, files.scratch.lastPathComponent].sorted()
        )
        #expect(try FileManager.default.contentsOfDirectory(atPath: files.scratch.path).isEmpty)
    }

    @Test func conversationTranscriptExportExcludesDecryptedScratchFromBackups() throws {
        let files = try transcriptExportTestFiles()
        defer { try? FileManager.default.removeItem(at: files.root) }
        let runtime = FakeMarmotRuntime(accounts: [desktopAccount()])
        runtime.timelineMessagesHandler = { _ in
            TimelinePageFfi(messages: [], hasMoreBefore: false, hasMoreAfter: false)
        }

        _ = try ConversationTranscriptExport.export(
            client: runtime,
            accountRef: "Desktop Account",
            groupIdHex: "group",
            groupName: "Test Group",
            to: files.destination,
            scratchDirectory: files.scratch,
            checkCancellation: {
                let scratchRoots = try FileManager.default.contentsOfDirectory(
                    at: files.scratch,
                    includingPropertiesForKeys: [.isExcludedFromBackupKey]
                )
                for scratchRoot in scratchRoots {
                    let values = try scratchRoot.resourceValues(forKeys: [.isExcludedFromBackupKey])
                    #expect(values.isExcludedFromBackup == true)
                }
            }
        )
    }

    @Test func conversationTranscriptExportAtomicallyReplacesExistingDestination() throws {
        let files = try transcriptExportTestFiles()
        defer { try? FileManager.default.removeItem(at: files.root) }
        try Data("existing transcript".utf8).write(to: files.destination)
        let runtime = FakeMarmotRuntime(accounts: [desktopAccount()])
        runtime.timelineMessagesHandler = { _ in
            TimelinePageFfi(messages: [], hasMoreBefore: false, hasMoreAfter: false)
        }

        let result = try ConversationTranscriptExport.export(
            client: runtime,
            accountRef: "Desktop Account",
            groupIdHex: "group",
            groupName: "Test Group",
            to: files.destination,
            scratchDirectory: files.scratch
        )

        let json = try #require(
            JSONSerialization.jsonObject(with: Data(contentsOf: files.destination)) as? [String: Any]
        )
        #expect(result.eventCount == 0)
        #expect(json["event_count"] as? Int == 0)
        #expect(
            try FileManager.default.contentsOfDirectory(atPath: files.root.path).sorted()
                == [files.destination.lastPathComponent, files.scratch.lastPathComponent].sorted()
        )
        #expect(try FileManager.default.contentsOfDirectory(atPath: files.scratch.path).isEmpty)
    }

    @Test func conversationTranscriptExportPublishFailureRemovesPartialFile() throws {
        let files = try transcriptExportTestFiles()
        defer { try? FileManager.default.removeItem(at: files.root) }
        try FileManager.default.createDirectory(at: files.destination, withIntermediateDirectories: false)
        let runtime = FakeMarmotRuntime(accounts: [desktopAccount()])
        runtime.timelineMessagesHandler = { _ in
            TimelinePageFfi(messages: [], hasMoreBefore: false, hasMoreAfter: false)
        }

        #expect(throws: ConversationTranscriptExport.ExportError.self) {
            try ConversationTranscriptExport.export(
                client: runtime,
                accountRef: "Desktop Account",
                groupIdHex: "group",
                groupName: "Test Group",
                to: files.destination,
                scratchDirectory: files.scratch
            )
        }
        var isDirectory: ObjCBool = false
        #expect(FileManager.default.fileExists(atPath: files.destination.path, isDirectory: &isDirectory))
        #expect(isDirectory.boolValue)
        #expect(
            try FileManager.default.contentsOfDirectory(atPath: files.root.path).sorted()
                == [files.destination.lastPathComponent, files.scratch.lastPathComponent].sorted()
        )
        #expect(try FileManager.default.contentsOfDirectory(atPath: files.scratch.path).isEmpty)
    }

    @MainActor
    @Test func timelineSenderProfilesReusePrimedGroupMemberDetails() async throws {
        // Regression for #9: loading/reprojecting a timeline should not hit `groupDetails`
        // again after chat-list enrichment has already cached the group's members. The
        // timeline only needs member display names as sender-name fallbacks.
        let account = AccountSummaryFfi(
            label: "Desktop Account",
            accountIdHex: "abcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890",
            localSigning: true,
            externalSigning: false,
            signedOut: false,
            running: true
        )
        let runtime = FakeMarmotRuntime(accounts: [account])
        runtime.installGroupDetails(groupDetailsFixture(selfAccountIdHex: account.accountIdHex))
        let state = WorkspaceState(clientFactory: { runtime })

        await state.bootstrap()
        let didPrimeMemberCache = await waitFor {
            (runtime.groupDetailsCallCounts["group"] ?? 0) >= 1
                && !state.selectedTimelineIsLoadingInitialPage
        }
        #expect(didPrimeMemberCache)
        let groupDetailsCallsAfterBootstrap = runtime.groupDetailsCallCounts["group"] ?? 0
        guard let groupChat = state.activeChats.first else {
            Issue.record("Expected an active group chat")
            return
        }

        // Leave the auto-selected empty timeline so a fresh selection below reloads the
        // subscription snapshot after installing messages, while retaining the member cache
        // primed by chat-list enrichment.
        state.showSettings()
        runtime.installMessages(
            [
                appMessage(
                    id: "alice-message",
                    groupIdHex: "group",
                    sender: "alice1234567890alice1234567890alice1234567890alice1234567890",
                    plaintext: "Timeline sender should reuse cached members.",
                    kind: 9,
                    recordedAt: 1_700_000_000
                )
            ], groupIdHex: "group")

        state.selectChat(groupChat)
        let didLoadTimelineMessage = await waitFor {
            state.messagesByChat["group"]?.map(\.id) == ["alice-message"]
        }

        #expect(didLoadTimelineMessage)
        #expect((runtime.groupDetailsCallCounts["group"] ?? 0) == groupDetailsCallsAfterBootstrap)
    }

    @MainActor
    @Test func timelineSenderProfilesSkipMemberFetchWhenSendersResolve() async throws {
        // Regression for #171: when every non-local sender already resolves from its cached
        // profile display/name, `messageSenderProfiles` must not fetch the group member list or
        // build the member-name fallback map. The fallback is only ever consulted for senders
        // with a blank resolved name, so in the all-resolved steady state the member fetch and
        // dictionary allocation are wasted work on the timeline hot path.
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
        runtime.installGroupDetails(groupDetailsFixture(selfAccountIdHex: account.accountIdHex))
        // Alice has a real profile, so the timeline resolves her name from the profile lookup and
        // never needs the group-member-name fallback.
        runtime.installProfile(
            accountIdHex: aliceId,
            profile: UserProfileMetadataFfi(
                name: "alice",
                displayName: "Alice Cooper",
                about: nil,
                picture: nil,
                nip05: nil,
                lud16: nil
            )
        )
        runtime.installMessages(
            (0..<150).map { index in
                appMessage(
                    id: String(format: "message-%03d", index),
                    groupIdHex: "group",
                    sender: aliceId,
                    plaintext: "Message \(index)",
                    kind: 9,
                    recordedAt: 1_700_000_000 + UInt64(index)
                )
            },
            groupIdHex: "group"
        )
        let state = WorkspaceState(clientFactory: { runtime })

        // Bootstrap auto-selects the only chat and applies its initial timeline window; the
        // explicit pagination call below applies a second window. Both run through
        // `messageSenderProfiles`, exercising the steady-state hot path.
        await state.bootstrap()
        await state.loadMessages(groupIdHex: "group")
        await state.loadOlderMessages(groupIdHex: "group")

        let messages = state.messagesByChat["group"] ?? []
        #expect(messages.first?.senderName == "Alice Cooper")
        // The optimization: no member fetch for the sender-name fallback across any window,
        // because every sender resolved from its profile. Before the #171 fix this would be >= 1.
        #expect(state.timelineSenderMemberFallbackFetchCount == 0)
    }

    @MainActor
    @Test func timelineSenderProfilesFallBackToMemberNameWhenProfileBlank() async throws {
        // Companion to #171: behavior for blank profile names is preserved. When a non-local
        // sender's resolved profile display/name is blank but the group exposes a member display
        // name, the timeline must still fall back to the member name (ahead of the directory
        // display name), which requires fetching the member list.
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
        // `groupDetailsFixture` exposes Alice with member display name "Alice".
        runtime.installGroupDetails(groupDetailsFixture(selfAccountIdHex: account.accountIdHex))
        // No profile/directory name for Alice, so the only usable name is the group member name.
        runtime.accountIdsMissingProfiles.insert(aliceId)
        runtime.installMessages(
            [
                appMessage(
                    id: "alice-message",
                    groupIdHex: "group",
                    sender: aliceId,
                    plaintext: "Member-name fallback still applies.",
                    kind: 9,
                    recordedAt: 1_700_000_000
                )
            ],
            groupIdHex: "group"
        )
        let state = WorkspaceState(clientFactory: { runtime })

        // Bootstrap auto-selects the only chat and applies its initial timeline window.
        await state.bootstrap()
        await state.loadMessages(groupIdHex: "group")

        let messages = state.messagesByChat["group"] ?? []
        #expect(messages.first?.senderName == "Alice")
        // The blank-profile sender needs the fallback, so the member list is fetched at least once.
        #expect(state.timelineSenderMemberFallbackFetchCount >= 1)
    }

    @MainActor
    @Test func messageDebugMetadataSummarizesTimelineKindAndId() async throws {
        let message = MessageItem(
            id: "abcdef0123456789abcdef0123456789",
            senderName: "Agent",
            body: "Working",
            sentAt: Date(timeIntervalSince1970: 1_800),
            timelineAt: 1_234,
            timelineKind: 12_345,
            isOutgoing: false,
            presentation: .agentOperation
        )

        #expect(message.debugTitle == "kind 12345 - agent-operation")
        #expect(message.debugDetail.hasSuffix(" - 1234"))
    }

    @MainActor
    @Test func messageDebugMetadataIncludesSourceAndReplyIdsWhenPresent() async throws {
        let sourceId = "sourceabcdef0123456789abcdef0123456789"
        let replyTargetId = "replyabcdef0123456789abcdef0123456789"
        let page = TimelinePageFfi(
            messages: [
                timelineMessage(
                    id: "localabcdef0123456789abcdef0123456789",
                    sourceMessageIdHex: sourceId,
                    groupIdHex: "group",
                    sender: "alice",
                    plaintext: "Unsupported reply body",
                    kind: 12_345,
                    recordedAt: 1_700_000_000,
                    replyToMessageIdHex: replyTargetId
                )
            ],
            hasMoreBefore: false,
            hasMoreAfter: false
        )

        let message = try #require(MessageItem.timeline(from: page, activeAccountIdHex: "self").first)

        #expect(message.presentation == .unsupported)
        #expect(message.replyContext == nil)
        #expect(message.debugDetail.contains("source \(DisplayText.short(sourceId, head: 10, tail: 8))"))
        #expect(message.debugDetail.contains("reply \(DisplayText.short(replyTargetId, head: 10, tail: 8))"))
    }

    @MainActor
    @Test func chatSwitchPreservesDraftTextPerConversation() async throws {
        let state = WorkspaceState.preview()
        let design = ChatItem.samples[0]
        let nvk = ChatItem.samples[1]

        #expect(state.selectedChat?.id == design.id)
        state.draftText = "Design reply in progress"

        state.selectChat(nvk)
        #expect(state.draftText.isEmpty)
        state.draftText = "NVK reply in progress"

        state.selectChat(design)
        #expect(state.draftText == "Design reply in progress")

        state.selectChat(nvk)
        #expect(state.draftText == "NVK reply in progress")
    }

    @MainActor
    @Test func chatSwitchPreservesReplyDraftContextPerConversation() async throws {
        let state = WorkspaceState.preview()
        let design = ChatItem.samples[0]
        let nvk = ChatItem.samples[1]
        let designReply = MessageItem(
            id: "design-parent",
            senderName: "NVK",
            body: "Design plan",
            sentAt: Date(timeIntervalSince1970: 1_700_000_000),
            isOutgoing: false
        )
        let nvkReply = MessageItem(
            id: "nvk-parent",
            senderName: "NVK",
            body: "Direct ping",
            sentAt: Date(timeIntervalSince1970: 1_700_000_010),
            isOutgoing: false
        )

        #expect(state.selectedChat?.id == design.id)
        state.startReply(to: designReply)

        state.selectChat(nvk)
        #expect(state.replyDraftContext == nil)
        state.startReply(to: nvkReply)

        state.selectChat(design)
        #expect(
            state.replyDraftContext
                == MessageReplyContext(
                    targetMessageId: "design-parent",
                    senderName: "NVK",
                    body: "Design plan"
                ))

        state.selectChat(nvk)
        #expect(
            state.replyDraftContext
                == MessageReplyContext(
                    targetMessageId: "nvk-parent",
                    senderName: "NVK",
                    body: "Direct ping"
                ))
    }

    @MainActor
    @Test func accountSwitchRestoresDraftTextWhenReturningToConversation() async throws {
        let state = WorkspaceState.preview()
        let design = ChatItem.samples[0]

        #expect(state.selectedChat?.id == design.id)
        state.draftText = "draft survives account hop"

        state.selectAccount(AccountItem.samples[1])
        #expect(state.activeAccountId == AccountItem.samples[1].id)
        #expect(state.draftText.isEmpty)

        state.selectAccount(AccountItem.samples[0])
        #expect(state.activeAccountId == AccountItem.samples[0].id)
        #expect(state.selectedChat?.id == design.id)
        #expect(state.draftText == "draft survives account hop")
    }

    @MainActor
    @Test func sharedConversationDraftsAreIsolatedPerAccount() async throws {
        let state = WorkspaceState.preview()
        let sharedChat = ChatItem.samples[1]

        state.selectChat(sharedChat)
        state.draftText = "primary account draft"

        state.selectAccount(AccountItem.samples[1])
        #expect(state.selectedChat?.id == sharedChat.id)
        #expect(state.draftText.isEmpty)
        state.draftText = "backup account draft"

        state.selectAccount(AccountItem.samples[0])
        state.selectChat(sharedChat)
        #expect(state.draftText == "primary account draft")

        state.selectAccount(AccountItem.samples[1])
        #expect(state.selectedChat?.id == sharedChat.id)
        #expect(state.draftText == "backup account draft")
    }

    @MainActor
    @Test func composerDraftChangesDebounceIntoLatestEncryptedBindingSave() async throws {
        let account = desktopAccount()
        let runtime = FakeMarmotRuntime(accounts: [account])
        runtime.installGroup(messageGroup())
        let state = WorkspaceState(clientFactory: { runtime })

        await state.bootstrap()
        #expect(state.selectedChat?.id == "group")
        runtime.clearSyncCallThreadRecords()

        state.draftText = "first"
        state.draftText = "latest"

        let didPersistLatest = await waitFor {
            runtime.storedMessageDraft(accountRef: account.label, groupIdHex: "group")?.content == "latest"
        }
        #expect(didPersistLatest)
        #expect(runtime.syncCallThreadRecord("saveMessageDraft") == [false])
    }

    @MainActor
    @Test func composerDraftRestoresTextMentionIdentityAndAttachmentAfterRestart() async throws {
        let account = desktopAccount()
        let runtime = FakeMarmotRuntime(accounts: [account])
        runtime.installGroupDetails(
            groupDetailsFixture(selfAccountIdHex: account.accountIdHex)
        )

        var firstState: WorkspaceState? = WorkspaceState(clientFactory: { runtime })
        await firstState?.bootstrap()
        #expect(firstState?.selectedChat?.id == "group")

        let visibleDraft = "Hi @Alice"
        firstState?.draftText = visibleDraft
        firstState?.composerMentionSelections = [
            ComposerMentionSelection(
                range: (visibleDraft as NSString).range(of: "@Alice"),
                displayText: "@Alice",
                npub: "npub1alyce"
            )
        ]
        let attachment = PendingMediaAttachment(
            id: UUID(uuidString: "4a31c735-b9cb-4af2-b8ef-85cf8fdc7711")!,
            fileName: "notes.txt",
            mediaType: "text/plain",
            data: Data("private notes".utf8),
            dim: nil
        )
        let firstDraftKey = try #require(firstState?.selectedComposerDraftKey)
        firstState?.appendPendingMediaAttachment(attachment, for: firstDraftKey)
        await firstState?.flushComposerDraftPersistence()

        let stored = try #require(
            runtime.storedMessageDraft(accountRef: account.label, groupIdHex: "group")
        )
        #expect(stored.content == "Hi @npub1alyce")
        #expect(stored.mediaAttachments.map(\.plaintext) == [Data("private notes".utf8)])
        firstState = nil

        let restoredState = WorkspaceState(clientFactory: { runtime })
        await restoredState.bootstrap()

        #expect(restoredState.draftText == visibleDraft)
        #expect(restoredState.composerMentionSelections.count == 1)
        #expect(restoredState.composerMentionSelections.first?.npub == "npub1alyce")
        #expect(restoredState.pendingMediaAttachments == [attachment])

        // Drafts persist plaintext, not Blossom references, so restore has to re-upload before the
        // composer becomes sendable again — one upload for the original staging, one for the
        // restore.
        await Self.settleComposerMediaUploads(restoredState)
        #expect(runtime.uploadMediaCallCount == 2)
        #expect(restoredState.pendingMediaUploadStates[attachment.id]?.isUploaded == true)
        #expect(restoredState.canSend)
    }

    @MainActor
    @Test func liveComposerEditWinsOverHeldPersistentDraftRestore() async throws {
        let account = desktopAccount()
        let runtime = FakeMarmotRuntime(accounts: [account])
        runtime.installGroup(messageGroup())
        runtime.installMessageDraft(
            MessageDraftFfi(
                groupIdHex: "group",
                content: "stale persisted text",
                replyToMessageIdHex: nil,
                mediaAttachments: [],
                createdAtMs: 1,
                updatedAtMs: 1
            ),
            accountRef: account.label
        )
        runtime.messageDraftReadGateEnabled = true
        let state = WorkspaceState(clientFactory: { runtime })

        let bootstrapTask = Task { await state.bootstrap() }
        let didReachRead = await waitFor { runtime.didReachMessageDraftReadGate }
        #expect(didReachRead)
        #expect(state.selectedChat?.id == "group")

        state.draftText = "new local text"
        runtime.releaseMessageDraftReadGate()
        await bootstrapTask.value

        #expect(state.draftText == "new local text")
        await state.flushComposerDraftPersistence()
        #expect(
            runtime.storedMessageDraft(accountRef: account.label, groupIdHex: "group")?.content
                == "new local text"
        )
    }

    @MainActor
    @Test func successfulSendDeletesPersistedComposerDraft() async throws {
        let account = desktopAccount()
        let runtime = FakeMarmotRuntime(accounts: [account])
        runtime.installGroup(messageGroup())
        let state = WorkspaceState(clientFactory: { runtime })

        await state.bootstrap()
        state.draftText = "send once"
        await state.flushComposerDraftPersistence()
        #expect(runtime.storedMessageDraft(accountRef: account.label, groupIdHex: "group") != nil)
        runtime.clearSyncCallThreadRecords()

        await state.sendDraft()
        await Self.settleOutgoingTextSends(state)

        #expect(runtime.sentText?.text == "send once")
        #expect(state.draftText.isEmpty)
        #expect(runtime.storedMessageDraft(accountRef: account.label, groupIdHex: "group") == nil)
        #expect(runtime.syncCallThreadRecord("deleteMessageDraft") == [false])
    }

    @MainActor
    @Test func reloadChatsPrunesDraftsForRemovedConversations() async throws {
        let account = AccountSummaryFfi(
            label: "Desktop Account",
            accountIdHex: "abcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890",
            localSigning: true,
            externalSigning: false,
            signedOut: false,
            running: true
        )
        let runtime = FakeMarmotRuntime(accounts: [account])
        runtime.installGroups([messageGroup(), directGroup()])
        let state = WorkspaceState(clientFactory: { runtime })

        await state.bootstrap()
        let didLoadBothChats = await waitFor {
            Set(state.activeChats.map(\.id)) == ["group", "direct-group"]
        }
        #expect(didLoadBothChats)

        guard let groupChat = state.activeChats.first(where: { $0.id == "group" }) else {
            Issue.record("Expected group chat")
            return
        }
        state.selectChat(groupChat)
        state.draftText = "draft for removed group"

        runtime.installGroups([directGroup()])
        await state.reloadChats()
        #expect(state.activeChats.map(\.id) == ["direct-group"])

        runtime.installGroups([messageGroup(), directGroup()])
        await state.reloadChats()
        guard let restoredGroupChat = state.activeChats.first(where: { $0.id == "group" }) else {
            Issue.record("Expected restored group chat")
            return
        }
        state.selectChat(restoredGroupChat)

        #expect(state.draftText.isEmpty)
    }

    @MainActor
    @Test func newChatComposerOpensInChatColumnWithoutChangingDetailSelection() async throws {
        let state = WorkspaceState.preview()
        let selection = state.selection
        state.draftText = "half-written message"

        state.showNewChat()

        #expect(state.isNewChatComposerVisible)
        #expect(state.selection == selection)
        #expect(state.draftText == "half-written message")
    }

    @MainActor
    @Test func startVoiceRecordingIgnoresConcurrentInvocationWhilePreparing() async {
        // #391: a second mic tap during the permission await must not start another recorder.
        let state = WorkspaceState.preview()
        state.isPreparingVoiceRecording = true

        await state.startVoiceRecording()

        #expect(state.isPreparingVoiceRecording)
        #expect(!state.isRecordingVoiceMessage)
        #expect(state.voiceRecorder == nil)
        #expect(state.voiceRecordingURL == nil)
    }

    @MainActor
    @Test func startVoiceRecordingDoesNotResumeAfterNavigationDuringPermissionAwait() async throws {
        // #441: a suspended mic-permission await must not resume after navigation tears down the
        // composer, including when the user returns to the same chat before granting access.
        let account = AccountSummaryFfi(
            label: "Desktop Account",
            accountIdHex: "abcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890",
            localSigning: true,
            externalSigning: false,
            signedOut: false,
            running: true
        )
        let runtime = FakeMarmotRuntime(accounts: [account])
        runtime.installGroups([messageGroup()])
        let microphoneGate = SuspendingMicrophoneAccessGate()
        let state = WorkspaceState(
            microphoneAccessProvider: { await microphoneGate.provider() },
            clientFactory: { runtime }
        )
        await state.bootstrap()

        guard let chat = state.activeChats.first(where: { $0.id == "group" }) else {
            Issue.record("Expected group chat")
            return
        }
        state.selectChat(chat)

        let recordingTask = Task { await state.startVoiceRecording() }
        #expect(await microphoneGate.waitUntilRequested())
        #expect(state.isPreparingVoiceRecording)

        state.showSettings(.profile)
        state.selectChat(chat)

        microphoneGate.grantAccess()
        await recordingTask.value

        #expect(!state.isRecordingVoiceMessage)
        #expect(state.voiceRecorder == nil)
        #expect(state.voiceRecordingURL == nil)
        #expect(state.voiceRecordingMeterTask == nil)

        state.lastError = nil
        let deniedTask = Task { await state.startVoiceRecording() }
        #expect(await microphoneGate.waitUntilRequested())
        state.showSettings(.profile)
        microphoneGate.denyAccess()
        await deniedTask.value
        #expect(state.lastError == nil)
    }

    @MainActor
    @Test func voiceRecordingDrawsItsTailButSendsTheWholeTakesWaveform() {
        // The live strip shows the last few seconds, so the window it draws is capped. The waveform
        // stored on the sent message is not that window: it is the shape of the whole recording, and
        // reading the capped window meant a two-minute voice note shipped with the waveform of its
        // final seconds. Both are fed from one metering tick, so this pins that the tail stays a
        // tail and the history keeps everything.
        let state = WorkspaceState.preview()
        let overrun = VoiceRecordingWaveform.maximumWindowSampleCount + 20
        let interval = VoiceRecordingLevelMeter.sampleIntervalSeconds

        for index in 0..<overrun {
            // Alternating levels, so a history that had silently become the window would show up as
            // a flat run rather than passing on count alone. One bar's worth of audio per call, so
            // each call owes exactly one bar.
            let quiet = index.isMultiple(of: 2)
            state.appendVoiceRecordingLevels(
                averagePower: quiet ? -44 : -14,
                peakPower: quiet ? -40 : -9,
                recordedSeconds: Double(index + 1) * interval
            )
        }

        #expect(state.voiceRecordingSamples.count == VoiceRecordingWaveform.maximumWindowSampleCount)
        #expect(state.voiceRecordingHistory.count == overrun)
        #expect(
            state.voiceRecordingSamples
                == Array(
                    state.voiceRecordingHistory.suffix(VoiceRecordingWaveform.maximumWindowSampleCount))
        )
        #expect(Set(state.voiceRecordingHistory).count > 2)

        // Teardown has to clear both, or the next recording starts with the last one's bars and sends
        // the last one's waveform.
        state.resetVoiceRecording(deleteFile: false)
        #expect(state.voiceRecordingSamples.isEmpty)
        #expect(state.voiceRecordingHistory.isEmpty)
    }

    @MainActor
    @Test func voiceRecordingStripAdvancesWithTheAudioNotWithTheMeteringTicks() {
        // The strip's horizontal speed is one bar per 40 ms of recorded sound. A metering tick that
        // arrives late owes the bars its silence earned, and one that fires twice for the same audio
        // owes none — so the waveform cannot speed up when the main actor is busy, which is what made
        // it accelerate when each wakeup appended exactly one bar and animated the travel.
        let state = WorkspaceState.preview()
        let interval = VoiceRecordingLevelMeter.sampleIntervalSeconds

        state.appendVoiceRecordingLevels(averagePower: -20, peakPower: -14, recordedSeconds: interval)
        #expect(state.voiceRecordingHistory.count == 1)

        // A duplicate tick for the same moment of audio adds nothing.
        state.appendVoiceRecordingLevels(averagePower: -20, peakPower: -14, recordedSeconds: interval)
        #expect(state.voiceRecordingHistory.count == 1)

        // A tick four intervals late catches the strip up to the audio exactly.
        state.appendVoiceRecordingLevels(averagePower: -20, peakPower: -14, recordedSeconds: interval * 5)
        #expect(state.voiceRecordingHistory.count == 5)

        // And one second of audio is always 25 bars, however many ticks delivered it.
        state.appendVoiceRecordingLevels(averagePower: -20, peakPower: -14, recordedSeconds: 1)
        #expect(state.voiceRecordingHistory.count == Int(1 / interval))

        state.resetVoiceRecording(deleteFile: false)
    }

    @MainActor
    @Test func showSettingsStopsInProgressVoiceRecording() throws {
        // #311: navigating to Settings removes the composer (its Stop/Cancel buttons) from the
        // hierarchy; it must also stop the recorder so the mic is not left hot with no control.
        let state = WorkspaceState.preview()
        let url = try armInProgressVoiceRecording(on: state)

        state.showSettings(.profile)

        #expect(!state.isRecordingVoiceMessage)
        #expect(state.voiceRecorder == nil)
        #expect(state.voiceRecordingURL == nil)
        #expect(state.voiceRecordingMeterTask == nil)
        #expect(state.voiceRecordingSamples.isEmpty)
        #expect(state.voiceRecordingDurationSeconds == 0)
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    @MainActor
    @Test func showNewChatStopsInProgressVoiceRecording() throws {
        // #311: opening the new-chat composer also swaps out the conversation composer, so the
        // recorder must be torn down on this path too.
        let state = WorkspaceState.preview()
        let url = try armInProgressVoiceRecording(on: state)

        state.showNewChat()

        #expect(!state.isRecordingVoiceMessage)
        #expect(state.voiceRecordingMeterTask == nil)
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    @MainActor
    @Test func selectChatStopsInProgressVoiceRecording() throws {
        // Regression guard for the existing `selectChat` cancellation now routed through the
        // shared `leaveActiveConversation()` teardown (#311).
        let state = WorkspaceState.preview()
        let url = try armInProgressVoiceRecording(on: state)
        guard let otherChat = state.activeChats.first(where: { $0.id != state.selectedChat?.id }) else {
            Issue.record("Expected a second chat to switch to")
            return
        }

        state.selectChat(otherChat)

        #expect(!state.isRecordingVoiceMessage)
        #expect(state.voiceRecordingMeterTask == nil)
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    @MainActor
    @Test func decliningSelectedGroupInviteLeavesActiveConversation() async throws {
        let account = desktopAccount()
        var details = groupDetailsFixture(selfAccountIdHex: account.accountIdHex)
        details.group.pendingConfirmation = true
        let runtime = FakeMarmotRuntime(accounts: [account])
        runtime.installGroupDetails(details)
        let state = WorkspaceState(clientFactory: { runtime })

        await state.bootstrap()
        let selectedChat = try #require(state.selectedChat)
        let recordingURL = try armInProgressVoiceRecording(on: state)
        defer { state.cancelVoiceRecording() }
        let transcriptExportTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 10_000_000)
            }
        }
        state.groupTranscriptExportTask = transcriptExportTask
        defer { transcriptExportTask.cancel() }

        await state.declineGroupInvite(for: selectedChat)

        #expect(state.selection != .chat(selectedChat.id))
        #expect(!state.isRecordingVoiceMessage)
        #expect(state.voiceRecordingMeterTask == nil)
        #expect(!FileManager.default.fileExists(atPath: recordingURL.path))
        #expect(transcriptExportTask.isCancelled)
        transcriptExportTask.cancel()
        await transcriptExportTask.value
    }

    @MainActor
    @Test func deletingSelectedGroupLocallyLeavesActiveConversation() async throws {
        let account = desktopAccount()
        let runtime = FakeMarmotRuntime(accounts: [account])
        runtime.installGroupDetails(groupDetailsFixture(selfAccountIdHex: account.accountIdHex))
        let state = WorkspaceState(clientFactory: { runtime })

        await state.bootstrap()
        let selectedChat = try #require(state.selectedChat)
        let recordingURL = try armInProgressVoiceRecording(on: state)
        defer { state.cancelVoiceRecording() }
        let transcriptExportTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 10_000_000)
            }
        }
        state.groupTranscriptExportTask = transcriptExportTask
        defer { transcriptExportTask.cancel() }

        await state.deleteGroupLocally(groupIdHex: selectedChat.id)

        #expect(runtime.locallyDeletedGroupIds == [selectedChat.id])
        #expect(state.selection != .chat(selectedChat.id))
        #expect(!state.isRecordingVoiceMessage)
        #expect(state.voiceRecordingMeterTask == nil)
        #expect(!FileManager.default.fileExists(atPath: recordingURL.path))
        #expect(transcriptExportTask.isCancelled)
        transcriptExportTask.cancel()
        await transcriptExportTask.value
    }

    @MainActor
    @Test func activeAccountNotificationResponseStopsInProgressVoiceRecordingBeforeChatSwitch() async throws {
        // #374: tapping a same-account notification is an implicit chat switch. It must run
        // the same conversation teardown as `selectChat` before the composer belongs to the
        // notified chat, or a live recording/transcript export from chat A can continue under
        // chat B.
        let state = WorkspaceState.preview()
        let account = try #require(state.activeAccount)
        let currentChatId = try #require(state.selectedChat?.id)
        let targetChat = try #require(state.activeChats.first { $0.id != currentChatId })
        let url = try armInProgressVoiceRecording(on: state)
        let transcriptExportTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 10_000_000)
            }
        }
        state.groupTranscriptExportTask = transcriptExportTask
        defer { transcriptExportTask.cancel() }

        state.handleNotificationResponse([
            "groupIdHex": targetChat.id,
            "accountIdHex": account.accountIdHex,
            "accountRef": account.accountRef,
        ])

        #expect(state.selection == .chat(targetChat.id))
        #expect(!state.isRecordingVoiceMessage)
        #expect(state.voiceRecordingMeterTask == nil)
        #expect(!FileManager.default.fileExists(atPath: url.path))
        #expect(transcriptExportTask.isCancelled)
        await transcriptExportTask.value
    }

    @MainActor
    @Test func unresolvableAccountNotificationResponseStopsInProgressVoiceRecordingForActiveChat() throws {
        // The fallback path for stale/missing notification account metadata still allows a chat
        // owned by the active account. That same-account switch must not bypass teardown either.
        let state = WorkspaceState.preview()
        let currentChatId = try #require(state.selectedChat?.id)
        let targetChat = try #require(state.activeChats.first { $0.id != currentChatId })
        let url = try armInProgressVoiceRecording(on: state)

        state.handleNotificationResponse(["groupIdHex": targetChat.id])

        #expect(state.selection == .chat(targetChat.id))
        #expect(!state.isRecordingVoiceMessage)
        #expect(state.voiceRecordingMeterTask == nil)
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    @MainActor
    @Test func removeSelectedChatStopsInProgressVoiceRecordingBeforeAutoReselection() async throws {
        // #362: subscription deltas can remove the selected chat and auto-select a different
        // conversation. That implicit navigation must tear down active conversation resources
        // before the composer belongs to the new chat, or finishing would file chat A's audio
        // under chat B and transcript export pagination would continue after leaving chat A.
        let state = WorkspaceState.preview()
        let account = AccountItem.samples[0]
        let removedChatId = try #require(state.selectedChat?.id)
        let url = try armInProgressVoiceRecording(on: state)
        let transcriptExportTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 10_000_000)
            }
        }
        state.groupTranscriptExportTask = transcriptExportTask
        defer { transcriptExportTask.cancel() }

        state.removeChat(groupIdHex: removedChatId, account: account)

        #expect(state.selection != .chat(removedChatId))
        #expect(state.selectedChat != nil)
        #expect(!state.isRecordingVoiceMessage)
        #expect(state.voiceRecordingMeterTask == nil)
        #expect(!FileManager.default.fileExists(atPath: url.path))
        #expect(transcriptExportTask.isCancelled)
        await transcriptExportTask.value
    }

    @MainActor
    @Test func removingLastSelectedChatStopsTimelineListener() async throws {
        // #525: incremental `removeChat` with no replacement chat must tear down the live
        // timeline listener/subscription; the old path only stopped it via `loadMessages(nextChat)`.
        let account = desktopAccount()
        let runtime = FakeMarmotRuntime(accounts: [account])
        runtime.installGroup(messageGroup())
        runtime.installMessages(
            [
                appMessage(
                    id: "only",
                    groupIdHex: "group",
                    sender: account.accountIdHex,
                    plaintext: "Only chat message",
                    kind: 9,
                    recordedAt: 1_700_000_000
                )
            ], groupIdHex: "group")
        let state = WorkspaceState(clientFactory: { runtime })

        await state.bootstrap()
        let activeAccount = try #require(state.activeAccount)
        let chat = try #require(state.activeChats.first)
        #expect(state.selection == .chat(chat.id))
        let didStartTimeline = await waitFor {
            state.activeTimelineSubscription != nil && state.timelineTask != nil
        }
        #expect(didStartTimeline)
        let timelineTask = try #require(state.timelineTask)

        state.removeChat(groupIdHex: chat.id, account: activeAccount)

        #expect(state.activeChats.isEmpty)
        #expect(state.selectedChat == nil)
        #expect(state.timelineTask == nil)
        #expect(state.timelineTaskGroupId == nil)
        #expect(state.activeTimelineSubscription == nil)
        #expect(state.activeTimelineGroupId == nil)
        #expect(timelineTask.isCancelled)
    }

    @MainActor
    @Test func archivingLastSelectedChatStopsTimelineListener() async throws {
        // #525: incremental archive delta (`moveChatToArchived`) with no replacement chat must
        // tear down the live timeline listener/subscription the same way explicit navigation does.
        let account = desktopAccount()
        let runtime = FakeMarmotRuntime(accounts: [account])
        runtime.installGroup(messageGroup())
        runtime.installMessages(
            [
                appMessage(
                    id: "only",
                    groupIdHex: "group",
                    sender: account.accountIdHex,
                    plaintext: "Only chat message",
                    kind: 9,
                    recordedAt: 1_700_000_000
                )
            ], groupIdHex: "group")
        let state = WorkspaceState(clientFactory: { runtime })

        await state.bootstrap()
        let activeAccount = try #require(state.activeAccount)
        let chat = try #require(state.activeChats.first)
        #expect(state.selection == .chat(chat.id))
        let didStartTimeline = await waitFor {
            state.activeTimelineSubscription != nil && state.timelineTask != nil
        }
        #expect(didStartTimeline)
        let timelineTask = try #require(state.timelineTask)

        await state.applyChatRow(
            ChatListRowFfi(
                groupIdHex: chat.id,
                archived: true,
                pendingConfirmation: false,
                title: "Test Group",
                groupName: "Test Group",
                avatarUrl: nil,
                avatar: nil,
                lastMessage: ChatListMessagePreviewFfi(
                    messageIdHex: "preview",
                    sender: account.accountIdHex,
                    senderDisplayName: nil,
                    plaintext: "Only chat message",
                    contentTokens: emptyMarkdownDocument(),
                    kind: 9,
                    timelineAt: 1_700_000_000,
                    deleted: false
                ),
                unreadCount: 0,
                hasUnread: false,
                unreadMentionCount: 0,
                unreadMention: false,
                firstUnreadMessageIdHex: nil,
                lastReadMessageIdHex: nil,
                lastReadTimelineAt: nil,
                updatedAt: 1_700_000_000,
                selfMembership: .member
            ),
            account: activeAccount
        )

        #expect(state.activeChats.isEmpty)
        #expect(state.archivedChats.count == 1)
        #expect(state.selectedChat == nil)
        #expect(state.timelineTask == nil)
        #expect(state.timelineTaskGroupId == nil)
        #expect(state.activeTimelineSubscription == nil)
        #expect(state.activeTimelineGroupId == nil)
        #expect(timelineTask.isCancelled)
    }

    @MainActor
    @Test func resetToNewInstallStateStopsInProgressVoiceRecording() throws {
        // #311: the full local-data teardown must also release the recorder so a wipe cannot
        // leave the microphone active or plaintext audio writes running in the old state.
        let state = WorkspaceState.preview()
        let url = try armInProgressVoiceRecording(on: state)

        state.resetToNewInstallState(storageRootPath: TestStorageRoot.isolated.resolvedPath())

        #expect(!state.isRecordingVoiceMessage)
        #expect(state.voiceRecordingMeterTask == nil)
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    @MainActor
    @Test func resetToNewInstallStateClearsComposeContacts() {
        let state = WorkspaceState.preview()
        state.composeContacts = [
            ComposeContact(
                accountIdHex: String(repeating: "2", count: 64),
                npub: "npub1accountacontact",
                displayName: "Account A contact",
                pictureURL: "https://example.com/account-a.png",
                lastActivity: Date()
            )
        ]
        state.isLoadingComposeContacts = true
        state.composeContactsGeneration = 41

        state.resetToNewInstallState(storageRootPath: TestStorageRoot.isolated.resolvedPath())

        #expect(state.composeContacts.isEmpty)
        #expect(!state.isLoadingComposeContacts)
        #expect(state.composeContactsGeneration == 42)
    }

    @MainActor
    @Test func resetToNewInstallStateClearsConversationMetadata() {
        let state = WorkspaceState.preview()
        state.conversationMetadataByChat["shared-group"] = ConversationMetadata(
            memberCount: 3,
            disappearingMessageSecs: 60,
            isSelfAdmin: true
        )
        state.conversationMetadataGenerationByChat["shared-group"] = 41

        state.resetToNewInstallState(storageRootPath: TestStorageRoot.isolated.resolvedPath())

        // A full local-data wipe must not retain metadata describing the departed identity's
        // group role, membership, or disappearing-message timer. See #628.
        #expect(state.conversationMetadataByChat.isEmpty)
        #expect(state.conversationMetadataGenerationByChat.isEmpty)
    }

    @MainActor
    @Test func endedMembershipRowUpdateStopsInProgressVoiceRecording() async throws {
        // A removal can land while the user is recording in that very chat. The
        // membership-ended notice then replaces the composer (and its Stop/Cancel
        // controls), so the chat-list row update must also tear down the recorder —
        // the mic must never stay hot with no visible way to stop it (#311).
        let state = WorkspaceState.preview()
        let account = AccountItem.samples[0]
        let selectedChatId = try #require(state.selectedChat?.id)
        let url = try armInProgressVoiceRecording(on: state)

        await state.applyChatRow(
            chatListRow(
                groupIdHex: selectedChatId,
                title: "Marmot Design",
                preview: "you were removed",
                sender: "alice1234567890alice1234567890alice1234567890alice1234567890",
                timelineAt: 1_700_000_000,
                selfMembership: .removed
            ),
            account: account
        )

        #expect(state.selectedChat?.selfMembership == .removed)
        #expect(!state.isRecordingVoiceMessage)
        #expect(state.voiceRecordingMeterTask == nil)
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    @MainActor
    @Test func removedSelectedChatFullSnapshotStopsInProgressVoiceRecordingAndClearsPerChatState() async throws {
        // #507: a reconnect full snapshot can omit the selected chat entirely (not just flip
        // membership). applyChatRows must run the same per-chat teardown and selected-chat
        // transition as removeChat, or selection, recording, transcript export, and cached
        // timeline state can linger after the conversation disappears.
        let state = WorkspaceState.preview()
        let account = AccountItem.samples[0]
        let removedChatId = try #require(state.selectedChat?.id)
        let sender = "alice1234567890alice1234567890alice1234567890alice1234567890"
        let url = try armInProgressVoiceRecording(on: state)
        let transcriptExportTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 10_000_000)
            }
        }
        state.groupTranscriptExportTask = transcriptExportTask
        defer { transcriptExportTask.cancel() }

        state.cachedMessageChatIds.insert(removedChatId)
        let removedTimelineStore = try #require(state.messageTimelineStores[removedChatId])
        #expect(!removedTimelineStore.messages.isEmpty)
        state.timelinePagingByChat[removedChatId] = TimelinePagingState(
            hasMoreBefore: true,
            hasMoreAfter: false,
            isLoadingBefore: false,
            isLoadingAfter: false
        )
        state.timelineInitialLoadGroupId = removedChatId
        let marker = ReadMarker(sentAt: Date(), messageId: "m-removed")
        state.lastMarkedReadMarkers[removedChatId] = marker
        state.lastConfirmedReadMarkers[removedChatId] = marker

        await state.applyChatRows(
            [
                chatListRow(
                    groupIdHex: "chat-nvk",
                    title: "NVK",
                    preview: "Let's keep the left rail fast for account switching.",
                    sender: sender,
                    timelineAt: 1_700_000_001
                ),
                chatListRow(
                    groupIdHex: "chat-relays",
                    title: "Relay Ops",
                    preview: "EU and US White Noise relays both caught up on the last run.",
                    sender: sender,
                    timelineAt: 1_700_000_002
                ),
            ],
            account: account
        )

        #expect(state.selection != .chat(removedChatId))
        #expect(state.selection == .chat("chat-relays"))
        #expect(!state.isRecordingVoiceMessage)
        #expect(state.voiceRecordingMeterTask == nil)
        #expect(!FileManager.default.fileExists(atPath: url.path))
        #expect(transcriptExportTask.isCancelled)
        await transcriptExportTask.value
        #expect(!state.cachedMessageChatIds.contains(removedChatId))
        #expect(state.messageTimelineStores[removedChatId] == nil)
        #expect(removedTimelineStore.messages.isEmpty)
        #expect(state.timelinePagingByChat[removedChatId] == nil)
        #expect(state.timelineInitialLoadGroupId != removedChatId)
        #expect(state.lastMarkedReadMarkers[removedChatId] == nil)
        #expect(state.lastConfirmedReadMarkers[removedChatId] == nil)
    }

    @MainActor
    @Test func endedMembershipBulkRowsUpdateStopsInProgressVoiceRecording() async throws {
        // Sibling of the single-row test above for the bulk snapshot/reconnect path
        // (`applyChatRows`), which also carries membership flips (#311).
        let state = WorkspaceState.preview()
        let account = AccountItem.samples[0]
        let selectedChatId = try #require(state.selectedChat?.id)
        let url = try armInProgressVoiceRecording(on: state)

        await state.applyChatRows(
            [
                chatListRow(
                    groupIdHex: selectedChatId,
                    title: "Marmot Design",
                    preview: "you were removed",
                    sender: "alice1234567890alice1234567890alice1234567890alice1234567890",
                    timelineAt: 1_700_000_000,
                    selfMembership: .removed
                )
            ],
            account: account
        )

        #expect(state.selectedChat?.selfMembership == .removed)
        #expect(!state.isRecordingVoiceMessage)
        #expect(state.voiceRecordingMeterTask == nil)
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    @MainActor
    @Test func archivingChatPreservesComposerDraftAcrossSnapshotReload() async throws {
        // #466: a chat moved active→archived through the full-snapshot reload (`applyChatRows`)
        // must not be treated as removed — its per-conversation composer draft has to survive.
        let state = WorkspaceState.preview()
        let account = AccountItem.samples[0]
        let chatId = "draft-survives-archive"
        let sender = "alice1234567890alice1234567890alice1234567890alice1234567890"

        await state.applyChatRows(
            [chatListRow(groupIdHex: chatId, title: "Planning", preview: "hi", sender: sender, timelineAt: 1)],
            account: account
        )
        let activeChat = try #require(state.chatsByAccount[account.id]?.first { $0.id == chatId })
        state.selectChat(activeChat)
        state.draftText = "see you at 6"
        let draftKey = WorkspaceState.ComposerDraftKey(accountId: account.id, chatId: chatId)
        #expect(state.draftTextByConversation[draftKey] == "see you at 6")

        // Same chat, now archived, via a fresh snapshot.
        await state.applyChatRows(
            [
                ChatListRowFfi(
                    groupIdHex: chatId,
                    archived: true,
                    pendingConfirmation: false,
                    title: "Planning",
                    groupName: "",
                    avatarUrl: nil,
                    avatar: nil,
                    lastMessage: ChatListMessagePreviewFfi(
                        messageIdHex: "preview",
                        sender: sender,
                        senderDisplayName: nil,
                        plaintext: "hi",
                        contentTokens: emptyMarkdownDocument(),
                        kind: 9,
                        timelineAt: 1,
                        deleted: false
                    ),
                    unreadCount: 0,
                    hasUnread: false,
                    unreadMentionCount: 0,
                    unreadMention: false,
                    firstUnreadMessageIdHex: nil,
                    lastReadMessageIdHex: nil,
                    lastReadTimelineAt: nil,
                    updatedAt: 1,
                    selfMembership: .member
                )
            ],
            account: account
        )

        #expect(state.archivedChatsByAccount[account.id]?.contains { $0.id == chatId } == true)
        #expect(state.draftTextByConversation[draftKey] == "see you at 6")
        #expect(state.selection == nil)
        #expect(state.selectedChat == nil)
        #expect(state.timelineTask == nil)
        #expect(!state.cachedMessageChatIds.contains(chatId))
    }
}
