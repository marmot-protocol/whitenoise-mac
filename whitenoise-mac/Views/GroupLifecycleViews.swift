//
//  GroupLifecycleViews.swift
//  whitenoise-mac
//
//  How a group that is being ended, or has ended, reads outside its inspector: in place of the
//  composer, and (while it is ending) as a capsule on its sidebar row.
//

import SwiftUI

/// Replaces the composer while a group is ending and after it has ended. The core blocks every
/// send in both states, so no input is offered; the transcript stays readable.
struct GroupLifecycleComposerNotice: View {
    let lifecycle: GroupLifecycle

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: lifecycle.symbolName ?? "")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)

            Text(lifecycle.composerNotice ?? "")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(WNColor.backgroundPrimary, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(WNColor.borderTertiary, lineWidth: 1)
        }
        .accessibilityIdentifier("composer.groupLifecycle")
    }
}

/// "Ending" capsule on a sidebar row, in the same shape as the leave capsule. An ended group wears
/// none: its row's preview line says "Group ended" instead.
struct GroupLifecycleBadge: View {
    let lifecycle: GroupLifecycle

    var body: some View {
        Label(lifecycle.sidebarBadgeLabel ?? "", systemImage: lifecycle.symbolName ?? "")
            .font(.caption2.weight(.semibold))
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
        GroupLifecycleComposerNotice(lifecycle: .ending)
        GroupLifecycleComposerNotice(lifecycle: .ended)
    }
    .padding()
    .frame(width: 480)
}

#Preview("Sidebar badge") {
    GroupLifecycleBadge(lifecycle: .ending)
        .padding()
}
