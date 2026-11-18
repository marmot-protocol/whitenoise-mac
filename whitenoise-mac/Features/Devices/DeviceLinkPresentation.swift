import Foundation
import MarmotKit

/// Wording for device linking: link states, why a link ended, device status and MDK's
/// `device group refused: <reason>` refusals. Kept apart from the views so it can be tested and so
/// every state the bindings can produce has copy.
nonisolated enum DeviceLinkPresentation {
    static let maxLabelBytes = 64

    // MARK: New device (this device asked to be linked)

    static func title(for state: NewDeviceLinkStateFfi) -> String {
        switch state {
        case .waitingForAnswer: L10n.string("Open White Noise on Your Other Device")
        case .comparing: L10n.string("Compare the Emoji")
        case .waitingForOtherDevice: L10n.string("Waiting for Your Other Device")
        case .joining: L10n.string("Linking…")
        case .linked: L10n.string("This Mac Is Linked")
        case .ended: L10n.string("Linking Stopped")
        }
    }

    static func message(for state: NewDeviceLinkStateFfi) -> String {
        switch state {
        case .waitingForAnswer:
            L10n.string(
                "Open White Noise on a device that’s already signed in to this profile. It needs to be online, with device linking on. The request appears there and expires after 10 minutes."
            )
        case .comparing:
            L10n.string("Check that your other device shows the same emoji, in the same order.")
        case .waitingForOtherDevice:
            L10n.string("Choose Link Device on your other device to finish.")
        case .joining:
            L10n.string("Your other device is adding this Mac. This can take a minute.")
        case .linked:
            L10n.string("Your chats appear here as your other devices add this Mac to them.")
        case .ended(let reason):
            message(for: reason)
        }
    }

    /// Whether the new device's link is still running, so the sheet offers Cancel rather than Done.
    static func isActive(_ state: NewDeviceLinkStateFfi) -> Bool {
        switch state {
        case .waitingForAnswer, .comparing, .waitingForOtherDevice, .joining: true
        case .linked, .ended: false
        }
    }

    // MARK: Prompt (another device asked this one)

    static func title(for state: DeviceLinkPromptStateFfi) -> String {
        switch state {
        case .preparing, .comparing, .competingRequests, .rateLimited, .cannotLink, .tooManyDevices:
            L10n.string("Link a New Device?")
        case .linking: L10n.string("Linking…")
        case .linked, .addedElsewhere: L10n.string("Device Linked")
        case .ended: L10n.string("Linking Stopped")
        }
    }

    static func message(for state: DeviceLinkPromptStateFfi, now: Date = Date()) -> String {
        switch state {
        case .preparing:
            L10n.string("A device signed in to your profile is asking to be linked. Getting the code…")
        case .comparing:
            L10n.string("Only link it if both screens show the same emoji, in the same order.")
        case .competingRequests:
            L10n.string(
                "More than one device is asking to be linked at once, so none can be. Try again from one device.")
        case .rateLimited(let retryAt):
            String(
                format: L10n.string("Too many link requests. Try again %@."),
                relative(retryAt, now: now))
        case .cannotLink:
            L10n.string("That device’s version of White Noise can’t be linked. Update it and try again.")
        case .tooManyDevices:
            L10n.string("You’ve linked 20 devices. Remove one to link another.")
        case .linking:
            L10n.string("Waiting for the new device to join. You can close this; linking carries on.")
        case .linked:
            L10n.string("The new device is linked to your profile.")
        case .addedElsewhere(let deviceLabel, let addedByLabel):
            String(
                format: L10n.string("%1$@ was added by %2$@."),
                deviceLabel.isEmpty ? L10n.string("A new device") : deviceLabel,
                addedByLabel.isEmpty ? L10n.string("another device") : addedByLabel)
        case .ended(let reason):
            message(for: reason)
        }
    }

    /// Prompt states that want the user's attention: the sheet opens on its own for these.
    static func needsAttention(_ state: DeviceLinkPromptStateFfi) -> Bool {
        switch state {
        case .preparing, .comparing, .competingRequests, .rateLimited, .cannotLink, .tooManyDevices: true
        case .linking, .linked, .addedElsewhere, .ended: false
        }
    }

    static func isFinished(_ state: DeviceLinkPromptStateFfi) -> Bool {
        switch state {
        case .linked, .addedElsewhere, .ended: true
        default: false
        }
    }

    static func message(for reason: DeviceLinkEndReasonFfi) -> String {
        switch reason {
        case .cancelled: L10n.string("Linking was cancelled.")
        case .cancelledElsewhere: L10n.string("Linking was cancelled on the other device.")
        case .codesDiffer: L10n.string("The emoji didn’t match, so the devices weren’t linked.")
        case .verificationFailed:
            L10n.string("The devices couldn’t verify each other, so they weren’t linked. Try again.")
        case .timedOut: L10n.string("Linking timed out. Try again.")
        case .answeredElsewhere: L10n.string("Another of your devices is linking it.")
        case .cannotLink:
            L10n.string("That device’s version of White Noise can’t be linked. Update it and try again.")
        case .rejected: L10n.string("This sign-in was rejected on one of your devices.")
        case .linkFailed: L10n.string("Linking didn’t finish. Try again.")
        }
    }

    // MARK: Devices

    static func name(of device: LinkedDeviceFfi) -> String {
        if !device.label.isEmpty { return device.label }
        let detail = [device.platform, device.client].filter { !$0.isEmpty }.joined(separator: " · ")
        return detail.isEmpty ? L10n.string("Unnamed device") : detail
    }

    /// The status line under a device's name, or nil for an active device with nothing to say.
    static func status(of device: LinkedDeviceFfi, now: Date = Date()) -> String? {
        if device.removalPending { return L10n.string("Removing…") }
        switch device.status {
        case .leaving: return L10n.string("Signing out")
        case .moved: return L10n.string("Moved to another device list")
        case .inactive: return L10n.string("Inactive")
        case .active: break
        }
        if device.inactive { return L10n.string("Not seen for 30 days") }
        if let lastActiveAt = device.lastActiveAt {
            return String(format: L10n.string("Last active %@"), relative(lastActiveAt, now: now))
        }
        return nil
    }

    /// The roster marked it inactive and nothing keeps it: offer Remove and Keep.
    static func offersKeepOrRemove(_ device: LinkedDeviceFfi) -> Bool {
        device.status == .inactive && !device.keepWhileInactive && !device.isThisDevice && !device.removalPending
    }

    /// A label MDK accepts for `link_device` and `rename_linked_device`: not blank, at most 64 bytes.
    static func isValidLabel(_ label: String) -> Bool {
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty && trimmed.utf8.count <= maxLabelBytes
    }

    // MARK: Sign-ins

    static func title(for signIn: UnrecognizedSignInFfi) -> String {
        signIn.beforeThisDevice ? L10n.string("Do You Still Have This Device?") : L10n.string("Was This You?")
    }

    static func message(for signIn: UnrecognizedSignInFfi, now: Date = Date()) -> String {
        switch signIn.state {
        case .linkedElsewhere: return L10n.string("Linked on another of your devices.")
        case .rejectedElsewhere: return L10n.string("Rejected on another of your devices.")
        case .prompt, .notNow: break
        }
        if signIn.beforeThisDevice {
            return String(
                format: L10n.string("Signed in before this Mac. Last seen %@."), relative(signIn.lastSeenAt, now: now))
        }
        return String(
            format: L10n.string("A new sign-in to your profile appeared %@."), relative(signIn.appearedAt, now: now))
    }

    // MARK: Compromise warning

    static func message(for item: CompromiseWarningItemFfi, now: Date = Date()) -> String {
        switch item.reason {
        case .rejectedSignIn:
            String(format: L10n.string("A sign-in was marked as not you %@."), relative(item.occurredAt, now: now))
        case .foreignOwnSlotKeyPackage:
            String(
                format: L10n.string("A key package this Mac didn’t make appeared in its place %@. It was replaced."),
                relative(item.occurredAt, now: now))
        }
    }

    // MARK: Moves

    static func title(for state: DeviceGroupMoveStateFfi) -> String {
        switch state {
        case .waitingForWelcome: L10n.string("Waiting to join your other device’s list")
        case .joining: L10n.string("Joining your other device’s list")
        case .made: L10n.string("Moved to your other device’s list")
        case .failed: L10n.string("Couldn’t move to your other device’s list")
        }
    }

    // MARK: Errors

    static let refusalPrefix = "device group refused: "

    static func errorMessage(for error: Error) -> String {
        guard case MarmotKitError.Runtime(let details) = error, details.hasPrefix(refusalPrefix) else {
            return UserFacingError.message(for: error)
        }
        return refusalMessage(String(details.dropFirst(refusalPrefix.count)))
    }

    static func refusalMessage(_ reason: String) -> String {
        switch reason {
        case "roster_unsupported", "pairing_unsupported":
            L10n.string("Device linking isn’t available in this build.")
        case "no_device_group": L10n.string("This Mac isn’t linked to any other devices yet.")
        case "unknown_device": L10n.string("That device is no longer in your device list.")
        case "this_device": L10n.string("To remove this Mac, sign out instead.")
        case "device_link_pending": L10n.string("That device is still being linked. Try again once it finishes.")
        case "roster_unavailable": L10n.string("Your device list couldn’t be read. Try again.")
        case "device_group_busy":
            L10n.string("Your devices are still syncing an earlier change. Try again in a moment.")
        case "label_too_long": L10n.string("That name is too long.")
        case "label_invalid": L10n.string("Enter a name for the device.")
        case "pairing_in_progress": L10n.string("A link is already in progress.")
        case "no_link_in_progress": L10n.string("There’s no link in progress.")
        case "key_package_not_published":
            L10n.string("This Mac hasn’t published its key package yet. Try again in a moment.")
        case "unknown_prompt": L10n.string("That link request has expired.")
        case "link_unavailable": L10n.string("This request can’t be linked right now.")
        case "device_already_linked": L10n.string("That device is already linked.")
        case "sign_in_rejected": L10n.string("This sign-in was rejected on one of your devices.")
        case "too_many_devices": L10n.string("You’ve linked 20 devices. Remove one to link another.")
        case "sign_ins_unchecked":
            L10n.string("White Noise hasn’t finished checking your sign-ins. Try again in a moment.")
        case "device_group_exists": L10n.string("This Mac is already linked to your other devices.")
        default: L10n.string("Device linking ran into a problem. Try again.")
        }
    }

    private static func relative(_ unixSeconds: UInt64, now: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = AppLanguage.currentLocale
        formatter.unitsStyle = .full
        return formatter.localizedString(for: Date(timeIntervalSince1970: TimeInterval(unixSeconds)), relativeTo: now)
    }
}
