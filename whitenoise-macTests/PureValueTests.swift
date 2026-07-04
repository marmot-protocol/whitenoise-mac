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
    @Test func disappearingMessageCustomLabelFormatsCoreUInt64Value() async throws {
        // Regression for whitenoise-mac#212: values can originate from the core as
        // UInt64, and Int(value) traps above Int.max while `%d` truncates large
        // 64-bit values to misleading labels such as "-1 seconds".
        let above32BitSeconds = UInt64(Int32.max) + 1
        let oversizedSeconds = UInt64(Int.max) + 1

        #expect(DisappearingMessageOption.custom(above32BitSeconds).label == "2147483648 seconds")
        #expect(DisappearingMessageOption.custom(oversizedSeconds).label == "9223372036854775808 seconds")
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

        let nprofileURL = MarkdownLinkPolicy.sanitizedURL(from: "nostr:nprofile1alice")
        #expect(nprofileURL?.absoluteString == "nostr:nprofile1alice")
        #expect(MarkdownLinkPolicy.isResolvableProfileReference("npub1alice"))
        #expect(MarkdownLinkPolicy.isResolvableProfileReference("nprofile1alice"))
        #expect(MarkdownLinkPolicy.isProfileReferenceInput("nostr:nprofile1alice"))
        #expect(!MarkdownLinkPolicy.isResolvableProfileReference("note1alice"))

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

    @Test func marmotProfileLinkAcceptsStrictProfileFormOnly() async throws {
        // Accepted: strict marmot://profile/<npub|nprofile>, query ignored, case-insensitive
        // scheme/host. These flow in from OS deep links and kit-emitted message autolinks.
        for raw in [
            "marmot://profile/npub1alice",
            "marmot://profile/npub1alice?from=qr",
            "marmot://profile/nprofile1alice",
            "MARMOT://PROFILE/npub1alice",
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
        let plain = try #require(URL(string: "marmot://profile/npub1alice"))
        #expect(MarmotProfileLink.profileReference(from: plain) == "npub1alice")
        let withQuery = try #require(URL(string: "marmot://profile/npub1alice?from=qr"))
        #expect(MarmotProfileLink.profileReference(from: withQuery) == "npub1alice")

        // Rejected: every other marmot:// shape. The scheme is not exclusive to this app,
        // so inbound URLs are untrusted; nothing here may reach LaunchServices either.
        for raw in [
            "marmot://group/abc",
            "marmot://profile",
            "marmot://profile/",
            "marmot://profile/note1abc",
            "marmot://profile/npub1x/extra",
            "marmot://x-callback-url/run",
            "marmot://profile/../npub1alice",
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
        #expect(MarkdownLinkPolicy.sanitizedURL(from: "darkmatter://profile/npub1alice") == nil)

        // QR payload emits the canonical link form and round-trips through the parser.
        let payload = MarmotProfileLink.qrPayload(npub: "npub1alice")
        #expect(payload == "marmot://profile/npub1alice?from=qr")
        let payloadURL = try #require(URL(string: payload))
        #expect(MarmotProfileLink.profileReference(from: payloadURL) == "npub1alice")

        // Paste pre-check prefix helper.
        #expect(MarmotProfileLink.hasProfileLinkPrefix("  marmot://profile/npub1alice?from=qr "))
        #expect(MarmotProfileLink.hasProfileLinkPrefix("MARMOT://PROFILE/npub1alice"))
        #expect(!MarmotProfileLink.hasProfileLinkPrefix("darkmatter://profile/npub1alice"))
        #expect(!MarmotProfileLink.hasProfileLinkPrefix("marmot://group/abc"))
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
        #expect(MarkdownLinkPolicy.sanitizedURL(from: "nostr:nprofile1alice") != nil)
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
    }

    @Test func markdownInlineBuilderKeepsNostrEntitiesInternal() async throws {
        let bech32 = "npub1qqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqq0l5v8"
        let attributed = MarkdownDisplayInlineBuilder.attributedString(
            from: [
                .nostrMention(entity: MarkdownNostrEntityFfi(hrp: .npub, bech32: bech32))
            ], remainingDepth: 32)
        #expect(links(in: attributed).map(\.absoluteString) == ["nostr:\(bech32)"])
    }

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
