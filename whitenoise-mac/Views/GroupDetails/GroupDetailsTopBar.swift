//
//  GroupDetailsTopBar.swift
//  whitenoise-mac
//
//  The strip above group info: back on the leading edge, the page's name centred, and Edit on
//  the trailing edge for whoever may edit the group.
//

import SwiftUI

/// Group info's title bar — and a contact profile's — in the shape of the iOS navigation bar it
/// replaces.
///
/// Both corner controls are `GlassCircleCloseButton` in its outline form — the app's one back
/// control, and the same disc for Edit — so the corners weigh the same. When there is no Edit,
/// the trailing corner reserves the control's width anyway, which keeps the title centred in the
/// pane rather than in whatever space the back button left.
struct GroupDetailsTopBar: View {
    let title: String
    var isLoading = false
    /// Where the chevron returns to, as a catalog key. A contact's profile can open over group
    /// info as well as over the chat, and the shared-media library is pushed inside group info,
    /// so both say "Back" rather than naming either.
    var backHelp = "Back to chat"
    let onBack: () -> Void
    /// `nil` when the reader may not edit the group.
    let onEdit: (() -> Void)?

    var body: some View {
        HStack(spacing: 12) {
            // Leading, like the compose pane and the settings header: this pane slides in over
            // the transcript, so the chevron is a back control and reads as one only on the side
            // you came from.
            GlassCircleCloseButton(
                symbol: "chevron.backward", help: backHelp, appearance: .outline, action: onBack)

            Spacer(minLength: 0)

            HStack(spacing: 8) {
                Text(title)
                    .wnFont(.semiBold14)
                    .foregroundStyle(WNColor.backgroundContentPrimary)
                    .lineLimit(1)
                if isLoading {
                    ProgressView()
                        .controlSize(.small)
                }
            }

            Spacer(minLength: 0)

            if let onEdit {
                GlassCircleCloseButton(symbol: "pencil", help: "Edit Group Info", appearance: .outline, action: onEdit)
            } else {
                Color.clear
                    .frame(width: MessagesLayout.circleControlSize, height: MessagesLayout.circleControlSize)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }
}

#Preview("Admin") {
    GroupDetailsTopBar(title: "Group Info", onBack: {}, onEdit: {})
        .frame(width: 520)
}

#Preview("Member, loading") {
    GroupDetailsTopBar(title: "Group Info", isLoading: true, onBack: {}, onEdit: nil)
        .frame(width: 520)
}
