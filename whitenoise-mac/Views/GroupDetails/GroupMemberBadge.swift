//
//  GroupMemberBadge.swift
//  whitenoise-mac
//
//  The "You" and "Admin" capsules beside a name in the group roster.
//

import SwiftUI

/// A small monochrome capsule beside a member's name (`You` / `Admin`, F01, inspector mockup).
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
            case .admin: .secondary
            case .you: .secondary
            }
        }

        var background: Color {
            switch self {
            case .admin: Color(nsColor: .quaternarySystemFill)
            case .you: .clear
            }
        }

        var border: Color {
            switch self {
            case .admin: Color(nsColor: .separatorColor).opacity(0.6)
            case .you: Color(nsColor: .separatorColor)
            }
        }
    }

    let kind: Kind

    var body: some View {
        Text(kind.title)
            .font(.caption.weight(.medium))
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
