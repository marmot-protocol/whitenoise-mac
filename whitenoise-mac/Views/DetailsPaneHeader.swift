//
//  DetailsPaneHeader.swift
//  whitenoise-mac
//

import SwiftUI

/// The header both slide-in detail panes wear: back, avatar, title, then whatever the pane adds at
/// its trailing edge.
///
/// One struct rather than two hand-matched copies, because the order is the part that matters and
/// the copies had already begun to disagree about it. The panes slide in over the transcript, so the
/// chevron is a **back** control and belongs on the leading edge — where the compose pane and the
/// settings header already put theirs — not trailing next to an add-members button, which reads as
/// an unrelated right-hand action. Written once, that order is no longer something either pane can
/// drift away from.
struct DetailsPaneHeader<Subtitle: View, Actions: View>: View {
    let backHelp: String
    let onBack: () -> Void
    let avatarSeed: String
    let avatarInitials: String
    let avatarURL: URL?
    var avatarImagePayload: DownloadedMediaPayload?
    let title: String
    @ViewBuilder let subtitle: Subtitle
    @ViewBuilder let actions: Actions

    /// The avatar's diameter, and with it the header's own height floor.
    static var avatarSize: CGFloat { 48 }

    var body: some View {
        HStack(spacing: 12) {
            GlassCircleCloseButton(symbol: "chevron.backward", help: backHelp, appearance: .outline) {
                onBack()
            }

            ProfileImageAvatarView(
                seed: avatarSeed,
                initials: avatarInitials,
                sanitizedPictureURL: avatarURL,
                localImagePayload: avatarImagePayload,
                size: Self.avatarSize,
                isSelected: false
            )

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .wnFont(.semiBold16)
                    .lineLimit(1)
                subtitle
            }

            Spacer()

            actions
        }
        .padding(20)
    }
}
