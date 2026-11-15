import MarmotKit

@testable import whitenoise_mac

extension FakeMarmotRuntime {
    /// - Parameters:
    ///   - storageRoot: Where this fake reports its storage root. Isolated per test by
    ///     default, so a test that forgets to inject a file store still cannot read
    ///     another test's records; pass `.explicit` only to share a directory on purpose.
    ///   - function: Do not pass these. They default at the call site, which is how the
    ///     isolated root falls back to naming the caller when there is no running test.
    convenience init(
        accounts: [AccountSummaryFfi],
        createdAccount: AccountSummaryFfi? = nil,
        storageRoot: TestStorageRoot = .isolated,
        function: StaticString = #function,
        fileID: StaticString = #fileID
    ) {
        self.init(
            accounts: accounts,
            createdAccount: createdAccount,
            storageRootPath: storageRoot.resolvedPath(function: function, fileID: fileID)
        )
    }
}
