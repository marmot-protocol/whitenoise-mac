import Foundation

struct AppLaunchConfiguration {
    let uiFixtureName: String?
    /// XCTest launched this process to host the unit tests. The tests build their own workspaces on
    /// fake runtimes, so the host's own must never start: it would open the flavor's real Marmot
    /// root and keychain items and connect to relays for the whole run.
    let isUnitTestHost: Bool

    /// A DEBUG launch on an in-memory fixture runtime (`-uiFixture`), which the shell keeps off
    /// the network and away from system prompts.
    var isUIFixture: Bool {
        #if DEBUG
            uiFixtureName != nil
        #else
            false
        #endif
    }

    static var current: AppLaunchConfiguration {
        AppLaunchConfiguration(
            uiFixtureName: fixtureName(
                arguments: ProcessInfo.processInfo.arguments,
                environment: ProcessInfo.processInfo.environment
            ),
            isUnitTestHost: ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
        )
    }

    func makeWorkspace() -> WorkspaceState {
        #if DEBUG
            if let uiFixtureName {
                return WorkspaceState.uiFixture(named: uiFixtureName)
            }
        #endif

        return WorkspaceState()
    }

    private static func fixtureName(arguments: [String], environment: [String: String]) -> String? {
        if let explicit = environment["WHITE_NOISE_UI_FIXTURE"]?.nilIfBlank {
            return explicit
        }

        if let index = arguments.firstIndex(of: "-uiFixture") {
            let valueIndex = arguments.index(after: index)
            if valueIndex < arguments.endIndex {
                return arguments[valueIndex].nilIfBlank
            }
        }

        let prefix = "--ui-fixture="
        return
            arguments
            .first { $0.hasPrefix(prefix) }
            .flatMap { String($0.dropFirst(prefix.count)).nilIfBlank }
    }
}
