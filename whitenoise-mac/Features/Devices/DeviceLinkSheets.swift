import MarmotKit
import SwiftUI

extension View {
    /// Hosts the account's device-linking sheet: this Mac's own link, or another device's request.
    /// Hosted once, in `ContentView`, because a request can arrive whatever the user is looking at.
    /// `suggestionAllowed` is whether this device has just finished setup. The "Signed in on another
    /// device?" suggestion waits for that, and is never offered on a device that was already set up:
    /// only the new device can start a link, and on an established device's first check every other
    /// installation looks like an earlier sign-in.
    func deviceLinkSheet(_ model: DeviceLinkingViewModel?, locale: Locale, suggestionAllowed: Bool) -> some View {
        modifier(DeviceLinkSheetHost(model: model, locale: locale, suggestionAllowed: suggestionAllowed))
    }
}

private struct DeviceLinkSheetHost: ViewModifier {
    let model: DeviceLinkingViewModel?
    let locale: Locale
    let suggestionAllowed: Bool

    func body(content: Content) -> some View {
        let suggest = suggestionAllowed && model?.suggestsLinking == true
        return content.task(id: suggest) {
            if suggest { model?.presentLinkSuggestionIfNeeded() }
        }
        .sheet(
            item: Binding(
                get: { model?.presentedSheet },
                set: { next in
                    if next == nil { model?.closeSheet() }
                }
            )
        ) { sheet in
            if let model {
                Group {
                    switch sheet {
                    case .newDevice:
                        NewDeviceLinkSheet(model: model)
                    case .linkSuggestion:
                        DeviceLinkSuggestionSheet(model: model)
                    case .addNewDevice:
                        AddNewDeviceSheet(model: model)
                    case .prompt(let id):
                        DeviceLinkPromptSheet(model: model, promptId: id)
                    }
                }
                // A sheet is its own presentation and does not inherit the root's locale.
                .environment(\.locale, locale)
            }
        }
    }
}

// MARK: - This Mac asks to be linked

/// The new device's side: wait for a device already signed in, compare the emoji, confirm.
struct NewDeviceLinkSheet: View {
    let model: DeviceLinkingViewModel

    var body: some View {
        let state = model.snapshot.newDevice
        DeviceLinkSheetFrame(
            title: state.map(DeviceLinkPresentation.title(for:)) ?? L10n.string("Link to Another Device"),
            message: state.map(DeviceLinkPresentation.message(for:))
                ?? L10n.string("Asking your other devices to link this Mac…"),
            error: model.actionError
        ) {
            switch state {
            case .comparing(let code):
                DeviceLinkCodeView(code: code)
            case .waitingForAnswer, .waitingForOtherDevice, .joining, nil:
                DeviceLinkProgressRow()
            case .linked:
                // The device that approved this one named it however it liked ("New Device" on
                // iOS); this is where its own user names it.
                NameThisMacField(model: model)
            case .ended:
                EmptyView()
            }
        } footer: {
            NewDeviceLinkFooter(model: model, state: state)
        }
        .interactiveDismissDisabled(state.map(DeviceLinkPresentation.isActive) ?? true)
    }
}

private struct NewDeviceLinkFooter: View {
    let model: DeviceLinkingViewModel
    let state: NewDeviceLinkStateFfi?

    var body: some View {
        switch state {
        case .comparing:
            Button(L10n.string("They Don’t Match")) {
                Task { await model.cancelLink() }
            }
            .buttonStyle(.wnSecondary)
            .disabled(model.isBusy(.cancelLink))
            WNPrimaryButton(L10n.string("They Match"), systemImage: "checkmark") {
                Task { await model.confirmMatch() }
            }
            .disabled(model.isBusy(.confirmMatch))
        case .waitingForAnswer, .waitingForOtherDevice, .joining:
            Button(L10n.string("Cancel Linking")) {
                Task { await model.cancelLink() }
            }
            .buttonStyle(.wnSecondary)
            .disabled(model.isBusy(.cancelLink))
        case .ended:
            Button(L10n.string("Done")) { model.closeSheet() }
                .buttonStyle(.wnSecondary)
            WNPrimaryButton(L10n.string("Try Again"), systemImage: "arrow.clockwise") {
                Task { await model.startLink() }
            }
            .disabled(model.isBusy(.startLink))
        case .linked:
            WNPrimaryButton(L10n.string("Done"), systemImage: "checkmark") { model.closeSheet() }
        case nil:
            // Before the first answer, or after `startDeviceLink` was refused.
            Button(L10n.string("Close")) { model.closeSheet() }
                .buttonStyle(.wnSecondary)
            if model.actionError != nil {
                WNPrimaryButton(L10n.string("Try Again"), systemImage: "arrow.clockwise") {
                    Task { await model.startLink() }
                }
                .disabled(model.isBusy(.startLink))
            }
        }
    }
}

// MARK: - Suggesting a link after sign-in

/// After signing in on this Mac, when the profile is already signed in on a device from before it:
/// the moment Signal and Element ask whether to link. Linking is what brings the chats over.
struct DeviceLinkSuggestionSheet: View {
    let model: DeviceLinkingViewModel

    var body: some View {
        DeviceLinkSheetFrame(
            title: L10n.string("Signed In on Another Device?"),
            message: L10n.string(
                "This profile is also signed in on another device. Link this Mac to it to keep them in sync."
            ),
            error: model.actionError
        ) {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(model.earlierSignIns, id: \.slotIdHex) { signIn in
                    Label(
                        [
                            signIn.client.isEmpty
                                ? L10n.string("Unknown app") : DeviceLinkPresentation.clientName(signIn.client),
                            DeviceLinkPresentation.message(for: signIn),
                        ].joined(separator: " · "),
                        systemImage: "iphone"
                    )
                    .foregroundStyle(WNColor.backgroundContentSecondary)
                }
            }
        } footer: {
            Button(L10n.string("Not Now")) { model.closeSheet() }
                .buttonStyle(.wnSecondary)
            WNPrimaryButton(L10n.string("Link This Mac"), systemImage: "link") {
                Task { await model.startLink() }
            }
            .disabled(model.isBusy(.startLink))
        }
    }
}

// MARK: - Adding a new device from this one

/// This Mac is the device already set up. MDK lets only the new device start a link, so this says
/// how and waits; the request's own sheet replaces this one when it arrives.
struct AddNewDeviceSheet: View {
    let model: DeviceLinkingViewModel

    var body: some View {
        DeviceLinkSheetFrame(
            title: L10n.string("Add a New Device"),
            message: L10n.string("Linking starts on the new device. Keep White Noise open here while you do this."),
            error: nil
        ) {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(AddNewDeviceSheet.steps.enumerated()), id: \.offset) { index, step in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(verbatim: "\(index + 1).")
                            .foregroundStyle(WNColor.backgroundContentSecondary)
                            .monospacedDigit()
                        Text(step)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(L10n.string("Waiting for a request…"))
                    .foregroundStyle(WNColor.backgroundContentSecondary)
            }
        } footer: {
            Button(L10n.string("Close")) { model.closeSheet() }
                .buttonStyle(.wnSecondary)
        }
    }

    private static var steps: [String] {
        [
            L10n.string("On the new device, sign in to this profile with its private key."),
            L10n.string("Open Settings → Devices there and choose Link to Another Device."),
            L10n.string("The request appears here. Check that both screens show the same emoji."),
        ]
    }
}

// MARK: - Another device asks this Mac

/// A device already signed in answering a new sign-in: compare, name it, choose what it gets, link.
struct DeviceLinkPromptSheet: View {
    let model: DeviceLinkingViewModel
    let promptId: String

    @State private var label = ""
    @State private var addToAllChats = true
    @State private var bringHistory = true
    /// This Mac's own name, asked for only while it has none: the first link makes its roster
    /// entry, and an unnamed one would read as unnamed on every other device.
    @State private var thisDeviceLabel = L10n.string("Mac")

    var body: some View {
        if let prompt = model.prompt(id: promptId) {
            DeviceLinkSheetFrame(
                title: DeviceLinkPresentation.title(for: prompt.state),
                message: DeviceLinkPresentation.message(for: prompt.state),
                error: model.actionError
            ) {
                switch prompt.state {
                case .comparing(let code):
                    DeviceLinkCodeView(code: code)
                    DeviceLinkPromptOptions(
                        label: $label,
                        addToAllChats: $addToAllChats,
                        bringHistory: $bringHistory
                    )
                    if model.thisDeviceNeedsName {
                        DeviceLabelField(title: L10n.string("This Mac’s Name"), label: $thisDeviceLabel)
                    }
                case .preparing, .linking:
                    DeviceLinkProgressRow()
                default:
                    EmptyView()
                }
            } footer: {
                DeviceLinkPromptFooter(
                    model: model,
                    prompt: prompt,
                    canLink: DeviceLinkPresentation.isValidLabel(label)
                        && (!model.thisDeviceNeedsName || DeviceLinkPresentation.isValidLabel(thisDeviceLabel)),
                    onLink: {
                        let ownName = model.thisDeviceNeedsName ? thisDeviceLabel : nil
                        Task {
                            await model.link(
                                promptId: promptId, label: label, addToAllChats: addToAllChats,
                                bringHistory: bringHistory, thisDeviceLabel: ownName)
                        }
                    }
                )
            }
            // Escape would leave the new device waiting with no answer: Not Now is the way out.
            .interactiveDismissDisabled(DeviceLinkPresentation.needsAttention(prompt.state))
        } else {
            DeviceLinkSheetFrame(
                title: L10n.string("Linking Stopped"),
                message: L10n.string("That link request has expired."),
                error: nil
            ) {
                EmptyView()
            } footer: {
                WNPrimaryButton(L10n.string("Done"), systemImage: "checkmark") { model.closeSheet() }
            }
        }
    }
}

/// A device name field with MDK's limit: not blank, at most 64 bytes.
private struct DeviceLabelField: View {
    let title: String
    @Binding var label: String

    var body: some View {
        WNInput(
            label: title,
            prompt: L10n.string("Mac"),
            text: $label,
            validationMessage: label.utf8.count > DeviceLinkPresentation.maxLabelBytes
                ? L10n.string("That name is too long.") : nil
        )
    }
}

/// On the new device once linked: its own name, prefilled with what the roster says or "Mac".
private struct NameThisMacField: View {
    let model: DeviceLinkingViewModel
    @State private var label = ""

    var body: some View {
        let current = model.thisDevice?.label ?? ""
        HStack(alignment: .bottom, spacing: 8) {
            DeviceLabelField(title: L10n.string("Name This Mac"), label: $label)
            Button(L10n.string("Save")) {
                model.saveThisDeviceName(label)
            }
            .buttonStyle(.wnSecondary)
            .disabled(!DeviceLinkPresentation.isValidLabel(label) || label == current)
        }
        .onAppear {
            // iOS names a device it approves "New Device"; that default is not a name to keep.
            label = current.isEmpty || current == "New Device" ? L10n.string("Mac") : current
        }
    }
}

private struct DeviceLinkPromptOptions: View {
    @Binding var label: String
    @Binding var addToAllChats: Bool
    @Binding var bringHistory: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            WNInput(
                label: L10n.string("Device Name"),
                prompt: L10n.string("e.g. iPhone"),
                text: $label,
                validationMessage: label.utf8.count > DeviceLinkPresentation.maxLabelBytes
                    ? L10n.string("That name is too long.") : nil,
                focusOnAppear: true
            )
            WNToggle(L10n.string("Add to all my chats"), isOn: $addToAllChats)
            WNToggle(L10n.string("Bring chat history"), isOn: $bringHistory)
        }
    }
}

private struct DeviceLinkPromptFooter: View {
    let model: DeviceLinkingViewModel
    let prompt: DeviceLinkPromptFfi
    let canLink: Bool
    let onLink: () -> Void

    var body: some View {
        let declineAction = DeviceLinkingViewModel.Action.decline(promptId: prompt.promptId)
        switch prompt.state {
        case .comparing:
            Button(L10n.string("Not Now")) {
                Task { await model.decline(promptId: prompt.promptId) }
            }
            .buttonStyle(.wnSecondary)
            .disabled(model.isBusy(declineAction))
            WNPrimaryButton(L10n.string("Link Device"), systemImage: "link") { onLink() }
                .disabled(!canLink || model.isBusy(.link(promptId: prompt.promptId)))
        case .preparing, .competingRequests, .rateLimited, .cannotLink, .tooManyDevices:
            Button(L10n.string("Not Now")) {
                Task { await model.decline(promptId: prompt.promptId) }
            }
            .buttonStyle(.wnSecondary)
            .disabled(model.isBusy(declineAction))
        case .linking:
            Button(L10n.string("Close")) { model.closePrompt(prompt.promptId) }
                .buttonStyle(.wnSecondary)
        case .linked, .addedElsewhere, .ended:
            WNPrimaryButton(L10n.string("Done"), systemImage: "checkmark") { model.closePrompt(prompt.promptId) }
        }
    }
}

// MARK: - Shared pieces

/// The seven emoji both screens show. Users compare the pictures; each one's English description is
/// for screen readers only, as MDK asks.
struct DeviceLinkCodeView: View {
    let code: [DeviceLinkEmojiFfi]

    var body: some View {
        // Four over three, the shape `whitenoise-ios` draws, so both screens read alike and the order
        // is easy to compare line by line.
        VStack(spacing: 16) {
            DeviceLinkCodeRow(items: Array(code.prefix(4)), offset: 0, total: code.count)
            if code.count > 4 {
                DeviceLinkCodeRow(items: Array(code.dropFirst(4)), offset: 4, total: code.count)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(L10n.string("Emoji to compare"))
    }
}

/// One line of the code: each emoji over MDK's description of it, which is also what VoiceOver says.
private struct DeviceLinkCodeRow: View {
    let items: [DeviceLinkEmojiFfi]
    let offset: Int
    let total: Int

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                VStack(spacing: 4) {
                    Text(verbatim: item.emoji)
                        .font(.system(size: 40))
                    Text(verbatim: item.description)
                        .font(.caption)
                        .foregroundStyle(WNColor.backgroundContentSecondary)
                        .multilineTextAlignment(.center)
                        .lineLimit(2)
                        .minimumScaleFactor(0.8)
                }
                .frame(width: 68)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Text(verbatim: item.description))
                .accessibilityValue(
                    Text(verbatim: String(format: L10n.string("%lld of %lld"), Int64(offset + index + 1), Int64(total)))
                )
            }
        }
    }
}

private struct DeviceLinkProgressRow: View {
    var body: some View {
        ProgressView()
            .controlSize(.small)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
    }
}

/// The chrome every linking sheet shares: title, explanation, content, an error line, a footer.
private struct DeviceLinkSheetFrame<Content: View, Footer: View>: View {
    let title: String
    let message: String
    let error: String?
    @ViewBuilder let content: Content
    @ViewBuilder let footer: Footer

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text(title)
                    .wnFont(.semiBold16)
                Text(message)
                    .foregroundStyle(WNColor.backgroundContentSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            content

            if let error {
                Text(error)
                    .wnFont(.medium12)
                    .foregroundStyle(WNColor.backgroundContentDestructive)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 8) {
                Spacer(minLength: 0)
                footer
            }
        }
        .padding(20)
        .frame(width: 440)
        .fixedSize(horizontal: false, vertical: true)
        .wnButtonShape(.capsule)
    }
}

// MARK: - Previews

private let previewCode: [DeviceLinkEmojiFfi] = [
    ("🐶", "dog"), ("🔑", "key"), ("🌵", "cactus"), ("🚲", "bicycle"), ("🎸", "guitar"), ("🍋", "lemon"),
    ("⚓️", "anchor"),
].map { DeviceLinkEmojiFfi(emoji: $0.0, description: $0.1) }

#Preview("New device: comparing") {
    NewDeviceLinkSheet(
        model: .preview(
            snapshot: DeviceLinkSnapshotFfi(
                newDevice: .comparing(code: previewCode), prompts: [], moves: [], deviceGroupStalled: false)
        )
    )
}

#Preview("Link suggestion") {
    DeviceLinkSuggestionSheet(
        model: .preview(signIns: [
            UnrecognizedSignInFfi(
                slotIdHex: String(repeating: "a", count: 64), client: "whitenoise", appearedAt: 1_760_000_000,
                lastSeenAt: 1_763_000_000, beforeThisDevice: true, signedIn: true, state: .prompt,
                linkedBySlotIdHex: nil, previouslyLinkedHere: false)
        ])
    )
}

#Preview("Add a new device") {
    AddNewDeviceSheet(model: .preview())
}

#Preview("Prompt: comparing") {
    DeviceLinkPromptSheet(
        model: .preview(
            snapshot: DeviceLinkSnapshotFfi(
                newDevice: nil,
                prompts: [
                    DeviceLinkPromptFfi(
                        promptId: "p1", slotIdHex: nil, requestedAt: 1_700_000_000,
                        state: .comparing(code: previewCode))
                ],
                moves: [],
                deviceGroupStalled: false
            )
        ),
        promptId: "p1"
    )
}
