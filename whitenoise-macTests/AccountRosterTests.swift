import Foundation
import MarmotKit
import Testing

@testable import whitenoise_mac

/// The account list's one owner: overlapping reloads install in the order they were asked for.
@MainActor
struct AccountRosterTests {
    /// A read held across a newer reload lands first, so the newer read is what's left installed.
    @Test func aHeldReadCannotLandAfterANewerOne() async throws {
        let desktop = desktopAccount()
        let runtime = FakeMarmotRuntime(accounts: [desktop])
        let roster = AccountRoster()

        runtime.userProfileGateEnabled = true
        let older = Task { try await roster.reload(from: runtime) }
        while !runtime.didReachUserProfileGate { await Task.yield() }

        runtime.unlinkFromAnotherDevice(accountRef: desktop.label)
        let newer = Task { try await roster.reload(from: runtime) }
        // Time for the newer read to overtake the held one, if reloads didn't wait their turn.
        try await Task.sleep(for: .milliseconds(100))
        runtime.releaseUserProfileGate()

        #expect(try await older.value.first?.signedOut == false)
        #expect(try await newer.value.first?.signedOut == true)
        #expect(roster.accounts.first?.signedOut == true)
    }

    /// A failed read installs nothing, and the next one still runs.
    @Test func aFailedReadKeepsTheListAndTheNextOneRuns() async throws {
        let runtime = FakeMarmotRuntime(accounts: [desktopAccount()])
        let roster = AccountRoster()
        try await roster.reload(from: runtime)

        runtime.listAccountsError = MarmotKitError.Runtime(details: "storage closed")
        await #expect(throws: (any Error).self) { try await roster.reload(from: runtime) }
        #expect(roster.accounts.count == 1)

        runtime.listAccountsError = nil
        try await runtime.removeAccount(accountRef: desktopAccount().label)
        try await roster.reload(from: runtime)
        #expect(roster.accounts.isEmpty)
    }

    /// Clearing (a reset to a new install) stops a reload still reading from putting the old list back.
    @Test func clearingStopsAReloadStillReading() async throws {
        let runtime = FakeMarmotRuntime(accounts: [desktopAccount()])
        let roster = AccountRoster()

        runtime.userProfileGateEnabled = true
        let reading = Task { try await roster.reload(from: runtime) }
        while !runtime.didReachUserProfileGate { await Task.yield() }
        roster.clear()
        runtime.releaseUserProfileGate()

        await #expect(throws: CancellationError.self) { try await reading.value }
        #expect(roster.accounts.isEmpty)
    }

    /// A name saved while a reload is still reading isn't replaced by the old name that reload read.
    @Test func aProfileEditOutlivesAReloadThatReadTheOldName() async throws {
        let runtime = FakeMarmotRuntime(accounts: [desktopAccount()])
        let roster = AccountRoster()
        try await roster.reload(from: runtime)
        let id = try #require(roster.accounts.first?.id)

        runtime.userProfileGateEnabled = true
        let reading = Task { try await roster.reload(from: runtime) }
        while !runtime.didReachUserProfileGate { await Task.yield() }
        roster.updateProfile(accountId: id, displayName: "Studio", pictureURL: nil)
        runtime.releaseUserProfileGate()
        _ = try await reading.value

        #expect(roster.accounts.first?.displayName == "Studio")
    }
}
