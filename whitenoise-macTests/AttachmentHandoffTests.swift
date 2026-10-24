import Foundation
import MarmotKit
import Synchronization
import Testing

@testable import whitenoise_mac

/// MDK handoff leases, ported from whitenoise-ios#1201: documents open in another app from MDK's
/// leased copy of their original slot, and every lease is released — once — on the live runtime.
@MainActor
struct AttachmentHandoffTests {
    private actor FakeReleaser: AttachmentHandoffReleasing {
        private var script: [Error?]
        private(set) var leases: [String] = []

        init(_ script: [Error?] = []) { self.script = script }

        func releaseAttachmentHandoff(lease: String) async throws {
            leases.append(lease)
            if !script.isEmpty, let error = script.removeFirst() { throw error }
        }
    }

    private let lease = String(repeating: "a", count: 32)

    private func waitForReleases(_ releaser: FakeReleaser, count: Int) async -> [String] {
        let deadline = ContinuousClock.now + .seconds(5)
        while ContinuousClock.now < deadline {
            let leases = await releaser.leases
            if leases.count >= count { return leases }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return await releaser.leases
    }

    // MARK: Release

    @Test func releaseRetriesIoAndClosedRuntimesUntilItSucceeds() async {
        let releaser = FakeReleaser([
            MarmotKitError.Io(details: "busy"), MarmotKitError.StorageClosed(details: "closed"), nil,
        ])
        var sleeps: [Duration] = []
        let outcome = await AttachmentHandoffRelease.run(lease: lease, using: releaser) { sleeps.append($0) }
        #expect(outcome == .released)
        #expect(await releaser.leases == [lease, lease, lease])
        #expect(
            sleeps == [
                AttachmentHandoffRelease.retryDelay(afterAttempt: 1),
                AttachmentHandoffRelease.retryDelay(afterAttempt: 2),
            ])
    }

    @Test func releaseWaitsForAnOpenRuntimeAndUsesTheOneOpenThen() async {
        let resumed = FakeReleaser()
        let runtimes = Mutex<[FakeReleaser?]>([nil, nil, resumed])
        let releaser = LiveRuntimeHandoffReleaser {
            runtimes.withLock { $0.isEmpty ? resumed : $0.removeFirst() }
        }
        var sleeps = 0
        let outcome = await AttachmentHandoffRelease.run(lease: lease, using: releaser) { _ in sleeps += 1 }
        #expect(outcome == .released)
        #expect(sleeps == 2)
        #expect(await resumed.leases == [lease])
    }

    @Test func malformedLeaseIsNeverRetried() async {
        let releaser = FakeReleaser([MarmotKitError.InvalidMediaReference(details: "invalid lease")])
        var sleeps = 0
        let outcome = await AttachmentHandoffRelease.run(lease: "bad", using: releaser) { _ in sleeps += 1 }
        #expect(outcome == .rejected)
        #expect(await releaser.leases.count == 1)
        #expect(sleeps == 0)
    }

    @Test func persistentIoFailureStopsAfterTheAttemptBudget() async {
        let failures = Array(
            repeating: MarmotKitError.Io(details: "busy") as Error?, count: AttachmentHandoffRelease.maxAttempts + 2)
        let releaser = FakeReleaser(failures)
        var sleeps = 0
        let outcome = await AttachmentHandoffRelease.run(lease: lease, using: releaser) { _ in sleeps += 1 }
        #expect(outcome == .abandoned)
        #expect(await releaser.leases.count == AttachmentHandoffRelease.maxAttempts)
        #expect(sleeps == AttachmentHandoffRelease.maxAttempts - 1)
    }

    @Test func retryDelayGrowsAndStaysBounded() {
        let delays = (1...12).map(AttachmentHandoffRelease.retryDelay(afterAttempt:))
        #expect(delays.first == .milliseconds(250))
        #expect(zip(delays, delays.dropFirst()).allSatisfy { $0 <= $1 })
        #expect(delays.last == .seconds(30))
    }

    @Test func aLeaseIsReleasedOnce() async {
        let releaser = FakeReleaser()
        let handoff = AttachmentHandoffFfi(
            lease: lease, path: "/tmp/handoff/\(lease)/Report.pdf",
            byteCount: 3, mediaType: "application/pdf", fileName: "Report.pdf")
        let leased = AttachmentHandoffLease(handoff, releaser: releaser)
        #expect(leased.url.lastPathComponent == "Report.pdf")
        #expect(leased.url.isFileURL)

        let first = leased.release()
        #expect(first != nil)
        #expect(leased.release() == nil)
        #expect(await first?.value == .released)
        #expect(await releaser.leases == [lease])
    }

    @Test func droppingAnUnreleasedLeaseReleasesIt() async {
        let releaser = FakeReleaser()
        do {
            _ = AttachmentHandoffLease(lease: lease, path: "/tmp/handoff/copy.pdf", releaser: releaser)
        }
        #expect(await waitForReleases(releaser, count: 1) == [lease])
    }

    // MARK: Opening

    @Test func heldAttachmentOpensWithoutAcquiring() async throws {
        var opens = 0
        var acquires = 0
        let opened = try await AttachmentHandoffOpening.open(
            handoff: {
                opens += 1
                return "lease"
            },
            hostHasBytes: false,
            acquire: { acquires += 1 }
        )
        #expect(opened == "lease")
        #expect(opens == 1)
        #expect(acquires == 0)
    }

    @Test func missAcquiresThenOpensOnce() async throws {
        var results: [String?] = [nil, "lease"]
        var acquires = 0
        let opened = try await AttachmentHandoffOpening.open(
            handoff: { results.removeFirst() },
            hostHasBytes: false,
            acquire: { acquires += 1 }
        )
        #expect(opened == "lease")
        #expect(acquires == 1)
        #expect(results.isEmpty)
    }

    @Test func stillMissingAfterAcquisitionIsNotHeldLocally() async {
        var opens = 0
        await #expect(throws: AttachmentHandoffFailure.notHeldLocally) {
            _ = try await AttachmentHandoffOpening.open(
                handoff: { () -> String? in
                    opens += 1
                    return nil
                },
                hostHasBytes: false, acquire: {})
        }
        #expect(opens == 2)
    }

    @Test func failedAcquisitionDoesNotOpenAgain() async {
        var opens = 0
        await #expect(throws: AttachmentFeatureError.self) {
            _ = try await AttachmentHandoffOpening.open(
                handoff: { () -> String? in
                    opens += 1
                    return nil
                },
                hostHasBytes: false,
                acquire: { throw AttachmentFeatureError.assetBecameUnavailable })
        }
        #expect(opens == 1)
    }

    /// The timeline row already holds the bytes, so a document MDK does not hold (an own send it
    /// has not stored yet) opens from the host's copy instead of being downloaded again.
    @Test func whatMDKDoesNotHoldFallsBackToTheHostBytes() async throws {
        var opens = 0
        var acquires = 0
        let opened = try await AttachmentHandoffOpening.open(
            handoff: { () -> String? in
                opens += 1
                return nil
            },
            hostHasBytes: true,
            acquire: { acquires += 1 }
        )
        #expect(opened == nil)
        #expect(opens == 1)
        #expect(acquires == 0)
    }

    @Test func storageFullAndControlCancellationMapToUserStates() {
        let full = AttachmentHandoffOpening.failure(
            for: MarmotKitError.StorageFull(details: "reserve"), controlCancelled: false)
        #expect(full as? AttachmentHandoffFailure == .storageFull)

        // MDK reports a copy cancelled through its control as invalid media.
        let cancelled = AttachmentHandoffOpening.failure(
            for: MarmotKitError.InvalidMediaReference(details: "media transfer cancelled"), controlCancelled: true)
        #expect(cancelled is CancellationError)

        let other = AttachmentHandoffOpening.failure(
            for: AttachmentFeatureError.truncatedAsset, controlCancelled: false)
        #expect(other as? AttachmentFeatureError == .truncatedAsset)
    }

    @Test func cancellingTheCallerCancelsThroughTheControlAndKeepsTheResult() async throws {
        let control = MediaFileTransferControlFfi()
        let gate = AsyncStream<Void>.makeStream()
        let caller = Task {
            try await AttachmentHandoffOpening.shielded(cancel: { control.cancel() }) {
                for await _ in gate.stream {}
                return "lease"
            }
        }
        caller.cancel()
        // The shielded call is still running: only the control saw the cancellation.
        let deadline = ContinuousClock.now + .seconds(5)
        while !control.isCancelled(), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(control.isCancelled())
        gate.continuation.finish()
        #expect(try await caller.value == "lease")
    }

    // MARK: Through the runtime

    private static let target = AttachmentLocalTargetFfi(
        messageIdHex: String(repeating: "1", count: 64),
        sourceMessageIdHex: String(repeating: "2", count: 64), attachmentIndex: 0)

    @Test func openLeaseHandsBackMDKsCopyOfTheSlot() async throws {
        let runtime = FakeMarmotRuntime(accounts: [])
        runtime.attachmentHandoffResults = [
            .success(
                AttachmentHandoffFfi(
                    lease: lease, path: "/tmp/handoff/\(lease)/Report.pdf", byteCount: 3,
                    mediaType: "application/pdf", fileName: "Report.pdf"))
        ]
        let releaser = FakeReleaser()

        let opened = try await AttachmentHandoffOpening.openLease(
            runtime: runtime, accountRef: "account", groupIdHex: "group", target: Self.target,
            control: MediaFileTransferControlFfi(), releaser: releaser, hostHasBytes: true)

        #expect(opened?.url.lastPathComponent == "Report.pdf")
        #expect(runtime.openedAttachmentHandoffTargets == [Self.target])
        #expect(await opened?.release()?.value == .released)
        #expect(await releaser.leases == [lease])
    }

    @Test func openLeaseReportsStorageFull() async {
        let runtime = FakeMarmotRuntime(accounts: [])
        runtime.attachmentHandoffResults = [.failure(MarmotKitError.StorageFull(details: "reserve"))]
        await #expect(throws: AttachmentHandoffFailure.storageFull) {
            _ = try await AttachmentHandoffOpening.openLease(
                runtime: runtime, accountRef: "account", groupIdHex: "group", target: Self.target,
                control: MediaFileTransferControlFfi(), releaser: FakeReleaser(), hostHasBytes: true)
        }
    }

    /// A lease that arrives after the row gave up is released, not leaked.
    @Test func aLeaseThatArrivesAfterCancellationIsReleased() async {
        let runtime = FakeMarmotRuntime(accounts: [])
        runtime.attachmentHandoffResults = [
            .success(
                AttachmentHandoffFfi(
                    lease: lease, path: "/tmp/handoff/late.pdf", byteCount: 1,
                    mediaType: "application/pdf", fileName: "late.pdf"))
        ]
        let releaser = FakeReleaser()
        let control = MediaFileTransferControlFfi()
        control.cancel()

        await #expect(throws: CancellationError.self) {
            _ = try await AttachmentHandoffOpening.openLease(
                runtime: runtime, accountRef: "account", groupIdHex: "group", target: Self.target,
                control: control, releaser: releaser, hostHasBytes: true)
        }
        #expect(await waitForReleases(releaser, count: 1) == [lease])
    }

    // MARK: Routing

    private static func message(source: String?) -> MessageItem {
        MessageItem(
            id: String(repeating: "1", count: 64),
            sourceMessageIdHex: source,
            senderName: "Alice",
            body: "",
            sentAt: Date(timeIntervalSince1970: 1_800_000_000),
            isOutgoing: false
        )
    }

    private static func document(index: UInt32?) -> MessageMediaAttachment {
        MessageMediaAttachment(
            id: "doc",
            reference: mediaAttachmentReference(mediaType: "application/pdf", fileName: "Report.pdf"),
            attachmentIndex: index
        )
    }

    /// The original slot is the message, its source, and the index MDK resolved the attachment
    /// from — the same target Shared Media and Manage Storage use.
    @Test func aResolvedAttachmentOpensItsOriginalSlot() {
        let target = Self.document(index: 0).localTarget(in: Self.message(source: String(repeating: "2", count: 64)))
        #expect(target == Self.target)
    }

    /// An own send still going out has no source id, so MDK holds no slot for it yet; the row opens
    /// the host's bytes.
    @Test func aMessageWithoutASourceHasNoSlot() {
        #expect(Self.document(index: 0).localTarget(in: Self.message(source: nil)) == nil)
    }

    /// References parsed locally from a record that predates FFI media resolution carry no slot.
    @Test func aLocallyParsedReferenceHasNoSlot() {
        #expect(Self.document(index: nil).localTarget(in: Self.message(source: "2")) == nil)
    }

    @Test func timelineMediaKeepsTheSlotMDKResolved() {
        let reference = mediaAttachmentReference(mediaType: "application/pdf", fileName: "Report.pdf")
        let attachments = MessageMediaParser.attachments(
            resolvedMedia: [.accepted(attachmentIndex: 3, reference: reference)],
            mediaJson: nil, tags: [], messageIdHex: "m1")
        #expect(attachments.first?.attachmentIndex == 3)
    }

    // MARK: Save As

    @Test func savingOverAnExistingFileReplacesIt() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("handoff-copy-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("lease.pdf")
        let destination = directory.appendingPathComponent("Report.pdf")
        try Data("new".utf8).write(to: source)
        try Data("old".utf8).write(to: destination)

        try RetainedAttachmentFileCopy.copy(from: source, to: destination)

        #expect(try Data(contentsOf: destination) == Data("new".utf8))
        #expect(FileManager.default.fileExists(atPath: source.path(percentEncoded: false)))
    }
}
