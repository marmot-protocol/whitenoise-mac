import Foundation
import MarmotKit
import Observation
import Testing

@testable import whitenoise_mac

/// Host-side changes for MarmotKit 0.14.0: advisory refusals of group changes, the reason on
/// `MissingKeyPackage`, and downloads parked for free space.
@MainActor
struct MarmotKit014AdoptionTests {
    private static let groupIdHex = "group-advisory"
    private static let catchingUp = MarmotKitError.GroupCatchingUp(groupIdHex: groupIdHex)
    private static let undelivered = MarmotKitError.GroupCommitUndelivered(groupIdHex: groupIdHex)
    private static let recipient = NewChatRecipient(
        sourceQuery: "npub1recipient",
        memberRef: "npub1recipient",
        accountIdHex: "abcdef0123",
        npub: "npub1recipient",
        displayName: "Robin",
        pictureURL: nil
    )

    // MARK: - Advisory retry

    @Test func advisoryIsRecognizedOnlyForTheTwoRefusals() {
        #expect(GroupChangeAdvisory(error: Self.catchingUp) == .catchingUp)
        #expect(GroupChangeAdvisory(error: Self.undelivered) == .commitUndelivered)
        #expect(GroupChangeAdvisory(error: MarmotKitError.FollowListTooLarge) == nil)
        #expect(GroupChangeAdvisory(error: CancellationError()) == nil)
    }

    @Test func consentAcknowledgesAndRetriesOnce() async throws {
        var attempts = 0
        var asked: [GroupChangeAdvisory] = []
        var acknowledged: [GroupChangeAdvisory] = []
        let result = try await GroupChangeAdvisoryRetry.perform(
            {
                attempts += 1
                if attempts == 1 { throw Self.catchingUp }
                return "done"
            },
            consent: {
                asked.append($0)
                return true
            },
            acknowledge: { acknowledged.append($0) }
        )
        #expect(result == "done")
        #expect(attempts == 2)
        #expect(asked == [.catchingUp])
        #expect(acknowledged == [.catchingUp])
    }

    @Test func waitingThrowsDeclinedWithoutAcknowledging() async {
        var acknowledged = 0
        await #expect(throws: GroupChangeAdvisoryDeclined(advisory: .commitUndelivered)) {
            try await GroupChangeAdvisoryRetry.perform(
                { () async throws -> Void in throw Self.undelivered },
                consent: { _ in false },
                acknowledge: { _ in acknowledged += 1 }
            )
        }
        #expect(acknowledged == 0)
    }

    /// One change can need both acknowledgements, but a refusal that recurs after its own
    /// acknowledgement is thrown rather than asked about again.
    @Test func eachKindIsAskedAtMostOncePerChange() async {
        var attempts = 0
        var asked: [GroupChangeAdvisory] = []
        await #expect(throws: MarmotKitError.self) {
            try await GroupChangeAdvisoryRetry.perform(
                { () async throws -> Void in
                    attempts += 1
                    throw attempts == 2 ? Self.undelivered : Self.catchingUp
                },
                consent: {
                    asked.append($0)
                    return true
                },
                acknowledge: { _ in }
            )
        }
        #expect(asked == [.catchingUp, .commitUndelivered])
        #expect(attempts == 3)
    }

    @Test func otherErrorsPassThroughUnasked() async {
        var asked = 0
        await #expect(throws: MarmotKitError.FollowListTooLarge) {
            try await GroupChangeAdvisoryRetry.perform(
                { () async throws -> Void in throw MarmotKitError.FollowListTooLarge },
                consent: { _ in
                    asked += 1
                    return true
                },
                acknowledge: { _ in }
            )
        }
        #expect(asked == 0)
    }

    // MARK: - Prompter

    @Test func newerRequestDeclinesTheOlderOne() async {
        let prompter = GroupChangeAdvisoryPrompter()
        let first = Task { await prompter.requestConsent(for: .catchingUp, isInvite: false) }
        let firstPrompt = await Self.awaitPrompt(prompter)
        let second = Task { await prompter.requestConsent(for: .commitUndelivered, isInvite: true) }
        #expect(await first.value == false)
        let secondPrompt = await Self.awaitPrompt(prompter, other: firstPrompt?.id)
        #expect(secondPrompt?.advisory == .commitUndelivered)
        #expect(secondPrompt?.isInvite == true)

        // A late answer for the first prompt cannot answer the second.
        if let firstPrompt { prompter.resolve(id: firstPrompt.id, approved: true) }
        #expect(prompter.prompt != nil)
        if let secondPrompt { prompter.resolve(id: secondPrompt.id, approved: true) }
        #expect(await second.value == true)
        #expect(prompter.prompt == nil)
    }

    @Test func cancelPendingDeclines() async {
        let prompter = GroupChangeAdvisoryPrompter()
        let request = Task { await prompter.requestConsent(for: .catchingUp, isInvite: false) }
        _ = await Self.awaitPrompt(prompter)
        prompter.cancelPending()
        #expect(await request.value == false)
    }

    /// A caller that is already cancelled is declined without ever setting a prompt, so its alert
    /// never flashes up.
    @Test func anAlreadyCancelledRequestNeverShowsAPrompt() async {
        let prompter = GroupChangeAdvisoryPrompter()
        nonisolated(unsafe) var promptChanged = false
        withObservationTracking {
            _ = prompter.prompt
        } onChange: {
            promptChanged = true
        }

        let approved = await Task { @MainActor in
            withUnsafeCurrentTask { $0?.cancel() }
            return await prompter.requestConsent(for: .catchingUp, isInvite: false)
        }.value

        #expect(approved == false)
        #expect(promptChanged == false)
        #expect(prompter.prompt == nil)
    }

    @Test func invitesGetTheStrongerCatchingUpWarning() {
        #expect(
            GroupChangeAdvisory.catchingUp.message(isInvite: true)
                != GroupChangeAdvisory.catchingUp.message(isInvite: false))
        #expect(
            GroupChangeAdvisory.commitUndelivered.message(isInvite: true)
                == GroupChangeAdvisory.commitUndelivered.message(isInvite: false))
    }

    // MARK: - Workspace group changes

    @Test func consentedProfileSaveIsAcknowledgedAndPublished() async throws {
        let (runtime, state, groupIdHex) = try await Self.openGroupDetails()
        runtime.groupChangeAdvisoryRefusals[groupIdHex] = .GroupCatchingUp(groupIdHex: groupIdHex)
        state.groupProfileDraftName = "Renamed"
        let prompter = GroupChangeAdvisoryPrompter()

        let save = Task { await state.saveGroupProfile(advisory: prompter) }
        let prompt = try #require(await Self.awaitPrompt(prompter))
        #expect(prompt.advisory == .catchingUp)
        #expect(prompt.isInvite == false)
        prompter.resolve(id: prompt.id, approved: true)
        await save.value

        #expect(state.lastError == nil)
        #expect(runtime.groupChangeAdvisoryAcknowledgements == ["catchingUp:\(groupIdHex)"])
        #expect(runtime.updatedGroupProfile?.name == "Renamed")
        #expect(runtime.updateGroupProfileCallCount == 2)
    }

    @Test func waitingLeavesTheGroupUnchangedWithTheDeclinedNote() async throws {
        let (runtime, state, groupIdHex) = try await Self.openGroupDetails()
        runtime.groupChangeAdvisoryRefusals[groupIdHex] = .GroupCommitUndelivered(groupIdHex: groupIdHex)
        state.groupProfileDraftName = "Renamed"
        let prompter = GroupChangeAdvisoryPrompter()

        let save = Task { await state.saveGroupProfile(advisory: prompter) }
        let prompt = try #require(await Self.awaitPrompt(prompter))
        prompter.resolve(id: prompt.id, approved: false)
        await save.value

        #expect(state.lastError == GroupChangeAdvisory.commitUndelivered.declinedMessage)
        #expect(runtime.groupChangeAdvisoryAcknowledgements.isEmpty)
        #expect(runtime.updatedGroupProfile == nil)
    }

    /// With nobody to ask, the refusal is never acknowledged on the user's behalf.
    @Test func noPrompterReportsTheRefusalAsDeclined() async throws {
        let (runtime, state, groupIdHex) = try await Self.openGroupDetails()
        runtime.groupChangeAdvisoryRefusals[groupIdHex] = .GroupCatchingUp(groupIdHex: groupIdHex)
        state.groupProfileDraftName = "Renamed"

        await state.saveGroupProfile()

        #expect(state.lastError == GroupChangeAdvisory.catchingUp.declinedMessage)
        #expect(runtime.groupChangeAdvisoryAcknowledgements.isEmpty)
        #expect(runtime.updateGroupProfileCallCount == 1)
    }

    // MARK: - MissingKeyPackage reason

    @Test func obsoleteOnlyKeyPackagesAskForAnUpdateInsteadOfAnInvite() {
        let notFound = MarmotKitError.MissingKeyPackage(account: "abcdef0123", reason: .notFound)
        let obsolete = MarmotKitError.MissingKeyPackage(account: "abcdef0123", reason: .obsoleteOnly)
        #expect(ChatCreationFailure(notFound) == .notOnWhiteNoise(account: "abcdef0123"))
        #expect(ChatCreationFailure(obsolete) == .needsAppUpdate(account: "abcdef0123"))
        #expect(
            ChatCreationFailure.message(for: obsolete, candidates: [Self.recipient])
                == String(
                    format: L10n.string("%@ needs to update their app before they can be invited."), "Robin"))
        #expect(
            ChatCreationFailure.message(for: obsolete, candidates: [])
                == L10n.string("This user needs to update their app before they can be invited."))
    }

    @Test func outdatedDirectChatRecipientGetsAnErrorNotAnInvitePrompt() {
        let runtime = FakeMarmotRuntime(accounts: [desktopAccount()])
        let state = WorkspaceState(clientFactory: { runtime })
        // The core's label need not match: a one-to-one attempt has exactly one recipient to name.
        state.applyChatCreationFailure(
            MarmotKitError.MissingKeyPackage(account: "someone-else", reason: .obsoleteOnly),
            recipients: [Self.recipient],
            surface: .directChat
        )
        #expect(state.startChatInvitePrompt == nil)
        #expect(
            state.lastError
                == String(
                    format: L10n.string("%@ needs to update their app before they can be invited."), "Robin"))
    }

    // MARK: - Storage-blocked downloads

    /// Parked for free space with checkpoints kept: an explicit request readmits it, and a
    /// download-again would discard the progress.
    @Test func storageBlockedDownloadIsReadmittedWithoutARearm() {
        #expect(AttachmentTransferStateFfi.storageBlocked.needsRearmToDownload == false)
    }

    // MARK: - Helpers

    private static func openGroupDetails() async throws -> (FakeMarmotRuntime, WorkspaceState, String) {
        let account = desktopAccount()
        let runtime = FakeMarmotRuntime(accounts: [account])
        let details = groupDetailsFixture(selfAccountIdHex: account.accountIdHex)
        runtime.installGroupDetails(details)
        let state = WorkspaceState(clientFactory: { runtime })
        await state.bootstrap()
        let chat = try #require(state.activeChats.first)
        await state.showGroupDetails(for: chat)
        return (runtime, state, details.group.groupIdHex)
    }

    /// The prompt is published on the main actor as soon as the refused attempt returns; no disk,
    /// Keychain or FFI work sits between, so yielding is enough to reach it.
    private static func awaitPrompt(
        _ prompter: GroupChangeAdvisoryPrompter, other previous: UUID? = nil
    ) async -> GroupChangeAdvisoryPrompter.Prompt? {
        for _ in 0..<10_000 {
            if let prompt = prompter.prompt, prompt.id != previous { return prompt }
            await Task.yield()
        }
        return nil
    }
}
