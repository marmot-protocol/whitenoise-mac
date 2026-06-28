import Foundation

struct AppLaunchConfiguration {
    let uiFixtureName: String?

    var shouldBootstrapWorkspace: Bool {
        #if DEBUG
            uiFixtureName == nil
        #else
            true
        #endif
    }

    static var current: AppLaunchConfiguration {
        AppLaunchConfiguration(
            uiFixtureName: fixtureName(
                arguments: ProcessInfo.processInfo.arguments,
                environment: ProcessInfo.processInfo.environment
            )
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
