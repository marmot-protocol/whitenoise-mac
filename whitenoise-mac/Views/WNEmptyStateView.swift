//
//  WNEmptyStateView.swift
//  whitenoise-mac
//
//  The quiet notice a pane shows when it has nothing to list: a glyph, a line
//  of title, and an optional line of detail.
//
//  It exists because `ContentUnavailableView` is drawn for a full iPhone screen
//  — a ~50pt glyph over a title in the `.title2` range — and the panes that use
//  it here are a narrow chat rail and a detail pane that already carries a
//  toolbar. At that scale the notice reads as an error rather than as an empty
//  shelf. This one is set on the app's own ramp, several rungs down, so it sits
//  in the space it is given instead of filling it.
//

import SwiftUI

struct WNEmptyStateView: View {
    let title: String
    var description: String?
    let systemImage: String

    var body: some View {
        ContentUnavailableView {
            Label(title, systemImage: systemImage)
        } description: {
            if let description {
                Text(description)
            }
        }
        .controlSize(.small)
        .frame(maxWidth: 280)
        .accessibilityElement(children: .combine)
    }
}

#Preview("Empty state") {
    WNEmptyStateView(
        title: L10n.string("No chats yet"),
        description: L10n.string("Start a conversation"),
        systemImage: "bubble.left.and.bubble.right"
    )
    .frame(width: 320, height: 220)
}
