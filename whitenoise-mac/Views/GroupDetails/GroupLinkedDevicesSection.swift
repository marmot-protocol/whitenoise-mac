import MarmotKit
import SwiftUI

/// Group details' nudge to let each member's own linked devices join this chat. Shown only while MDK
/// answers `eligible` (to an admin, when every device in the chat supports it) and nothing in any
/// other state: there is no on/off control, because turning it on can't be undone. Matches
/// `whitenoise-ios`'s "Linked Devices Are Ready".
struct GroupLinkedDevicesSection: View {
    let model: GroupAccountDevicesViewModel
    @State private var confirming = false

    var body: some View {
        if model.isAvailable, model.activation == .eligible {
            Section {
                Button {
                    confirming = true
                } label: {
                    SettingsBusyLabel(
                        title: L10n.string("Turn On Linked Devices"),
                        systemImage: "laptopcomputer.and.iphone",
                        isBusy: model.isEnabling
                    )
                }
                .disabled(model.isEnabling)
                if let error = model.error {
                    Text(error)
                        .font(.callout)
                        .foregroundStyle(WNColor.backgroundContentDestructive)
                }
            } header: {
                Text(L10n.string("Linked Devices Are Ready"))
            } footer: {
                Text(L10n.string("Lets each member’s own linked devices join this chat without an admin."))
            }
            .confirmationDialog(L10n.string("Turn on linked devices for this chat?"), isPresented: $confirming) {
                Button(L10n.string("Turn On")) {
                    Task { await model.enable() }
                }
            } message: {
                Text(
                    L10n.string(
                        "Each member’s own linked devices can then join this chat without an admin. This can’t be turned off."
                    ))
            }
        }
    }
}

#Preview {
    Form {
        GroupLinkedDevicesSection(model: .preview(.eligible))
        // Every other state draws nothing.
        GroupLinkedDevicesSection(model: .preview(.alreadyEnabled))
    }
    .formStyle(.grouped)
    .frame(width: 480, height: 240)
}
