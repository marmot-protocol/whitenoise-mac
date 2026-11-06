//
//  GroupLifecycleViews.swift
//  whitenoise-mac
//
//  How a group that is being ended, or has ended, reads outside its inspector: in place of the
//  composer, and as a capsule on its sidebar row.
//

import SwiftUI

/// Replaces the composer while a group is ending and after it has ended. The core blocks every
/// send in both states, so no input is offered; the transcript stays readable.
struct GroupLifecycleComposerNotice: View {
    let lifecycle: GroupLifecycle
    let message: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: lifecycle.symbolName ?? "")
                .wnFont(.semiBold14)
                .foregroundStyle(WNColor.backgroundContentSecondary)

            Text(message)
                .wnFont(.semiBold12)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .glassCard()
        .accessibilityIdentifier("composer.groupLifecycle")
    }
}

/// "Ending" / "Ended" capsule on a sidebar row, in the same shape as the leave and membership
/// capsules beside it.
struct GroupLifecycleBadge: View {
    let lifecycle: GroupLifecycle

    var body: some View {
        Label(lifecycle.sidebarBadgeLabel ?? "", systemImage: lifecycle.symbolName ?? "")
            .wnFont(.semiBold10)
            .labelStyle(.titleAndIcon)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .foregroundStyle(WNColor.fillContentTertiary)
            .background(WNColor.fillSecondary, in: Capsule())
            .overlay(Capsule().strokeBorder(WNColor.borderTertiary, lineWidth: 1))
            .help(lifecycle.composerNotice ?? "")
    }
}

#Preview("Composer notice") {
    VStack(spacing: 12) {
        GroupLifecycleComposerNotice(lifecycle: .ending, message: GroupLifecycle.ending.composerNotice ?? "")
        GroupLifecycleComposerNotice(lifecycle: .ended, message: GroupLifecycle.ended.composerNotice ?? "")
    }
    .padding()
    .frame(width: 480)
}

#Preview("Sidebar badge") {
    HStack {
        GroupLifecycleBadge(lifecycle: .ending)
        GroupLifecycleBadge(lifecycle: .ended)
    }
    .padding()
}
