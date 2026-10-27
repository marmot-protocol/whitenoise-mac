import CryptoKit
import Foundation
import MarmotKit
import Testing

@Suite(.serialized)
struct MarmotKitMigrationTests {
    private static let accountID = "35960c078f910c0c9e2e069662a733427c1310684f3857bf323289985f205906"
    private static let fixtureSHA256 = "fbe5e3e903a6b1c08393bfbe0f77d0dd4495815e2f16fe9b084312dc219a6e99"

    @Test func opensAndReopensThePublished0916AccountDatabase() async throws {
        let fixture = try Self.fixtureURL()
        let fixtureData = try Data(contentsOf: fixture)
        #expect(Self.sha256(fixtureData) == Self.fixtureSHA256)

        let extracted = try Self.extractFixture(fixture)
        defer { try? FileManager.default.removeItem(at: extracted.parent) }

        let firstOpen = try Self.open(root: extracted.root)
        #expect(try firstOpen.listAccounts().map(\.accountIdHex) == [Self.accountID])
        try await firstOpen.shutdownAndClose()

        let reopened = try Self.open(root: extracted.root)
        #expect(try reopened.listAccounts().map(\.accountIdHex) == [Self.accountID])
        try await reopened.shutdownAndClose()
    }

    @Test func recoversThe0916WalBackedInterruptedState() async throws {
        let extracted = try Self.extractFixture(Self.fixtureURL())
        defer { try? FileManager.default.removeItem(at: extracted.parent) }

        let accountRoot = extracted.root
            .appending(path: "accounts", directoryHint: .isDirectory)
            .appending(path: Self.accountID, directoryHint: .isDirectory)
        let wal = accountRoot.appending(path: "session.sqlite-wal")
        #expect(try FileManager.default.attributesOfItem(atPath: wal.path)[.size] as? UInt64 != 0)

        let migrated = try Self.open(root: extracted.root)
        #expect(try migrated.listAccounts().contains { $0.accountIdHex == Self.accountID })
        try await migrated.shutdownAndClose()
    }

    private static func open(root: URL) throws -> Marmot {
        try Marmot.newWithConfiguration(
            rootPath: root.path,
            relayUrls: ["wss://relay.invalid.test"],
            options: MarmotOptions(
                relayPolicy: .publicOnly,
                cursorPersistence: .advance,
                clientName: "whitenoise",
                secretStore: nil,
                attachmentAcquisitionMode: .hostManaged,
                deployment: marmotDeploymentWhiteNoise()
            )
        )
    }

    private static func fixtureURL() throws -> URL {
        let bundle = Bundle(for: MigrationFixtureBundleAnchor.self)
        if let nested = bundle.url(
            forResource: "MarmotKit-0.9.16-account-root",
            withExtension: "zip",
            subdirectory: "Fixtures"
        ) {
            return nested
        }
        return try #require(
            bundle.url(forResource: "MarmotKit-0.9.16-account-root", withExtension: "zip")
        )
    }

    private static func extractFixture(_ fixture: URL) throws -> (parent: URL, root: URL) {
        let parent = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appending(path: "WhiteNoiseMigrationTests", directoryHint: .isDirectory)
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-x", "-k", fixture.path, parent.path]
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw MigrationFixtureError.extractionFailed(process.terminationStatus)
        }

        return (
            parent,
            parent.appending(path: "account-clean-0.9.16-v1", directoryHint: .isDirectory)
        )
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

private final class MigrationFixtureBundleAnchor {}

private enum MigrationFixtureError: Error {
    case extractionFailed(Int32)
}
