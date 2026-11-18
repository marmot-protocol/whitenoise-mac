import MarmotKit
import SwiftUI

/// Settings → Devices: this account's linked devices, linking this Mac or approving another device,
/// sign-ins no device recognizes, and the warnings MDK raises about them.
///
/// The model is the account's `DeviceLinkingViewModel`, shared with the sheet the shell hosts, so a
/// request answered there shows here and the other way round.
struct DevicesSettingsView: View {
    let model: DeviceLinkingViewModel
    /// Link requests waiting on the user's other signed-in profiles; Review switches to one.
    var otherProfileRequests: [ProfileLinkRequestsMonitor.Request] = []
    var onReviewOtherProfile: (ProfileLinkRequestsMonitor.Request) -> Void = { _ in }

    @State private var selectedDevice: LinkedDeviceSelection?

    var body: some View {
        SettingsScaffold(title: L10n.string("Devices")) {
            if model.isAvailable {
                DeviceWarningsSection(model: model)
                LinkedDevicesSection(model: model, onSelect: { selectedDevice = LinkedDeviceSelection(id: $0) })
                DeviceLinkSection(model: model)
                if !otherProfileRequests.isEmpty {
                    OtherProfileLinkRequestsSection(requests: otherProfileRequests, onReview: onReviewOtherProfile)
                }
                if !model.snapshot.moves.isEmpty {
                    DeviceMovesSection(model: model)
                }
                SignInsSection(model: model)
                if let error = model.actionError, model.presentedSheet == nil, selectedDevice == nil {
                    SettingsSection {
                        SettingsErrorView(error: error)
                    }
                }
            } else {
                SettingsSection {
                    Text(L10n.string("Device linking isn’t available in this build."))
                        .foregroundStyle(WNColor.backgroundContentSecondary)
                }
            }
        }
        .task {
            await model.refreshAll()
        }
        .sheet(item: $selectedDevice) { selection in
            LinkedDeviceSheet(model: model, slotIdHex: selection.id)
        }
    }
}

struct LinkedDeviceSelection: Identifiable, Hashable {
    let id: String
}

// MARK: - Warnings

private struct DeviceWarningsSection: View {
    let model: DeviceLinkingViewModel
    @State private var confirmingReset = false

    var body: some View {
        let showsAny =
            !model.compromiseItems.isEmpty || model.snapshot.deviceGroupStalled || model.keyPackageRefreshOverdue
        if showsAny {
            SettingsSection {
                if !model.compromiseItems.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        WNCallout(
                            title: L10n.string("Someone Else May Have Your Private Key"),
                            message: model.compromiseItems.map { DeviceLinkPresentation.message(for: $0) }
                                .joined(separator: "\n"),
                            intent: .error
                        )
                        Button(L10n.string("Dismiss")) {
                            Task { await model.dismissCompromiseWarning() }
                        }
                        .buttonStyle(.wnSecondary)
                        .disabled(model.isBusy(.dismissCompromise))
                    }
                }
                if model.snapshot.deviceGroupStalled {
                    VStack(alignment: .leading, spacing: 8) {
                        WNCallout(
                            title: L10n.string("This Mac Can’t Catch Up With Your Other Devices"),
                            message: L10n.string(
                                "Reset this Mac’s copy of your device list, then link it again. Your chats and messages stay on this Mac."
                            ),
                            intent: .warning
                        )
                        Button(L10n.string("Reset Device List…")) { confirmingReset = true }
                            .buttonStyle(.wnSecondary)
                            .disabled(model.isBusy(.reset))
                    }
                }
                if model.keyPackageRefreshOverdue {
                    WNCallout(
                        title: L10n.string("Key Package Refresh Overdue"),
                        message: L10n.string(
                            "Your devices couldn’t sync this Mac’s new key package. After 30 days, people may not be able to add this Mac to chats."
                        ),
                        intent: .warning
                    )
                }
            }
            .confirmationDialog(
                L10n.string("Reset this Mac’s device list?"),
                isPresented: $confirmingReset
            ) {
                Button(L10n.string("Reset"), role: .destructive) {
                    Task { await model.resetForRepair() }
                }
            } message: {
                Text(
                    L10n.string(
                        "This Mac forgets its copy of your device list and stops being linked. Your chats, messages and settings stay. Afterwards, link it to another device again."
                    ))
            }
        }
    }
}

// MARK: - Devices

private struct LinkedDevicesSection: View {
    let model: DeviceLinkingViewModel
    let onSelect: (String) -> Void

    var body: some View {
        SettingsSection(
            title: L10n.string("Your Devices"),
            footer: footer
        ) {
            if model.devices.isEmpty {
                Text(L10n.string("This Mac isn’t linked to any other devices yet."))
                    .foregroundStyle(WNColor.backgroundContentSecondary)
            } else {
                ForEach(model.devices, id: \.slotIdHex) { device in
                    LinkedDeviceRow(model: model, device: device, onSelect: { onSelect(device.slotIdHex) })
                }
            }
        }
    }

    private var footer: String? {
        var notes: [String] = []
        if model.chatsClosedToLinkedDevices > 0 {
            notes.append(
                String(
                    format: L10n.string(
                        "Chats that can’t add your linked devices: %lld. A chat admin can turn this on."),
                    Int64(model.chatsClosedToLinkedDevices)))
        }
        if model.removedDeviceLeftoverChats > 0 {
            notes.append(
                String(
                    format: L10n.string(
                        "Chats still holding a device you removed: %lld. A chat admin can remove it."),
                    Int64(model.removedDeviceLeftoverChats)))
        }
        return notes.isEmpty ? nil : notes.joined(separator: " ")
    }
}

private struct LinkedDeviceRow: View {
    let model: DeviceLinkingViewModel
    let device: LinkedDeviceFfi
    let onSelect: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Button(action: onSelect) {
                HStack(spacing: 10) {
                    Image(systemName: device.platform.lowercased().contains("ios") ? "iphone" : "laptopcomputer")
                        .foregroundStyle(WNColor.backgroundContentSecondary)
                        .frame(width: 20)
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(DeviceLinkPresentation.name(of: device))
                            if device.isThisDevice {
                                Text(L10n.string("This Mac"))
                                    .wnFont(.medium12)
                                    .foregroundStyle(WNColor.backgroundContentSecondary)
                            }
                        }
                        if let status = DeviceLinkPresentation.status(of: device) {
                            Text(status)
                                .wnFont(.medium12)
                                .foregroundStyle(WNColor.backgroundContentSecondary)
                        }
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if DeviceLinkPresentation.offersKeepOrRemove(device) {
                Button(L10n.string("Keep")) {
                    Task { await model.update(slotIdHex: device.slotIdHex, keepWhileInactive: true) }
                }
                .buttonStyle(.wnSecondary)
                .disabled(model.isBusy(.device(slotIdHex: device.slotIdHex)))
            }
            Image(systemName: "chevron.right")
                .wnFont(.semiBold10)
                .foregroundStyle(WNColor.backgroundContentTertiary)
        }
    }
}

// MARK: - Linking

private struct DeviceLinkSection: View {
    let model: DeviceLinkingViewModel

    var body: some View {
        let newDevice = model.snapshot.newDevice
        let linking = newDevice.map(DeviceLinkPresentation.isActive) == true
        SettingsSection(
            title: L10n.string("Link a Device"),
            footer: L10n.string(
                "To add a new device, sign in to this profile on it, then choose Link to Another Device there. You’ll be asked to approve it here."
            )
        ) {
            if let newDevice, linking {
                DeviceLinkStatusRow(
                    title: DeviceLinkPresentation.title(for: newDevice),
                    actionTitle: L10n.string("Show"),
                    action: { model.showNewDeviceLink() }
                )
            }
            ForEach(model.openPrompts, id: \.promptId) { prompt in
                DeviceLinkStatusRow(
                    title: DeviceLinkPresentation.message(for: prompt.state),
                    actionTitle: L10n.string("Review"),
                    action: { model.showPrompt(prompt.promptId) }
                )
            }
            // MDK lets only the new device start a link, so offer both sides and say which is which.
            HStack(spacing: 8) {
                Button {
                    model.showAddNewDevice()
                } label: {
                    Label(L10n.string("Add a New Device…"), systemImage: "plus")
                }
                .buttonStyle(.wnSecondary)
                .disabled(linking)
                Button {
                    Task { await model.startLink() }
                } label: {
                    SettingsBusyLabel(
                        title: L10n.string("Link This Mac to Another Device"),
                        systemImage: "link",
                        isBusy: model.isBusy(.startLink)
                    )
                }
                .buttonStyle(.wnSecondary)
                .disabled(linking || model.isBusy(.startLink))
            }
            if !model.otherDevices.isEmpty {
                Text(
                    L10n.string(
                        "This Mac is already linked. Linking it to a device from a different list moves it to that list."
                    )
                )
                .wnFont(.medium12)
                .foregroundStyle(WNColor.backgroundContentSecondary)
            }
            // A note only: moving is still allowed, but can fail a link this Mac approved.
            if model.approvedLinkStillJoining {
                Text(
                    L10n.string(
                        "Finish linking your new device before moving this Mac. Moving now can stop it from joining your chats."
                    )
                )
                .wnFont(.medium12)
                .foregroundStyle(WNColor.backgroundContentSecondary)
            }
        }
    }
}

private struct OtherProfileLinkRequestsSection: View {
    let requests: [ProfileLinkRequestsMonitor.Request]
    let onReview: (ProfileLinkRequestsMonitor.Request) -> Void

    var body: some View {
        SettingsSection(
            title: L10n.string("Other Profiles"),
            footer: L10n.string("Review switches to that profile to compare the emoji.")
        ) {
            ForEach(requests) { request in
                DeviceLinkStatusRow(
                    title: ProfileLinkRequestsPresentation.message(profileName: request.profileName),
                    actionTitle: L10n.string("Review"),
                    action: { onReview(request) }
                )
            }
        }
    }
}

private struct DeviceLinkStatusRow: View {
    let title: String
    let actionTitle: String
    let action: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Text(title)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            Button(actionTitle, action: action)
                .buttonStyle(.wnSecondary)
        }
    }
}

private struct DeviceMovesSection: View {
    let model: DeviceLinkingViewModel

    var body: some View {
        SettingsSection(title: L10n.string("Moving This Mac")) {
            ForEach(model.snapshot.moves, id: \.moveId) { move in
                VStack(alignment: .leading, spacing: 6) {
                    Text(DeviceLinkPresentation.title(for: move.state))
                    ForEach(move.oldSiblings.filter(\.questionSuppressed), id: \.slotIdHex) { sibling in
                        DeviceLinkStatusRow(
                            title: String(
                                format: L10n.string("%@ is still in your old device list. Link it from that device."),
                                sibling.label.isEmpty ? L10n.string("Unnamed device") : sibling.label),
                            actionTitle: L10n.string("Dismiss"),
                            action: {
                                Task {
                                    await model.dismissMoveSibling(moveId: move.moveId, slotIdHex: sibling.slotIdHex)
                                }
                            }
                        )
                    }
                }
            }
        }
    }
}

// MARK: - Sign-ins

private struct SignInsSection: View {
    let model: DeviceLinkingViewModel

    var body: some View {
        let offersStartFresh =
            model.otherDevices.isEmpty && !model.startedFresh
            && model.signIns.contains { $0.beforeThisDevice && $0.state == .prompt }
        SettingsSection(
            title: L10n.string("Sign-ins"),
            footer: model.startedFresh
                ? L10n.string("You started fresh on this Mac. Only chats you’re invited to from now on are here.")
                : L10n.string("Sign-ins to your profile that none of your devices recognizes.")
        ) {
            if model.signIns.isEmpty {
                Text(L10n.string("No unrecognized sign-ins."))
                    .foregroundStyle(WNColor.backgroundContentSecondary)
            }
            ForEach(model.signIns, id: \.slotIdHex) { signIn in
                SignInRow(model: model, signIn: signIn)
            }
            HStack(spacing: 8) {
                Button {
                    Task { await model.checkSignIns() }
                } label: {
                    SettingsBusyLabel(
                        title: L10n.string("Check Now"),
                        systemImage: "arrow.clockwise",
                        isBusy: model.isBusy(.checkSignIns)
                    )
                }
                .buttonStyle(.wnSecondary)
                .disabled(model.isBusy(.checkSignIns))
                if offersStartFresh {
                    Button(L10n.string("I Don’t Have Those Devices")) {
                        Task { await model.startFresh() }
                    }
                    .buttonStyle(.wnSecondary)
                    .disabled(model.isBusy(.startFresh))
                }
            }
        }
    }
}

private struct SignInRow: View {
    let model: DeviceLinkingViewModel
    let signIn: UnrecognizedSignInFfi
    @State private var confirmingReject = false

    var body: some View {
        let busy = model.isBusy(.signIn(slotIdHex: signIn.slotIdHex))
        VStack(alignment: .leading, spacing: 6) {
            Text(DeviceLinkPresentation.title(for: signIn))
            Text(
                [
                    signIn.client.isEmpty ? L10n.string("Unknown app") : signIn.client,
                    DeviceLinkPresentation.message(for: signIn),
                ].joined(separator: " · ")
            )
            .wnFont(.medium12)
            .foregroundStyle(WNColor.backgroundContentSecondary)
            if signIn.previouslyLinkedHere {
                Text(
                    L10n.string(
                        "A device linked here before is missing from this Mac’s device list. Open both devices to check the link."
                    )
                )
                .wnFont(.medium12)
                .foregroundStyle(WNColor.intentionWarningContent)
            }
            HStack(spacing: 8) {
                switch signIn.state {
                case .prompt, .notNow:
                    if signIn.state == .prompt {
                        Button(L10n.string("Not Now")) {
                            Task { await model.answer(slotIdHex: signIn.slotIdHex, response: .notNow) }
                        }
                        .buttonStyle(.wnSecondary)
                        .disabled(busy)
                    }
                    // Linking starts on that device; this explains how and waits for its request.
                    Button(L10n.string("Link This Device…")) { model.showAddNewDevice() }
                        .buttonStyle(.wnSecondary)
                        .disabled(busy)
                    Button(L10n.string("This Wasn’t Me…")) { confirmingReject = true }
                        .buttonStyle(.wnDestructive)
                        .disabled(busy)
                case .linkedElsewhere, .rejectedElsewhere:
                    Button(L10n.string("Dismiss")) {
                        Task { await model.answer(slotIdHex: signIn.slotIdHex, response: .dismiss) }
                    }
                    .buttonStyle(.wnSecondary)
                    .disabled(busy)
                }
            }
        }
        .padding(.vertical, 2)
        .confirmationDialog(L10n.string("This wasn’t you?"), isPresented: $confirmingReject) {
            Button(L10n.string("This Wasn’t Me"), role: .destructive) {
                Task { await model.answer(slotIdHex: signIn.slotIdHex, response: .reject) }
            }
        } message: {
            Text(
                L10n.string(
                    "It’s marked as rejected on all your devices and can’t be linked. Someone else may have your private key."
                ))
        }
    }
}

// MARK: - One device

/// A device's name, settings and removal. Every control writes the roster through MDK and shows
/// what the roster says after, not what was typed: a competing edit from another device can win.
struct LinkedDeviceSheet: View {
    let model: DeviceLinkingViewModel
    let slotIdHex: String

    @Environment(\.dismiss) private var dismiss
    @State private var label = ""
    @State private var confirmingRemoval = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let device = model.device(slotIdHex: slotIdHex) {
                LinkedDeviceSheetContent(model: model, device: device, label: $label)
                if let error = model.actionError {
                    SettingsErrorView(error: error)
                }
                HStack(spacing: 8) {
                    if !device.isThisDevice && !device.removalPending {
                        Button(L10n.string("Remove Device…"), role: .destructive) { confirmingRemoval = true }
                            .buttonStyle(.wnDestructive)
                    }
                    Spacer(minLength: 0)
                    Button(L10n.string("Close")) { dismiss() }
                        .buttonStyle(.wnSecondary)
                }
                .confirmationDialog(
                    String(format: L10n.string("Remove %@?"), DeviceLinkPresentation.name(of: device)),
                    isPresented: $confirmingRemoval
                ) {
                    Button(L10n.string("Remove"), role: .destructive) {
                        Task {
                            if await model.remove(slotIdHex: slotIdHex) { dismiss() }
                        }
                    }
                } message: {
                    Text(
                        L10n.string(
                            "It’s removed from your chats and stops getting messages. To use it again, sign in on it and link it again."
                        ))
                }
            } else {
                Text(L10n.string("That device is no longer in your device list."))
                Button(L10n.string("Close")) { dismiss() }
                    .buttonStyle(.wnSecondary)
            }
        }
        .padding(20)
        .frame(width: 440)
        .fixedSize(horizontal: false, vertical: true)
        .wnButtonShape(.capsule)
        .onAppear {
            label = model.device(slotIdHex: slotIdHex)?.label ?? ""
        }
        // Removed meanwhile, here or from another device: go back to the list rather than leave
        // the reader on a sheet about a device that's gone.
        .onChange(of: model.device(slotIdHex: slotIdHex) == nil) { _, isGone in
            if isGone { dismiss() }
        }
    }
}

private struct LinkedDeviceSheetContent: View {
    let model: DeviceLinkingViewModel
    let device: LinkedDeviceFfi
    @Binding var label: String

    var body: some View {
        let busy = model.isBusy(.device(slotIdHex: device.slotIdHex))
        Text(DeviceLinkPresentation.name(of: device))
            .wnFont(.semiBold16)

        HStack(alignment: .bottom, spacing: 8) {
            WNInput(
                label: L10n.string("Device Name"),
                prompt: L10n.string("e.g. iPhone"),
                text: $label,
                validationMessage: label.utf8.count > DeviceLinkPresentation.maxLabelBytes
                    ? L10n.string("That name is too long.") : nil
            )
            Button(L10n.string("Save")) {
                Task { await model.rename(slotIdHex: device.slotIdHex, label: label) }
            }
            .buttonStyle(.wnSecondary)
            .disabled(
                busy || label == device.label
                    || label.trimmingCharacters(in: .whitespacesAndNewlines).utf8.count
                        > DeviceLinkPresentation.maxLabelBytes
            )
        }

        VStack(alignment: .leading, spacing: 10) {
            LinkedDeviceToggle(
                title: L10n.string("Add to all my chats"),
                detail: L10n.string("Your other devices add it to the chats you’re in."),
                isOn: device.addToAllChats, isDisabled: busy
            ) { value in
                Task { await model.update(slotIdHex: device.slotIdHex, addToAllChats: value) }
            }
            LinkedDeviceToggle(
                title: L10n.string("Bring chat history"),
                detail: L10n.string("Your other devices send it history when they add it to a chat."),
                isOn: device.bringHistory, isDisabled: busy
            ) { value in
                Task { await model.update(slotIdHex: device.slotIdHex, bringHistory: value) }
            }
            LinkedDeviceToggle(
                title: L10n.string("Keep while inactive"),
                detail: L10n.string("It isn’t removed automatically after 90 days without activity."),
                isOn: device.keepWhileInactive, isDisabled: busy
            ) { value in
                Task { await model.update(slotIdHex: device.slotIdHex, keepWhileInactive: value) }
            }
        }

        VStack(alignment: .leading, spacing: 4) {
            if !device.client.isEmpty || !device.platform.isEmpty {
                SettingsValueRow(
                    title: L10n.string("App"),
                    value: [device.platform, device.client].filter { !$0.isEmpty }.joined(separator: " · "))
            }
            SettingsValueRow(
                title: L10n.string("Linked"),
                value: Date(timeIntervalSince1970: TimeInterval(device.linkedAt))
                    .formatted(date: .abbreviated, time: .shortened))
            if let linker = model.device(slotIdHex: device.linkedBySlotIdHex) {
                SettingsValueRow(title: L10n.string("Linked by"), value: DeviceLinkPresentation.name(of: linker))
            }
            if let status = DeviceLinkPresentation.status(of: device) {
                SettingsValueRow(title: L10n.string("Status"), value: status)
            }
        }
    }
}

private struct LinkedDeviceToggle: View {
    let title: String
    let detail: String
    let isOn: Bool
    let isDisabled: Bool
    let onChange: (Bool) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            WNToggle(title, isOn: Binding(get: { isOn }, set: onChange))
                .disabled(isDisabled)
            Text(detail)
                .wnFont(.medium12)
                .foregroundStyle(WNColor.backgroundContentSecondary)
        }
    }
}

// MARK: - Previews

private let previewDevices: [LinkedDeviceFfi] = [
    LinkedDeviceFfi(
        slotIdHex: String(repeating: "a", count: 64), isThisDevice: true, label: "Studio Mac", client: "whitenoise",
        platform: "macOS", linkedAt: 1_760_000_000, linkedBySlotIdHex: nil, status: .active, addToAllChats: true,
        bringHistory: true, keepWhileInactive: false, lastActiveAt: nil, inactive: false, removalPending: false),
    LinkedDeviceFfi(
        slotIdHex: String(repeating: "b", count: 64), isThisDevice: false, label: "iPhone", client: "whitenoise",
        platform: "iOS", linkedAt: 1_760_100_000, linkedBySlotIdHex: String(repeating: "a", count: 64),
        status: .inactive, addToAllChats: true, bringHistory: false, keepWhileInactive: false,
        lastActiveAt: 1_760_200_000, inactive: true, removalPending: false),
]

#Preview("Devices") {
    DevicesSettingsView(
        model: .preview(
            devices: previewDevices,
            signIns: [
                UnrecognizedSignInFfi(
                    slotIdHex: String(repeating: "c", count: 64), client: "amethyst", appearedAt: 1_760_300_000,
                    lastSeenAt: 1_760_300_000, beforeThisDevice: false, signedIn: true, state: .prompt,
                    linkedBySlotIdHex: nil, previouslyLinkedHere: false)
            ]
        )
    )
    .environment(WorkspaceState.preview())
    .frame(width: 760, height: 720)
}

#Preview("Device") {
    LinkedDeviceSheet(model: .preview(devices: previewDevices), slotIdHex: String(repeating: "b", count: 64))
}
