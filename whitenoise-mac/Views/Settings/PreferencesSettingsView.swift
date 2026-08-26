//
//  PreferencesSettingsView.swift
//  whitenoise-mac
//
//  The Preferences page: how White Noise starts up, how it behaves in chats, and which
//  six reactions the message actions offer.
//

import AppKit
import SwiftUI

/// The small day-to-day choices that are not about how the app looks: startup, and which
/// six emoji the message actions offer. Quick reactions used to sit under Appearance, next
/// to theme and language, where a choice about interaction was hard to find.
struct PreferencesSettingsView: View {
    @Environment(WorkspaceState.self) private var workspace
    @State private var launchAtLogin = LaunchAtLoginController()

    var body: some View {
        SettingsScaffold(
            title: L10n.string("Preferences"),
            subtitle: L10n.string("Choose how White Noise starts up and how it behaves in chats.")
        ) {
            // Two toggles that explain themselves differently are two groups. They used to share
            // one `Section` with a `Divider()` between them and a grey paragraph after each — the
            // divider was standing in for this split, and a divider cannot carry a footer.
            SettingsSection(
                title: L10n.string("Startup"),
                footer: L10n.string("Open the White Noise window automatically when you log in to your Mac.")
            ) {
                SettingsToggleRow(
                    title: L10n.string("Launch White Noise at Login"),
                    systemImage: "power",
                    isOn: Binding(
                        get: { launchAtLogin.isEnabled },
                        set: { launchAtLogin.setEnabled($0) }
                    )
                )

                LaunchAtLoginStatusRows(controller: launchAtLogin)
            }

            SettingsSection(
                footer: L10n.string(
                    "Return to the last conversation selected for this account, both on launch and when you switch accounts."
                )
            ) {
                SettingsToggleRow(
                    title: L10n.string("Restore last selected chat"),
                    systemImage: "bubble.left.and.bubble.right",
                    isOn: Binding(
                        get: { workspace.restoreLastSelectedChat },
                        set: { workspace.setRestoreLastSelectedChat($0) }
                    )
                )
            }

            QuickReactionsSettingsSection()
        }
        .onAppear {
            launchAtLogin.refresh()
        }
        .onReceive(
            NotificationCenter.default.publisher(
                for: NSApplication.didBecomeActiveNotification
            )
        ) { _ in
            // Login Items can be changed outside White Noise. Treat ServiceManagement as
            // the source of truth whenever the app returns from System Settings.
            launchAtLogin.refresh()
        }
    }
}

/// What Login Items has to say back: the error from the last attempt, and the two states where
/// macOS has the final word. Its own view rather than a computed property on the page, so the
/// page body stays the list of groups it describes.
struct LaunchAtLoginStatusRows: View {
    let controller: LaunchAtLoginController

    var body: some View {
        if let error = controller.errorMessage {
            SettingsErrorView(error: error)
        }

        switch controller.status {
        case .requiresApproval:
            SettingsStatusNote(
                text: L10n.string("White Noise needs approval in Login Items before it can open at login."),
                intention: .warning
            )

            Button(L10n.string("Open Login Items Settings")) {
                controller.openSystemSettings()
            }
            .buttonStyle(.wnSecondary)

        case .notFound:
            SettingsStatusNote(
                text: L10n.string("macOS could not find White Noise's login item."),
                intention: .warning
            )

        case .notRegistered, .enabled:
            EmptyView()
        }
    }
}

/// Lives in `PreferencesSettingsView`, as its own view so that page stays readable.
struct QuickReactionsSettingsSection: View {
    @Environment(WorkspaceState.self) private var workspace
    @State private var quickReactionBeingReplaced: Int?

    var body: some View {
        SettingsSection(
            title: L10n.string("Quick reactions"),
            footer: L10n.string("Choose and order the six reactions shown in message actions.")
        ) {
            ForEach(Array(workspace.quickReactions.enumerated()), id: \.offset) { index, emoji in
                HStack(spacing: 12) {
                    Button {
                        quickReactionBeingReplaced = index
                    } label: {
                        Text(emoji)
                            .wnFont(.medium24)
                            .frame(width: 38, height: 32)
                            .background(WNColor.fillSecondary, in: RoundedRectangle(cornerRadius: 8))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(
                        String(
                            format: L10n.string("Replace quick reaction %d, currently %@"),
                            index + 1,
                            emoji
                        )
                    )
                    .popover(isPresented: replacementPopoverBinding(for: index), arrowEdge: .leading) {
                        ChatEmojiPicker(disabledEmoji: unavailableReplacementEmoji(for: index)) { replacement in
                            guard workspace.replaceQuickReaction(at: index, with: replacement) else { return }
                            quickReactionBeingReplaced = nil
                        }
                    }

                    Text(String(format: L10n.string("Quick reaction %d"), index + 1))
                        .foregroundStyle(WNColor.backgroundContentSecondary)

                    Spacer()

                    Button {
                        workspace.moveQuickReaction(at: index, by: -1)
                    } label: {
                        Image(systemName: "arrow.up")
                    }
                    .buttonStyle(.borderless)
                    .disabled(index == workspace.quickReactions.startIndex)
                    .help(L10n.string("Move earlier"))

                    Button {
                        workspace.moveQuickReaction(at: index, by: 1)
                    } label: {
                        Image(systemName: "arrow.down")
                    }
                    .buttonStyle(.borderless)
                    .disabled(index == workspace.quickReactions.index(before: workspace.quickReactions.endIndex))
                    .help(L10n.string("Move later"))
                }
            }

            Button(L10n.string("Restore defaults")) {
                workspace.restoreDefaultQuickReactions()
            }
            .buttonStyle(.wnSecondary)
            .disabled(workspace.quickReactions == ChatReactionDefaults.quick)
        }
    }

    private func replacementPopoverBinding(for index: Int) -> Binding<Bool> {
        Binding(
            get: { quickReactionBeingReplaced == index },
            set: { isPresented in
                if !isPresented, quickReactionBeingReplaced == index {
                    quickReactionBeingReplaced = nil
                }
            }
        )
    }

    private func unavailableReplacementEmoji(for index: Int) -> Set<String> {
        Set(
            workspace.quickReactions.enumerated().compactMap { offset, emoji in
                offset == index ? nil : emoji
            }
        )
    }
}
