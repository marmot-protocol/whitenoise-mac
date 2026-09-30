//
//  GroupMemberBadge.swift
//  whitenoise-mac
//
//  The "You" and "Admin" capsules beside a name in the group roster.
//

import SwiftUI

/// A small capsule beside a member's name. Admin is the one role that changes what someone can
/// do in the group, so it takes the palette's warning pair, as iOS tints it orange; "You" is
/// only orientation and stays neutral — outlined rather than filled, because every neutral fill
/// one step off the surface resolves to the roster card's own `neutral100` in Light and vanishes.
struct GroupMemberBadge: View {
    enum Kind {
        case admin
        case you

        var title: String {
            switch self {
            case .admin: L10n.string("Admin")
            case .you: L10n.string("You")
            }
        }

        var content: Color {
            switch self {
            case .admin: WNColor.intentionWarningContent
            case .you: WNColor.fillContentSecondary
            }
        }

        var background: Color {
            switch self {
            case .admin: WNColor.intentionWarningBackground
            case .you: .clear
            }
        }

        var border: Color {
            switch self {
            case .admin: .clear
            case .you: WNColor.borderSecondary
            }
        }
    }

    let kind: Kind

    var body: some View {
        Text(kind.title)
            .wnFont(.semiBold10)
            .foregroundStyle(kind.content)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(kind.background, in: .capsule)
            .overlay { Capsule().strokeBorder(kind.border, lineWidth: 1) }
    }
}

#Preview {
    HStack {
        GroupMemberBadge(kind: .you)
        GroupMemberBadge(kind: .admin)
    }
    .padding()
}
