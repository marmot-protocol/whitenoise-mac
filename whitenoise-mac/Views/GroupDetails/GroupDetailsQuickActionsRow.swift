//
//  GroupDetailsQuickActionsRow.swift
//  whitenoise-mac
//
//  Compact native quick actions under the inspector identity header (S05, G05, #1042):
//  one mute route (using the shared mute options) and in-conversation search, without
//  oversized phone-style circle tiles or duplicated retention/add controls.
//

import SwiftUI

struct GroupDetailsQuickActionsRow: View {
    @Environment(WorkspaceState.self) private var workspace
    @Environment(\.locale) private var locale
    let chat: ChatItem
    var onSearchInChat: (() -> Void)? = nil

    var body: some View {
        HStack(spacing: 8) {
            if chat.muted {
                Button {
                    Task { await workspace.clearChatMuted(chat) }
                } label: {
                    Label(L10n.string("Unmute", locale: locale), systemImage: "bell")
                }
                .wnSecondaryButtonStyle()
                .disabled(workspace.isMutatingChatPreferences(chat))
                .accessibilityIdentifier("inspector.action.mute")
            } else {
                Menu {
                    ForEach(ChatMuteDuration.allCases) { duration in
                        Button {
                            Task { await workspace.setChatMuted(chat, duration: duration.interval) }
                        } label: {
                            Label(L10n.string(duration.titleKey, locale: locale), systemImage: duration.systemImage)
                        }
                    }
                } label: {
                    Label(L10n.string("Mute", locale: locale), systemImage: "bell.slash")
                }
                .menuStyle(.borderedButton)
                .fixedSize()
                .disabled(workspace.isMutatingChatPreferences(chat))
                .accessibilityIdentifier("inspector.action.mute")
            }

            if let onSearchInChat {
                Button(action: onSearchInChat) {
                    Label(L10n.string("Search", locale: locale), systemImage: "magnifyingglass")
                }
                .wnSecondaryButtonStyle()
                .help(L10n.string("Find in Conversation…", locale: locale))
                .accessibilityIdentifier("inspector.action.search")
            }
        }
        .controlSize(.small)
    }
}

#Preview("Unmuted") {
    GroupDetailsQuickActionsRow(chat: ChatItem.samples[0], onSearchInChat: {})
        .environment(WorkspaceState.preview())
        .padding()
}
