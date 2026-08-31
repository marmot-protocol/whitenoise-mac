//
//  PureValueTests.swift
//  whitenoise-macTests
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

@Suite(.serialized)
struct PureValueTests {
    @Test func ownAccountAvatarLoadsItsPictureWithTheRemoteImagePreferenceOff() {
        // The bug this pins: "Load Remote Profile Images" is off by default, and the profile
        // editor's 96pt avatar went through the same gate as a stranger's. Picking an image
        // uploaded it and updated the draft, then drew initials anyway — no picture, no error,
        // indistinguishable from a broken picker. Your own avatar is not remote content you were
        // sent, so the preference must not reach it.
        #expect(
            RemoteImageDisplayPolicy.loadsRemoteImage(isOwnAccountImage: true, preferenceEnabled: false)
        )
        #expect(
            RemoteImageDisplayPolicy.loadsRemoteImage(isOwnAccountImage: true, preferenceEnabled: true)
        )
    }

    @Test func peerAvatarStillWaitsForTheRemoteImagePreference() {
        // The other half of the rule, and the reason the exemption is a per-call-site flag rather
        // than a default: a peer's `picture` is a URL they chose, so fetching it hands them the
        // viewer's IP address and presence. That stays gated.
        #expect(
            !RemoteImageDisplayPolicy.loadsRemoteImage(isOwnAccountImage: false, preferenceEnabled: false)
        )
        #expect(
            RemoteImageDisplayPolicy.loadsRemoteImage(isOwnAccountImage: false, preferenceEnabled: true)
        )
    }

    @MainActor
    @Test func primaryButtonSizesGrowMonotonicallyAcrossTheWholeScale() {
        // `small` was added after `medium`/`large` were already in use, so the risk is not that it
        // is wrong on its own but that it is wrong *relative* to its neighbours — a rung that
        // shrank the type while growing the padding would still pass every per-size check below.
        // Asserted pairwise across the declared order rather than against fixed numbers, so
        // retuning a value stays legal and reordering the scale does not.
        let scale: [WNPrimaryButtonSize] = [.small, .medium, .large]
        #expect(Set(scale) == Set(WNPrimaryButtonSize.allCases), "a size is missing from the scale")

        for (smaller, larger) in zip(scale, scale.dropFirst()) {
            #expect(smaller.font.size < larger.font.size)
            #expect(smaller.verticalPadding < larger.verticalPadding)
            #expect(smaller.horizontalPadding < larger.horizontalPadding)
        }

        // The outlined tier already had a `.small` rung keyed off `controlSize`; the primary one
        // has to land on the same `ControlSize` or the two tiers cannot be paired at that end.
        #expect(WNPrimaryButtonSize.small.controlSize == .small)
    }

    @MainActor
    @Test func primaryButtonLargeIsBiggerThanMediumOnEveryAxisItControls() {
        // The whole point of the `large` size is that it reads as the one action on the screen.
        // "Bigger" has to hold on all three axes at once — a size that grew its padding while
        // keeping the medium type ramp would just be a loose button, not a prominent one.
        let medium = WNPrimaryButtonSize.medium
        let large = WNPrimaryButtonSize.large

        #expect(large.font.size > medium.font.size)
        #expect(large.verticalPadding > medium.verticalPadding)
        #expect(large.horizontalPadding > medium.horizontalPadding)
        #expect(large.controlSize == .large)
        #expect(medium.controlSize == .regular)

        // The radius is the fourth axis, and it is no longer the size's to hold: it comes from the
        // shared table by way of `controlSize`, which is what keeps a primary button and the
        // `.wnSecondary` one beside it cut alike.
        #expect(
            WNButtonMetrics.cornerRadius(for: large.controlSize)
                > WNButtonMetrics.cornerRadius(for: medium.controlSize))
    }

    @MainActor
    @Test func bothPushButtonTiersDrawOneRadiusAtEveryControlSize() {
        // The two tiers are seen side by side — `Accept` beside `Decline`, `Message` beside
        // `Follow` — so the radius has to come out of one table. It did not: the outline style held
        // a flat 8 while the primary one asked for 12 at `.large`, and a primary button written as a
        // bare glass `Button` asked for nothing at all and got the platform's capsule.
        for controlSize in [ControlSize.mini, .small, .regular, .large, .extraLarge] {
            // `WnButton` uses 8 at every size but `xsmall`, which the mac app has no use for, so 8
            // is the floor rather than a value any size may drop below.
            #expect(WNButtonMetrics.cornerRadius(for: controlSize) >= 8)
        }

        // `.large` is the one size that opens up, and both tiers have to open up with it.
        #expect(WNButtonMetrics.cornerRadius(for: .large) == 12)
        #expect(WNButtonMetrics.cornerRadius(for: .regular) == 8)

        // The sizes hold no radius to compare against any more — `WNPrimaryButtonSize` names only
        // a `controlSize`, and `WNPrimaryButton` takes its outline from the table above. Drift is
        // impossible rather than merely asserted.
        for size in WNPrimaryButtonSize.allCases {
            #expect(WNButtonMetrics.cornerRadius(for: size.controlSize) >= 8)
        }
    }

    @MainActor
    @Test func primaryButtonSizesKeepWnButtonsRadiusFloorAndPositivePadding() {
        for size in WNPrimaryButtonSize.allCases {
            // Interior padding is what grows the native chrome; zero would silently make a size
            // indistinguishable from the platform default.
            #expect(size.verticalPadding > 0)
            #expect(size.horizontalPadding > 0)
        }
    }

    @Test func groupedSplitsAnIdentifierIntoFixedBlocksWithoutDroppingTheRemainder() {
        // The whole npub has to survive the split: a reader checking a key against another
        // screen compares every block, so a lost tail character is a silent wrong answer.
        let npub = "npub1qy8lsm2fmc0ck4lz9r7zx8gz9nkzmk2h5a9ka7xnmp"
        let grouped = DisplayText.grouped(npub)

        #expect(grouped.replacing(" ", with: "") == npub)
        #expect(grouped.hasPrefix("npub 1qy8 lsm2"))
        // 47 characters is not a multiple of 4, so the final block is the short one.
        #expect(grouped.split(separator: " ").last == "nmp")
    }

    @Test func groupedHandlesShortValuesAndARefusedBlockSize() {
        #expect(DisplayText.grouped("") == "")
        #expect(DisplayText.grouped("ab") == "ab")
        #expect(DisplayText.grouped("abcd") == "abcd")
        #expect(DisplayText.grouped("abcde") == "abcd e")
        #expect(DisplayText.grouped("abcdef", every: 2) == "ab cd ef")
        // A non-positive size would loop forever in `stride`; the value comes back untouched.
        #expect(DisplayText.grouped("abcdef", every: 0) == "abcdef")
    }

    @Test func pendingMediaUploadStateExposesItsReferenceOnlyWhenUploaded() {
        let reference = mediaReference(fileName: "photo.png")

        #expect(PendingMediaUploadState.uploaded(reference).reference == reference)
        #expect(PendingMediaUploadState.uploaded(reference).isUploaded)
        #expect(PendingMediaUploadState.uploading.reference == nil)
        #expect(!PendingMediaUploadState.uploading.isUploaded)
        #expect(PendingMediaUploadState.failed.reference == nil)
        #expect(!PendingMediaUploadState.failed.isUploaded)
    }

    @Test func pendingMediaUploadStatesWithDifferentReferencesAreDistinct() {
        // The composer stores these in a dictionary keyed by attachment, and the send path reads
        // the reference back out — collapsing two distinct uploads into one value would publish
        // the same blob twice.
        let first = PendingMediaUploadState.uploaded(mediaReference(fileName: "first.png"))
        let second = PendingMediaUploadState.uploaded(mediaReference(fileName: "second.png"))

        #expect(first != second)
        #expect(Set([first, second]).count == 2)
        #expect(first == PendingMediaUploadState.uploaded(mediaReference(fileName: "first.png")))
    }

    private func mediaReference(fileName: String) -> MediaAttachmentReferenceFfi {
        MediaAttachmentReferenceFfi(
            locators: [MediaLocatorFfi(kind: "blossom", value: "https://example.com/\(fileName)")],
            ciphertextSha256: "cipher-\(fileName)",
            plaintextSha256: "plain-\(fileName)",
            nonceHex: "nonce-\(fileName)",
            fileName: fileName,
            mediaType: "image/png",
            version: .v1,
            sourceEpoch: 1,
            dim: nil,
            thumbhash: nil
        )
    }

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

    /// A nickname is what the picker inserts, so it has to canonicalize — but the published name
    /// stays live too: a draft written before the nickname existed, or one where the sender typed
    /// the name they see elsewhere, must still leave as an npub rather than as literal text.
    @Test func nicknamedMemberCanonicalizesUnderEitherName() {
        let candidates = [mentionCandidate(id: "alice", displayName: "Alice", npub: "npub1alice", nickname: "Mum")]

        #expect(ComposerMentionCanonicalizer.canonicalize("Hi @Mum", candidates: candidates) == "Hi @npub1alice")
        #expect(ComposerMentionCanonicalizer.canonicalize("Hi @Alice", candidates: candidates) == "Hi @npub1alice")
    }

    /// Nicknames are chosen by the viewer, so nothing stops one from colliding with another
    /// member's published name. That is the same ambiguity two identical display names create,
    /// and it has to be resolved the same way: refuse to guess, and let the picker disambiguate.
    @Test func aNicknameCollidingWithAnotherMembersRealNameIsNotGuessed() {
        let candidates = [
            mentionCandidate(id: "alice", displayName: "Alice", npub: "npub1alice", nickname: "Bob"),
            mentionCandidate(id: "bob", displayName: "Bob", npub: "npub1bob"),
        ]

        #expect(ComposerMentionCanonicalizer.canonicalize("Hi @Bob", candidates: candidates) == "Hi @Bob")
        // The names that stayed unique still resolve.
        #expect(ComposerMentionCanonicalizer.canonicalize("Hi @Alice", candidates: candidates) == "Hi @npub1alice")
    }

    @Test func nicknamedMentionCandidateIsFoundByEitherNameAndKeepsThePublishedOne() {
        let nicknamed = mentionCandidate(id: "alice", displayName: "Alice", npub: "npub1alice", nickname: "Mum")

        #expect(nicknamed.displayName == "Mum")
        #expect(nicknamed.publishedDisplayName == "Alice")
        #expect(nicknamed.searchableNames == ["Mum", "Alice"])
        #expect(ComposerMentionQuery.filter([nicknamed], matching: "mum").map(\.id) == ["alice"])
        #expect(ComposerMentionQuery.filter([nicknamed], matching: "alic").map(\.id) == ["alice"])
        #expect(ComposerMentionQuery.filter([nicknamed], matching: "bob").isEmpty)

        // No nickname means nothing is being overridden, so there is no second name to record.
        let plain = mentionCandidate(id: "bob", displayName: "Bob", npub: "npub1bob")
        #expect(plain.publishedDisplayName == nil)
        #expect(plain.searchableNames == ["Bob"])
    }

    /// A nickname is the only name a member who published none has, so it must reach the mention
    /// map — that member renders as truncated bech32 without it.
    @Test func mentionNamesPreferNicknamesAndNameAnUnpublishedMember() {
        let members = [
            mentionMember(id: "self", displayName: "Local", npub: "npub1self", isSelf: true),
            mentionMember(id: "alice", displayName: "Alice", npub: "npub1alice"),
            mentionMember(id: "bob", displayName: "", npub: "npub1bob"),
            mentionMember(id: "carol", displayName: "Carol", npub: "npub1carol"),
        ]
        let nicknames = ContactNicknames(
            ownerAccountIdHex: "owner",
            byContactIdHex: ["alice": "Mum", "bob": "Plumber", "self": "Not Me"]
        )

        let names = WorkspaceState.mentionNames(from: members, nicknames: nicknames)

        #expect(names["npub1alice"] == "Mum")
        #expect(names["npub1bob"] == "Plumber")
        #expect(names["npub1carol"] == "Carol")
        // A nickname on file for one of this device's own accounts is never your own label.
        #expect(names["npub1self"] == "Local")
        // Nothing published and nothing private stays unnamed, so the bech32 fallback survives.
        #expect(
            WorkspaceState.mentionNames(from: members, nicknames: .none)["npub1bob"] == nil
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

    @Test func typedProfileReferenceCannotBeRetargetedByPeerDisplayName() {
        let victimNpub = "npub1" + String(repeating: "q", count: 58)
        let attacker = mentionCandidate(
            id: "attacker",
            displayName: victimNpub,
            npub: "npub1" + String(repeating: "p", count: 58)
        )
        let draft = "Hi @\(victimNpub)"

        #expect(
            ComposerMentionCanonicalizer.canonicalize(draft, candidates: [attacker])
                == draft
        )
    }

    @Test func explicitlySelectedProfileShapedDisplayNameUsesPickedNpub() {
        let victimNpub = "npub1" + String(repeating: "q", count: 58)
        let attackerNpub = "npub1" + String(repeating: "p", count: 58)
        let attacker = mentionCandidate(
            id: "attacker",
            displayName: victimNpub,
            npub: attackerNpub
        )
        let visibleMention = "@\(victimNpub)"
        let selection = ComposerMentionSelection(
            range: NSRange(location: 0, length: (visibleMention as NSString).length),
            displayText: visibleMention,
            npub: attackerNpub
        )

        #expect(
            ComposerMentionCanonicalizer.canonicalize(
                visibleMention,
                selections: [selection],
                candidates: [attacker]
            ) == "@\(attackerNpub)"
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

    /// A composer token's styling is derived from the identity markers rather than tracked on its
    /// own, so the styled range must follow a repaired marker and vanish with an invalidated one.
    /// Drift either way would leave a mention's styling on text that is no longer a mention, or a
    /// mention with no visible affordance.
    @MainActor
    @Test func mentionStylingTracksTheIdentityRangeAndDisappearsWithTheMarker() throws {
        let candidate = mentionCandidate(id: "first", displayName: "Alex", npub: "npub1qqqq")
        let selection = ComposerMentionSelection(
            range: NSRange(location: 0, length: 5),
            displayText: "@Alex",
            npub: candidate.npub
        )

        let textView = NSTextView()
        textView.isRichText = false
        textView.string = "@Alex "
        ComposerMentionMarkerStore.replaceAll(with: [selection], in: textView)
        #expect(mentionStyledRanges(in: textView) == [NSRange(location: 0, length: 5)])

        // Boundary edit: the marker is repaired to the shifted range, and so is the styling.
        textView.insertText("Hi ", replacementRange: NSRange(location: 0, length: 0))
        let repaired = ComposerMentionMarkerStore.selections(in: textView)
        #expect(repaired.map(\.range) == [NSRange(location: 3, length: 5)])
        #expect(mentionStyledRanges(in: textView) == repaired.map(\.range))

        // Internal edit: the marker is dropped, and the styling goes with it.
        let editedMentionView = NSTextView()
        editedMentionView.isRichText = false
        editedMentionView.string = "@Alex "
        ComposerMentionMarkerStore.replaceAll(with: [selection], in: editedMentionView)
        editedMentionView.insertText("x", replacementRange: NSRange(location: 3, length: 0))
        #expect(ComposerMentionMarkerStore.selections(in: editedMentionView).isEmpty)
        #expect(mentionStyledRanges(in: editedMentionView).isEmpty)

        // A draft with no picked mention is never styled.
        let plainView = NSTextView()
        plainView.isRichText = false
        plainView.string = "@Alex "
        ComposerMentionMarkerStore.replaceAll(with: [], in: plainView)
        #expect(mentionStyledRanges(in: plainView).isEmpty)
    }

    /// Dropping a token has to leave *plain typed text* behind, not text with no foreground color
    /// at all: TextKit draws an uncolored run in opaque black rather than falling back to the text
    /// view's `textColor`, so a swept draft is invisible on the composer's dark field and perfectly
    /// legible on its light one. `replaceAll` sweeps the whole storage before re-adding tokens, so
    /// this covers every character of the draft and not just the former token.
    @MainActor
    @Test func draftKeepsTheComposerContentColorAfterItsMentionsAreDropped() throws {
        let selection = ComposerMentionSelection(
            range: NSRange(location: 3, length: 5),
            displayText: "@Alex",
            npub: "npub1qqqq"
        )
        let textView = NSTextView()
        textView.isRichText = false
        textView.string = "Hi @Alex there"
        ComposerMentionMarkerStore.replaceAll(with: [selection], in: textView)

        // The token is dropped the way an invalidating edit drops it: markers gone, no styled run
        // left anywhere.
        ComposerMentionMarkerStore.replaceAll(with: [], in: textView)
        #expect(ComposerMentionMarkerStore.selections(in: textView).isEmpty)
        #expect(mentionStyledRanges(in: textView).isEmpty)

        let storage = try #require(textView.textStorage)
        let plainForeground =
            ComposerMessageTextViewRepresentable.plainTypingAttributes[.foregroundColor] as? NSColor
        for location in 0..<(textView.string as NSString).length {
            let foreground = storage.attribute(.foregroundColor, at: location, effectiveRange: nil) as? NSColor
            #expect(
                foreground == plainForeground,
                "character \(location) lost the composer's content color"
            )
        }
    }

    @MainActor
    @Test func mentionSynchronizationDefersObservableWritesUntilAfterTheViewUpdate() async {
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
        let insertion = ComposerMentionInsertion(
            scope: secondScope,
            context: ComposerMentionContext(query: "Al", tokenRange: NSRange(location: 0, length: 3)),
            candidate: mentionCandidate(id: "first", displayName: "Alex", npub: "npub1qqqq")
        )

        coordinator.scheduleMentionSynchronization(
            scope: secondScope,
            insertion: insertion,
            in: textView
        )

        #expect(boundText == "@Al")
        #expect(boundSelections.isEmpty)
        #expect(publishedContexts.isEmpty)
        #expect(consumedInsertions.isEmpty)

        await withCheckedContinuation { continuation in
            DispatchQueue.main.async {
                continuation.resume()
            }
        }

        #expect(boundText == "@Alex ")
        #expect(boundSelections.map(\.npub) == ["npub1qqqq"])
        #expect(publishedContexts.compactMap { $0 }.first?.query == "Al")
        #expect(consumedInsertions == [insertion.id])
    }

    @MainActor
    @Test func newerMentionSynchronizationSupersedesQueuedWorkFromPreviousScope() async {
        let firstScope = WorkspaceState.ComposerDraftKey(accountId: "account", chatId: "first")
        let secondScope = WorkspaceState.ComposerDraftKey(accountId: "account", chatId: "second")
        let thirdScope = WorkspaceState.ComposerDraftKey(accountId: "account", chatId: "third")
        var boundText = "@Al"
        var measuredHeight: CGFloat = 20
        var boundSelections: [ComposerMentionSelection] = []
        var consumedInsertions: [UUID] = []
        let coordinator = ComposerMessageTextViewRepresentable.Coordinator(
            text: Binding(get: { boundText }, set: { boundText = $0 }),
            measuredHeight: Binding(get: { measuredHeight }, set: { measuredHeight = $0 }),
            mentionSelections: Binding(get: { boundSelections }, set: { boundSelections = $0 }),
            mentionContextScope: firstScope,
            onPasteMedia: { _ in },
            onSend: {},
            onMentionInsertionConsumed: { consumedInsertions.append($0) }
        )
        let textView = NSTextView()
        textView.string = boundText
        textView.setSelectedRange(NSRange(location: 3, length: 0))
        let context = ComposerMentionContext(query: "Al", tokenRange: NSRange(location: 0, length: 3))
        let staleInsertion = ComposerMentionInsertion(
            scope: secondScope,
            context: context,
            candidate: mentionCandidate(id: "stale", displayName: "Alex", npub: "npub1stale")
        )
        let latestInsertion = ComposerMentionInsertion(
            scope: thirdScope,
            context: context,
            candidate: mentionCandidate(id: "latest", displayName: "Alicia", npub: "npub1latest")
        )

        coordinator.scheduleMentionSynchronization(
            scope: secondScope,
            insertion: staleInsertion,
            in: textView
        )
        coordinator.scheduleMentionSynchronization(
            scope: thirdScope,
            insertion: latestInsertion,
            in: textView
        )

        await withCheckedContinuation { continuation in
            DispatchQueue.main.async {
                continuation.resume()
            }
        }

        #expect(boundText == "@Alicia ")
        #expect(boundSelections.map(\.npub) == ["npub1latest"])
        #expect(consumedInsertions == [latestInsertion.id])
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
    @Test func mentionProjectionsReuseRosterUntilGroupMembersChange() {
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
        state.storeGroupMembers([local, alice], welcomerAccountIdHex: nil, for: group.id)

        #expect(state.mentionRoster().map(\.id) == ["alice"])
        #expect(state.mentionRoster().map(\.id) == ["alice"])
        #expect(state.mentionRosterBuildCount == 1)
        #expect(state.cachedMentionNames(groupIdHex: group.id)["npub1alice"] == "Alice")
        #expect(state.cachedMentionNames(groupIdHex: group.id)["npub1alice"] == "Alice")
        #expect(state.mentionNamesBuildCount == 1)

        let bob = mentionMember(id: "bob", displayName: "Bob", npub: "npub1bob")
        state.storeGroupMembers([local, bob], welcomerAccountIdHex: nil, for: group.id)

        #expect(state.mentionRoster().map(\.id) == ["bob"])
        #expect(state.mentionRosterBuildCount == 2)
        #expect(state.cachedMentionNames(groupIdHex: group.id)["npub1bob"] == "Bob")
        #expect(state.mentionNamesBuildCount == 2)
    }

    /// Mention projections fold nicknames in, so they must notice a nickname write — but noticing
    /// it may not cost anything on the read path, which the timeline hits on every window and
    /// every keystroke. Exactly one rebuild per write, and none at all for a write that changed
    /// nothing.
    @MainActor
    @Test func mentionProjectionsRebuildOncePerNicknameWrite() {
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
        state.storeGroupMembers(
            [
                mentionMember(id: "self", displayName: "Local", npub: "npub1self", isSelf: true),
                mentionMember(id: "alice", displayName: "Alice", npub: "npub1alice"),
            ],
            welcomerAccountIdHex: nil,
            for: group.id
        )

        #expect(state.cachedMentionNames(groupIdHex: group.id)["npub1alice"] == "Alice")
        #expect(state.mentionRoster().map(\.displayName) == ["Alice"])
        #expect(state.mentionNamesBuildCount == 1)
        #expect(state.mentionRosterBuildCount == 1)

        state.setContactNickname("Mum", forContactAccountIdHex: "alice")

        #expect(state.cachedMentionNames(groupIdHex: group.id)["npub1alice"] == "Mum")
        #expect(state.cachedMentionNames(groupIdHex: group.id)["npub1alice"] == "Mum")
        #expect(state.mentionNamesBuildCount == 2)
        #expect(state.mentionRoster().map(\.displayName) == ["Mum"])
        #expect(state.mentionRoster().map(\.publishedDisplayName) == ["Alice"])
        #expect(state.mentionRosterBuildCount == 2)

        // Re-saving the same nickname is not a change, so nothing is invalidated.
        state.setContactNickname("Mum", forContactAccountIdHex: "alice")
        #expect(state.cachedMentionNames(groupIdHex: group.id)["npub1alice"] == "Mum")
        _ = state.mentionRoster()
        #expect(state.mentionNamesBuildCount == 2)
        #expect(state.mentionRosterBuildCount == 2)

        // Clearing hands the label back to the published name, through the same one rebuild.
        state.setContactNickname(nil, forContactAccountIdHex: "alice")
        #expect(state.cachedMentionNames(groupIdHex: group.id)["npub1alice"] == "Alice")
        #expect(state.mentionRoster().map(\.displayName) == ["Alice"])
        #expect(state.mentionNamesBuildCount == 3)
        #expect(state.mentionRosterBuildCount == 3)
    }

    /// A nickname belongs to the account that set it. Two accounts sharing a conversation must
    /// never read each other's private labels out of a projection cached under one group id.
    @MainActor
    @Test func mentionNamesAreScopedToTheAccountThatNicknamedTheContact() {
        let owner = AccountItem.samples[0]
        let other = AccountItem.samples[1]
        let group = ChatItem.samples[0]
        let state = WorkspaceState(
            accounts: [owner, other],
            chatsByAccount: [owner.id: [group], other.id: [group]],
            localNotificationCenter: NoopLocalNotificationCenter(),
            appActivityProvider: { false },
            conversationWindowVisibilityProvider: { false }
        )
        state.activeAccountId = owner.id
        state.selection = .chat(group.id)
        state.storeGroupMembers(
            [mentionMember(id: "alice", displayName: "Alice", npub: "npub1alice")],
            welcomerAccountIdHex: nil,
            for: group.id
        )

        state.setContactNickname("Mum", forContactAccountIdHex: "alice")
        #expect(state.cachedMentionNames(groupIdHex: group.id)["npub1alice"] == "Mum")

        state.activeAccountId = other.id
        #expect(state.cachedMentionNames(groupIdHex: group.id)["npub1alice"] == "Alice")
        #expect(state.mentionRoster().map(\.displayName) == ["Alice"])

        state.activeAccountId = owner.id
        #expect(state.cachedMentionNames(groupIdHex: group.id)["npub1alice"] == "Mum")
    }

    @MainActor
    @Test func mentionRosterOffersTheSolePeerInADirectChat() {
        let account = AccountItem.samples[0]
        let direct = ChatItem.samples[1]
        #expect(direct.isDirect)
        let state = WorkspaceState(
            accounts: [account],
            chatsByAccount: [account.id: [direct]],
            localNotificationCenter: NoopLocalNotificationCenter(),
            appActivityProvider: { false },
            conversationWindowVisibilityProvider: { false }
        )
        state.activeAccountId = account.id
        state.selection = .chat(direct.id)

        let local = mentionMember(id: "self", displayName: "Local", npub: "npub1self", isSelf: true)
        let peer = mentionMember(id: "nvk", displayName: "NVK", npub: "npub1nvk")
        state.storeGroupMembers([local, peer], welcomerAccountIdHex: nil, for: direct.id)

        #expect(state.mentionRoster().map(\.id) == ["nvk"])
        #expect(state.mentionCandidates(matching: "nv").map(\.displayName) == ["NVK"])
        // A single candidate can never trip the canonicaliser's duplicate-name ambiguity rule.
        #expect(state.canonicalizeMentions(in: "hey @NVK") == "hey @npub1nvk")
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

    @Test func disappearingMessageDurationUsesLargestExactUnitAndRoundTrips() throws {
        let cases: [(seconds: UInt64, unit: DisappearingMessageDurationUnit, count: UInt64)] = [
            (90, .seconds, 90),
            (120, .minutes, 2),
            (7_200, .hours, 2),
            (172_800, .days, 2),
            (2_419_200, .weeks, 4),
            (UInt64.max, .seconds, UInt64.max),
        ]

        #expect(DisappearingMessageDurationUnit.largestWholeUnit(for: 0) == nil)
        for testCase in cases {
            let duration = try #require(
                DisappearingMessageDurationUnit.largestWholeUnit(for: testCase.seconds)
            )
            #expect(duration.unit == testCase.unit)
            #expect(duration.count == testCase.count)
            #expect(duration.count * duration.unit.seconds == testCase.seconds)
        }
        #expect(DisappearingMessageOption.custom(2_419_200).label == "4 weeks")
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
                == ComposerAudioWaveformPresentation.bars(for: MediaWaveformAnalyzer.fallbackSamples)
        )
    }

    @Test func audioPlaybackSpeedCyclesThroughTheIOSRatesAndWrapsBackToNormal() {
        // Parity with the iOS client's audio bubble, which cycles one badge through exactly these
        // three rates in this order. A fourth rate, a different order, or a cycle that stopped at
        // 2x instead of wrapping would make the same voice note behave differently on each client.
        #expect(AudioPlaybackSpeed.allCases == [.normal, .oneAndAHalf, .double])
        #expect(AudioPlaybackSpeed.initial == .normal)

        #expect(AudioPlaybackSpeed.normal.next == .oneAndAHalf)
        #expect(AudioPlaybackSpeed.oneAndAHalf.next == .double)
        #expect(AudioPlaybackSpeed.double.next == .normal)

        // Cycling once per case returns to where it started, whatever the case count grows to.
        var speed = AudioPlaybackSpeed.initial
        for _ in AudioPlaybackSpeed.allCases {
            speed = speed.next
        }
        #expect(speed == .initial)
    }

    @Test func audioPlaybackSpeedRatesAndLabelsAgree() {
        // The badge is the only thing a listener sees, so its text has to name the rate the player
        // is actually set to. `1` matters especially: it is what `AVAudioPlayer` plays at natively,
        // so a mislabelled normal speed would look like a broken control rather than a wrong rate.
        #expect(AudioPlaybackSpeed.normal.rate == 1)
        #expect(AudioPlaybackSpeed.oneAndAHalf.rate == 1.5)
        #expect(AudioPlaybackSpeed.double.rate == 2)

        #expect(AudioPlaybackSpeed.normal.label(locale: Locale(identifier: "en")) == "1x")
        #expect(AudioPlaybackSpeed.oneAndAHalf.label(locale: Locale(identifier: "en")) == "1.5x")
        #expect(AudioPlaybackSpeed.double.label(locale: Locale(identifier: "en")) == "2x")
    }

    @Test func audioPlaybackSpeedLabelsUseEachLanguagesDecimalSeparator() {
        // `1.5x` is not language-neutral: seven of the nine languages the app ships write it `1,5x`.
        // The separator is asserted from the locale's own data rather than spelled out here, so this
        // stays true if CLDR revises one — the point is that the label never hardcodes a `.`.
        // The whole rates must also stay whole: `1,0x` would be a worse regression than `1.5x`.
        for identifier in ["en", "es", "de", "fr", "it", "pt", "ru", "tr", "zh-Hans", "zh-Hant"] {
            let locale = Locale(identifier: identifier)
            let separator = locale.decimalSeparator ?? "."

            #expect(AudioPlaybackSpeed.normal.label(locale: locale) == "1x")
            #expect(AudioPlaybackSpeed.oneAndAHalf.label(locale: locale) == "1\(separator)5x")
            #expect(AudioPlaybackSpeed.double.label(locale: locale) == "2x")
        }

        // The seven comma languages really are reached above, rather than every locale quietly
        // resolving to a dot and the loop passing for the wrong reason.
        let commaLanguages = ["es", "de", "fr", "it", "pt", "ru", "tr"]
        for identifier in commaLanguages {
            #expect(AudioPlaybackSpeed.oneAndAHalf.label(locale: Locale(identifier: identifier)) == "1,5x")
        }
    }

    @Test func composerAudioWaveformSelectsLoadedBarsForMatchingPayload() async throws {
        // The metadata-loaded path stores bars once, then playback progress should only
        // recolor those loaded bars. Stale or missing metadata keeps showing fallback.
        let loadedBars = ComposerAudioWaveformPresentation.bars(for: [0.15, 0.35, 0.65, 1.0])

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

    @Test func voiceRecordingLevelsSpreadSpeechAcrossTheWholeBarHeight() {
        // The mapping this replaces was a power ratio (`pow(10, average / 36)`), and speech occupies
        // a narrow slice of it: a quiet passage and a raised voice both landed mid-height, so the
        // live strip read as a hedge rather than as a voice. Keeping the two visibly apart is the
        // whole point of drawing a waveform while the mic is hot.
        let quiet = VoiceRecordingLevelMeter.amplitude(averagePower: -46, peakPower: -42)
        let speaking = VoiceRecordingLevelMeter.amplitude(averagePower: -26, peakPower: -20)
        let loud = VoiceRecordingLevelMeter.amplitude(averagePower: -12, peakPower: -6)

        #expect(quiet < 0.25)
        #expect(speaking > 0.4)
        #expect(speaking < 0.75)
        #expect(loud > 0.9)
        #expect(loud - quiet > 0.65)

        // The same three levels through the old curve, so the improvement is pinned rather than
        // asserted from memory: it spanned less than half the strip, with speech barely above rest.
        let legacy = { (power: Float) in max(0.05, min(1, CGFloat(pow(10, power / 36)))) }
        #expect(legacy(-12) - legacy(-46) < 0.5)
        #expect(legacy(-26) < 0.3)
    }

    @Test func voiceRecordingLevelsClampSilenceAndFullScale() {
        // `AVAudioRecorder` reports -160 dBFS for silence and 0 for full scale. Silence still draws
        // the resting sliver, so a speaker who pauses reads as a waveform at rest rather than as a
        // control that died.
        #expect(
            VoiceRecordingLevelMeter.amplitude(averagePower: -160, peakPower: -160)
                == VoiceRecordingLevelMeter.minimumAmplitude
        )
        #expect(VoiceRecordingLevelMeter.amplitude(averagePower: 0, peakPower: 0) > 0.99)

        // A meter read before the first `updateMeters()`, or on a channel that never carried audio,
        // can hand back a non-finite value. A NaN height collapses the bar's frame instead of
        // drawing the sliver, so it has to land on silence.
        #expect(
            VoiceRecordingLevelMeter.amplitude(averagePower: .nan, peakPower: .nan)
                == VoiceRecordingLevelMeter.minimumAmplitude
        )
        #expect(
            VoiceRecordingLevelMeter.amplitude(averagePower: -.infinity, peakPower: -20)
                > VoiceRecordingLevelMeter.minimumAmplitude
        )
    }

    @Test func voiceRecordingLevelsRiseFasterThanTheyFall() {
        // The attack/release asymmetry is what makes the strip read as speech: an onset lands almost
        // at once, and the gap between two words must not flicker the bar back to the floor. A
        // symmetric filter can only pick one of those two failures.
        #expect(VoiceRecordingLevelMeter.attack > VoiceRecordingLevelMeter.release)
        let oneStepUp = VoiceRecordingLevelMeter.smoothed(1, previous: 0.2) - 0.2
        let oneStepDown = 1 - VoiceRecordingLevelMeter.smoothed(0.2, previous: 1)
        #expect(oneStepUp > oneStepDown)

        // Asserted over time rather than per bar, because the coefficients are derived from the bar
        // rate: five bars (0.2 s) of a shout is nearly all the way up, while five bars of silence has
        // given up only about half the way down.
        var rising: CGFloat = 0.2
        var falling: CGFloat = 1
        for _ in 0..<5 {
            rising = VoiceRecordingLevelMeter.smoothed(1, previous: rising)
            falling = VoiceRecordingLevelMeter.smoothed(0.2, previous: falling)
        }
        #expect(rising > 0.9)
        #expect(falling > 0.5)
        #expect(falling < 0.65)

        // The first sample of a take lands where the level actually is instead of ramping up out of
        // the floor, which would clip the start of every recording's waveform.
        #expect(VoiceRecordingLevelMeter.smoothed(0.8, previous: nil) == 0.8)

        // Nothing leaves the drawable range, whatever the filter is handed.
        #expect(VoiceRecordingLevelMeter.smoothed(4, previous: 0.9) == 1)
        #expect(
            VoiceRecordingLevelMeter.smoothed(-3, previous: 0.1)
                == VoiceRecordingLevelMeter.minimumAmplitude
        )
    }

    @Test func liveRecordingBarsAreNarrowAndFollowTheWidthTheyAreGiven() {
        // The playback waveform divides its width between a fixed number of samples, which in a
        // composer-wide bar makes every bar about as wide as a finger. A live strip keeps the bar
        // width fixed and takes as many bars as fit, so it stays thin at any window size.
        #expect(VoiceRecordingWaveform.barWidth == 3)
        #expect(VoiceRecordingWaveform.barPitch == 5)

        #expect(VoiceRecordingWaveform.barCount(forWidth: 440) == 88)
        #expect(VoiceRecordingWaveform.barCount(forWidth: 220) == 44)

        // The last bar needs no trailing gap, so a width that is an exact number of bars plus their
        // inner gaps holds all of them rather than one fewer.
        #expect(VoiceRecordingWaveform.barCount(forWidth: 5 * 4 - 2) == 4)

        // Degenerate widths draw nothing instead of trapping, and the count is bounded by the tail
        // the model actually keeps.
        #expect(VoiceRecordingWaveform.barCount(forWidth: 0) == 0)
        #expect(VoiceRecordingWaveform.barCount(forWidth: -12) == 0)
        #expect(VoiceRecordingWaveform.barCount(forWidth: .nan) == 0)
        #expect(
            VoiceRecordingWaveform.barCount(forWidth: 40_000)
                == VoiceRecordingWaveform.maximumWindowSampleCount
        )
    }

    @Test func liveRecordingStripShowsItsNewestLevelsClamped() {
        let window: [CGFloat] = [0.2, 0.4, 0.6, 0.8]

        #expect(VoiceRecordingWaveform.visibleLevels(window: window, barCount: 2) == [0.6, 0.8])
        #expect(VoiceRecordingWaveform.visibleLevels(window: window, barCount: 9) == window)
        #expect(VoiceRecordingWaveform.visibleLevels(window: window, barCount: 0).isEmpty)

        // Heights are clamped on the way out, so no level can draw past the strip or vanish.
        #expect(
            VoiceRecordingWaveform.visibleLevels(window: [-1, 5], barCount: 2)
                == [VoiceRecordingLevelMeter.minimumAmplitude, 1]
        )
    }

    @Test func aStoppedRecordingKeepsTheStripLengthItHadWhenTheMicWentOff() {
        // The strip is 25 bars a second while it is being recorded, so a two-second take is 50
        // bars once it is stopped too. Stretching the take across the whole composer instead is
        // what made the staged recording read as a different control from the one the user had
        // been watching a moment earlier.
        #expect(VoiceRecordingWaveform.stoppedBarCount(width: 440, recordedSeconds: 2) == 50)

        // A take longer than the bar fills it and no more.
        #expect(VoiceRecordingWaveform.stoppedBarCount(width: 440, recordedSeconds: 60) == 88)

        // Nothing recorded draws nothing, and a duration the recorder could not report falls back
        // to filling the width rather than to an empty strip.
        #expect(VoiceRecordingWaveform.stoppedBarCount(width: 440, recordedSeconds: 0) == 0)
        #expect(VoiceRecordingWaveform.stoppedBarCount(width: 440, recordedSeconds: .nan) == 0)
        #expect(VoiceRecordingWaveform.stoppedBarCount(width: 440, recordedSeconds: nil) == 88)
        #expect(VoiceRecordingWaveform.stoppedBarCount(width: 0, recordedSeconds: 2) == 0)
    }

    @Test func aStoppedRecordingDrawsTheWholeTakeNotItsTail() {
        let history: [CGFloat] = [0.25, 0.5, 0.75, 1]

        // Averaged onto the bars there are, so the opening of the take survives — unlike the live
        // window, which keeps only the newest levels.
        #expect(VoiceRecordingWaveform.condensedLevels(history: history, barCount: 2) == [0.375, 0.875])
        #expect(VoiceRecordingWaveform.condensedLevels(history: history, barCount: 4) == history)

        #expect(VoiceRecordingWaveform.condensedLevels(history: history, barCount: 0).isEmpty)
        #expect(VoiceRecordingWaveform.condensedLevels(history: [], barCount: 8).isEmpty)

        // Heights are clamped the same way the live strip clamps them, so the two draw one take at
        // one scale.
        #expect(
            VoiceRecordingWaveform.condensedLevels(history: [-1, 5], barCount: 2)
                == [VoiceRecordingLevelMeter.minimumAmplitude, 1]
        )
    }

    @Test func aFinishedRecordingKeepsEnoughSamplesForItsOwnBars() {
        // The staged recording draws one thin bar per 40 ms, so the 36 buckets a playback waveform
        // needs would repeat each value across seven neighbours of a long take — the stepped, fat
        // look these bars replaced, rebuilt out of thin ones.
        #expect(VoiceRecordingWaveform.storedSampleCount(forMeteredCount: 250) == 250)
        #expect(
            VoiceRecordingWaveform.storedSampleCount(forMeteredCount: 5_000)
                == VoiceRecordingWaveform.maximumWindowSampleCount
        )

        // Metering that never ran keeps the playback waveform's own count, so the synthetic
        // fallback stays the size the transcript bubble expects to draw.
        #expect(
            VoiceRecordingWaveform.storedSampleCount(forMeteredCount: 0)
                == MediaWaveformAnalyzer.sampleCount
        )
    }

    @Test func recordedAudioNotTheSchedulerDecidesHowFarTheStripTravels() {
        // This is the constant-speed guarantee, and the bug it answers: the strip used to advance one
        // bar per metering wakeup, with the travel handed to an implicit animation that was
        // retargeted before it settled — so scheduling lag became extra distance per frame and the
        // waveform visibly accelerated. Bars are owed by the recorder's clock instead: 40 ms of
        // sound is one bar, always.
        #expect(
            VoiceRecordingLevelMeter.barsOwed(recordedSeconds: 0.04, alreadyMetered: 0, maximum: 512) == 1
        )
        #expect(
            VoiceRecordingLevelMeter.barsOwed(recordedSeconds: 1, alreadyMetered: 0, maximum: 512) == 25
        )

        // A wakeup that arrives three intervals late owes three bars, so the waveform stays lined up
        // with the audio instead of lagging further behind with every stall.
        #expect(
            VoiceRecordingLevelMeter.barsOwed(recordedSeconds: 0.16, alreadyMetered: 1, maximum: 512) == 3
        )

        // A wakeup that fires early, or twice, owes nothing — it cannot pull the strip forward.
        #expect(
            VoiceRecordingLevelMeter.barsOwed(recordedSeconds: 0.05, alreadyMetered: 1, maximum: 512) == 0
        )
        #expect(
            VoiceRecordingLevelMeter.barsOwed(recordedSeconds: 0.039, alreadyMetered: 0, maximum: 512) == 0
        )

        // A long stall catches up by at most a windowful rather than by minutes of bars at once.
        #expect(
            VoiceRecordingLevelMeter.barsOwed(recordedSeconds: 600, alreadyMetered: 0, maximum: 512) == 512
        )

        // A clock that reads zero, backwards, or non-finite owes nothing.
        #expect(VoiceRecordingLevelMeter.barsOwed(recordedSeconds: 0, alreadyMetered: 0, maximum: 512) == 0)
        #expect(VoiceRecordingLevelMeter.barsOwed(recordedSeconds: -3, alreadyMetered: 0, maximum: 512) == 0)
        #expect(VoiceRecordingLevelMeter.barsOwed(recordedSeconds: .nan, alreadyMetered: 0, maximum: 512) == 0)
        #expect(VoiceRecordingLevelMeter.barsOwed(recordedSeconds: 1, alreadyMetered: 25, maximum: 512) == 0)
    }

    @MainActor
    @Test func emojiInsertionDefersObservableWritesUntilAfterViewUpdate() async {
        var boundText = ""
        var measuredHeight: CGFloat = -1
        var measuredHeightWriteCount = 0
        var boundSelections: [ComposerMentionSelection] = []
        var consumedInsertions: [UUID] = []
        let coordinator = ComposerMessageTextViewRepresentable.Coordinator(
            text: Binding(get: { boundText }, set: { boundText = $0 }),
            measuredHeight: Binding(
                get: { measuredHeight },
                set: {
                    measuredHeight = $0
                    measuredHeightWriteCount += 1
                }
            ),
            mentionSelections: Binding(
                get: { boundSelections },
                set: { boundSelections = $0 }
            ),
            mentionContextScope: nil,
            onPasteMedia: { _ in },
            onSend: {},
            onEmojiInsertionConsumed: { consumedInsertions.append($0) }
        )
        let textView = NSTextView()
        textView.string = boundText
        textView.setSelectedRange(NSRange(location: 0, length: 0))
        let insertion = ComposerEmojiInsertion(emoji: "🐾")

        coordinator.scheduleEmojiInsertion(insertion, into: textView)
        coordinator.scheduleEmojiInsertion(insertion, into: textView)

        #expect(textView.string.isEmpty)
        #expect(boundText.isEmpty)
        #expect(measuredHeight == -1)
        #expect(measuredHeightWriteCount == 0)
        #expect(consumedInsertions.isEmpty)

        await withCheckedContinuation { continuation in
            DispatchQueue.main.async {
                continuation.resume()
            }
        }

        #expect(textView.string == "🐾")
        #expect(boundText == "🐾")
        #expect(measuredHeight > -1)
        #expect(measuredHeightWriteCount == 1)
        #expect(consumedInsertions == [insertion.id])
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

        let catalog = ChatEmojiCatalog(entries: entries)
        #expect(ChatEmojiSearch.results(in: catalog, query: "LAUGH").map(\.emoji) == ["😂"])
        #expect(ChatEmojiSearch.results(in: catalog, query: "red").map(\.emoji) == ["❤️"])
        #expect(ChatEmojiSearch.results(in: catalog, query: "face").map(\.emoji) == ["😂", "😀"])
    }

    @Test func emojiCatalogPreservesEntriesPartitionsByGroupAndToleratesDuplicateEmojiKeys() {
        let entries = [
            ChatEmojiCatalogEntry(emoji: "😀", name: "grinning face", group: 0, keywords: []),
            ChatEmojiCatalogEntry(emoji: "👋", name: "waving hand", group: 1, keywords: []),
            ChatEmojiCatalogEntry(emoji: "🐶", name: "dog", group: 2, keywords: []),
            ChatEmojiCatalogEntry(emoji: "❤️", name: "red heart", group: 7, keywords: []),
            ChatEmojiCatalogEntry(emoji: "❤️", name: "duplicate heart", group: 7, keywords: []),
        ]
        let catalog = ChatEmojiCatalog(entries: entries)

        #expect(catalog.entries == entries)
        #expect(catalog.entries(forGroup: 0).map(\.emoji) == ["😀"])
        #expect(catalog.entries(forGroup: 1).map(\.emoji) == ["👋"])
        #expect(catalog.entries(forGroup: 2).map(\.emoji) == ["🐶"])
        #expect(catalog.entries(forGroup: 3).isEmpty)
        #expect(catalog.entries(forGroup: 7).map(\.name) == ["red heart", "duplicate heart"])
        #expect(
            catalog.recents(from: ["👋", "❤️", "😀", "missing"]).map(\.name)
                == ["waving hand", "red heart", "grinning face"]
        )
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

    @Test func onlyThisAppsRecordingFileNamesAreRecognizedAsVoiceMessages() async throws {
        // A persisted draft loses the "recorded here" flag at the FFI boundary, so a restored
        // recording is recognized by the exact name `prepareVoiceRecordingFile` writes. The UUID
        // stem is what keeps a user's own audio file out of the voice-draft composer.
        let recordingName = "voice-\(UUID().uuidString).m4a"

        #expect(OutgoingMediaAttachmentPolicy.isVoiceRecordingFileName(recordingName, mediaType: "audio/mp4"))
        #expect(
            OutgoingMediaAttachmentPolicy.isVoiceRecordingFileName(
                recordingName.uppercased(),
                mediaType: "AUDIO/MP4"
            )
        )

        #expect(!OutgoingMediaAttachmentPolicy.isVoiceRecordingFileName("voice-notes.m4a", mediaType: "audio/mp4"))
        #expect(!OutgoingMediaAttachmentPolicy.isVoiceRecordingFileName("interview.m4a", mediaType: "audio/mp4"))
        #expect(!OutgoingMediaAttachmentPolicy.isVoiceRecordingFileName(recordingName, mediaType: "application/pdf"))
        #expect(
            !OutgoingMediaAttachmentPolicy.isVoiceRecordingFileName(
                "voice-\(UUID().uuidString).mp3",
                mediaType: "audio/mpeg"
            )
        )
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

    /// A row whose last word was yours has to say so, in both a group and a DM — otherwise your
    /// own message reads as though the other side sent it.
    @Test func chatRowAttributesYourOwnLastMessageToYou() async throws {
        let selfIdHex = String(repeating: "5", count: 64)
        func chat(groupName: String, plaintext: String, sender: String) -> ChatItem {
            ChatItem(
                row: chatRow(groupName: groupName, sender: sender, senderDisplayName: "Alice", plaintext: plaintext),
                activeAccountIdHex: selfIdHex
            )
        }

        let ownGroupMessage = chat(groupName: "Planning", plaintext: "On my way", sender: selfIdHex)
        #expect(ownGroupMessage.preview == String(format: L10n.string("You: %@"), "On my way"))
        // Nothing to relabel: "You" is not a name a nickname can override.
        #expect(ownGroupMessage.previewAttribution == nil)

        let ownDirectMessage = ChatItem(
            row: chatRow(groupName: "", sender: selfIdHex, senderDisplayName: "Alice", plaintext: "On my way"),
            activeAccountIdHex: selfIdHex,
            directPeer: ChatPeerProfile(accountIdHex: aliceIdHex, displayName: "Alice", pictureURL: nil)
        )
        #expect(ownDirectMessage.isDirect)
        #expect(ownDirectMessage.preview == String(format: L10n.string("You: %@"), "On my way"))

        // The attribution wraps whatever the line resolved to, media wording included.
        let ownAttachment = chat(groupName: "Planning", plaintext: "", sender: selfIdHex)
        #expect(ownAttachment.preview == String(format: L10n.string("You: %@"), L10n.string("Attachment")))

        // Someone else's message keeps its own name, and stays relabelable.
        let peerMessage = chat(groupName: "Planning", plaintext: "On my way", sender: aliceIdHex)
        #expect(peerMessage.preview == "\(bidiIsolated("Alice")): On my way")
        #expect(peerMessage.previewAttribution?.senderAccountIdHex == aliceIdHex)
        #expect(peerMessage.previewAttribution?.publishedSenderName == "Alice")
        #expect(peerMessage.previewAttribution?.body == "On my way")

        // With no account resolved yet, no message can be claimed as your own.
        let unattributed = ChatItem(
            row: chatRow(groupName: "Planning", sender: selfIdHex, senderDisplayName: "Alice", plaintext: "Hi"),
            activeAccountIdHex: nil
        )
        #expect(unattributed.preview == "\(bidiIsolated("Alice")): Hi")
    }

    /// The preview's author is the same person as the row title and the sender label, so the
    /// viewer's private label has to reach it too.
    @Test func chatRowLastSenderPrefixPrefersTheNickname() async throws {
        let row = chatRow(groupName: "Planning", sender: aliceIdHex, senderDisplayName: "Alice", plaintext: "Hi")

        let nicknamed = ChatItem(row: row, activeAccountIdHex: "self", lastSenderNickname: "Mum")
        #expect(nicknamed.preview == "\(bidiIsolated("Mum")): Hi")
        // The published name is recorded so clearing the nickname restores it.
        #expect(nicknamed.previewAttribution?.publishedSenderName == "Alice")

        // A member who published no name has nothing to prefix with — until they are nicknamed.
        let anonymous = chatRow(groupName: "Planning", sender: aliceIdHex, senderDisplayName: nil, plaintext: "Hi")
        #expect(ChatItem(row: anonymous, activeAccountIdHex: "self").preview == "Hi")
        #expect(
            ChatItem(row: anonymous, activeAccountIdHex: "self", lastSenderNickname: "Mum").preview
                == "\(bidiIsolated("Mum")): Hi"
        )
    }

    /// Relabeling recomposes the line from the parts it was built from, so a rename lands without
    /// re-running chat-list enrichment — and touches nothing else on the row.
    @Test func chatRowPreviewRelabelsOnlyItsOwnLastSender() async throws {
        let row = chatRow(groupName: "Planning", sender: aliceIdHex, senderDisplayName: "Alice", plaintext: "Hi")
        let chat = ChatItem(row: row, activeAccountIdHex: "self")

        let renamed = chat.relabelingPreviewSender(accountIdHex: aliceIdHex, nickname: "Mum")
        #expect(renamed.preview == "\(bidiIsolated("Mum")): Hi")
        #expect(renamed.previewAttribution == chat.previewAttribution)
        #expect(renamed.title == chat.title)
        #expect(renamed.unreadCount == chat.unreadCount)

        // Clearing hands the line back to the published name, exactly as `applyingNickname` does.
        #expect(renamed.relabelingPreviewSender(accountIdHex: aliceIdHex, nickname: nil) == chat)

        // Another contact's rename must leave the row untouched, so the chat-list generation and
        // the memoized sidebar filter never churn for it.
        #expect(chat.relabelingPreviewSender(accountIdHex: String(repeating: "b", count: 64), nickname: "Dad") == chat)
        #expect(chat.relabelingPreviewSender(accountIdHex: aliceIdHex, nickname: "Alice") == chat)

        // A row with no attributed sender has nothing to recompose.
        let own = ChatItem(
            row: chatRow(groupName: "Planning", sender: "self", senderDisplayName: "You", plaintext: "Hi"),
            activeAccountIdHex: "self"
        )
        #expect(own.relabelingPreviewSender(accountIdHex: "self", nickname: "Me") == own)
    }

    /// The chat row draws the attributed sender in Bold and the message in its ordinary weight, so
    /// it needs the composed line handed back in two pieces.
    ///
    /// The split is anchored on the tail — everything before `body`'s separator is the name —
    /// because the name on display may be a nickname that never appears in `previewAttribution`.
    /// Rebuilding the prefix from `publishedSenderName` instead would set the *published* name in
    /// Bold while the rest of the line showed the private one.
    @Test func chatRowSplitsAnAttributedPreviewIntoItsSenderAndBody() async throws {
        let row = chatRow(groupName: "Planning", sender: aliceIdHex, senderDisplayName: "Alice", plaintext: "On my way")
        let chat = ChatItem(row: row, activeAccountIdHex: "self")

        let parts = try #require(chat.previewAttributionParts)
        #expect(parts.senderName == bidiIsolated("Alice"))
        #expect(parts.body == "On my way")
        // The two pieces put back together are the line the row would otherwise have drawn whole.
        #expect(parts.senderName + ChatItem.previewAttributionSeparator + parts.body == chat.preview)

        // A nickname is what the row shows, so it is what the Bold run has to be.
        let nicknamed = chat.relabelingPreviewSender(accountIdHex: aliceIdHex, nickname: "Mum")
        #expect(nicknamed.previewAttributionParts?.senderName == bidiIsolated("Mum"))

        // A name carrying the separator itself still splits at the seam, because the body is
        // matched rather than the prefix.
        let colonNamed = ChatItem(
            row: chatRow(groupName: "Planning", sender: aliceIdHex, senderDisplayName: "Alice: PM", plaintext: "Hi"),
            activeAccountIdHex: "self"
        )
        #expect(colonNamed.previewAttributionParts?.senderName == bidiIsolated("Alice: PM"))
        #expect(colonNamed.previewAttributionParts?.body == "Hi")

        // A body that repeats the separator is not a seam either.
        let colonBody = ChatItem(
            row: chatRow(
                groupName: "Planning", sender: aliceIdHex, senderDisplayName: "Alice", plaintext: "note: read"),
            activeAccountIdHex: "self"
        )
        #expect(colonBody.previewAttributionParts?.senderName == bidiIsolated("Alice"))
        #expect(colonBody.previewAttributionParts?.body == "note: read")

        // Your own line has no attribution — "You" is not a name to scan a group for — and an
        // unattributed line has nothing to set apart, so both stay one plain run.
        let own = ChatItem(
            row: chatRow(groupName: "Planning", sender: "self", senderDisplayName: "You", plaintext: "Hi"),
            activeAccountIdHex: "self"
        )
        #expect(own.previewAttributionParts == nil)

        let anonymous = ChatItem(
            row: chatRow(groupName: "Planning", sender: aliceIdHex, senderDisplayName: nil, plaintext: "Hi"),
            activeAccountIdHex: "self"
        )
        #expect(anonymous.preview == "Hi")
        #expect(anonymous.previewAttributionParts == nil)
    }

    /// A conversation the user named keeps that name even when it has exactly one other member.
    ///
    /// The roster of a two-person group resolves a direct peer, and that peer's profile used to win
    /// the row title — so a group created as "Book club" with one other member came back titled
    /// "Alice". mdk classifies any named conversation as a group whatever its member count, and the
    /// name the user typed is the whole point of having typed it.
    @Test func namedTwoMemberGroupKeepsItsNameOverTheOtherMembersProfile() async throws {
        let selfIdHex = String(repeating: "5", count: 64)
        let peer = ChatPeerProfile(
            accountIdHex: aliceIdHex,
            displayName: "Alice",
            pictureURL: "https://example.com/alice.png"
        )

        let named = ChatItem(
            row: chatRow(groupName: "Book club", sender: aliceIdHex, senderDisplayName: "Alice", plaintext: "Hi"),
            activeAccountIdHex: selfIdHex,
            directPeer: peer,
            groupAvatarURL: "https://example.com/group.png"
        )

        #expect(named.title == "Book club")
        #expect(!named.isDirect)
        #expect(named.subtitle == "Book club")
        // The group's own avatar, not the other member's: seeded by group id so the initials
        // fallback draws the group name, and picturing the peer would read as a DM.
        #expect(named.avatarSeed == "group")
        #expect(named.pictureURL == "https://example.com/group.png")
        // Nothing to reveal behind a private label, because no peer name is on display.
        #expect(named.publishedTitle == nil)
        #expect(named.directPeerAccountIdHex == nil)

        // A private nickname for that member cannot retitle it either.
        let nicknamed = ChatItem(
            row: chatRow(groupName: "Book club", sender: aliceIdHex, senderDisplayName: "Alice", plaintext: "Hi"),
            activeAccountIdHex: selfIdHex,
            directPeer: ChatPeerProfile(
                accountIdHex: aliceIdHex,
                displayName: "Mum",
                publishedDisplayName: "Alice",
                pictureURL: nil
            )
        )
        #expect(nicknamed.title == "Book club")
        #expect(nicknamed.publishedTitle == nil)

        // A real DM carries no name of its own, so the peer is still the only thing that titles it.
        let direct = ChatItem(
            row: chatRow(groupName: "", sender: aliceIdHex, senderDisplayName: "Alice", plaintext: "Hi"),
            activeAccountIdHex: selfIdHex,
            directPeer: peer
        )
        #expect(direct.title == "Alice")
        #expect(direct.isDirect)
        #expect(direct.subtitle == L10n.string("Direct message"))
        #expect(direct.avatarSeed == aliceIdHex)
        #expect(direct.pictureURL == "https://example.com/alice.png")
        #expect(direct.directPeerAccountIdHex == aliceIdHex)
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
        func message(
            id: String,
            timelineAt: UInt64,
            mediaAttachments: [MessageMediaAttachment] = []
        ) -> MessageItem {
            MessageItem(
                id: id,
                senderName: "sender",
                body: id,
                sentAt: Date(timeIntervalSince1970: 1_700_000_000),
                timelineAt: timelineAt,
                isOutgoing: false,
                mediaAttachments: mediaAttachments
            )
        }

        // Window (oldest→newest): L(95), M(100). We are scrolled back, so anchoredToNewest == false.
        let store = MessageTimelineStore.loaded(with: [
            message(id: "L", timelineAt: 95),
            message(id: "M", timelineAt: 100),
        ])

        // The delta removes the current newest row M and upserts N(98). After M is gone the true
        // head is L(95); N(98) is strictly newer and must not become a new head.
        let suppressedMedia = MessageMediaAttachment(
            id: "suppressed-attachment",
            reference: mediaReference(fileName: "suppressed.png", mediaType: "image/png")
        )
        let result = store.applyProjection(
            upserts: [message(id: "N", timelineAt: 98, mediaAttachments: [suppressedMedia])],
            removals: ["M"],
            anchoredToNewest: false,
            windowLimit: 10
        )

        #expect(store.messages.map(\.id) == ["L"])
        #expect(!store.containsMessage(id: "N"))
        #expect(result.didChange)
        #expect(!result.didChangeMediaAttachments)

        // #631: media added by unrelated backward pagination must not consume the pending
        // invalidation. It fires once the suppressed media row is actually retained.
        let olderMedia = MessageMediaAttachment(
            id: "older-attachment",
            reference: mediaReference(fileName: "older.png", mediaType: "image/png")
        )
        let pagingOlderMedia = store.replace(with: [
            message(id: "O", timelineAt: 90, mediaAttachments: [olderMedia]),
            message(id: "L", timelineAt: 95),
        ])
        #expect(!pagingOlderMedia)

        let retainedSuppressedMedia = store.replace(with: [
            message(id: "L", timelineAt: 95),
            message(id: "N", timelineAt: 98, mediaAttachments: [suppressedMedia]),
        ])
        #expect(retainedSuppressedMedia)
        #expect(
            !store.replace(with: [
                message(id: "L", timelineAt: 95),
                message(id: "N", timelineAt: 98, mediaAttachments: [suppressedMedia]),
            ]))
    }

    /// An edited row carries no Markdown — `applyingEdit` drops it and resolves the mention into
    /// plain text from the base's `mentionNames` — so relabeling only the base would leave the
    /// bubble on the old label until the next full recomputation.
    @MainActor
    @Test func relabelingAMentionRerendersEditedRowsFromTheirBase() async throws {
        let npub = "npub1alyce"
        let store = MessageTimelineStore.loaded(with: [
            MessageItem(
                id: "target",
                senderAccountIdHex: "alice",
                senderName: "alice",
                body: "ping @\(npub)",
                contentMarkdown: MarkdownDocumentFfi(
                    blocks: [
                        .paragraph(inlines: [
                            .text(content: "ping "),
                            .nostrMention(entity: MarkdownNostrEntityFfi(hrp: .npub, bech32: npub)),
                        ])
                    ],
                    truncated: false
                ),
                mentionNames: [npub: "Alice"],
                sentAt: Date(timeIntervalSince1970: 1_800_000_000),
                timelineAt: 1_800_000_000,
                isOutgoing: false
            )
        ])
        // The edit republishes the same mention token, so the label the row shows comes purely
        // from the map the base carries.
        let applied = store.applyProjection(
            upserts: [],
            removals: [],
            editMutations: [
                editUpsert(
                    makeEditOverlay(editId: "edit-1", plaintext: "ping @\(npub) again", timelineAt: 1_800_000_060)
                )
            ],
            anchoredToNewest: true,
            windowLimit: 10
        )
        #expect(applied.didChange)
        #expect(store.lookup["target"]?.body == "ping @Alice again")
        #expect(store.lookup["target"]?.isEdited == true)

        #expect(store.relabelMention(bech32: npub, name: "Mum"))
        #expect(store.lookup["target"]?.body == "ping @Mum again")
        #expect(store.displayItems.first?.message.body == "ping @Mum again")
        // Still an edit, still rendered from the same base.
        #expect(store.lookup["target"]?.isEdited == true)

        // Clearing drops the entry, so the edited row's plain text falls back to the raw token —
        // exactly what `applyingEdit` produces from an empty map, which is the parity that matters.
        #expect(store.relabelMention(bech32: npub, name: nil))
        #expect(store.lookup["target"]?.body == "ping @\(npub) again")

        // And re-applying the same label is reported as no change rather than churning the row.
        #expect(!store.relabelMention(bech32: npub, name: nil))
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

    /// The invite prompt used to guess the inviter from the row preview, which is empty for the
    /// case it matters most — a direct invite with no messages yet — so it said "Someone". The
    /// group record's welcome sender is the authoritative answer, and it arrives on the same
    /// read that fills the roster.
    @MainActor
    @Test func inviteRecordsWhoSentTheWelcomeAndNamesThemFromTheRoster() async throws {
        let welcomer = "alice1234567890alice1234567890alice1234567890alice12345678"
        let state = WorkspaceState(
            localNotificationCenter: NoopLocalNotificationCenter(),
            appActivityProvider: { false },
            conversationWindowVisibilityProvider: { false }
        )

        state.applyGroupDetails(
            GroupDetailsFfi(
                group: inviteGroupRecord(groupIdHex: "group", welcomerAccountIdHex: welcomer),
                members: [
                    mentionMember(id: welcomer, displayName: "Alice", npub: "npub1alice"),
                    mentionMember(id: "self", displayName: "Local", npub: "npub1self", isSelf: true),
                ]
            ),
            managementState: inviteManagementState
        )

        #expect(state.inviterAccountIdHex(forGroupIdHex: "group") == welcomer)
        #expect(state.inviterDisplayName(forGroupIdHex: "group") == "Alice")
        // A group nobody welcomed this account into (one it created) names no inviter, and
        // neither does a group whose roster has never been read.
        #expect(state.inviterDisplayName(forGroupIdHex: "unfetched") == nil)
    }

    /// An inviter whose profile has not resolved yet is still someone: naming them by npub beats
    /// falling back to "Someone", and the published name replaces it in place when it lands. It
    /// stays a separate lookup from the name so callers with a better fallback of their own —
    /// a direct chat's title is the peer, already resolved — can rank it below theirs.
    @MainActor
    @Test func inviteNamesAnUnresolvedInviterByIdentifier() async throws {
        let welcomer = "bob1234567890bob1234567890bob1234567890bob1234567890bob123"
        let state = WorkspaceState(
            localNotificationCenter: NoopLocalNotificationCenter(),
            appActivityProvider: { false },
            conversationWindowVisibilityProvider: { false }
        )

        state.applyGroupDetails(
            GroupDetailsFfi(
                group: inviteGroupRecord(groupIdHex: "group", welcomerAccountIdHex: welcomer),
                members: [
                    GroupMemberDetailsFfi(
                        memberIdHex: welcomer,
                        account: nil,
                        local: false,
                        isAdmin: false,
                        isSelf: false,
                        npub: "npub1bobbobbobbobbobbob",
                        displayName: nil
                    )
                ]
            ),
            managementState: inviteManagementState
        )

        #expect(state.inviterDisplayName(forGroupIdHex: "group") == nil)
        #expect(
            state.inviterIdentifierLabel(forGroupIdHex: "group")
                == DisplayText.short("npub1bobbobbobbobbobbob", head: 12, tail: 8))

        // A roster the app has not read at all cannot name the inviter from a member entry, so
        // the account id itself is the last thing left to show.
        state.storeGroupMembers([], welcomerAccountIdHex: welcomer, for: "other")
        #expect(state.inviterIdentifierLabel(forGroupIdHex: "other") == DisplayText.short(welcomer))
    }

    /// The inviter is cached with the roster, so it must be dropped with it: a stale welcome
    /// sender outliving the membership read that produced it would name the wrong account.
    @MainActor
    @Test func invalidatingTheRosterForgetsTheInviter() async throws {
        let welcomer = "carol234567890carol234567890carol234567890carol2345678901"
        let state = WorkspaceState(
            localNotificationCenter: NoopLocalNotificationCenter(),
            appActivityProvider: { false },
            conversationWindowVisibilityProvider: { false }
        )

        state.storeGroupMembers(
            [mentionMember(id: welcomer, displayName: "Carol", npub: "npub1carol")],
            welcomerAccountIdHex: welcomer,
            for: "group"
        )
        #expect(state.inviterDisplayName(forGroupIdHex: "group") == "Carol")

        state.invalidateGroupMembers(for: "group")
        #expect(state.inviterAccountIdHex(forGroupIdHex: "group") == nil)

        // A record that carries no welcome sender leaves no entry behind either, so a later
        // read of a different group cannot inherit one.
        state.storeGroupMembers([], welcomerAccountIdHex: "   ", for: "group")
        #expect(state.inviterAccountIdHex(forGroupIdHex: "group") == nil)
    }

    /// Naming the inviter is one thing; being able to check who they actually are is another.
    /// The avatar in the invite prompt opens their profile, and that needs the npub — the whole
    /// point of looking before accepting is comparing a key rather than trusting a display name.
    @MainActor
    @Test func pendingInviteInviterIdentityCarriesTheNpubTheProfileNeeds() async throws {
        let welcomer = "alice1234567890alice1234567890alice1234567890alice12345678"
        let state = WorkspaceState(
            localNotificationCenter: NoopLocalNotificationCenter(),
            appActivityProvider: { false },
            conversationWindowVisibilityProvider: { false }
        )
        let invite = pendingInviteChat(id: "group")
        state.storeGroupMembers(
            [mentionMember(id: welcomer, displayName: "Alice", npub: "npub1alice")],
            welcomerAccountIdHex: welcomer,
            for: "group"
        )

        let identity = try #require(state.pendingInviteInviterIdentity(for: invite))
        #expect(identity.accountIdHex == welcomer)
        #expect(identity.npub == "npub1alice")

        // An answered invite has no inviter to offer: an accepted group is just a group.
        let accepted = pendingInviteChat(id: "group", pendingConfirmation: false)
        #expect(state.pendingInviteInviterIdentity(for: accepted) == nil)
    }

    /// A record that kept no welcome sender still has an inviter in a one-to-one: the single
    /// other member. This is the same fallback the prompt's own name ladder makes, so the avatar
    /// cannot end up naming one person and opening another.
    @MainActor
    @Test func pendingDirectInviteFallsBackToThePeerAsInviter() async throws {
        let peer = "bob1234567890bob1234567890bob1234567890bob1234567890bob123"
        let state = WorkspaceState(
            localNotificationCenter: NoopLocalNotificationCenter(),
            appActivityProvider: { false },
            conversationWindowVisibilityProvider: { false }
        )
        let invite = pendingInviteChat(id: "direct-group", avatarSeed: peer, isDirect: true)
        state.storeGroupMembers(
            [mentionMember(id: peer, displayName: "Bob", npub: "npub1bob")],
            welcomerAccountIdHex: nil,
            for: "direct-group"
        )

        #expect(state.inviterAccountIdHex(forGroupIdHex: "direct-group") == nil)
        let identity = try #require(state.pendingInviteInviterIdentity(for: invite))
        #expect(identity.accountIdHex == peer)
        #expect(identity.npub == "npub1bob")

        // A direct chat whose peer has not resolved seeds `avatarSeed` with the group id, which
        // is nobody — offering that as a profile would open a page for a group id.
        let unresolved = pendingInviteChat(id: "direct-group", avatarSeed: "direct-group", isDirect: true)
        #expect(state.pendingInviteInviterIdentity(for: unresolved) == nil)
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
    @Test func emptyAccountLabelFallsBackToResolvableAccountId() {
        let accountIdHex = String(repeating: "a", count: 64)
        let account = AccountItem(
            summary: AccountSummaryFfi(
                label: "",
                accountIdHex: accountIdHex,
                localSigning: true,
                externalSigning: false,
                signedOut: false,
                running: true
            )
        )

        #expect(account.id == accountIdHex)
        #expect(account.accountRef == accountIdHex)
        #expect(account.displayName == DisplayText.short(accountIdHex))
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

    @MainActor
    @Test func profileDraftRoundTripsBannerMetadata() async throws {
        let draft = ProfileDraft(
            displayName: "Alice",
            picture: "https://example.com/profile.jpg",
            banner: "https://example.com/banner.jpg"
        )

        #expect(draft.metadata.banner == "https://example.com/banner.jpg")
        let restored = ProfileDraft(profile: draft.metadata, fallbackName: "Fallback")
        #expect(restored.banner == "https://example.com/banner.jpg")
    }

    /// What gets published is `NIP05Identifier`'s canonical spelling — lowercased local part,
    /// canonical domain — not what the cursor happened to leave behind. A value that does not
    /// parse comes back trimmed but otherwise untouched, so the field someone still has to fix
    /// shows them what they typed.
    @MainActor
    @Test func aNostrAddressIsNormalizedOnTheWayOutAndLeftAloneWhenItCannotParse() {
        #expect(
            WorkspaceState.normalizedNostrAddress("  MARMOTA@Example.COM  ") == "marmota@example.com")
        #expect(WorkspaceState.normalizedNostrAddress("marmota@example.com") == "marmota@example.com")
        #expect(WorkspaceState.normalizedNostrAddress("  marmota  ") == "marmota")
        #expect(WorkspaceState.normalizedNostrAddress("   ").isEmpty)
    }

    /// The seal means the domain named *this* account. A well-known document that names a
    /// perfectly valid key belonging to somebody else earns nothing — which is the whole reason
    /// the reference is compared rather than merely fetched.
    @Test func theSealIsOnlyEarnedByThisAccountsOwnKey() {
        let hex = String(repeating: "ab", count: 32)
        let npub = "npub1marmota"
        let stranger = String(repeating: "cd", count: 32)

        #expect(
            WorkspaceState.nostrAddressVerdict(reference: hex, accountIdHex: hex, npub: npub) == .verified)
        #expect(
            WorkspaceState.nostrAddressVerdict(reference: hex.uppercased(), accountIdHex: hex, npub: npub)
                == .verified)
        #expect(
            WorkspaceState.nostrAddressVerdict(reference: " \(npub) ", accountIdHex: hex, npub: npub)
                == .verified)
        #expect(
            WorkspaceState.nostrAddressVerdict(reference: stranger, accountIdHex: hex, npub: npub)
                == .unverified)
        #expect(
            WorkspaceState.nostrAddressVerdict(reference: "", accountIdHex: hex, npub: npub) == .unverified)
        #expect(
            WorkspaceState.nostrAddressVerdict(reference: npub, accountIdHex: hex, npub: nil) == .unverified)
    }

    /// `OnboardingLayout` forwards its field metrics to `WNInput`, which now owns them. Asserted
    /// because the sign-up pane budgets a 620pt window against these numbers by the *old* names —
    /// a forward that silently stopped forwarding would be a pane measured against a fiction.
    @MainActor
    @Test func theOnboardingFieldMetricsAreTheOnesWNInputDraws() {
        #expect(OnboardingLayout.fieldLabelSpacing == WNInputMetrics.labelSpacing)
        #expect(OnboardingLayout.fieldHorizontalPadding == WNInputMetrics.horizontalPadding)
        #expect(OnboardingLayout.fieldVerticalPadding == WNInputMetrics.verticalPadding)
        #expect(OnboardingLayout.singleLineFieldHeight == WNInputMetrics.singleLineHeight)
        #expect(OnboardingLayout.multilineFieldCornerRadius == WNInputMetrics.multilineCornerRadius)
        #expect(
            OnboardingLayout.fieldHeight(forLineLimit: 3) == WNInputMetrics.height(forLineLimit: 3))
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

    @Test func downsampledImageKeyDistinguishesBothURLAndSize() async throws {
        let key = DownsampledImageTaskKey(url: URL(string: "https://example.com/a.png"), size: 128)

        #expect(DownsampledImageTaskKey(url: key.url, size: 128) == key)
        #expect(DownsampledImageTaskKey(url: URL(string: "https://example.com/b.png"), size: 128) != key)
        // A size change has to invalidate too: the decoded image is cached per URL *and* pixel
        // budget, so a key that only tracked the URL would hand back a decode of the wrong size.
        #expect(DownsampledImageTaskKey(url: key.url, size: 256) != key)
        #expect(DownsampledImageTaskKey(url: nil, size: 128) != key)
    }

    @Test func downsampledImageGateDropsAnImageLoadedForAnotherKey() async throws {
        // The bug this pins: `.task(id:)` restarts the task, not the view's identity, so SwiftUI
        // carries `@State image` across a rebind and evaluates `body` for the new key *first*.
        // The conversation header avatar therefore drew the previous chat's picture for a pass
        // before `loadImage(for:)` cleared it. Nothing loaded for another key may reach `content`.
        let showing = DownsampledImageTaskKey(url: URL(string: "https://example.com/a.png"), size: 128)
        let previous = DownsampledImageTaskKey(url: URL(string: "https://example.com/b.png"), size: 128)

        #expect(DownsampledImageGate.value("a", loadedFor: showing, showing: showing) == "a")
        #expect(DownsampledImageGate.value("b", loadedFor: previous, showing: showing) == nil)
        #expect(DownsampledImageGate.value("b", loadedFor: nil, showing: showing) == nil)
    }

    @Test func downsampledDataImageGateDropsAnImageLoadedForAnotherPayload() async throws {
        // Same defect in the local-attachment twin, reached from the same header avatar: the
        // group-image branch has no shared-cache fallback, so a stale pass shows the previous
        // chat's picture outright.
        let showing = DownsampledDataImageTaskKey(payloadID: "payload-a", size: 128)
        let previous = DownsampledDataImageTaskKey(payloadID: "payload-b", size: 128)

        #expect(DownsampledDataImageTaskKey(payloadID: "payload-a", size: 128) == showing)
        #expect(DownsampledDataImageTaskKey(payloadID: "payload-a", size: 256) != showing)
        #expect(DownsampledImageGate.value("a", loadedFor: showing, showing: showing) == "a")
        #expect(DownsampledImageGate.value("b", loadedFor: previous, showing: showing) == nil)
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
                    children: [.text(content: spoofedLinkLabel)],
                    classification: .web
                )
            ],
            remainingDepth: 32
        )
        #expect(!containsBidiEmbeddingOrIsolate(String(linkAttributed.characters)))
        #expect(String(linkAttributed.characters) == "moc.elpmaxe//:sptth")
        #expect(links(in: linkAttributed).map(\.absoluteString) == ["https://evil.example/phish"])

        let spoofedAutolinkURL = "\(rtlOverride)https://example.com\(ltrIsolate)"
        let autolinkAttributed = MarkdownDisplayInlineBuilder.attributedString(
            from: [.autolink(url: spoofedAutolinkURL, kind: .uri, classification: .web)],
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

    @Test func markdownDisplayUnderlinesLinksButNotMentions() async throws {
        let webAutolink = MarkdownDisplayInlineBuilder.attributedString(
            from: [.autolink(url: "https://example.com", kind: .uri, classification: .web)],
            remainingDepth: 32
        )
        #expect(links(in: webAutolink).map(\.absoluteString) == ["https://example.com"])
        #expect(underlineStyles(in: webAutolink) == [.single])

        let emphasizedLink = MarkdownDisplayInlineBuilder.attributedString(
            from: [
                .link(
                    dest: "https://example.com/docs",
                    title: nil,
                    children: [
                        .strong(children: [.text(content: "bold")]),
                        .text(content: " plain"),
                    ],
                    classification: .web
                )
            ],
            remainingDepth: 32
        )
        #expect(String(emphasizedLink.characters) == "bold plain")
        #expect(underlineStyles(in: emphasizedLink) == [.single, .single])
        #expect(
            links(in: emphasizedLink).map(\.absoluteString) == [
                "https://example.com/docs", "https://example.com/docs",
            ])
        #expect(emphasizedLink.runs.first?.inlinePresentationIntent?.contains(.stronglyEmphasized) == true)

        let npub = "npub1qqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqq0l5v8"
        let mention = MarkdownDisplayInlineBuilder.attributedString(
            from: [.nostrMention(entity: MarkdownNostrEntityFfi(hrp: .npub, bech32: npub))],
            remainingDepth: 32
        )
        #expect(links(in: mention).map(\.absoluteString) == ["nostr:\(npub)"])
        #expect(underlineStyles(in: mention) == [nil])

        // A mention is bold, in `MentionTextPalette.foreground`, and carries no background chip.
        // Asserted against the palette rather than "it differs from the body" so a mention that
        // quietly stopped being marked at all fails here.
        #expect(mention.runs.allSatisfy { $0.backgroundColor == nil })
        #expect(
            mention.runs.first?.inlinePresentationIntent?.contains(.stronglyEmphasized) == true)
        #expect(mention.runs.first?.foregroundColor == MentionTextPalette.foreground)

        // An `nprofile` is TLV-encoded rather than a bare key, so it identifies no one this side
        // of a lookup — which no longer matters, because the color marks a tag rather than the
        // person tagged. It takes the same blue as any other mention.
        let nprofile = "nprofile1qqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqq0l5v8"
        let nprofileMention = MarkdownDisplayInlineBuilder.attributedString(
            from: [.nostrMention(entity: MarkdownNostrEntityFfi(hrp: .nprofile, bech32: nprofile))],
            remainingDepth: 32
        )
        #expect(nprofileMention.runs.first?.foregroundColor == MentionTextPalette.foreground)
        #expect(
            nprofileMention.runs.first?.inlinePresentationIntent?.contains(.stronglyEmphasized)
                == true)

        let note = "note1qqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqq0l5v8"
        let noteReference = MarkdownDisplayInlineBuilder.attributedString(
            from: [.nostrUri(entity: MarkdownNostrEntityFfi(hrp: .note, bech32: note))],
            remainingDepth: 32
        )
        #expect(links(in: noteReference).map(\.absoluteString) == ["nostr:\(note)"])
        #expect(noteReference.runs.allSatisfy { $0.backgroundColor == nil })
        #expect(underlineStyles(in: noteReference) == [.single])

        let mentionInsideLink = MarkdownDisplayInlineBuilder.attributedString(
            from: [
                .link(
                    dest: "https://example.com",
                    title: nil,
                    children: [
                        .text(content: "see "),
                        .nostrMention(entity: MarkdownNostrEntityFfi(hrp: .npub, bech32: npub)),
                    ],
                    classification: .web
                )
            ],
            remainingDepth: 32
        )
        #expect(underlineStyles(in: mentionInsideLink) == [.single, nil])
        #expect(
            links(in: mentionInsideLink).map(\.absoluteString) == [
                "https://example.com", "nostr:\(npub)",
            ])

        let plain = MarkdownDisplayInlineBuilder.attributedString(
            from: [.text(content: "plain")],
            remainingDepth: 32
        )
        #expect(underlineStyles(in: plain) == [nil])

        let rejected: [MarkdownLinkDestinationKindFfi] = [.dangerous, .sensitive, .relative, .unknown]
        for classification in rejected {
            let dropped = MarkdownDisplayInlineBuilder.attributedString(
                from: [
                    .link(
                        dest: "https://example.com",
                        title: nil,
                        children: [.text(content: "label")],
                        classification: classification
                    )
                ],
                remainingDepth: 32
            )
            #expect(links(in: dropped).isEmpty, "expected no link for \(classification)")
            #expect(underlineStyles(in: dropped) == [nil], "expected no underline for \(classification)")
        }
    }

    @Test func markdownDisplayLeavesContactAndForeignAppAutolinksInert() async throws {
        let contactAutolinks: [MarkdownInlineFfi] = [
            .autolink(url: "a@b.com", kind: .email, classification: .contact),
            .autolink(url: "mailto:foo@bar.com", kind: .uri, classification: .contact),
            .autolink(url: "tel:+15551234567", kind: .uri, classification: .contact),
        ]
        for inline in contactAutolinks {
            let attributed = MarkdownDisplayInlineBuilder.attributedString(
                from: [inline],
                remainingDepth: 32
            )
            #expect(links(in: attributed).isEmpty, "expected no link for \(inline)")
            #expect(underlineStyles(in: attributed) == [nil], "expected no underline for \(inline)")
        }

        // `whitenoise://` classifies as `.app` and stays inert — this app registers `marmot://`.
        let foreignAppScheme = MarkdownDisplayInlineBuilder.attributedString(
            from: [.autolink(url: "whitenoise://group/abc", kind: .uri, classification: .app)],
            remainingDepth: 32
        )
        #expect(links(in: foreignAppScheme).isEmpty)
        #expect(underlineStyles(in: foreignAppScheme) == [nil])

        // ...while `marmot://profile/<nprofile>` is the `.app` form the app does consume, so the
        // branch is not dead.
        let profileLink = MarkdownDisplayInlineBuilder.attributedString(
            from: [.autolink(url: "marmot://profile/nprofile1alyce", kind: .uri, classification: .app)],
            remainingDepth: 32
        )
        #expect(links(in: profileLink).map(\.absoluteString) == ["marmot://profile/nprofile1alyce"])
        #expect(underlineStyles(in: profileLink) == [.single])
    }

    @Test func markdownInlineBuilderDropsUnsafeMarkdownLinks() async throws {
        let safe = MarkdownDisplayInlineBuilder.attributedString(
            from: [
                .link(
                    dest: "https://example.com/profile",
                    title: nil,
                    children: [.text(content: "safe")],
                    classification: .web
                )
            ], remainingDepth: 32)
        #expect(String(safe.characters) == "safe")
        #expect(links(in: safe).map(\.absoluteString) == ["https://example.com/profile"])

        let unsafe = MarkdownDisplayInlineBuilder.attributedString(
            from: [
                .link(
                    dest: "file:///Applications/Calculator.app",
                    title: nil,
                    children: [.text(content: "unsafe")],
                    classification: .dangerous
                )
            ], remainingDepth: 32)
        #expect(String(unsafe.characters) == "unsafe")
        #expect(links(in: unsafe).isEmpty)

        let unsafeAutolink = MarkdownDisplayInlineBuilder.attributedString(
            from: [
                .autolink(url: "smb://attacker/share", kind: .uri, classification: .unknown)
            ], remainingDepth: 32)
        #expect(String(unsafeAutolink.characters) == "smb://attacker/share")
        #expect(links(in: unsafeAutolink).isEmpty)

        let hostConfusion = MarkdownDisplayInlineBuilder.attributedString(
            from: [
                .link(
                    dest: "https://relay.damus.io@evil.example/phish",
                    title: nil,
                    children: [.text(content: "spoof")],
                    classification: .web
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

    @Test func overWideMarkdownTableBoundsDisplayNodesAndSetsTruncated() async throws {
        // Regression for whitenoise-mac#517: depth is bounded but sibling width is not.
        // A single wide table must not materialize thousands of Grid cells.
        let document = wideMarkdownTable(columns: 50, rows: 50)
        let display = MarkdownDisplayDocument(document: document)

        #expect(display.truncated)
        #expect(markdownDisplayNodeCount(display) <= MarkdownDisplayDocument.maxDisplayNodes)
        guard case .table(let header, let rows) = display.blocks.first?.block else {
            Issue.record("expected a table block")
            return
        }
        #expect(!header.isEmpty)
        #expect(header.first?.id == 0)
        #expect(!rows.isEmpty)
        #expect(rows.first?.id == 0)
        #expect(rows.first?.cells.first?.id == 0)
        #expect(rows.last?.cells.isEmpty == false)
    }

    @Test func overLongMarkdownListBoundsDisplayNodesAndSetsTruncated() async throws {
        let document = longMarkdownList(itemCount: 500)
        let display = MarkdownDisplayDocument(document: document)

        #expect(display.truncated)
        #expect(markdownDisplayNodeCount(display) <= MarkdownDisplayDocument.maxDisplayNodes)
        guard case .list(let items) = display.blocks.first?.block else {
            Issue.record("expected a list block")
            return
        }
        #expect(!items.isEmpty)
        #expect(items.first?.id == 0)
        #expect(items.first?.blocks.first?.id == 0)
        #expect(items.last?.blocks.isEmpty == false)
    }

    /// The in-place mention relabel has to reach every inline run in the tree, not just the
    /// top-level paragraph a one-line message renders as — a mention inside a quote, a list item,
    /// or a table cell is the same person under the same label.
    @Test func mentionRelabelRewritesEveryNestedRunAndLeavesOtherReferencesAlone() async throws {
        let alice = "npub1alyce"
        let note = "note1someeventreference0000"
        let mention: MarkdownInlineFfi = .nostrMention(
            entity: MarkdownNostrEntityFfi(hrp: .npub, bech32: alice)
        )
        let paragraph: MarkdownBlockFfi = .paragraph(inlines: [.text(content: "hi "), mention])
        let document = MarkdownDisplayDocument(
            document: MarkdownDocumentFfi(
                blocks: [
                    paragraph,
                    .heading(level: 2, inlines: [mention]),
                    .blockQuote(blocks: [paragraph], blankLinesBefore: Data([0])),
                    .listBlock(
                        kind: .bullet(marker: "-"),
                        tight: true,
                        items: [MarkdownListItemFfi(blocks: [paragraph], checked: nil)]
                    ),
                    .table(
                        alignments: [.left],
                        header: [MarkdownTableCellFfi(inlines: [mention])],
                        rows: [[MarkdownTableCellFfi(inlines: [mention])]]
                    ),
                    .paragraph(inlines: [
                        .nostrMention(entity: MarkdownNostrEntityFfi(hrp: .note, bech32: note))
                    ]),
                ],
                truncated: false
            ),
            mentionNames: [alice: "Alice"]
        )
        #expect(markdownDisplayText(document).contains("@Alice"))

        let relabeled = try #require(document.relabelingMention(bech32: alice, name: "Mum"))
        let text = markdownDisplayText(relabeled)
        #expect(!text.contains("@Alice"))
        // One run each in the paragraph, heading, quote, list item, table header, and table body.
        #expect(text.components(separatedBy: "@Mum").count - 1 == 6)
        // An unrelated reference keeps its own rendering, and the document's own flags survive.
        #expect(text.contains(MarkdownMentionText.shortBech32(note)))
        #expect(relabeled.truncated == document.truncated)
        #expect(relabeled.blocks.map(\.id) == document.blocks.map(\.id))

        // Clearing the label falls back to the truncated reference, and a document that never
        // mentions this person is reported as unchanged rather than copied.
        let cleared = try #require(relabeled.relabelingMention(bech32: alice, name: nil))
        #expect(markdownDisplayText(cleared).contains("@\(MarkdownMentionText.shortBech32(alice))"))
        #expect(cleared.relabelingMention(bech32: "npub1nobody", name: "Nobody") == nil)
        #expect(relabeled.relabelingMention(bech32: alice, name: "Mum") == nil)
    }

    @Test func normalMarkdownTableIsNotTruncatedByDisplayBudget() async throws {
        let document = wideMarkdownTable(columns: 4, rows: 3)
        let display = MarkdownDisplayDocument(document: document)
        #expect(!display.truncated)
        guard case .table(let header, let rows) = display.blocks.first?.block else {
            Issue.record("expected a table block")
            return
        }
        #expect(header.count == 4)
        #expect(rows.count == 3)
        #expect(rows.allSatisfy { $0.cells.count == 4 })
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

    @Test func markdownNostrFallbackStripsBidiControlsAfterTruncation() async throws {
        let rtlOverride = "\u{202E}"
        let ltrIsolate = "\u{2066}"
        let profileReference = "npub1abc\(rtlOverride)defghijklmnop\(ltrIsolate)"
        let eventReference = "note1abc\(rtlOverride)defghijklmnop\(ltrIsolate)"

        let profile = MarkdownDisplayInlineBuilder.attributedString(
            from: [
                .nostrMention(
                    entity: MarkdownNostrEntityFfi(hrp: .npub, bech32: profileReference)
                )
            ],
            remainingDepth: 32
        )
        let event = MarkdownDisplayInlineBuilder.attributedString(
            from: [
                .nostrUri(
                    entity: MarkdownNostrEntityFfi(hrp: .note, bech32: eventReference)
                )
            ],
            remainingDepth: 32
        )

        #expect(String(profile.characters) == "@npub1abcd...nop")
        #expect(String(event.characters) == "note1abcd...nop")
        #expect(!containsBidiEmbeddingOrIsolate(String(profile.characters)))
        #expect(!containsBidiEmbeddingOrIsolate(String(event.characters)))
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
            version: .v1,
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

    private func underlineStyles(in attributed: AttributedString) -> [Text.LineStyle?] {
        attributed.runs.map(\.underlineStyle)
    }

    /// Ranges carrying a mention token's visible styling, read back from a composer text view's
    /// storage. The identity markers use private attribute keys, so the styling is what a test can
    /// observe directly; identity is observed through
    /// `ComposerMentionMarkerStore.selections(in:)`.
    ///
    /// A token is styled by weight and by the mentioned person's accent, matching a rendered
    /// mention, rather than by a background chip. The **weight** is what is enumerated here: the
    /// composer's typing attributes carry a foreground color for every character, so enumerating
    /// color alone would match the entire draft, while only a mention is bold.
    ///
    /// The baseline is the composer's *own* plain typing face, not the system body font. The
    /// composer types at the ramp's Medium rung, which AppKit ranks a step above system regular,
    /// so a plain-system baseline would rank every plain character as styled and match the whole
    /// draft.
    @MainActor
    private func mentionStyledRanges(in textView: NSTextView) -> [NSRange] {
        guard let storage = textView.textStorage else { return [] }
        let plainWeight = NSFontManager.shared.weight(
            of: WNNSFont.font(for: ComposerMessageTextViewRepresentable.typingStyle))
        var result: [NSRange] = []
        storage.enumerateAttribute(
            .font,
            in: NSRange(location: 0, length: (textView.string as NSString).length)
        ) { value, range, _ in
            guard let font = value as? NSFont,
                NSFontManager.shared.weight(of: font) > plainWeight
            else { return }
            result.append(range)
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

    // MARK: - User discovery ranking

    @Test func discoveryRadiusDecidesOrderWhenEveryHigherTierIsTied() {
        let near = discoveryResult(hex: "a", radius: 1)
        let far = discoveryResult(hex: "b", radius: 2)

        #expect(sortedHexes([far, near]) == [hex("a"), hex("b")])
    }

    @Test func discoveryProviderRankDecidesOrderWithinTheSameRadius() {
        let strong = discoveryResult(hex: "a", radius: 2, providerRank: 0.9)
        let weak = discoveryResult(hex: "b", radius: 2, providerRank: 0.1)

        #expect(sortedHexes([weak, strong]) == [hex("a"), hex("b")])
    }

    @Test func discoveryAbsentProviderRankSortsAfterAPresentOne() {
        let ranked = discoveryResult(hex: "b", radius: 2, providerRank: 0.01)
        let unranked = discoveryResult(hex: "a", radius: 2, providerRank: nil)

        #expect(sortedHexes([unranked, ranked]) == [hex("b"), hex("a")])
    }

    @Test func discoveryRadiusOutranksProviderRank() {
        let nearUnranked = discoveryResult(hex: "b", radius: 1, providerRank: nil)
        let farHighlyRanked = discoveryResult(hex: "a", radius: 255, providerRank: 0.99)

        #expect(sortedHexes([farHighlyRanked, nearUnranked]) == [hex("b"), hex("a")])
    }

    @Test func discoveryMatchQualityDecidesOrderWhenRadiusAndRankAreTied() {
        let contains = discoveryResult(hex: "a", radius: 1, matchQuality: .contains)
        let prefix = discoveryResult(hex: "b", radius: 1, matchQuality: .prefix)
        let exact = discoveryResult(hex: "c", radius: 1, matchQuality: .exact)

        #expect(sortedHexes([contains, prefix, exact]) == [hex("c"), hex("b"), hex("a")])
    }

    @Test func discoveryMatchedFieldDecidesOrderWhenMatchQualityIsTied() {
        let fields: [MatchedFieldFfi] = [.pubkey, .npub, .about, .displayName, .nip05, .name]
        let results = fields.enumerated().map { index, field in
            discoveryResult(hex: String(index), radius: 1, matchedField: field)
        }

        // Most identifying first, so the input order reverses exactly.
        #expect(sortedHexes(results) == (0..<fields.count).reversed().map { hex(String($0)) })
    }

    @Test func discoveryDedupesByLowercasedHexKeepingTheFirstOccurrence() {
        let first = discoveryResult(hex: "a", radius: 1, displayName: "First")
        let duplicate = UserDirectorySearchResultFfi(
            accountIdHex: hex("a").uppercased(),
            npub: "npub1a",
            radius: 2,
            matchedField: .name,
            matchQuality: .exact,
            providerRank: nil,
            profile: discoveryProfile(displayName: "Second")
        )

        let people = UserDiscoveryRanking.sortedUnique(
            [first, duplicate].compactMap(UserDiscoveryRanking.person)
        )

        #expect(people.count == 1)
        #expect(people.first?.displayName == "First")
    }

    @Test func discoveryHexTiebreakMakesOtherwiseIdenticalResultsDeterministic() {
        let first = discoveryResult(hex: "a", radius: 1)
        let second = discoveryResult(hex: "b", radius: 1)

        // Sorting is not stable, so without the total-order hex tiebreak the rendered order could
        // swap between updates for two results that tie on every meaningful key.
        #expect(sortedHexes([first, second]) == sortedHexes([second, first]))
        #expect(sortedHexes([second, first]) == [hex("a"), hex("b")])
    }

    @Test func discoveryStripsBidiControlsAndNewlinesFromStrangerDisplayNames() {
        let result = discoveryResult(hex: "a", radius: 1, displayName: "Al\u{202E}ice\nBob")

        #expect(UserDiscoveryRanking.person(from: result)?.displayName == "AliceBob")
    }

    @Test func discoveryRejectsUnsafeStrangerPictureURLs() {
        let unsafe = [
            "http://example.com/avatar.png",
            "file:///etc/passwd",
            "https://localhost/avatar.png",
            "https://127.0.0.1/avatar.png",
            "https://10.0.0.5/avatar.png",
        ]

        for raw in unsafe {
            let result = discoveryResult(hex: "a", radius: 1, picture: raw)
            let person = UserDiscoveryRanking.person(from: result)
            #expect(person?.sanitizedPictureURL == nil, "\(raw) must not be fetchable")
        }

        let safe = discoveryResult(hex: "a", radius: 1, picture: "https://example.com/avatar.png")
        #expect(UserDiscoveryRanking.person(from: safe)?.sanitizedPictureURL != nil)
    }

    @Test func discoveryMergeKeepsTheKnownContactForAHexPresentInBothSources() {
        let known = ComposeContact(
            accountIdHex: hex("a"),
            npub: "npub1a",
            displayName: "Real conversation name",
            pictureURL: nil,
            lastActivity: nil
        )
        let discovered = UserDiscoveryRanking.person(
            from: discoveryResult(hex: "a", radius: 1, displayName: "Search snapshot name")
        )

        let merged = UserDiscoveryRanking.merged(
            known: [known],
            discovered: [discovered].compactMap { $0 },
            excluding: []
        )

        #expect(merged.known.map(\.accountIdHex) == [hex("a")])
        #expect(merged.known.first?.displayName == "Real conversation name")
        #expect(merged.discovered.isEmpty)
    }

    @Test func discoveryMergeRemovesExcludedHexesFromEitherSource() {
        let known = ComposeContact(
            accountIdHex: hex("a"),
            npub: "npub1a",
            displayName: "Known",
            pictureURL: nil,
            lastActivity: nil
        )
        let discovered = [
            discoveryResult(hex: "b", radius: 1),
            discoveryResult(hex: "c", radius: 1),
        ].compactMap(UserDiscoveryRanking.person)

        let merged = UserDiscoveryRanking.merged(
            known: [known],
            discovered: discovered,
            // Uppercased on purpose: exclusion is hex-case-insensitive.
            excluding: [hex("a").uppercased(), hex("b")]
        )

        #expect(merged.known.isEmpty)
        #expect(merged.discovered.map(\.accountIdHex) == [hex("c")])
    }

    // MARK: - User discovery presentation

    @Test func discoveryProvenanceLabelsOnlyClaimAConnectionForRequestedRadii() {
        #expect(UserDiscoveryPresentation.provenanceLabel(radius: 1) == L10n.string("In your network"))
        #expect(UserDiscoveryPresentation.provenanceLabel(radius: 2) == L10n.string("Via your network"))
        #expect(UserDiscoveryPresentation.provenanceLabel(radius: 255) == L10n.string("Discovery"))
        // 0 is the searcher and 3...254 are outside the 1...2 window, so there is no honest
        // provenance to show — and 255 must never read as a distance from the user.
        #expect(UserDiscoveryPresentation.provenanceLabel(radius: 0) == nil)
        #expect(UserDiscoveryPresentation.provenanceLabel(radius: 3) == nil)
        #expect(UserDiscoveryPresentation.provenanceLabel(radius: 254) == nil)
    }

    @Test func discoveryStatusResolvesToExactlyOneRowForEveryFlagCombination() {
        var seen: [UserDiscoveryStatus] = []
        for isSearching in [false, true] {
            for didFail in [false, true] {
                for isPartial in [false, true] {
                    seen.append(
                        UserDiscoveryPresentation.status(
                            isSearching: isSearching,
                            didFail: didFail,
                            isPartial: isPartial
                        )
                    )
                }
            }
        }

        #expect(
            seen == [
                .none, .partial, .failed, .failed,
                .searching, .searching, .searching, .searching,
            ]
        )
    }

    @Test func discoveryNoMatchesIsSuppressedWhileSearchingWithNoResultsYet() {
        let empty = MergedComposeResults(known: [], discovered: [])
        #expect(!UserDiscoveryPresentation.showsNoMatches(results: empty, isSearching: true))
        #expect(UserDiscoveryPresentation.showsNoMatches(results: empty, isSearching: false))

        let withResults = MergedComposeResults(
            known: [],
            discovered: [discoveryResult(hex: "a", radius: 1)].compactMap(UserDiscoveryRanking.person)
        )
        #expect(!UserDiscoveryPresentation.showsNoMatches(results: withResults, isSearching: false))
    }

    // MARK: - ChatDestructiveActions

    @Test func destructiveActionOffersLeaveOnlyWhileStillAMember() {
        #expect(
            ChatDestructiveActions.action(membership: .member, leaveRequestPending: false) == .leave
        )
        #expect(
            ChatDestructiveActions.action(membership: .left, leaveRequestPending: false)
                == .deleteLocally
        )
        #expect(
            ChatDestructiveActions.action(membership: .removed, leaveRequestPending: false)
                == .deleteLocally
        )
    }

    /// A leave already in flight suppresses a *second* leave, and only while the group still counts
    /// this account as a member — that is the one state where neither action is honest.
    @Test func pendingLeaveSuppressesTheLeaveOnlyWhileStillAMember() {
        #expect(
            ChatDestructiveActions.action(membership: .member, leaveRequestPending: true) == nil
        )
    }

    /// The regression this file exists to pin: `leaveRequestPending` stays true from the SelfRemove
    /// publish until a remaining member commits it, which for a group whose others never return is
    /// never. Withholding the local delete there left every departed chat stuck on a "Leaving" badge
    /// with no action that could clear it, so a departed chat must always offer the delete.
    @Test func departedChatOffersLocalDeleteEvenWithAnUnresolvedLeaveRequest() {
        for membership: ChatSelfMembership in [.left, .removed] {
            for pending in [false, true] {
                #expect(
                    ChatDestructiveActions.action(
                        membership: membership,
                        leaveRequestPending: pending
                    ) == .deleteLocally,
                    "\(membership) with pending=\(pending) must still offer the local delete"
                )
            }
        }
    }

    /// The badge and the menu are two readings of one state, so no chat may show a leave in progress
    /// while its menu offers a destructive action, and none may sit on `.leaving` with no way out.
    @Test func onlyTheBadgelessLeavingStateWithholdsEveryDestructiveAction() {
        for membership: ChatSelfMembership in [.member, .left, .removed] {
            for pending in [false, true] {
                for invited in [false, true] {
                    let status = ChatRowStatus.status(
                        membership: membership,
                        leaveRequestPending: pending,
                        pendingConfirmation: invited
                    )
                    let action = ChatDestructiveActions.action(
                        membership: membership,
                        leaveRequestPending: pending
                    )
                    #expect(
                        (status == .leaving) == (action == nil),
                        "\(membership)/pending=\(pending): a stuck badge needs an action, and vice versa"
                    )
                }
            }
        }
    }

    @Test func rowStatusReportsTheSettledMembershipRatherThanAnUnresolvedLeave() {
        #expect(
            ChatRowStatus.status(
                membership: .left,
                leaveRequestPending: true,
                pendingConfirmation: false
            ) == .membershipEnded(.left)
        )
        #expect(
            ChatRowStatus.status(
                membership: .member,
                leaveRequestPending: true,
                pendingConfirmation: false
            ) == .leaving
        )
        #expect(
            ChatRowStatus.status(
                membership: .member,
                leaveRequestPending: false,
                pendingConfirmation: true
            ) == .pendingInvite
        )
        #expect(
            ChatRowStatus.status(
                membership: .member,
                leaveRequestPending: false,
                pendingConfirmation: false
            ) == nil
        )
        // An ended membership outranks both flags, so the row never shows two contradictory badges.
        #expect(
            ChatRowStatus.status(
                membership: .removed,
                leaveRequestPending: true,
                pendingConfirmation: true
            ) == .membershipEnded(.removed)
        )
    }

    /// The load-bearing invariant: **no leave eligibility, however bad, produces a local delete for
    /// someone the group still counts as a member — while anyone else is still in the group.**
    /// Deleting locally with others present would strand every later message they send, with nothing
    /// on the wire to say so, so eligibility never decides it.
    ///
    /// Crosses both forms over the whole eligibility product: the membership-only one, which is all a
    /// sidebar row can evaluate and which never yields a delete for a member at all, and the
    /// roster-aware one, held here to a roster with a second member present. The single shape allowed
    /// to deviate — nobody left in the group — is pinned in
    /// `soleRemainingMemberBlockedAsLastAdminIsOfferedTheLocalDelete`, and the reason it is safe there
    /// is exactly the reason it is forbidden here.
    @MainActor
    @Test func noEligibilityStateOffersLocalDeleteWhileOthersRemainInTheGroup() {
        let othersPresent = ChatDestructiveActions.lastAdminResolution(
            members: [
                handoffMember(id: "self", isSelf: true, isAdmin: true),
                handoffMember(id: "still-here", canPromote: false),
            ]
        )
        #expect(othersPresent == .blocked)

        for pending in [false, true] {
            for canLeave in [false, true] {
                for requiresSelfDemote in [false, true] {
                    for isLastAdmin in [false, true] {
                        let eligibility = leaveEligibility(
                            canLeave: canLeave,
                            requiresSelfDemoteBeforeLeave: requiresSelfDemote,
                            leaveRequestPending: pending,
                            isLastAdmin: isLastAdmin
                        )
                        let action = ChatDestructiveActions.action(
                            membership: .member,
                            leaveRequestPending: pending
                        )
                        #expect(action != .deleteLocally)
                        // Blocked or not, a member is only ever offered the leave.
                        #expect(action == (pending ? nil : .leave))

                        let blocker = ChatDestructiveActions.leaveBlocker(
                            membership: .member,
                            eligibility: eligibility
                        )
                        // Same answer from the roster-aware form while someone else is present.
                        #expect(
                            ChatDestructiveActions.action(
                                membership: .member,
                                leaveRequestPending: pending,
                                leaveBlocker: blocker,
                                lastAdminResolution: othersPresent
                            ) == action
                        )
                        // And the blocker only ever explains itself — it carries no delete.
                        if let blocker {
                            #expect(!ChatActionAlert.leaveBlocked(blocker).message.isEmpty)
                        }
                    }
                }
            }
        }
    }

    /// The last admin is the case the core makes unavoidable: it reports
    /// `requiresSelfDemoteBeforeLeave` for *any* self-admin, but MIP-03 forbids the self-removal
    /// that would empty the admin set. Self-demoting first must not be attempted there.
    @Test func lastAdminCanNeitherLeaveNorSelfDemoteFirst() {
        let lastAdmin = leaveEligibility(
            canLeave: false,
            requiresSelfDemoteBeforeLeave: true,
            isLastAdmin: true
        )
        #expect(!ChatDestructiveActions.shouldSelfDemoteBeforeLeave(lastAdmin))
        #expect(!ChatDestructiveActions.canLeave(lastAdmin))
        #expect(
            ChatDestructiveActions.leaveBlocker(membership: .member, eligibility: lastAdmin)
                == .lastAdmin
        )
        // From membership alone the answer is still Leave, and deliberately *not* a local delete:
        // the group has to learn that this account stopped reading, and only a leave tells them.
        // What happens next depends on who is left — a successor to promote
        // (`soleAdminWithASuccessorIsGuidedToTheHandoffRatherThanBlocked`), nobody at all
        // (`soleRemainingMemberBlockedAsLastAdminIsOfferedTheLocalDelete`), or this dead end.
        #expect(
            ChatDestructiveActions.action(membership: .member, leaveRequestPending: false) == .leave
        )
        #expect(
            ChatActionAlert.leaveBlocked(.lastAdmin).message
                == L10n.string(
                    "You're the only admin, and there's no one here who can take over. Invite someone before you leave."
                )
        )
    }

    /// The reason this flow exists: a sole admin with a member who can take over is not blocked,
    /// they are one step from leaving. Only the genuine dead end — nobody to promote — may be
    /// reported as a blocker.
    @Test func soleAdminWithASuccessorIsGuidedToTheHandoffRatherThanBlocked() {
        let lastAdmin = leaveEligibility(
            canLeave: false,
            requiresSelfDemoteBeforeLeave: true,
            isLastAdmin: true
        )

        #expect(
            ChatDestructiveActions.leaveGuidance(
                membership: .member,
                eligibility: lastAdmin,
                lastAdminResolution: .handOffAdmin
            ) == .adminHandoffRequired
        )
        #expect(
            ChatDestructiveActions.leaveGuidance(
                membership: .member,
                eligibility: lastAdmin,
                lastAdminResolution: .blocked
            ) == .blocked(.lastAdmin)
        )
        // One promises the leave will happen, the other says it cannot — sharing wording would make
        // the footer a lie in whichever case it was not written for.
        #expect(
            ChatDestructiveActions.LeaveGuidance.adminHandoffRequired.message
                != ChatDestructiveActions.LeaveBlocker.lastAdmin.message
        )
    }

    /// `.lastAdmin` is the only blocker a promotion resolves. A pending leave and a disabled group
    /// are unaffected by who else could be made admin, and must never open the picker.
    @Test func onlyTheSoleAdminBlockIsResolvedByHandingAdminOver() {
        let pending = leaveEligibility(canLeave: false, leaveRequestPending: true, isLastAdmin: true)
        let unavailable = leaveEligibility(canLeave: false, isLastAdmin: false)

        // No roster answer may soften either one — not the successor that resolves `.lastAdmin`, and
        // not the empty group that redirects it to a local delete.
        for eligibility in [pending, unavailable] {
            let blocker = ChatDestructiveActions.leaveBlocker(
                membership: .member,
                eligibility: eligibility
            )
            for resolution: ChatDestructiveActions.LastAdminResolution in [
                .handOffAdmin, .deleteLocally, .blocked,
            ] {
                #expect(
                    ChatDestructiveActions.leaveGuidance(
                        membership: .member,
                        eligibility: eligibility,
                        lastAdminResolution: resolution
                    ) == blocker.map(ChatDestructiveActions.LeaveGuidance.blocked)
                )
                #expect(
                    ChatDestructiveActions.action(
                        membership: .member,
                        leaveRequestPending: eligibility.leaveRequestPending,
                        leaveBlocker: blocker,
                        lastAdminResolution: resolution
                    ) != .deleteLocally
                )
            }
        }

        // And a leave with nothing wrong with it needs no footer at all, whoever is in the roster.
        for resolution: ChatDestructiveActions.LastAdminResolution in [
            .handOffAdmin, .deleteLocally, .blocked,
        ] {
            #expect(
                ChatDestructiveActions.leaveGuidance(
                    membership: .member,
                    eligibility: leaveEligibility(canLeave: true),
                    lastAdminResolution: resolution
                ) == nil
            )
        }
    }

    /// The dead end this flow used to produce: alone in a chat, blocked for being the last admin,
    /// and advised to invite someone before leaving. There is nobody to invite and nobody to hand the
    /// role to, so the leave can never happen — the local delete is the only way to close the chat,
    /// and it is safe precisely because there is no one left to strand.
    @MainActor
    @Test func soleRemainingMemberBlockedAsLastAdminIsOfferedTheLocalDelete() {
        let alone = [handoffMember(id: "self", isSelf: true, isAdmin: true, canPromote: true)]
        #expect(ChatDestructiveActions.isSoleRemainingMember(alone))
        #expect(ChatDestructiveActions.lastAdminResolution(members: alone) == .deleteLocally)

        let lastAdmin = leaveEligibility(
            canLeave: false,
            requiresSelfDemoteBeforeLeave: true,
            isLastAdmin: true
        )
        #expect(
            ChatDestructiveActions.leaveGuidance(
                membership: .member,
                eligibility: lastAdmin,
                lastAdminResolution: .deleteLocally
            ) == .localDeleteInstead
        )
        #expect(
            ChatDestructiveActions.action(
                membership: .member,
                leaveRequestPending: false,
                leaveBlocker: .lastAdmin,
                lastAdminResolution: .deleteLocally
            ) == .deleteLocally
        )
        // Its own wording: neither the handoff promise nor the "invite someone" dead end applies.
        let message = ChatDestructiveActions.LeaveGuidance.localDeleteInstead.message
        #expect(message != ChatDestructiveActions.LeaveGuidance.adminHandoffRequired.message)
        #expect(message != ChatDestructiveActions.LeaveBlocker.lastAdmin.message)
        #expect(
            message
                == L10n.string(
                    "You're the only one left in this chat, so there's no one to hand admin to. Remove it from this device to close it out."
                )
        )
    }

    /// The line the escape must not cross. "Nobody to promote" and "nobody left at all" are
    /// different facts, and only the second one makes a local delete safe: a sole admin whose
    /// companions the core refuses to promote is just as stuck, but deleting locally there would
    /// strand the members still in the group — the exact harm the membership rule exists to prevent.
    @MainActor
    @Test func soleAdminWithUnpromotableCompanionsStaysBlockedRatherThanDeleting() {
        let stuckWithOthers = [
            handoffMember(id: "self", isSelf: true, isAdmin: true, canPromote: true),
            handoffMember(id: "not-promotable", canPromote: false),
        ]
        #expect(!ChatDestructiveActions.isSoleRemainingMember(stuckWithOthers))
        #expect(ChatDestructiveActions.adminHandoffCandidates(from: stuckWithOthers).isEmpty)
        #expect(ChatDestructiveActions.lastAdminResolution(members: stuckWithOthers) == .blocked)
        #expect(
            ChatDestructiveActions.action(
                membership: .member,
                leaveRequestPending: false,
                leaveBlocker: .lastAdmin,
                lastAdminResolution: .blocked
            ) == .leave
        )

        // A successor keeps precedence over both: it is the only resolution that puts the departure
        // on the wire, so it is never traded for a local delete.
        let withSuccessor = [
            handoffMember(id: "self", isSelf: true, isAdmin: true, canPromote: true),
            handoffMember(id: "successor", canPromote: true),
        ]
        #expect(ChatDestructiveActions.lastAdminResolution(members: withSuccessor) == .handOffAdmin)
        #expect(
            ChatDestructiveActions.action(
                membership: .member,
                leaveRequestPending: false,
                leaveBlocker: .lastAdmin,
                lastAdminResolution: .handOffAdmin
            ) == .leave
        )
    }

    /// `canPromote` is the core's verdict on whether the promotion would commit, so it decides who
    /// is offered. Self, existing admins, and anyone the core won't let this account promote are all
    /// useless as successors — offering them would produce a picker whose choice fails.
    @MainActor
    @Test func adminHandoffCandidatesAreOnlyMembersThePromotionWouldActuallyWorkFor() {
        let members = [
            handoffMember(id: "self", isSelf: true, isAdmin: true, canPromote: true),
            handoffMember(id: "already-admin", isAdmin: true, canPromote: true),
            handoffMember(id: "not-promotable", canPromote: false),
            handoffMember(id: "successor", canPromote: true),
        ]

        #expect(ChatDestructiveActions.adminHandoffCandidates(from: members).map(\.id) == ["successor"])
        #expect(ChatDestructiveActions.adminHandoffCandidates(from: []).isEmpty)
        // An admin alone in the group is the dead end the `.lastAdmin` blocker still reports.
        #expect(
            ChatDestructiveActions.adminHandoffCandidates(
                from: [handoffMember(id: "self", isSelf: true, isAdmin: true, canPromote: true)]
            ).isEmpty
        )
    }

    /// A one-row picker asks a question with a single available answer, so the sheet opens with that
    /// answer chosen and the confirmation is all that is left. Two or more is a decision that stays
    /// the user's to make.
    @MainActor
    @Test func soleSuccessorIsPreselectedWhileARealChoiceIsNot() {
        let alice = handoffMember(id: "alice", canPromote: true)
        let bob = handoffMember(id: "bob", canPromote: true)

        #expect(handoffTarget(candidates: [alice]).preselectedSuccessorId == "alice")
        #expect(handoffTarget(candidates: [alice, bob]).preselectedSuccessorId == nil)
        // A target is never built with an empty roster — that case is the `.lastAdmin` dead end — but
        // the property must answer "nobody" rather than invent a successor if one ever is.
        #expect(handoffTarget(candidates: []).preselectedSuccessorId == nil)
    }

    @Test func nonLastAdminLeavesBySteppingDownFirst() {
        let admin = leaveEligibility(
            canLeave: false,
            requiresSelfDemoteBeforeLeave: true,
            isLastAdmin: false
        )
        #expect(ChatDestructiveActions.shouldSelfDemoteBeforeLeave(admin))
        #expect(ChatDestructiveActions.canLeave(admin))
        #expect(ChatDestructiveActions.leaveBlocker(membership: .member, eligibility: admin) == nil)
        #expect(
            ChatDestructiveActions.action(membership: .member, leaveRequestPending: false) == .leave
        )
    }

    /// `canLeave == false` without an admin role means ordinary group actions are disabled
    /// (disbanding, or a terminal lifecycle). Reporting "you're the only admin" there would be a
    /// plain lie, so it gets its own blocker.
    @Test func blockedNonAdminReportsUnavailableRatherThanLastAdmin() {
        let blocked = leaveEligibility(
            canLeave: false,
            requiresSelfDemoteBeforeLeave: false,
            isLastAdmin: false
        )
        #expect(
            ChatDestructiveActions.leaveBlocker(membership: .member, eligibility: blocked)
                == .unavailable
        )
        #expect(
            ChatDestructiveActions.leaveBlocker(membership: .left, eligibility: blocked) == nil,
            "a non-member has nothing left to leave, so nothing to explain"
        )
    }

    /// Every blocker explains itself and stops there; none of them carries an alternative action.
    @Test func everyLeaveBlockerReportsOnlyItsReason() {
        for blocker: ChatDestructiveActions.LeaveBlocker in [.pending, .lastAdmin, .unavailable] {
            let alert = ChatActionAlert.leaveBlocked(blocker)
            #expect(alert.title == L10n.string("Couldn't leave chat"))
            #expect(alert.message == blocker.message)
        }
    }

    /// Regression for the report that opened this: an unnamed group's leave dialog read
    /// `Leave “Unnamed group”? Are you sure you want to leave…`.
    ///
    /// The assertion is about the *sentences* rather than about one placeholder string, because the
    /// two surfaces feed the dialog different stand-ins — the localized "Unnamed group" from the
    /// inspector, MDK's raw conversation id from the sidebar — so pinning either one alone would
    /// leave the other free to come back.
    @MainActor
    @Test func noConfirmationSentenceQuotesAStandInForAnUnnamedChat() {
        let unnamedId = String(repeating: "a", count: 64)
        let chat = ChatItem(
            row: confirmationRow(groupIdHex: unnamedId, groupName: "", conversationKind: .group),
            activeAccountIdHex: nil
        )
        // What the sidebar row shows for a group nobody titled, and exactly why quoting it failed.
        #expect(chat.title == unnamedId)
        #expect(chat.confirmationSubject == .unnamedGroup)

        for subject: ChatConfirmationSubject in [.unnamedGroup, .unnamedChat] {
            for sentence in confirmationSentences(of: subject) {
                #expect(!sentence.contains(L10n.string("Unnamed group")), "\(subject): \(sentence)")
                #expect(!sentence.contains(unnamedId), "\(subject): \(sentence)")
                // The other way a dropped name shows up: the quotes stay and the slot is empty.
                #expect(!sentence.contains("“”"), "\(subject): \(sentence)")
            }
        }
    }

    /// "If it is only a chat with one person, name the person instead." A one-to-one chat is
    /// addressed rather than quoted like a group title, and it must not be told it will stop
    /// receiving messages "from this group" — it is not one.
    @MainActor
    @Test func directChatConfirmationsNameThePeerRatherThanTheConversation() {
        let chat = ChatItem(
            row: confirmationRow(groupIdHex: "dm", groupName: "", conversationKind: .direct),
            activeAccountIdHex: nil,
            directPeer: ChatPeerProfile(accountIdHex: "alice", displayName: "Alice", pictureURL: nil)
        )
        #expect(chat.confirmationSubject == .directChat(peerName: "Alice"))

        let subject = ChatConfirmationSubject.directChat(peerName: "Alice")
        #expect(subject.leaveConfirmationTitle.contains("Alice"))
        #expect(subject.localDeleteConfirmationTitle.contains("Alice"))
        // A peer-controlled name is isolated, so it cannot reorder the sentence around it.
        #expect(subject.leaveConfirmationTitle.contains(PeerDisplayText.templateFragment("Alice")))
        // Compared against the group wording rather than grepped for the word "group": the
        // assertion has to hold in every language the catalog carries.
        for requiresSelfDemote in [false, true] {
            #expect(
                subject.leaveConfirmationMessage(requiresSelfDemote: requiresSelfDemote)
                    != ChatConfirmationSubject.unnamedGroup.leaveConfirmationMessage(
                        requiresSelfDemote: requiresSelfDemote)
            )
        }
    }

    /// The inspector's own path. `name` keeps the placeholder its header needs, so the subject has
    /// to be read off `customName` — reading `name` is what put "Unnamed group" in the sentence.
    @MainActor
    @Test func snapshotSubjectReadsTheGroupsOwnNameRatherThanItsHeaderLabel() {
        let alice = handoffMember(id: "Alice")
        let unnamed = confirmationSnapshot(
            customName: nil,
            others: [alice, handoffMember(id: "Bob")]
        )
        #expect(unnamed.name == L10n.string("Unnamed group"))
        #expect(unnamed.confirmationSubject == .unnamedGroup)

        // One other member and no name: MDK calls that a direct chat, and so does the sentence.
        #expect(
            confirmationSnapshot(customName: nil, others: [alice]).confirmationSubject
                == .directChat(peerName: "Alice")
        )
        // Nobody else on the roster — an emptied-out chat has no name *and* no peer.
        #expect(confirmationSnapshot(customName: nil, others: []).confirmationSubject == .unnamedChat)

        // A name makes a conversation a group whatever its size, which is MDK's rule too: a named
        // two-person chat must not be downgraded to "your chat with Alice".
        #expect(
            confirmationSnapshot(customName: "Book club", others: [alice]).confirmationSubject
                == .namedGroup("Book club")
        )
    }

    /// The case that already worked keeps working: a group the user named is still quoted by name
    /// in all three dialogs.
    @Test func namedGroupConfirmationsStillQuoteTheName() {
        let subject = ChatConfirmationSubject.namedGroup("Design team")
        for sentence in [
            subject.leaveConfirmationTitle,
            subject.localDeleteConfirmationTitle,
            subject.adminHandoffExplanation,
        ] {
            #expect(sentence.contains("Design team"), "\(sentence)")
        }
        #expect(subject.leaveConfirmationTitle.contains(PeerDisplayText.templateFragment("Design team")))
        #expect(subject.leaveConfirmationTitle != ChatConfirmationSubject.unnamedGroup.leaveConfirmationTitle)
    }

    /// A direct message is a two-member MLS group here, so it must follow the same rule; the copy
    /// is chat-neutral precisely so no `isDirect` branch is needed.
    @Test func directChatsFollowTheSameDestructiveActionRule() {
        for isDirect in [false, true] {
            let chat = destructiveActionChat(
                membership: .member,
                leaveRequestPending: false,
                isDirect: isDirect
            )
            #expect(ChatDestructiveActions.action(for: chat) == .leave)

            let left = destructiveActionChat(
                membership: .left,
                leaveRequestPending: false,
                isDirect: isDirect
            )
            #expect(ChatDestructiveActions.action(for: left) == .deleteLocally)
        }
    }

    /// The `ChatItem` adapters the sidebar row actually calls, so it cannot read a different rule
    /// than the one the cases above pin.
    @Test func departedChatItemShowsTheEndedBadgeAndStillOffersTheDelete() {
        let left = destructiveActionChat(
            membership: .left,
            leaveRequestPending: true,
            isDirect: false
        )
        #expect(ChatRowStatus.status(for: left) == .membershipEnded(.left))
        #expect(ChatDestructiveActions.action(for: left) == .deleteLocally)

        let leaving = destructiveActionChat(
            membership: .member,
            leaveRequestPending: true,
            isDirect: false
        )
        #expect(ChatRowStatus.status(for: leaving) == .leaving)
        #expect(ChatDestructiveActions.action(for: leaving) == nil)
    }

    // MARK: - Chat row preview line

    /// An unanswered invite says so where the last message would go, so the row explains itself in
    /// words instead of in a capsule beside the title. Direct and group invites read differently
    /// because only the direct row's title names the person who sent it.
    @Test func pendingInviteWithoutMessagesExplainsItselfInThePreviewLine() {
        let english = Locale(identifier: "en")

        #expect(
            invitePreviewChat(isDirect: true, preview: "").previewPlaceholder(locale: english)
                == "Has invited you to a secure chat"
        )
        #expect(
            invitePreviewChat(isDirect: false, preview: "").previewPlaceholder(locale: english)
                == "You have been invited to a secure chat"
        )
    }

    /// The invite line is a *placeholder*: an invite that already carries history shows that
    /// history, exactly as an accepted chat would.
    @Test func pendingInviteCarryingMessagesShowsThemRatherThanTheInviteLine() {
        #expect(
            invitePreviewChat(isDirect: true, preview: "Alice: Welcome in")
                .previewPlaceholder(locale: Locale(identifier: "en")) == nil
        )
    }

    /// Only a pending invite gets the invite wording; every other empty chat keeps the neutral
    /// placeholder, including one whose invite flag survives alongside an ended membership —
    /// `ChatRowStatus` settles that precedence, and the preview line must not re-decide it.
    @Test func emptyChatsThatAreNotPendingInvitesKeepTheNeutralPlaceholder() {
        let english = Locale(identifier: "en")

        #expect(
            invitePreviewChat(isDirect: true, preview: "", pendingConfirmation: false)
                .previewPlaceholder(locale: english) == "No messages yet"
        )
        #expect(
            invitePreviewChat(isDirect: false, preview: "", membership: .removed)
                .previewPlaceholder(locale: english) == "No messages yet"
        )
        #expect(
            invitePreviewChat(isDirect: false, preview: "", leaveRequestPending: true)
                .previewPlaceholder(locale: english) == "No messages yet"
        )
    }

    /// The line is resolved against the caller's locale rather than baked in at mapping time,
    /// which is what lets a language switch reach a chat list nothing else rebuilt.
    @Test func invitePreviewLineFollowsTheRequestedLocale() {
        let chat = invitePreviewChat(isDirect: false, preview: "")
        let spanish = chat.previewPlaceholder(locale: Locale(identifier: AppLanguage.spanish.rawValue))
        #expect(spanish == "Has sido invitado a un chat seguro")
        #expect(spanish != chat.previewPlaceholder(locale: Locale(identifier: "en")))
    }

    /// A removal takes the preview line outright — the chat is closed to the reader, so the row
    /// reports that instead of whatever was said before it, in the same words the chat's own
    /// composer notice uses. The "Removed" capsule beside the title goes away with it.
    @Test func removalTakesThePreviewLineFromTheLastMessage() {
        let removed = invitePreviewChat(
            isDirect: false,
            preview: "Alice: see you Monday",
            pendingConfirmation: false,
            membership: .removed
        )

        #expect(
            removed.previewNotice(locale: Locale(identifier: "en"))
                == "You were removed from this group"
        )
        #expect(ChatSelfMembership.removed.reportsInChatRowPreviewLine)
    }

    /// Leaving is the reader's own doing and stays a capsule, so its rows keep showing the last
    /// message — the one thing a row can say that the reader does not already know.
    @Test func leavingKeepsItsCapsuleAndItsLastMessage() {
        let left = invitePreviewChat(
            isDirect: false,
            preview: "Alice: see you Monday",
            pendingConfirmation: false,
            membership: .left
        )

        #expect(left.previewNotice(locale: Locale(identifier: "en")) == nil)
        #expect(ChatSelfMembership.left.reportsInChatRowPreviewLine == false)
        #expect(ChatSelfMembership.member.reportsInChatRowPreviewLine == false)
    }

    /// Everything the line said before still reaches it: a chat with no last message keeps the
    /// placeholder wording, and the removal notice does not displace an unanswered invite's.
    @Test func previewNoticeStillDefersToThePlaceholderWordingItReplaced() {
        let english = Locale(identifier: "en")

        #expect(
            invitePreviewChat(isDirect: true, preview: "").previewNotice(locale: english)
                == "Has invited you to a secure chat"
        )
        #expect(
            invitePreviewChat(isDirect: false, preview: "", pendingConfirmation: false)
                .previewNotice(locale: english) == "No messages yet"
        )
        #expect(
            invitePreviewChat(isDirect: true, preview: "Alice: Welcome in")
                .previewNotice(locale: english) == nil
        )
    }

    /// Resolved against the caller's locale for the same reason the invite line is: the chat list
    /// is not rebuilt on a language switch.
    @Test func removalPreviewLineFollowsTheRequestedLocale() {
        let removed = invitePreviewChat(
            isDirect: false,
            preview: "Alice: see you Monday",
            pendingConfirmation: false,
            membership: .removed
        )
        let spanish = removed.previewNotice(
            locale: Locale(identifier: AppLanguage.spanish.rawValue)
        )

        #expect(spanish == "Te eliminaron de este grupo")
        #expect(spanish != removed.previewNotice(locale: Locale(identifier: "en")))
    }

    // MARK: - PeerProfileRefreshGate

    @Test func peerProfileGateDedupesInFlightAttemptsForTheSameAccount() {
        var gate = PeerProfileRefreshGate()
        let now = Date(timeIntervalSince1970: 1_000)

        let firstAttempt = gate.tryStart("alice", now: now)
        // A second caller for the same id while the first attempt is outstanding must not
        // start another relay round-trip: render paths ask on every frame.
        let concurrentAttempt = gate.tryStart("alice", now: now)
        // A different id is unaffected.
        let otherPeer = gate.tryStart("bob", now: now)

        #expect(firstAttempt)
        #expect(!concurrentAttempt)
        #expect(otherPeer)
    }

    @Test func peerProfileGateSuppressesRetriesUntilTheBackoffElapses() {
        var gate = PeerProfileRefreshGate()
        let start = Date(timeIntervalSince1970: 1_000)

        _ = gate.tryStart("alice", now: start)
        gate.finish("alice", now: start, resolved: false)

        // A first failure backs off by 2s; nothing before that instant may start.
        let duringBackoff = gate.tryStart("alice", now: start.addingTimeInterval(1.9))
        let afterBackoff = gate.tryStart("alice", now: start.addingTimeInterval(2.0))

        #expect(!duringBackoff)
        #expect(afterBackoff)
    }

    @Test func peerProfileGateWalksTheBackoffLadderThenFallsBackToTheLongCooldown() {
        // Attempt 1 → 2s, attempt 2 → 4s, attempt 3 spends the run → the long cooldown.
        // Mirrors whitenoise-linux's 3-attempt 2s/4s ladder, so a peer whose kind:0 is
        // nowhere costs a bounded number of round-trips instead of looping.
        var gate = PeerProfileRefreshGate()
        var now = Date(timeIntervalSince1970: 1_000)
        var observedDelays: [TimeInterval] = []

        for _ in 0..<PeerProfileRefreshGate.maxAttemptsPerWindow {
            _ = gate.tryStart("alice", now: now)
            gate.finish("alice", now: now, resolved: false)
            let retryAfter = gate.retryAfterForTesting("alice")
            observedDelays.append(retryAfter?.timeIntervalSince(now) ?? -1)
            now = retryAfter ?? now
        }

        #expect(observedDelays == [2, 4, PeerProfileRefreshGate.retryCooldown])
        // The ladder resets once the run is spent, so a later window starts fresh.
        #expect(gate.attemptForTesting("alice") == 0)
    }

    @Test func peerProfileGateAppliesTheLongCooldownOnceAPeerResolves() {
        var gate = PeerProfileRefreshGate()
        let start = Date(timeIntervalSince1970: 1_000)

        _ = gate.tryStart("alice", now: start)
        gate.finish("alice", now: start, resolved: true)
        // Read the ladder state before the probes below: the `tryStart` at +60 prunes this
        // settled entry as its cooldown expires, which is the intended bound.
        #expect(gate.attemptForTesting("alice") == 0)

        let duringCooldown = gate.tryStart("alice", now: start.addingTimeInterval(59))
        let afterCooldown = gate.tryStart("alice", now: start.addingTimeInterval(60))

        #expect(!duringCooldown)
        #expect(afterCooldown)
    }

    @Test func peerProfileGatePrunesSettledEntriesOnFinishNotOnlyOnTryStart() {
        // Android's #230: a gate that goes quiescent after a burst of `finish` calls — a large
        // group whose senders all resolve in one pass — must not retain one entry per distinct
        // pubkey for the process lifetime. Pruning on `finish` too bounds the retained set to
        // the pubkeys with a live cooldown rather than every pubkey ever seen.
        var gate = PeerProfileRefreshGate()
        let start = Date(timeIntervalSince1970: 1_000)

        for index in 0..<50 {
            let id = "peer-\(index)"
            _ = gate.tryStart(id, now: start)
            gate.finish(id, now: start, resolved: true)
        }
        #expect(gate.retainedEntryCountForTesting == 50)

        // One later `finish`, past every cooldown, sweeps the whole settled set.
        let later = start.addingTimeInterval(PeerProfileRefreshGate.retryCooldown + 1)
        _ = gate.tryStart("late", now: later)
        gate.finish("late", now: later, resolved: true)

        #expect(gate.retainedEntryCountForTesting == 1)
    }

    @Test func peerProfileGateRetainsAMidLadderEntryPastItsBackoffSoTheLadderCannotRestart() {
        // Pruning a mid-ladder entry the moment its backoff expired would drop the attempt
        // counter, and the next request would restart at 2s forever instead of ever reaching
        // the long cooldown. Retention is still bounded: an entry nobody re-asks about within
        // one cooldown of its backoff expiring is stale, and does reset.
        var gate = PeerProfileRefreshGate()
        let start = Date(timeIntervalSince1970: 1_000)

        _ = gate.tryStart("alice", now: start)
        gate.finish("alice", now: start, resolved: false)

        let secondAttemptAt = start.addingTimeInterval(2.5)
        _ = gate.tryStart("alice", now: secondAttemptAt)
        gate.finish("alice", now: secondAttemptAt, resolved: false)
        // The 4s rung, i.e. attempt 2 — not attempt 1 again.
        #expect(gate.retryAfterForTesting("alice")?.timeIntervalSince(secondAttemptAt) == 4)

        let longAbandoned = secondAttemptAt.addingTimeInterval(4 + PeerProfileRefreshGate.retryCooldown + 1)
        _ = gate.tryStart("alice", now: longAbandoned)
        #expect(gate.attemptForTesting("alice") == nil)
    }

    @Test func peerProfileGateRemoveClearsAdmissionStateForAnExternalUpdate() {
        // A profile that arrives from outside this gate must not be held off by the cooldown
        // the gate set for its own earlier failed attempt.
        var gate = PeerProfileRefreshGate()
        let start = Date(timeIntervalSince1970: 1_000)

        _ = gate.tryStart("alice", now: start)
        gate.finish("alice", now: start, resolved: false)
        let blockedByCooldown = gate.tryStart("alice", now: start)

        gate.remove("alice")
        let allowedAfterRemove = gate.tryStart("alice", now: start)

        #expect(!blockedByCooldown)
        #expect(allowedAfterRemove)
    }

    @Test func peerProfileGateEscalatesTheCooldownAcrossRepeatedFailedRuns() {
        // Without escalation the gate is an infinite pulse: a spent run reset the ladder, the
        // 60s cooldown elapsed, and the next projection re-admitted the id at 2s — three relay
        // round-trips per peer per ~66s for the life of the process. The projection paths
        // request every sender and roster member they see, so an unresolvable 50-member group
        // sustained that forever. Each successive dead run must cost less than the last.
        var gate = PeerProfileRefreshGate()
        var now = Date(timeIntervalSince1970: 1_000)
        var cooldowns: [TimeInterval] = []

        // Four runs: one more than `repeatedFailureCooldowns` has rungs, to pin the ceiling.
        for _ in 0..<4 {
            var settledAt = now
            for _ in 0..<PeerProfileRefreshGate.maxAttemptsPerWindow {
                let admitted = gate.tryStart("alice", now: now)
                #expect(admitted)
                gate.finish("alice", now: now, resolved: false)
                settledAt = now
                now = gate.retryAfterForTesting("alice") ?? now
            }
            // `now` is the instant the spent run will next admit; the delta from the last
            // `finish` is the cooldown that run actually bought.
            cooldowns.append(now.timeIntervalSince(settledAt))
        }

        #expect(cooldowns == [60, 300, 1800, 1800])
        #expect(gate.failedRunsForTesting("alice") == 4)
    }

    @Test func peerProfileGateHoldsAFailedRunPastItsCooldownSoEscalationSurvivesPruning() {
        // The escalation lives in the retained entry. Pruning it the moment its cooldown
        // elapsed would drop `failedRuns` and put the id straight back on the 2s rung — the
        // exact pulse the escalation exists to stop.
        var gate = PeerProfileRefreshGate()
        var now = Date(timeIntervalSince1970: 1_000)

        for _ in 0..<PeerProfileRefreshGate.maxAttemptsPerWindow {
            _ = gate.tryStart("alice", now: now)
            gate.finish("alice", now: now, resolved: false)
            now = gate.retryAfterForTesting("alice") ?? now
        }
        #expect(gate.failedRunsForTesting("alice") == 1)

        // Admitted again once the cooldown elapses, and the run count carries forward.
        let admittedAfterCooldown = gate.tryStart("alice", now: now)
        #expect(admittedAfterCooldown)
        gate.finish("alice", now: now, resolved: false)
        #expect(gate.failedRunsForTesting("alice") == 1)
        #expect(gate.attemptForTesting("alice") == 1)
    }

    @Test func peerProfileGateClearsTheFailureHistoryOnceThePeerResolves() {
        // A peer going unnameable again later is a fresh problem — a changed pubkey, a rotated
        // relay set — and must get the responsive ladder back, not the escalated cooldown.
        var gate = PeerProfileRefreshGate()
        var now = Date(timeIntervalSince1970: 1_000)

        for _ in 0..<PeerProfileRefreshGate.maxAttemptsPerWindow {
            _ = gate.tryStart("alice", now: now)
            gate.finish("alice", now: now, resolved: false)
            now = gate.retryAfterForTesting("alice") ?? now
        }
        #expect(gate.failedRunsForTesting("alice") == 1)

        _ = gate.tryStart("alice", now: now)
        gate.finish("alice", now: now, resolved: true)

        #expect(gate.failedRunsForTesting("alice") == 0)
        now = now.addingTimeInterval(PeerProfileRefreshGate.retryCooldown)
        _ = gate.tryStart("alice", now: now)
        gate.finish("alice", now: now, resolved: false)
        // Back on the first rung of the urgent ladder.
        #expect(gate.retryAfterForTesting("alice")?.timeIntervalSince(now) == 2)
    }

    @Test func peerProfileGateDeferRetriesSkipsTheUrgentLadderAndSettlesTheRun() {
        // A nicknamed peer already renders correctly everywhere; only the published name shown
        // beneath the nickname is missing. That does not justify the 2s/4s burst.
        var gate = PeerProfileRefreshGate()
        let start = Date(timeIntervalSince1970: 1_000)

        _ = gate.tryStart("alice", now: start)
        gate.finish("alice", now: start, resolved: false, deferRetries: true)

        #expect(gate.retryAfterForTesting("alice")?.timeIntervalSince(start) == 60)
        #expect(gate.attemptForTesting("alice") == 0)
        // One deferred run still counts, so a peer who stays unnameable keeps escalating.
        #expect(gate.failedRunsForTesting("alice") == 1)
    }

    // MARK: - ChatItem peer presentation

    @Test func replacingPeerPresentationCarriesEveryFieldItDoesNotOwn() {
        // This copy used to re-invoke the memberwise initializer and list the carried fields by
        // hand, which silently dropped `previewAttachmentKind` the moment that field was added:
        // every direct row whose peer resolved late lost its media glyph. Mutating a copy makes
        // the carry total by construction.
        let original = ChatItem(
            id: "group-1",
            title: "npub1abc…",
            subtitle: "subtitle",
            preview: "Photo",
            previewAttachmentKind: .photo,
            updatedAt: Date(timeIntervalSince1970: 1_000),
            avatarSeed: hex("a"),
            pictureURL: "https://example.com/old.png",
            unreadCount: 3,
            manuallyMarkedUnread: true,
            unreadMentionCount: 2,
            isDirect: true,
            hasAuthoritativeConversationKind: true,
            muted: true,
            mutedUntilMs: 12_345,
            leaveRequestPending: true,
            pendingConfirmation: true,
            selfMembership: .left
        )

        let updated = original.replacingPeerPresentation(
            displayName: "Ali",
            publishedDisplayName: "Alice Cooper",
            pictureURL: "https://example.com/new.png"
        )

        #expect(updated.title == "Ali")
        #expect(updated.publishedTitle == "Alice Cooper")
        #expect(updated.pictureURL == "https://example.com/new.png")
        // Derived alongside `pictureURL`, never left pointing at the previous avatar.
        #expect(updated.sanitizedPictureURL == URL(string: "https://example.com/new.png"))
        // Everything else is row state a profile refresh has no business inventing.
        #expect(updated.previewAttachmentKind == .photo)
        #expect(updated.preview == "Photo")
        #expect(updated.subtitle == "subtitle")
        #expect(updated.unreadCount == 3)
        #expect(updated.manuallyMarkedUnread)
        #expect(updated.unreadMentionCount == 2)
        #expect(updated.muted)
        #expect(updated.mutedUntilMs == 12_345)
        #expect(updated.leaveRequestPending)
        #expect(updated.pendingConfirmation)
        #expect(updated.selfMembership == .left)
        #expect(updated.updatedAt == original.updatedAt)
    }

    @Test func replacingPeerPresentationKeepsTheExistingAvatarWhenNoneResolved() {
        // A peer whose name resolved but whose picture did not must not be blanked back to no
        // avatar; `nil` here means "nothing new", not "clear it".
        let original = ChatItem(
            id: "group-1",
            title: "npub1abc…",
            subtitle: "",
            preview: "",
            updatedAt: nil,
            avatarSeed: hex("a"),
            pictureURL: "https://example.com/old.png",
            unreadCount: 0,
            isDirect: true
        )

        let updated = original.replacingPeerPresentation(
            displayName: "Alice Cooper",
            publishedDisplayName: nil,
            pictureURL: nil
        )

        #expect(updated.title == "Alice Cooper")
        #expect(updated.publishedTitle == nil)
        #expect(updated.pictureURL == "https://example.com/old.png")
        #expect(updated.sanitizedPictureURL == original.sanitizedPictureURL)
    }
}

/// 64-char hex built from a short seed, so tests read as `hex("a")` rather than a wall of digits.
private func hex(_ seed: String) -> String {
    String((seed + String(repeating: "0", count: 64)).prefix(64))
}

/// The peer whose messages the chat-row preview tests attribute.
private let aliceIdHex = hex("a11ce")

/// A display name as a template composes it: bidi-isolated so peer-controlled text cannot
/// reorder what follows it.
private func bidiIsolated(_ text: String) -> String {
    "\u{2068}\(text)\u{2069}"
}

private func chatRow(
    groupName: String,
    sender: String,
    senderDisplayName: String?,
    plaintext: String
) -> ChatListRowFfi {
    ChatListRowFfi(
        groupIdHex: "group",
        archived: false,
        pendingConfirmation: false,
        title: groupName.isEmpty ? "Alice" : groupName,
        groupName: groupName,
        avatarUrl: nil,
        avatar: nil,
        lastMessage: ChatListMessagePreviewFfi(
            messageIdHex: "message-1",
            sender: sender,
            senderDisplayName: senderDisplayName,
            plaintext: plaintext,
            contentTokens: MarkdownDocumentFfi(blocks: [], truncated: false),
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
    )
}

private func discoveryProfile(displayName: String? = nil, picture: String? = nil) -> UserProfileMetadataFfi {
    UserProfileMetadataFfi(
        name: nil,
        displayName: displayName,
        about: nil,
        picture: picture,
        nip05: nil,
        lud16: nil
    )
}

private func discoveryResult(
    hex seed: String,
    radius: UInt8,
    matchedField: MatchedFieldFfi = .name,
    matchQuality: MatchQualityFfi = .exact,
    providerRank: Double? = nil,
    displayName: String? = nil,
    picture: String? = nil
) -> UserDirectorySearchResultFfi {
    UserDirectorySearchResultFfi(
        accountIdHex: hex(seed),
        npub: "npub1\(seed)",
        radius: radius,
        matchedField: matchedField,
        matchQuality: matchQuality,
        providerRank: providerRank,
        profile: displayName == nil && picture == nil
            ? nil
            : discoveryProfile(displayName: displayName, picture: picture)
    )
}

private func sortedHexes(_ results: [UserDirectorySearchResultFfi]) -> [String] {
    UserDiscoveryRanking.sortedUnique(results.compactMap(UserDiscoveryRanking.person))
        .map(\.accountIdHex)
}

private func leaveEligibility(
    canLeave: Bool = true,
    requiresSelfDemoteBeforeLeave: Bool = false,
    leaveRequestPending: Bool = false,
    isLastAdmin: Bool = false
) -> ChatLeaveEligibility {
    ChatLeaveEligibility(
        canLeave: canLeave,
        requiresSelfDemoteBeforeLeave: requiresSelfDemoteBeforeLeave,
        leaveRequestPending: leaveRequestPending,
        isLastAdmin: isLastAdmin
    )
}

@MainActor
private func handoffMember(
    id: String,
    isSelf: Bool = false,
    isAdmin: Bool = false,
    canPromote: Bool = false
) -> GroupMemberItem {
    GroupMemberItem(
        id: id,
        displayName: id,
        publishedDisplayName: nil,
        npub: "npub1\(id)",
        accountLabel: nil,
        isLocal: isSelf,
        isAdmin: isAdmin,
        isSelf: isSelf,
        canRemove: false,
        canPromote: canPromote,
        canDemote: isAdmin
    )
}

private func handoffTarget(candidates: [GroupMemberItem]) -> ChatAdminHandoffTarget {
    ChatAdminHandoffTarget(
        groupIdHex: "group",
        subject: .namedGroup("Planning"),
        candidates: candidates
    )
}

private func confirmationSentences(of subject: ChatConfirmationSubject) -> [String] {
    [
        subject.leaveConfirmationTitle,
        subject.leaveConfirmationMessage(requiresSelfDemote: false),
        subject.leaveConfirmationMessage(requiresSelfDemote: true),
        subject.localDeleteConfirmationTitle,
        subject.adminHandoffExplanation,
    ]
}

private func confirmationRow(
    groupIdHex: String,
    groupName: String,
    conversationKind: ChatConversationKindFfi
) -> ChatListRowFfi {
    ChatListRowFfi(
        groupIdHex: groupIdHex,
        archived: false,
        pendingConfirmation: false,
        // MDK's `chat_title`: the conversation id stands in whenever the profile name is blank.
        title: groupName.isEmpty ? groupIdHex : groupName,
        groupName: groupName,
        avatarUrl: nil,
        avatar: nil,
        lastMessage: nil,
        unreadCount: 0,
        hasUnread: false,
        unreadMentionCount: 0,
        unreadMention: false,
        firstUnreadMessageIdHex: nil,
        lastReadMessageIdHex: nil,
        lastReadTimelineAt: nil,
        updatedAt: 0,
        selfMembership: .member,
        conversationKind: conversationKind
    )
}

@MainActor
private func confirmationSnapshot(
    customName: String?,
    others: [GroupMemberItem]
) -> GroupDetailsSnapshot {
    GroupDetailsSnapshot(
        groupIdHex: "group",
        endpoint: "",
        name: customName ?? L10n.string("Unnamed group"),
        customName: customName,
        description: "",
        avatarURL: nil,
        sanitizedAvatarURL: nil,
        avatarDimension: nil,
        nostrGroupIdHex: "",
        relays: [],
        adminIds: [],
        archived: false,
        pendingConfirmation: false,
        selfMembership: .member,
        members: [handoffMember(id: "self", isSelf: true)] + others,
        isSelfAdmin: false,
        isLastAdmin: false,
        canInvite: false,
        canLeave: true,
        requiresSelfDemoteBeforeLeave: false,
        disappearingMessageSecs: 0
    )
}

private func destructiveActionChat(
    membership: ChatSelfMembership,
    leaveRequestPending: Bool,
    isDirect: Bool
) -> ChatItem {
    ChatItem(
        id: "group",
        title: "Planning",
        subtitle: "",
        preview: "",
        updatedAt: nil,
        avatarSeed: "seed",
        pictureURL: nil,
        unreadCount: 0,
        isDirect: isDirect,
        leaveRequestPending: leaveRequestPending,
        selfMembership: membership
    )
}

private func invitePreviewChat(
    isDirect: Bool,
    preview: String,
    pendingConfirmation: Bool = true,
    leaveRequestPending: Bool = false,
    membership: ChatSelfMembership = .member
) -> ChatItem {
    ChatItem(
        id: "group",
        title: "Alice",
        subtitle: "",
        preview: preview,
        updatedAt: nil,
        avatarSeed: "seed",
        pictureURL: nil,
        unreadCount: 0,
        isDirect: isDirect,
        leaveRequestPending: leaveRequestPending,
        pendingConfirmation: pendingConfirmation,
        selfMembership: membership
    )
}

private func mentionCandidate(
    id: String,
    displayName: String,
    npub: String,
    nickname: String? = nil
) -> ComposerMentionCandidate {
    ComposerMentionCandidate(
        details: mentionMember(id: id, displayName: displayName, npub: npub),
        nickname: nickname
    )
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

/// A chat row for an invite nobody has answered yet — the state the invite prompt draws in.
private func pendingInviteChat(
    id: String,
    avatarSeed: String? = nil,
    isDirect: Bool = false,
    pendingConfirmation: Bool = true
) -> ChatItem {
    ChatItem(
        id: id,
        title: "Test Group",
        subtitle: "",
        preview: "",
        updatedAt: nil,
        avatarSeed: avatarSeed ?? id,
        pictureURL: nil,
        unreadCount: 0,
        isDirect: isDirect,
        pendingConfirmation: pendingConfirmation
    )
}

/// A group record whose only interesting field is who sent the welcome.
private func inviteGroupRecord(groupIdHex: String, welcomerAccountIdHex: String?) -> AppGroupRecordFfi {
    AppGroupRecordFfi(
        groupIdHex: groupIdHex,
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
        pendingConfirmation: true,
        selfMembership: .member,
        welcomerAccountIdHex: welcomerAccountIdHex,
        viaWelcomeMessageIdHex: nil
    )
}

private let inviteManagementState = GroupManagementStateFfi(
    myAccountIdHex: "self",
    isSelfAdmin: false,
    isLastAdmin: false,
    canInvite: false,
    canLeave: true,
    requiresSelfDemoteBeforeLeave: false,
    memberActions: []
)

private func wideMarkdownTable(columns: Int, rows: Int) -> MarkdownDocumentFfi {
    let header = (0..<columns).map { column in
        MarkdownTableCellFfi(inlines: [.text(content: "h\(column)")])
    }
    let tableRows = (0..<rows).map { row in
        (0..<columns).map { column in
            MarkdownTableCellFfi(inlines: [.text(content: "\(row),\(column)")])
        }
    }
    return MarkdownDocumentFfi(
        blocks: [
            .table(
                alignments: Array(repeating: .left, count: columns),
                header: header,
                rows: tableRows
            )
        ],
        truncated: false
    )
}

private func longMarkdownList(itemCount: Int) -> MarkdownDocumentFfi {
    let items = (0..<itemCount).map { index in
        MarkdownListItemFfi(
            blocks: [.paragraph(inlines: [.text(content: "item \(index)")])],
            checked: nil
        )
    }
    return MarkdownDocumentFfi(
        blocks: [
            .listBlock(
                kind: .bullet(marker: "-"),
                tight: true,
                items: items
            )
        ],
        truncated: false
    )
}

/// Every inline run in a rendered document, flattened, so a relabel can be asserted across nested
/// block kinds without reaching into each case at the call site.
private func markdownDisplayText(_ document: MarkdownDisplayDocument) -> String {
    func text(of blocks: [MarkdownDisplayBlockNode]) -> String {
        blocks.map { text(of: $0.block) }.joined(separator: "\n")
    }

    func text(of block: MarkdownDisplayBlock) -> String {
        switch block {
        case .paragraph(let value):
            return String(value.characters)
        case .heading(_, let value):
            return String(value.characters)
        case .blockQuote(let inner):
            return text(of: inner)
        case .list(let items):
            return items.map { text(of: $0.blocks) }.joined(separator: "\n")
        case .table(let header, let rows):
            let headerText = header.map { String($0.text.characters) }
            let rowText = rows.flatMap { $0.cells.map { String($0.text.characters) } }
            return (headerText + rowText).joined(separator: "\n")
        case .codeBlock(let value), .mathBlock(let value):
            return value
        case .thematicBreak:
            return ""
        }
    }

    return text(of: document.blocks)
}

private func markdownDisplayNodeCount(_ document: MarkdownDisplayDocument) -> Int {
    func countBlocks(_ blocks: [MarkdownDisplayBlockNode]) -> Int {
        blocks.reduce(0) { total, node in
            total + 1 + countBlock(node.block)
        }
    }

    func countBlock(_ block: MarkdownDisplayBlock) -> Int {
        switch block {
        case .blockQuote(let inner):
            return countBlocks(inner)
        case .list(let items):
            return items.reduce(0) { partial, item in
                partial + 1 + countBlocks(item.blocks)
            }
        case .table(let header, let rows):
            return header.count
                + rows.reduce(0) { partial, row in
                    partial + 1 + row.cells.count
                }
        default:
            return 0
        }
    }

    return countBlocks(document.blocks)
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
