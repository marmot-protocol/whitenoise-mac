//
//  GroupDetailsQuickAction.swift
//  whitenoise-mac
//
//  One button of group info's quick-action row: a round glyph over a short caption. Ported
//  from the iOS client's `DetailsQuickAction`.
//

import SwiftUI

/// A round icon button with its caption underneath, the shape iOS gives Mute, Disappearing and
/// the other actions under a conversation's name.
///
/// The disc is `MessagesCircleControlBackground` — the `outline` icon button the composer and
/// the account rail already draw — so these read as the same family of control, at a size that
/// suits a primary action. The whole column, caption included, is the click target.
struct GroupDetailsQuickAction: View {
    let title: String
    let systemImage: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
        }
        .buttonStyle(GroupDetailsQuickActionStyle())
        .help(title)
    }
}

private struct GroupDetailsQuickActionStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        VStack(spacing: 6) {
            configuration.label
                .labelStyle(.iconOnly)
                .wnFont(.semiBold14)
                .foregroundStyle(WNColor.fillContentSecondary)
                .frame(
                    width: MessagesLayout.groupDetailsQuickActionSize,
                    height: MessagesLayout.groupDetailsQuickActionSize
                )
                .background { MessagesCircleControlBackground(isSelected: configuration.isPressed) }

            configuration.label
                .labelStyle(.titleOnly)
                .wnFont(.medium12)
                .foregroundStyle(WNColor.backgroundContentPrimary)
                .lineLimit(1)
                .accessibilityHidden(true)
        }
        .frame(minWidth: 72)
        .contentShape(.rect)
        .opacity(isEnabled ? 1 : 0.45)
    }
}

#Preview {
    HStack(spacing: 12) {
        GroupDetailsQuickAction(title: "Mute", systemImage: "bell.slash") {}
        GroupDetailsQuickAction(title: "Disappearing", systemImage: "timer") {}
        GroupDetailsQuickAction(title: "Add", systemImage: "person.badge.plus") {}
            .disabled(true)
    }
    .padding()
}
