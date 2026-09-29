import CryptoKit
import Foundation
import MarmotKit
import Testing

@testable import whitenoise_mac

@MainActor
struct ProjectionMigrationTests {
    @Test func automaticAttachmentPermissionStaysDeniedUntilAccountIsReady() async {
        let runtime = FakeMarmotRuntime(accounts: [])
        runtime.attachmentPolicy.automatic = true
        runtime.setupReadiness = .initializing
        let model = AttachmentPolicyController(accountRef: "account", runtime: runtime)

        await model.refresh(connectivityAvailable: true)

        #expect(model.effectivePermission.images == false)
        #expect(runtime.attachmentPermissionUpdates.last?.files == false)

        runtime.setupReadiness = .networkReady
        await model.refresh(connectivityAvailable: true)

        #expect(model.effectivePermission.images)
        #expect(model.effectivePermission.videos)
        #expect(model.effectivePermission.audio)
        #expect(model.effectivePermission.files)
    }

    @Test func explicitAttachmentReadIsBoundedAndExact() async throws {
        let runtime = FakeMarmotRuntime(accounts: [])
        let expected = Data(repeating: 0x5a, count: 2_500_000)
        runtime.attachmentBytesByReference["asset"] = expected
        let model = AttachmentViewModel(accountRef: "account", groupIdHex: "group", runtime: runtime)

        let actual = try await model.readRetainedAsset(reference: "asset", byteCount: UInt64(expected.count))

        #expect(actual == expected)
    }

    @Test func explicitAttachmentDownloadBypassesAutomaticPolicyFence() async throws {
        let runtime = FakeMarmotRuntime(accounts: [])
        runtime.attachmentPolicy.automatic = false
        runtime.setupReadiness = .initializing
        runtime.downloadAttachmentAgainResult = "queued-reference"
        let target = AttachmentLocalTargetFfi(
            messageIdHex: "message",
            sourceMessageIdHex: "source",
            attachmentIndex: 2
        )
        let model = AttachmentViewModel(accountRef: "account", groupIdHex: "group", runtime: runtime)

        let reference = try await model.downloadExplicitly(target)

        #expect(reference == "queued-reference")
        #expect(runtime.explicitAttachmentDownloadTargets == [target])
        #expect(runtime.attachmentPermissionUpdates.isEmpty)
    }

    @Test func retainedAttachmentBytesRemainDiscoverableAcrossModelRestart() async throws {
        let runtime = FakeMarmotRuntime(accounts: [])
        let bytes = Data("retained across restart".utf8)
        let reference = MediaAttachmentReferenceFfi(
            locators: [],
            ciphertextSha256: "ciphertext",
            plaintextSha256: "plaintext",
            nonceHex: "nonce",
            fileName: "document.txt",
            mediaType: "text/plain",
            version: .v2,
            sourceEpoch: 3,
            dim: nil,
            thumbhash: nil
        )
        runtime.attachmentHistoryPageResult = .page(
            page: AttachmentPageFfi(
                entries: [
                    AttachmentEntryFfi(
                        messageIdHex: "message",
                        sourceMessageIdHex: "source",
                        sender: "alice",
                        timelineAt: 10,
                        receivedAt: 10,
                        sourceEpoch: 3,
                        category: .file,
                        attachment: .accepted(attachmentIndex: 0, reference: reference)
                    )
                ],
                version: AttachmentHistoryVersion(noPointer: .init()),
                nextCursor: nil,
                hasMore: false
            )
        )
        runtime.attachmentLocalAssetResults = [
            AttachmentLocalAssetFfi(reference: "retained-reference", byteCount: UInt64(bytes.count))
        ]
        runtime.attachmentBytesByReference["retained-reference"] = bytes

        let first = AttachmentViewModel(accountRef: "account", groupIdHex: "group", runtime: runtime)
        await first.refreshHistory()
        let firstTarget = try #require(first.items.first?.target)
        let firstAsset = try #require(first.localAssetsByTarget[firstTarget])
        #expect(
            try await first.readRetainedAsset(
                reference: #require(firstAsset.reference),
                byteCount: firstAsset.byteCount
            ) == bytes
        )
        first.stopTransferObservation()

        let relaunched = AttachmentViewModel(accountRef: "account", groupIdHex: "group", runtime: runtime)
        await relaunched.refreshHistory()
        let relaunchedTarget = try #require(relaunched.items.first?.target)
        let relaunchedAsset = try #require(relaunched.localAssetsByTarget[relaunchedTarget])
        #expect(
            try await relaunched.readRetainedAsset(
                reference: #require(relaunchedAsset.reference),
                byteCount: relaunchedAsset.byteCount
            ) == bytes
        )
    }

    @Test func retainedReadDiscardsPartialBytesWhenAssetBecomesUnavailable() async {
        let runtime = FakeMarmotRuntime(accounts: [])
        let model = AttachmentViewModel(accountRef: "account", groupIdHex: "group", runtime: runtime)

        await #expect(throws: AttachmentFeatureError.assetBecameUnavailable) {
            _ = try await model.readRetainedAsset(reference: "missing", byteCount: 10)
        }
    }

    @Test func retainedConversationAvatarBytesReachPreparedSenderProfiles() async {
        let runtime = FakeMarmotRuntime(accounts: [])
        let bytes = Data([0x89, 0x50, 0x4e, 0x47])
        let asset = AvatarAssetFfi(
            target: "peer",
            reference: "avatar-ref",
            availability: .ready,
            acquisition: nil,
            contentRevision: 1,
            byteCount: UInt64(bytes.count)
        )
        runtime.avatarBytes = [
            AvatarBytesFfi(
                reference: "avatar-ref",
                availability: .ready,
                contentRevision: 1,
                byteCount: UInt64(bytes.count),
                deferred: false,
                bytes: bytes,
                mediaType: "image/png",
                width: 1,
                height: 1
            )
        ]
        let store = AvatarAssetStore(accountRef: "account", runtime: runtime)

        await store.load(assets: [asset])

        var snapshot = Self.conversationSnapshot(sequence: 1, title: "Conversation")
        snapshot.identities = [
            ConversationIdentityFfi(
                accountIdHex: "peer",
                displayName: "Peer",
                avatar: .placeholder(stableSeed: "peer", source: .peerProfile),
                hasCachedProfile: true,
                avatarAsset: asset
            )
        ]
        let profiles = snapshot.senderProfiles(
            activeAccount: AccountItem.samples[0],
            nicknames: .none,
            avatarBytesByReference: store.bytesByReference
        )

        #expect(profiles["peer"]?.imagePayload?.data == bytes)
    }

    @Test func preparedConversationIdentitiesResolveMentionNpubsWithNicknameOverlay() {
        let peerID = "peer-id"
        let peerNpub = "npub1peer"
        var snapshot = Self.conversationSnapshot(sequence: 1, title: "Conversation")
        snapshot.identities = [
            ConversationIdentityFfi(
                accountIdHex: peerID,
                displayName: "Published Alice",
                avatar: .placeholder(stableSeed: peerID, source: .peerProfile),
                hasCachedProfile: true,
                avatarAsset: nil
            )
        ]
        snapshot.messages = [
            Self.conversationMessage(
                timelineMessage(
                    id: "mention",
                    direction: "inbound",
                    groupIdHex: "group",
                    sender: "sender",
                    plaintext: "Hello @\(peerNpub)",
                    recordedAt: 1
                ),
                mentions: [peerID]
            )
        ]
        let nicknames = ContactNicknames(
            ownerAccountIdHex: AccountItem.samples[0].accountIdHex,
            byContactIdHex: [peerID: "Mum"]
        )

        let names = snapshot.mentionNames(
            activeAccount: AccountItem.samples[0],
            nicknames: nicknames,
            npubForAccountIdHex: { $0 == peerID ? peerNpub : nil }
        )

        #expect(names == [peerNpub: "Mum"])
    }

    @Test func mediaOutcomesPreserveAcceptedAndRejectedAttachmentOrder() {
        let reference = MediaAttachmentReferenceFfi(
            locators: [],
            ciphertextSha256: "ciphertext",
            plaintextSha256: "plaintext",
            nonceHex: "nonce",
            fileName: "photo.jpg",
            mediaType: "image/jpeg",
            version: .v2,
            sourceEpoch: 4,
            dim: nil,
            thumbhash: nil
        )

        let attachments = MessageMediaParser.attachments(
            resolvedMedia: [
                .accepted(attachmentIndex: 0, reference: reference),
                .rejected(
                    attachmentIndex: 1,
                    rejection: MediaAttachmentRejectionFfi(
                        kind: .unsupportedFormat,
                        detail: "unsupported attachment"
                    )
                ),
                .accepted(attachmentIndex: 2, reference: reference),
            ],
            mediaJson: nil,
            tags: [],
            messageIdHex: "message"
        )

        #expect(attachments.map(\.rejectionKind) == [nil, .unsupportedFormat, nil])
        #expect(attachments.map(\.id)[1] == "message#1#rejected")
    }

    @Test func retainedAttachmentHistoryCorrelatesAssetsAndTransfersByOriginalSlot() async throws {
        let runtime = FakeMarmotRuntime(accounts: [])
        let reference = MediaAttachmentReferenceFfi(
            locators: [],
            ciphertextSha256: "ciphertext",
            plaintextSha256: "plaintext",
            nonceHex: "nonce",
            fileName: "photo.jpg",
            mediaType: "image/jpeg",
            version: .v2,
            sourceEpoch: 4,
            dim: nil,
            thumbhash: nil
        )
        runtime.attachmentHistoryPageResult = .page(
            page: AttachmentPageFfi(
                entries: [
                    AttachmentEntryFfi(
                        messageIdHex: "message",
                        sourceMessageIdHex: "source",
                        sender: "alice",
                        timelineAt: 10,
                        receivedAt: 10,
                        sourceEpoch: 4,
                        category: .image,
                        attachment: .accepted(attachmentIndex: 0, reference: reference)
                    ),
                    AttachmentEntryFfi(
                        messageIdHex: "message",
                        sourceMessageIdHex: "source",
                        sender: "alice",
                        timelineAt: 10,
                        receivedAt: 10,
                        sourceEpoch: 4,
                        category: .rejected,
                        attachment: .rejected(
                            attachmentIndex: 1,
                            rejection: MediaAttachmentRejectionFfi(
                                kind: .unsupportedFormat,
                                detail: "future format"
                            )
                        )
                    ),
                    AttachmentEntryFfi(
                        messageIdHex: "message",
                        sourceMessageIdHex: "source",
                        sender: "alice",
                        timelineAt: 10,
                        receivedAt: 10,
                        sourceEpoch: 4,
                        category: .file,
                        attachment: .accepted(attachmentIndex: 2, reference: reference)
                    ),
                ],
                version: AttachmentHistoryVersion(noPointer: .init()),
                nextCursor: nil,
                hasMore: false
            )
        )
        runtime.attachmentLocalAssetResults = [
            AttachmentLocalAssetFfi(reference: "asset-zero", byteCount: 10),
            AttachmentLocalAssetFfi(reference: "asset-two", byteCount: 20),
        ]
        runtime.attachmentTransferSnapshots = [
            AttachmentTransferSnapshotFfi(items: [
                AttachmentTransferStatusFfi(
                    reference: "asset-zero",
                    state: .ready,
                    attempt: 1,
                    received: 10,
                    total: 10,
                    retryAt: nil
                ),
                AttachmentTransferStatusFfi(
                    reference: "asset-two",
                    state: .downloading,
                    attempt: 1,
                    received: 5,
                    total: 20,
                    retryAt: nil
                ),
            ])
        ]
        let model = AttachmentViewModel(accountRef: "account", groupIdHex: "group", runtime: runtime)

        await model.refreshHistory()

        #expect(model.items.map(\.attachmentIndex) == [0, 1, 2])
        #expect(model.items[1].rejection?.kind == .unsupportedFormat)
        let firstTarget = try #require(model.items[0].target)
        let thirdTarget = try #require(model.items[2].target)
        #expect(model.localAssetsByTarget[firstTarget]?.reference == "asset-zero")
        #expect(model.localAssetsByTarget[thirdTarget]?.reference == "asset-two")
        let didReceiveTransfer = await waitFor {
            model.transfersByTarget[thirdTarget]?.state == .downloading
        }
        #expect(didReceiveTransfer)
    }

    @Test func groupRecoveryRejectsAStaleInvitationBeforeMutatingCoreState() async throws {
        let runtime = FakeMarmotRuntime(accounts: [])
        let current = GroupRejoinInvitationFfi(
            welcomeIdHex: "welcome",
            welcomerAccountIdHex: "alice",
            epoch: 7,
            localStateToken: "current-token"
        )
        runtime.groupRecoveryStatuses["group"] = GroupRecoveryStatusFfi(
            groupIdHex: "group",
            automaticRecoveryFailed: false,
            pendingReinvites: 0,
            failedReinvites: 0,
            rejoinInvitations: [current]
        )
        let model = GroupSafetyViewModel(accountRef: "account", groupIdHex: "group", runtime: runtime)
        await model.load(canModerate: false)
        #expect(runtime.contentReportRequests.isEmpty)
        let stale = GroupRejoinInvitationFfi(
            welcomeIdHex: "welcome",
            welcomerAccountIdHex: "alice",
            epoch: 7,
            localStateToken: "stale-token"
        )

        await #expect(throws: GroupSafetyError.staleInvitation) {
            try await model.confirm(stale)
        }
        #expect(runtime.groupRecoveryStatuses["group"]?.rejoinInvitations == [current])

        try await model.confirm(current)
        #expect(model.recovery?.rejoinInvitations.isEmpty == true)
    }

    @Test func reportingIsCapabilityGatedAndUsesTheFeatureService() async throws {
        let incoming = MessageItem(
            id: "message",
            groupIdHex: "group",
            senderName: "Alice",
            body: "content",
            sentAt: .now,
            isOutgoing: false
        )
        let reported = MessageItem(
            id: "reported-message",
            groupIdHex: "group",
            senderName: "Alice",
            body: "content",
            sentAt: .now,
            hasReports: true,
            isOutgoing: false
        )
        let outgoing = MessageItem(
            id: "own-message",
            groupIdHex: "group",
            senderName: "Me",
            body: "content",
            sentAt: .now,
            isOutgoing: true
        )

        #expect(incoming.canReport)
        #expect(!reported.canReport)
        #expect(reported.metadataLabel.contains(L10n.string("Report submitted")))
        #expect(!outgoing.canReport)

        let runtime = FakeMarmotRuntime(accounts: [])
        let model = GroupSafetyViewModel(accountRef: "account", groupIdHex: "group", runtime: runtime)
        try await model.report(messageID: incoming.id, reason: .spam, explanation: "duplicate posts")

        #expect(runtime.reportRequests.count == 1)
        #expect(runtime.reportRequests[0].messageId == incoming.id)
        #expect(runtime.reportRequests[0].reason == .spam)
        #expect(runtime.reportRequests[0].explanation == "duplicate posts")
    }

    @Test func moderationDismissalAndLocalForgetUseTheSafetyService() async throws {
        let runtime = FakeMarmotRuntime(accounts: [])
        runtime.installGroup(messageGroup())
        runtime.contentReportPage = ContentReportPageFfi(
            reports: [
                ContentReportFfi(
                    reportIdHex: "report",
                    messageIdHex: "message",
                    messageAuthor: "author",
                    reporter: "reporter",
                    reason: .spam,
                    explanation: "duplicate posts",
                    reportedAt: 10,
                    dismissed: false
                )
            ],
            nextCursor: nil
        )
        let model = GroupSafetyViewModel(accountRef: "account", groupIdHex: "group", runtime: runtime)

        await model.load(canModerate: true)
        #expect(runtime.contentReportRequests.map(\.groupIdHex) == ["group"])
        #expect(model.reports.map(\.reportIdHex) == ["report"])

        try await model.dismiss(reportIDs: ["report"], explanation: "reviewed")
        #expect(runtime.dismissedReportIDs == [["report"]])
        #expect(model.reports.isEmpty)

        #expect(try await model.forgetLocally())
        #expect(runtime.forgottenGroupIDs == ["group"])
    }

    @Test func agentPublisherKeepsSecretsOpaqueAndFinishesExactTranscript() async throws {
        let runtime = FakeMarmotRuntime(accounts: [])
        let info = PublisherInfoFfi(streamIdHex: "stream", startMessageIdHex: "start")
        let summary = SendSummaryFfi(published: 1, messageIds: ["final"])
        let publisher = FakeAgentTextPublisher(
            info: info,
            acknowledgements: [
                PublisherAckFfi(chunkCount: 1, liveError: nil),
                PublisherAckFfi(chunkCount: 2, liveError: "preview unavailable"),
                PublisherAckFfi(chunkCount: 3, liveError: nil),
            ],
            finishResults: [.success(summary)]
        )
        runtime.agentPublisher = publisher
        let model = AgentSettingsViewModel(account: AccountItem.samples[0], runtime: runtime)
        let records = [
            AgentPublicationRecord(kind: .status, text: "thinking"),
            AgentPublicationRecord(kind: .progress, text: "halfway"),
            AgentPublicationRecord(kind: .text, text: "done"),
        ]

        let receipt = try await model.publish(
            groupIdHex: "group",
            brokerCandidate: "https://broker.example",
            records: records
        )

        #expect(runtime.agentPublisherRequests.count == 1)
        #expect(runtime.agentPublisherRequests[0].accountRef == AccountItem.samples[0].accountRef)
        #expect(runtime.agentPublisherRequests[0].groupIdHex == "group")
        #expect(runtime.agentPublisherRequests[0].options.candidate == "https://broker.example")
        #expect(runtime.agentPublisherRequests[0].options.serverCertDer == nil)
        #expect(runtime.agentPublisherRequests[0].options.trust == .publicOnly)
        #expect(publisher.appended == records)
        #expect(publisher.finishCount == 1)
        #expect(publisher.cancelCount == 0)
        #expect(receipt.info == info)
        #expect(receipt.acceptedChunkCount == 3)
        #expect(receipt.previewWarning == "preview unavailable")
        #expect(receipt.send == summary)
        #expect(model.pendingPublisherInfo == nil)
    }

    @Test func agentPublisherRetriesTheSameSealedFinalSend() async throws {
        let runtime = FakeMarmotRuntime(accounts: [])
        let publisher = FakeAgentTextPublisher(
            info: PublisherInfoFfi(streamIdHex: "stream", startMessageIdHex: "start"),
            acknowledgements: [PublisherAckFfi(chunkCount: 1, liveError: nil)],
            finishResults: [
                .failure(FakeAgentPublisherError.finishFailed),
                .success(SendSummaryFfi(published: 1, messageIds: ["final"])),
            ]
        )
        runtime.agentPublisher = publisher
        let model = AgentSettingsViewModel(account: AccountItem.samples[0], runtime: runtime)

        await #expect(throws: FakeAgentPublisherError.finishFailed) {
            _ = try await model.publish(
                groupIdHex: "group",
                brokerCandidate: "https://broker.example",
                records: [AgentPublicationRecord(kind: .text, text: "answer")]
            )
        }

        #expect(model.pendingPublisherInfo?.streamIdHex == "stream")
        #expect(runtime.agentPublisherRequests.count == 1)
        #expect(publisher.appended.count == 1)

        let receipt = try await model.retryFinish()

        #expect(receipt.send.messageIds == ["final"])
        #expect(runtime.agentPublisherRequests.count == 1)
        #expect(publisher.appended.count == 1)
        #expect(publisher.finishCount == 2)
        #expect(model.pendingPublisherInfo == nil)
    }

    @Test func onboardingActionsInstallTheDurableReturnedRevision() async {
        let runtime = FakeMarmotRuntime(accounts: [])
        runtime.onboardingState = OnboardingSnapshotFfi(
            accountIdHex: "account-id",
            recoveryEpoch: "epoch",
            revision: 7,
            ready: false,
            steps: [],
            proposal: nil,
            singleDeviceNotice: nil,
            cancellationPending: false
        )
        let model = OnboardingCoordinator(accountRef: "account", runtime: runtime)

        await model.run()

        #expect(model.snapshot?.revision == 8)
        #expect(model.recoveryRequired)
    }

    @Test func onboardingDiscoveryRelayProposalUsesTheCheckpointedOperation() async {
        let runtime = FakeMarmotRuntime(accounts: [])
        runtime.onboardingState = OnboardingSnapshotFfi(
            accountIdHex: "account-id",
            recoveryEpoch: nil,
            revision: 2,
            ready: false,
            steps: [],
            proposal: nil,
            singleDeviceNotice: nil,
            cancellationPending: false
        )
        let model = OnboardingCoordinator(accountRef: "account", runtime: runtime)

        await model.setDiscoveryRelays(["wss://relay.example.com"])

        #expect(runtime.onboardingDiscoveryRelayUpdates == [["wss://relay.example.com"]])
        #expect(model.snapshot?.revision == 3)
    }

    @Test func settingsDiagnosticsFlushUsesTheUnifiedExporter() async {
        let runtime = FakeMarmotRuntime(accounts: [])
        let settings = SettingsViewModel(account: AccountItem.samples[0], runtime: runtime)
        let model = settings.diagnostics

        await model.flush()

        #expect(runtime.productAnalyticsFlushCount == 1)
        #expect(model.status == runtime.usageStatus)
    }

    @Test func relaySettingsOwnsItsAccountSnapshotAndPublishesBothRoles() async {
        let runtime = FakeMarmotRuntime(accounts: [])
        runtime.installRelayLists(
            AccountRelayListsFfi(
                complete: true,
                missing: [],
                defaultRelays: ["wss://default.example"],
                bootstrapRelays: ["wss://bootstrap.example"],
                nip65: RelayListFfi(kind: 10_002, relays: ["wss://profile.example"]),
                inbox: RelayListFfi(kind: 10_050, relays: ["wss://inbox.example"])
            ))
        var didPublish = false
        let model = RelaySettingsViewModel(accountRef: "account", runtime: runtime) {
            didPublish = true
        }

        await model.load()
        #expect(runtime.accountRelayListsCallCount == 1)
        #expect(model.endpoints.count == 2)

        await model.addRelay("wss://both.example/", roles: [.profile, .inbox])

        #expect(model.settings.nip65.contains("wss://both.example"))
        #expect(model.settings.inbox.contains("wss://both.example"))
        #expect(runtime.lastSetNip65BootstrapRelays == ["wss://bootstrap.example"])
        #expect(runtime.lastSetInboxBootstrapRelays == ["wss://bootstrap.example"])
        #expect(didPublish)
        #expect(model.error == nil)
    }

    @Test func relaySettingsRejectsInvalidAndLastRelayMutationsLocally() async {
        let runtime = FakeMarmotRuntime(accounts: [])
        let model = RelaySettingsViewModel(accountRef: "account", runtime: runtime)
        await model.load()
        let before = model.settings

        await model.addRelay("ws://relay.example", roles: [.profile])
        #expect(model.error == .invalidURL)
        #expect(model.settings == before)

        await model.setRole(.profile, isEnabled: false, forRelay: MarmotClient.seedRelays[0])
        #expect(model.settings.nip65.count == MarmotClient.seedRelays.count - 1)
        await model.setRole(.profile, isEnabled: false, forRelay: MarmotClient.seedRelays[1])
        #expect(model.error == .lastRelay(.profile))
        #expect(model.settings.nip65 == [MarmotClient.seedRelays[1]])
    }

    @Test func deactivatedRelaySettingsRejectsALatePublishCompletion() async {
        let runtime = FakeMarmotRuntime(accounts: [])
        runtime.setAccountRelaysGateEnabled = true
        var didPublish = false
        let model = RelaySettingsViewModel(accountRef: "account-a", runtime: runtime) {
            didPublish = true
        }
        await model.load()

        let publication = Task {
            await model.addRelay("wss://new.example", roles: [.profile])
        }
        while !runtime.didReachSetAccountRelaysGate {
            await Task.yield()
        }
        model.deactivate()
        runtime.releaseSetAccountRelaysGate()
        await publication.value

        #expect(!didPublish)
    }

    @Test func keyPackageSettingsLoadUsesOnlyTheLocalInventory() async {
        let runtime = FakeMarmotRuntime(accounts: [])
        let settings = SettingsViewModel(account: AccountItem.samples[0], runtime: runtime)
        let model = settings.keyPackageSettings

        await settings.diagnostics.load()
        #expect(runtime.localAccountKeyPackagesCallCount == 0)
        await model.loadLocalInventory()

        #expect(model.inventory.count == 2)
        #expect(model.relayEvents.isEmpty)
        #expect(runtime.localAccountKeyPackagesCallCount == 1)
        #expect(runtime.refreshAccountKeyPackagesCallCount == 0)
        #expect(runtime.accountKeyPackageRelayEventsCallCount == 0)
        #expect(runtime.accountRelayListsCallCount == 0)
    }

    @Test func explicitKeyPackageRefreshUsesAccountBootstrapRelaysAndLoadsHistory() async {
        let runtime = FakeMarmotRuntime(accounts: [])
        runtime.installRelayLists(
            AccountRelayListsFfi(
                complete: true,
                missing: [],
                defaultRelays: ["wss://default.example"],
                bootstrapRelays: [" wss://bootstrap.example ", "wss://bootstrap.example"],
                nip65: RelayListFfi(kind: 10_002, relays: ["wss://profile.example"]),
                inbox: RelayListFfi(kind: 10_050, relays: ["wss://inbox.example"])
            ))
        let settings = SettingsViewModel(account: AccountItem.samples[0], runtime: runtime)
        let model = settings.keyPackageSettings
        await model.loadLocalInventory()

        await model.refresh()

        #expect(model.inventory.count == 2)
        #expect(model.relayEvents.count == 2)
        #expect(runtime.refreshAccountKeyPackagesCallCount == 1)
        #expect(runtime.accountKeyPackageRelayEventsCallCount == 1)
        #expect(runtime.accountRelayListsCallCount == 1)
        #expect(runtime.lastPackageFetchBootstrapRelays == ["wss://bootstrap.example"])
        #expect(!model.isRefreshing)
        #expect(model.error == nil)
    }

    @Test func storageLimitsPreserveAutomaticPolicyAndRefreshHostPermission() async {
        let runtime = FakeMarmotRuntime(accounts: [])
        runtime.attachmentPolicy = AttachmentDownloadPolicyFfi(
            automatic: true,
            retainedBytes: 2 * 1_024 * 1_024 * 1_024,
            diskReserve: 256 * 1_024 * 1_024,
            transferLimit: 64 * 1_024 * 1_024
        )
        let controller = AttachmentPolicyController(
            accountRef: AccountItem.samples[0].accountRef,
            runtime: runtime
        )
        await controller.refresh(connectivityAvailable: true)
        let settings = SettingsViewModel(
            account: AccountItem.samples[0],
            runtime: runtime,
            attachmentPolicyController: controller
        )
        let model = settings.storage
        await model.load()

        await model.saveLimits(
            retainedBytes: 4 * 1_024 * 1_024 * 1_024,
            diskReserve: 512 * 1_024 * 1_024,
            transferLimit: 128 * 1_024 * 1_024
        )

        #expect(runtime.attachmentPolicy.automatic)
        #expect(runtime.attachmentPolicy.retainedBytes == 4 * 1_024 * 1_024 * 1_024)
        #expect(runtime.attachmentPolicy.diskReserve == 512 * 1_024 * 1_024)
        #expect(runtime.attachmentPolicy.transferLimit == 128 * 1_024 * 1_024)
        #expect(
            controller.effectivePermission
                == AttachmentAutomaticPermissionFfi(
                    images: true,
                    videos: true,
                    audio: true,
                    files: true
                ))
        #expect(!model.isSaving)
        #expect(model.error == nil)
    }

    @Test func settingsQuarantineActionsRefreshLocalFeatureState() async {
        let runtime = FakeMarmotRuntime(accounts: [])
        runtime.quarantinedGroupRecords = [
            AppQuarantinedGroupFfi(groupIdHex: "quarantined", reason: .openMlsGroupMissing)
        ]
        let settings = SettingsViewModel(account: AccountItem.samples[0], runtime: runtime)
        let model = settings.quarantinedGroups

        await model.load()
        #expect(model.groups.map(\.groupIdHex) == ["quarantined"])

        await model.retry("quarantined")

        #expect(model.groups.isEmpty)
        #expect(model.error == nil)
    }

    @Test func blockedUsersSettingsUsesTheScopeOwnedLiveModel() async {
        let runtime = FakeMarmotRuntime(accounts: [])
        runtime.blockedUsers = [BlockedUserFfi(publicKey: "blocked", isPrivate: true, createdAtMs: 1)]
        let model = BlockedUsersViewModel(accountRef: "account", runtime: runtime)

        model.start()
        for _ in 0..<100 where model.users.isEmpty {
            await Task.yield()
        }
        #expect(model.users.map(\.publicKey) == ["blocked"])

        await model.setBlocked(false, accountID: "blocked")

        #expect(model.users.isEmpty)
        #expect(model.mutatingUserIDs.isEmpty)
        #expect(model.error == nil)
        model.stop()
    }

    @Test func blockedDirectPeerContentIsReplacedInPreparedChatRows() async throws {
        let runtime = FakeMarmotRuntime(accounts: [])
        runtime.blockedUsers = [BlockedUserFfi(publicKey: "PEER", isPrivate: true, createdAtMs: 1)]
        let blockedUsers = BlockedUsersViewModel(accountRef: "account", runtime: runtime)
        let row = chatListRow(
            groupIdHex: "direct",
            title: "Peer",
            preview: "content that must be hidden",
            sender: "peer",
            timelineAt: 1
        )
        runtime.presentedChatListSnapshot = PresentedChatListSnapshotFfi(
            rows: [Self.presentedChatRow(row, peerID: "peer")],
            presentationVersion: PresentationVersionFfi(
                accountStoreEpoch: Data(repeating: 1, count: 16),
                revision: 1
            )
        )
        let model = ChatListViewModel(
            account: AccountItem.samples[0],
            runtime: runtime,
            blockedUsersModel: blockedUsers
        )

        blockedUsers.start()
        model.start()
        for _ in 0..<100 where !blockedUsers.isLoaded || model.presentedRows.isEmpty {
            await Task.yield()
        }

        let chat = try #require(model.chats(view: .chats, nicknames: .none).first)
        #expect(chat.preview == "content that must be hidden")
        #expect(chat.isBlockedDirectPeer)
        #expect(chat.previewNotice(locale: Locale(identifier: "en")) == "You blocked this user")
        blockedUsers.stop()
        model.stop()
    }

    @Test func uncertainBlockPublicationOnlyAllowsTheSameMutationToRetry() async {
        let runtime = FakeMarmotRuntime(accounts: [])
        let model = BlockedUsersViewModel(accountRef: "account", runtime: runtime)
        model.start()
        for _ in 0..<100 where !model.isLoaded {
            await Task.yield()
        }
        runtime.blockUserError = MarmotKitError.BlockPublicationUncertain

        await model.setBlocked(true, accountID: "PEER")

        #expect(model.uncertainIntent == BlockedUserMutationIntent(accountID: "peer", blocked: true))
        #expect(model.canMutate(accountID: "peer"))
        #expect(!model.canMutate(accountID: "someone-else"))

        await model.setBlocked(false, accountID: "peer")
        #expect(model.uncertainIntent?.blocked == true)

        runtime.blockUserError = nil
        await model.setBlocked(true, accountID: "peer")
        #expect(model.uncertainIntent == nil)
        #expect(model.isBlocked(accountID: "PEER"))
        model.stop()
    }

    @Test func accountAttentionIsTheOnlyRailBadgeAuthority() async {
        let runtime = FakeMarmotRuntime(accounts: [])
        runtime.accountAttentionFallbackRows = [
            AccountUnreadFfi(
                accountIdHex: "legacy",
                unreadCount: 99,
                unreadConversations: 1,
                hasUnread: true
            )
        ]
        runtime.accountAttentionInitialSnapshot = AccountAttentionSnapshotFfi(
            subscriptionGeneration: "attention",
            sequence: 1,
            accounts: [
                AccountAttentionEntryFfi(
                    accountIdHex: "ready",
                    state: .ready(
                        total: AccountAttentionTotalFfi(
                            unreadCount: 4,
                            unreadMentionCount: 2,
                            unreadConversations: 1,
                            attentionOnlyConversations: 3
                        )
                    )
                ),
                AccountAttentionEntryFfi(
                    accountIdHex: "unavailable",
                    state: .unavailable(reason: .preparing)
                ),
            ]
        )
        let model = AccountAttentionViewModel(runtime: runtime)

        model.start()
        for _ in 0..<100 where model.valuesByAccountId.count != 2 {
            await Task.yield()
        }

        #expect(model.unreadCount(accountIdHex: "ready") == 7)
        #expect(model.mentionCount(accountIdHex: "ready") == 2)
        #expect(model.unreadCount(accountIdHex: "unavailable") == nil)
        model.stop()
    }

    @Test func accountScopeOwnsOneAttachmentAndSafetyModelPerConversation() {
        let scope = AccountScope(account: AccountItem.samples[0], runtime: FakeMarmotRuntime(accounts: []))

        #expect(scope.attachmentModel(groupIdHex: "group") === scope.attachmentModel(groupIdHex: "group"))
        #expect(scope.safetyModel(groupIdHex: "group") === scope.safetyModel(groupIdHex: "group"))
    }

    @Test func accountScopeKeepsOnlyTheSelectedConversationWindowAlive() {
        let runtime = FakeMarmotRuntime(accounts: [])
        runtime.conversationWindowInitialSnapshots["first"] = Self.conversationSnapshot(sequence: 1, title: "First")
        runtime.conversationWindowInitialSnapshots["second"] = Self.conversationSnapshot(sequence: 1, title: "Second")
        let scope = AccountScope(account: AccountItem.samples[0], runtime: runtime)

        let first = scope.selectConversation(groupIdHex: "first")
        let second = scope.selectConversation(groupIdHex: "second")

        #expect(first !== second)
        #expect(scope.selectedConversationModel === second)
        #expect(scope.conversationModel(groupIdHex: "second") === second)
        first.stop()
        second.stop()
    }

    @Test func cancelledAccountScopeRejectsLateConversationAndAttachmentSnapshots() async throws {
        let runtime = FakeMarmotRuntime(accounts: [])
        let initial = Self.conversationSnapshot(sequence: 1, title: "Initial")
        let late = Self.conversationSnapshot(sequence: 2, title: "Late")
        runtime.conversationWindowInitialSnapshots["group"] = initial
        runtime.conversationWindowUpdates["group"] = [late]
        runtime.conversationWindowUpdateDelayNanoseconds = 80_000_000
        runtime.attachmentTransferSnapshots = [
            AttachmentTransferSnapshotFfi(items: [
                AttachmentTransferStatusFfi(
                    reference: "late-asset",
                    state: .downloading,
                    attempt: 1,
                    received: 5,
                    total: 10,
                    retryAt: nil
                )
            ])
        ]
        runtime.attachmentTransferDelayNanoseconds = 80_000_000
        let scope = AccountScope(account: AccountItem.samples[0], runtime: runtime)
        let conversation = scope.selectConversation(groupIdHex: "group")
        let attachments = scope.attachmentModel(groupIdHex: "group")
        let target = AttachmentLocalTargetFfi(
            messageIdHex: "message",
            sourceMessageIdHex: "source",
            attachmentIndex: 0
        )
        attachments.observeTransfers(for: [target])

        let didInstallInitial = await waitFor {
            conversation.snapshot?.revision.sequence == 1
        }
        #expect(didInstallInitial)
        await scope.cancelAll()
        try await Task.sleep(for: .milliseconds(120))

        #expect(conversation.snapshot?.revision.sequence == 1)
        #expect(attachments.transfersByTarget.isEmpty)
    }

    @Test func cancelledAccountScopeRejectsALateCompleteChatListSnapshot() async throws {
        let runtime = FakeMarmotRuntime(accounts: [])
        runtime.chatListSubscriptionDelayNanoseconds = 80_000_000
        runtime.presentedChatListSnapshot = PresentedChatListSnapshotFfi(
            rows: [],
            presentationVersion: PresentationVersionFfi(
                accountStoreEpoch: Data(repeating: 1, count: 16),
                revision: 1
            )
        )
        let scope = AccountScope(account: AccountItem.samples[0], runtime: runtime)
        scope.start(connectivityAvailable: true)
        let model = scope.chatListModel
        let didOpenWindow = await waitFor { runtime.chatListWindowSubscriptionCount == 1 }
        #expect(didOpenWindow)

        await scope.cancelAll()
        let lateRow = chatListRow(
            groupIdHex: "late",
            title: "Late",
            preview: "must not install",
            sender: "peer",
            timelineAt: 1
        )
        runtime.presentedChatListSnapshot = PresentedChatListSnapshotFfi(
            rows: [Self.presentedChatRow(lateRow)],
            presentationVersion: PresentationVersionFfi(
                accountStoreEpoch: Data(repeating: 1, count: 16),
                revision: 2
            )
        )
        try await Task.sleep(for: .milliseconds(120))

        #expect(model.presentedRows.isEmpty)
    }

    @Test func productEventsAndHostTimingsRequireCurrentUnifiedConsent() async {
        let runtime = FakeMarmotRuntime(accounts: [])
        runtime.usageSettings.decision = .granted
        runtime.usageStatus.consent = .granted
        let recorder = ProductAnalyticsRecorder()
        let diagnostics = DiagnosticsSettingsViewModel(
            runtime: runtime,
            productAnalytics: recorder
        )

        await diagnostics.load()
        let consentTicket = recorder.ticket()
        let timing = recorder.beginTiming()
        await recorder.record(.screen(.conversation), ticket: consentTicket)?.value
        await recorder.recordTiming(.timelineWindow, since: timing)?.value

        #expect(runtime.recordedProductEvents.map(\.name) == ["app_screen_viewed"])
        #expect(runtime.recordedProductEvents.first?.properties.first?.value == "conversation")
        #expect(runtime.recordedHostTimings.map(\.0) == ["app_timeline_window"])

        await diagnostics.setEnabled(false)
        #expect(recorder.record(.screen(.settings), ticket: consentTicket) == nil)
        #expect(recorder.recordTiming(.timelineWindow, since: timing) == nil)
        #expect(runtime.recordedProductEvents.count == 1)
        #expect(runtime.recordedHostTimings.count == 1)
    }

    @Test func diagnosticsFeatureOwnsAuditConsentInventoryUploadAndDeletion() async {
        let runtime = FakeMarmotRuntime(accounts: [])
        runtime.storedAuditLogFiles = [
            AuditLogFileFfi(
                accountRef: "account",
                path: "/tmp/diagnostics-a.jsonl",
                fileName: "diagnostics-a.jsonl",
                sizeBytes: 12,
                modifiedAtMs: 1
            ),
            AuditLogFileFfi(
                accountRef: "account",
                path: "/tmp/diagnostics-b.jsonl",
                fileName: "diagnostics-b.jsonl",
                sizeBytes: 34,
                modifiedAtMs: 2
            ),
        ]
        runtime.nextAuditLogTrackerUpdate = AuditLogTrackerUpdateResultV5Ffi(
            enabled: true,
            v4Uploaded: [],
            v4SkippedReason: nil,
            v5: AuditOtlpTrackerResultV5Ffi(
                acceptedBatches: 0,
                pendingAccounts: 0,
                blockedAccounts: 0,
                idleAccounts: 0,
                skippedReason: "offline"
            )
        )
        let model = DiagnosticsSettingsViewModel(runtime: runtime)

        await model.load()
        #expect(model.auditSettings?.enabled == false)
        #expect(model.auditLogFiles.map(\.sizeBytes) == [12, 34])

        await model.setAuditEnabled(true)
        #expect(model.auditSettings?.enabled == true)
        #expect(runtime.storedAuditLogSettings.enabled)

        await model.uploadAuditLogs()
        #expect(runtime.didPostAuditLogTrackerUpdate)
        #expect(model.auditUploadStatus?.contains("offline") == true)

        await model.deleteAllAuditLogs()
        #expect(model.auditLogFiles.isEmpty)
        #expect(runtime.deletedAuditLogFilePaths.count == 2)
        #expect(model.error == nil)
    }

    @Test func cancelledAccountScopeCannotInstallLateDiagnosticInventory() async {
        let runtime = FakeMarmotRuntime(accounts: [])
        runtime.storedAuditLogFiles = [
            AuditLogFileFfi(
                accountRef: "old-account",
                path: "/tmp/old-account.jsonl",
                fileName: "old-account.jsonl",
                sizeBytes: 12,
                modifiedAtMs: 1
            )
        ]
        runtime.auditLogFilesGateEnabled = true
        let scope = AccountScope(account: AccountItem.samples[0], runtime: runtime)
        let diagnostics = scope.settingsModel.diagnostics

        scope.start(connectivityAvailable: true)
        for _ in 0..<100 where !runtime.didReachAuditLogFilesGate {
            await Task.yield()
        }
        #expect(runtime.didReachAuditLogFilesGate)

        await scope.cancelAll()
        runtime.releaseAuditLogFilesGate()
        for _ in 0..<100 {
            await Task.yield()
        }

        #expect(diagnostics.auditLogFiles.isEmpty)
    }

    @Test func preparedChatViewsKeepDepartedGroupsOutOfActiveAndUnreadLists() async {
        let runtime = FakeMarmotRuntime(accounts: [])
        let active = Self.presentedChatRow(
            chatListRow(
                groupIdHex: "active",
                title: "Active",
                preview: "hello",
                sender: "peer",
                timelineAt: 3,
                unreadCount: 1,
                hasUnread: true
            ))
        let left = Self.presentedChatRow(
            chatListRow(
                groupIdHex: "left",
                title: "Left",
                preview: "history",
                sender: "peer",
                timelineAt: 2,
                selfMembership: .left,
                unreadCount: 1,
                hasUnread: true
            ))
        let archivedRemoved = Self.presentedChatRow(
            chatListRow(
                groupIdHex: "removed",
                title: "Removed",
                preview: "history",
                sender: "peer",
                timelineAt: 1,
                selfMembership: .removed,
                archived: true
            ))
        runtime.presentedChatListSnapshot = PresentedChatListSnapshotFfi(
            rows: [active, left, archivedRemoved],
            presentationVersion: PresentationVersionFfi(
                accountStoreEpoch: Data(repeating: 1, count: 16),
                revision: 1
            )
        )
        let model = ChatListViewModel(account: AccountItem.samples[0], runtime: runtime)

        model.start()
        for _ in 0..<100 where model.presentedRows.count != 3 {
            await Task.yield()
        }

        #expect(model.chats(view: .chats, nicknames: .none).map(\.id) == ["active"])
        #expect(model.chats(view: .unread, nicknames: .none).map(\.id) == ["active"])
        #expect(model.chats(view: .left, nicknames: .none).map(\.id) == ["left", "removed"])
        #expect(model.chats(view: .archived, nicknames: .none).map(\.id) == ["removed"])
        model.stop()
    }

    @Test func boundedChatWindowOwnsVisibleInboxAndPagesBySequence() async {
        let runtime = FakeMarmotRuntime(accounts: [])
        let complete = Self.presentedChatRow(
            chatListRow(
                groupIdHex: "complete-only",
                title: "Complete",
                preview: "searchable",
                sender: "peer",
                timelineAt: 1
            )
        )
        let first = Self.presentedChatRow(
            chatListRow(
                groupIdHex: "window-first",
                title: "First",
                preview: "first",
                sender: "peer",
                timelineAt: 3
            )
        )
        let second = Self.presentedChatRow(
            chatListRow(
                groupIdHex: "window-second",
                title: "Second",
                preview: "second",
                sender: "peer",
                timelineAt: 2
            )
        )
        runtime.presentedChatListSnapshot = PresentedChatListSnapshotFfi(
            rows: [complete],
            presentationVersion: PresentationVersionFfi(
                accountStoreEpoch: Data(repeating: 1, count: 16),
                revision: 1
            )
        )
        runtime.chatListWindowInitialSnapshot = ChatListWindowSnapshotFfi(
            subscriptionGeneration: "window-generation",
            sequence: 1,
            view: .chats,
            rows: [first],
            hasMoreBefore: false,
            hasMoreAfter: true,
            anchor: .top
        )
        runtime.chatListWindowPageSnapshots = [
            ChatListWindowSnapshotFfi(
                subscriptionGeneration: "window-generation",
                sequence: 2,
                view: .chats,
                rows: [second],
                hasMoreBefore: true,
                hasMoreAfter: false,
                anchor: .recovered(groupIdHex: "window-second", index: 0)
            )
        ]
        let model = ChatListViewModel(account: AccountItem.samples[0], runtime: runtime)

        model.start()
        for _ in 0..<100 where model.windowSnapshot?.sequence != 1 || model.presentedRows.isEmpty {
            await Task.yield()
        }

        #expect(runtime.chatListWindowSubscriptionCount == 1)
        #expect(runtime.lastChatListWindowInitialRows == 50)
        #expect(model.chats(view: .chats, nicknames: .none).map(\.id) == ["window-first"])
        #expect(
            model.chats(view: .chats, nicknames: .none, useWindow: false).map(\.id)
                == ["complete-only"]
        )

        await model.pageWindow(.forward)

        #expect(model.windowSnapshot?.sequence == 2)
        #expect(model.chats(view: .chats, nicknames: .none).map(\.id) == ["window-second"])
        model.stop()
    }

    @Test func conversationProjectionInstallsOnlyCompleteNewerReplacements() async throws {
        let runtime = FakeMarmotRuntime(accounts: [])
        let initial = Self.conversationSnapshot(sequence: 1, title: "Initial")
        let replacement = Self.conversationSnapshot(sequence: 2, title: "Replacement", unreadCount: 3)
        runtime.conversationWindowInitialSnapshots["group"] = initial
        runtime.conversationWindowUpdates["group"] = [replacement]
        let model = ConversationViewModel(
            account: AccountItem.samples[0],
            groupIdHex: "group",
            runtime: runtime
        )

        model.start(mode: .latest)
        for _ in 0..<100 where model.snapshot?.revision.sequence != 2 {
            await Task.yield()
        }

        #expect(model.snapshot?.revision.sequence == 2)
        #expect(model.snapshot?.header.selected.title == .literal(text: "Replacement"))
        #expect(model.snapshot?.readState.unreadCount == 3)
        model.stop()
    }

    @Test func conversationProjectionObserverReceivesEveryInstalledReplacement() async {
        let runtime = FakeMarmotRuntime(accounts: [])
        let initial = Self.conversationSnapshot(sequence: 1, title: "Initial")
        let replacement = Self.conversationSnapshot(sequence: 2, title: "Replacement")
        runtime.conversationWindowInitialSnapshots["group"] = initial
        runtime.conversationWindowUpdates["group"] = [replacement]
        let model = ConversationViewModel(
            account: AccountItem.samples[0],
            groupIdHex: "group",
            runtime: runtime
        )
        var observedSequences: [UInt64] = []
        await model.setSnapshotObserver { snapshot in
            observedSequences.append(snapshot.revision.sequence)
        }

        model.start(mode: .latest)
        for _ in 0..<100 where observedSequences.count != 2 {
            await Task.yield()
        }

        #expect(observedSequences == [1, 2])
        model.stop()
    }

    @Test func preparedConversationCarriesEditSummaryAndDeletionProvenance() throws {
        var record = timelineMessage(
            id: "edited",
            direction: "outbound",
            groupIdHex: "group",
            sender: AccountItem.samples[0].accountIdHex,
            plaintext: "latest text",
            recordedAt: 20,
            deleted: true
        )
        record.edit = TimelineEditSummaryFfi(
            editCount: 3,
            latestEditMessageIdHex: "edit-3",
            editedAt: 19
        )
        record.deletionSource = .admin

        let item = try #require(
            MessageItem.timeline(
                from: TimelinePageFfi(messages: [record], hasMoreBefore: false, hasMoreAfter: false),
                activeAccountIdHex: AccountItem.samples[0].accountIdHex
            ).first
        )

        #expect(item.isEdited)
        #expect(item.editCount == 3)
        #expect(item.deletionSource == .admin)
        #expect(item.body == L10n.string("This message was deleted by an admin."))
    }

    @Test func blockedConversationProjectionHidesAuthorsAndTheirQuotedContent() {
        let blocked = timelineMessage(
            id: "blocked",
            groupIdHex: "group",
            sender: "BLOCKED-PEER",
            plaintext: "hidden body",
            recordedAt: 10
        )
        var visible = timelineMessage(
            id: "visible",
            groupIdHex: "group",
            sender: "visible-peer",
            plaintext: "visible body",
            recordedAt: 11
        )
        visible.replyPreview = TimelineReplyPreviewFfi(
            messageIdHex: blocked.messageIdHex,
            sender: blocked.sender,
            plaintext: blocked.plaintext,
            contentTokens: blocked.contentTokens,
            kind: blocked.kind,
            mediaJson: nil,
            media: [],
            agentTextStreamJson: nil,
            deleted: false,
            invalidationStatus: nil
        )
        var snapshot = Self.conversationSnapshot(sequence: 1, title: "Conversation")
        snapshot.messages = [
            Self.conversationMessage(blocked),
            Self.conversationMessage(visible, replyAuthor: blocked.sender),
        ]

        let filtered = BlockedConversationPresentation.timelineRecords(
            snapshot: snapshot,
            blockedAccountIDs: ["blocked-peer"]
        )

        #expect(filtered.map(\.messageIdHex) == ["visible"])
        #expect(filtered.first?.replyPreview == nil)
        #expect(
            BlockedConversationPresentation.timelineRecords(
                snapshot: snapshot,
                blockedAccountIDs: []
            ).count == 2
        )
    }

    @Test func preparedConversationEditHistoryUsesDurableStableCursor() async throws {
        let runtime = FakeMarmotRuntime(accounts: [])
        let newest = TimelineEditVersionFfi(messageIdHex: "edit-3", editedAt: 30, plaintext: "third")
        let older = TimelineEditVersionFfi(messageIdHex: "edit-2", editedAt: 20, plaintext: "second")
        runtime.messageEditHistoryPages["message"] = [
            TimelineEditHistoryPageFfi(versions: [older, newest], hasMoreBefore: true),
            TimelineEditHistoryPageFfi(
                versions: [
                    TimelineEditVersionFfi(messageIdHex: "edit-1", editedAt: 10, plaintext: "first")
                ],
                hasMoreBefore: false
            ),
        ]
        let model = ConversationViewModel(
            account: AccountItem.samples[0],
            groupIdHex: "group",
            runtime: runtime
        )

        let first = try await model.editHistory(messageIdHex: "message", before: nil, limit: 2)
        let second = try await model.editHistory(messageIdHex: "message", before: first.versions.first, limit: 2)

        #expect(first.versions.map(\.messageIdHex) == ["edit-2", "edit-3"])
        #expect(second.versions.map(\.messageIdHex) == ["edit-1"])
        #expect(runtime.messageEditHistoryRequests.count == 2)
        #expect(runtime.messageEditHistoryRequests[0].beforeEditedAt == nil)
        #expect(runtime.messageEditHistoryRequests[1].beforeEditedAt == 20)
        #expect(runtime.messageEditHistoryRequests[1].beforeMessageIdHex == "edit-2")
        #expect(runtime.messageEditHistoryRequests[1].limit == 2)
    }

    @Test func conversationProjectionSweepsAnAlreadyExpiredRetentionDeadline() async {
        let runtime = FakeMarmotRuntime(accounts: [])
        var record = timelineMessage(
            id: "expired",
            groupIdHex: "group",
            sender: "peer",
            plaintext: "gone",
            recordedAt: 1
        )
        record.retentionSeconds = 60
        record.retentionExpiresAt = 1
        var snapshot = Self.conversationSnapshot(sequence: 1, title: "Expiring")
        snapshot.messages = [Self.conversationMessage(record)]
        runtime.conversationWindowInitialSnapshots["group"] = snapshot
        let model = ConversationViewModel(
            account: AccountItem.samples[0],
            groupIdHex: "group",
            runtime: runtime
        )

        model.start(mode: .latest)
        for _ in 0..<100 where runtime.sweepExpiredRetentionCallCount == 0 {
            await Task.yield()
        }

        #expect(runtime.sweepExpiredRetentionCallCount == 1)
        model.stop()
    }

    @Test func projectedRetentionDeadlineRendersItsExactExpiration() {
        let message = MessageItem(
            id: "retained",
            sourceEpoch: 7,
            retentionSeconds: 3_600,
            retentionExpiresAt: 1_700_000_000,
            senderName: "Peer",
            body: "temporary",
            sentAt: Date(timeIntervalSince1970: 1_699_999_000),
            isOutgoing: false
        )

        let label = message.retentionExpirationLabel(locale: Locale(identifier: "en_US"))

        #expect(message.hasFiniteRetentionExpiry)
        #expect(label?.contains("2023") == true)
        #expect(message.metadataLabel(at: .now, locale: Locale(identifier: "en_US")).contains("2023"))
    }

    private static func conversationSnapshot(
        sequence: UInt64,
        title: String,
        unreadCount: UInt64 = 0
    ) -> ConversationWindowSnapshotFfi {
        let presentation = ConversationPresentationFfi(
            title: .literal(text: title),
            avatar: .placeholder(stableSeed: "group", source: .groupFallback),
            titleSource: .group,
            avatarSource: .groupFallback,
            peerId: nil,
            resolution: .cached
        )
        return ConversationWindowSnapshotFfi(
            revision: ConversationWindowRevisionFfi(generation: "generation", sequence: sequence),
            header: ConversationHeaderFfi(
                selected: presentation,
                memberCount: 2,
                archived: false,
                epoch: 3,
                lifecycle: .stable,
                disbanding: false,
                unrecoverable: false,
                capabilities: ConversationCapabilitiesFfi(
                    participation: .active,
                    isSelfAdmin: false,
                    isLastAdmin: false,
                    canSend: true,
                    canInvite: false,
                    canEditGroup: false,
                    canLeave: true,
                    requiresSelfDemoteBeforeLeave: false,
                    canEnableDisbanding: false,
                    canDisband: false
                ),
                avatarAsset: nil
            ),
            messages: [],
            identities: [],
            readState: ConversationOpenReadStateFfi(
                initialized: true,
                lastReadMessageIdHex: nil,
                lastReadTimelineAt: nil,
                manuallyMarkedUnread: false,
                unreadCount: unreadCount,
                unreadMentionCount: 0,
                firstUnreadMessageIdHex: nil
            ),
            draft: SelectedMessageDraftFfi(
                revision: MessageDraftRevisionFfi(noPointer: .init()),
                draft: nil
            ),
            pendingConfirmation: false,
            anchor: ConversationAnchorOutcomeFfi(kind: .latest, index: nil),
            hasMoreBefore: false,
            hasMoreAfter: false
        )
    }

    private static func conversationMessage(
        _ record: TimelineMessageRecordFfi,
        replyAuthor: String? = nil,
        mentions: [String] = [],
        replyMentions: [String] = []
    ) -> ConversationMessageFfi {
        ConversationMessageFfi(
            timeline: record,
            references: ConversationMessageReferencesFfi(
                messageIdHex: record.messageIdHex,
                sender: record.sender,
                replyAuthor: replyAuthor,
                mentions: mentions,
                mentionsTruncated: false,
                replyMentions: replyMentions,
                replyMentionsTruncated: false,
                system: nil,
                reactions: ConversationReactionsFfi(
                    totalCount: 0,
                    totalKinds: 0,
                    items: [],
                    omittedKinds: 0
                )
            )
        )
    }

    private static func presentedChatRow(
        _ row: ChatListRowFfi,
        peerID: String? = nil
    ) -> PresentedChatRowFfi {
        PresentedChatRowFfi(
            preview: .message,
            actions: ChatListRowActionsFfi(
                canMarkRead: row.hasUnread,
                canMarkUnread: !row.hasUnread,
                canPin: true,
                canUnpin: false,
                canMute: true,
                canUnmute: false,
                canArchive: !row.archived,
                canRestore: row.archived,
                canStartLeave: row.selfMembership == .member,
                canDeleteLocal: row.selfMembership != .member
            ),
            row: row,
            presentation: ConversationPresentationFfi(
                title: .literal(text: row.title),
                avatar: .placeholder(
                    stableSeed: peerID ?? row.groupIdHex,
                    source: peerID == nil ? .group : .peerProfile
                ),
                titleSource: peerID == nil ? .group : .peerProfile,
                avatarSource: peerID == nil ? .group : .peerProfile,
                peerId: peerID,
                resolution: .cached
            ),
            avatarAsset: nil
        )
    }
}

struct MarmotKitReleaseProvenanceTests {
    @Test func generatedReleaseProvenancePinsTheAuditedBuild() throws {
        #expect(MarmotKitVersion.mdkTag == "marmotkit-v0.11.0")
        #expect(MarmotKitVersion.mdkSHA == "946e0547485c9a2c393c2048ec3a968fd50fb441")
        #expect(MarmotKitVersion.uniffiVersion == "0.29.4")
        #expect(MarmotKitVersion.features == "otlp-export,product-analytics-export")
        #expect(MarmotKitVersion.swiftPMChecksum == "bad0475a6793cfe5787326a87456d00b80dc02d39a095da4ccc28459c310becb")
        #expect(
            MarmotKitVersion.vendoredSwiftSHA256 == "07bd2ce60659467ecbbd9b598d71ae83cc7502fa23f8368fa9c5762e0c25c360")
        #expect(MarmotKitVersion.distribution == "static-library-and-privacy-v1")
        #expect(MarmotKitVersion.privacySHA256 == "3759ff2493741386342599b39673989a461f491ad1fb207a7133a2b0035140f7")
        let privacyData = try #require(MarmotKitVersion.privacyManifestData())
        #expect(
            SHA256.hash(data: privacyData).map { String(format: "%02x", $0) }.joined()
                == MarmotKitVersion.privacySHA256)
    }
}
