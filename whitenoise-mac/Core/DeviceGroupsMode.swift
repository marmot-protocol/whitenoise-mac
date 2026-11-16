import Foundation
import MarmotKit

/// Whether a runtime opens with MDK's experimental device groups, which device linking needs.
///
/// Device groups exist only in a native library built with MDK's `dev-device-groups` feature and
/// opened through `Marmot.newWithExperimentalDeviceGroups`. Published MarmotKit releases are not
/// built with it, so with the vendored release that constructor refuses with
/// `experimental_device_groups_unavailable` before it opens the root or touches the keychain, and
/// the ordinary constructor runs instead. `scripts/dev-device-groups.sh` swaps in a capable local
/// build, and then Debug and staging builds open with device groups on.
///
/// Production never tries it: a release install must not open its root in a test mode, even if
/// a capable library were ever linked in. And the fallback is taken only for that one refusal:
/// any other failure of the experimental constructor is the open failing, not the library lacking
/// the feature. Retrying with the ordinary constructor would hide it, and an ordinary open of a
/// root whose account holds a device group refuses that account anyway
/// (`experimental_device_groups_required`).
nonisolated enum DeviceGroupsMode {
    static let unavailableDetails = "experimental_device_groups_unavailable"

    static func shouldTryExperimental(flavor: AppFlavor) -> Bool {
        flavor != .production
    }

    /// Whether `error` is the capability refusal, after which the ordinary constructor is safe.
    static func isCapabilityMissing(_ error: Error) -> Bool {
        guard case MarmotKitError.Runtime(let details) = error else { return false }
        return details == unavailableDetails
    }

    static func open(
        rootPath: String,
        relayUrls: [String],
        options: MarmotOptions,
        flavor: AppFlavor = .current
    ) throws -> (marmot: Marmot, deviceGroupsEnabled: Bool) {
        if shouldTryExperimental(flavor: flavor) {
            do {
                let marmot = try Marmot.newWithExperimentalDeviceGroups(
                    rootPath: rootPath,
                    relayUrls: relayUrls,
                    options: options
                )
                return (marmot, true)
            } catch  where isCapabilityMissing(error) {
                // The published library: fall through to the ordinary open.
            }
        }
        let marmot = try Marmot.newWithConfiguration(rootPath: rootPath, relayUrls: relayUrls, options: options)
        return (marmot, false)
    }
}
