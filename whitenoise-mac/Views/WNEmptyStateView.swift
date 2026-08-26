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
        VStack(spacing: 10) {
            Image(systemName: systemImage)
                .wnFont(.medium28)
                .foregroundStyle(WNColor.backgroundContentTertiary)

            VStack(spacing: 3) {
                Text(title)
                    .wnFont(.semiBold14)
                    .foregroundStyle(WNColor.backgroundContentPrimary)

                if let description {
                    Text(description)
                        .wnFont(.medium12)
                        .foregroundStyle(WNColor.backgroundContentSecondary)
                }
            }
            .multilineTextAlignment(.center)
        }
        // Every title and detail line in the catalog fits on one line at this width in
        // all ten languages — the longest measures 199pt ("Nenhuma conversa arquivada")
        // — while the detail pane, several times wider, is kept from stretching two
        // short lines into one long rule. A rail narrower than this proposes its own
        // width instead, and the text wraps as it did before.
        .frame(maxWidth: 240)
        .padding(.horizontal, 16)
        .accessibilityElement(children: .combine)
    }
}
