//
//  SettingsSidebarView.swift
//  whitenoise-mac
//
//  Native macOS Settings sidebar (S01): active profile summary/QR and Add Profile at the top,
//  the #1036 category list in a native sidebar `List(selection:)`, clearly separated destructive
//  account actions at the bottom, and the app version footer.
//

import SwiftUI

struct SettingsSidebarView: View {
    let coordinator: SettingsWindowCoordinator
    @Environment(WorkspaceState.self) private var workspace
    @Environment(SessionState.self) private var session
    // Localizing through `\.locale` (not the stored preference) re-renders sidebar labels
    // immediately on a language switch in Settings.
    @Environment(\.locale) private var locale

    private var selection: Binding<SettingsPage?> {
        Binding(
            get: { coordinator.parentPage },
            set: { destination in
                guard let destination else { return }
                coordinator.navigate(to: destination)
            }
        )
    }

    var body: some View {
        List(selection: selection) {
            Section {
                SettingsSidebarActiveProfileRow()
                SettingsSidebarAddProfileRow(onAddProfile: coordinator.beginAddProfile)
            }

            ForEach(Array(SettingsPage.sidebarGroups.map(visiblePages).enumerated()), id: \.offset) {
                _, group in
                Section {
                    ForEach(group) { page in
                        SettingsSidebarCategoryRow(page: page)
                            .tag(page)
                    }
                }
            }

            if let account = workspace.activeAccount {
                SettingsSidebarDestructiveSection(
                    account: account,
                    isDisabled: workspace.isAccountMutationInProgress
                )
            }
        }
        .listStyle(.sidebar)
        .disabled(workspace.activeAccount == nil)
        .accessibilityIdentifier("settings.sidebar")
        .safeAreaInset(edge: .bottom, spacing: 0) {
            SettingsVersionFooter()
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
        }
    }

    /// Devices is listed only when linking is available on the active runtime.
    private func visiblePages(_ group: [SettingsPage]) -> [SettingsPage] {
        let devicesAvailable = session.accountScope?.deviceLinking.isAvailable == true
        return group.filter { $0 != .devices || devicesAvailable }
    }
}

private struct SettingsSidebarActiveProfileRow: View {
    @Environment(WorkspaceState.self) private var workspace
    @Environment(\.locale) private var locale
    @State private var isQRPresented = false

    var body: some View {
        Group {
            if let account = workspace.activeAccount {
                Button {
                    isQRPresented = true
                } label: {
                    HStack(spacing: 10) {
                        ProfileImageAvatarView(
                            seed: account.accountIdHex,
                            initials: account.initials,
                            sanitizedPictureURL: account.sanitizedPictureURL,
                            size: MessagesLayout.settingsProfileAvatarSize,
                            isSelected: false
                        )

                        VStack(alignment: .leading, spacing: 2) {
                            Text(account.displayName)
                                .font(.body.weight(.medium))
                                .foregroundStyle(WNColor.textPrimary)
                                .lineLimit(1)

                            CopyableKeyLabel(
                                accountIdHex: account.accountIdHex,
                                head: 8,
                                tail: 6,
                                showsCopyButton: false
                            )
                        }

                        Spacer(minLength: 0)

                        Image(systemName: "qrcode")
                            .font(.body)
                            .foregroundStyle(WNColor.textPrimary)
                            .accessibilityHidden(true)
                    }
                    .padding(.vertical, 4)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(L10n.string("Show npub QR code", locale: locale))
                .accessibilityIdentifier("settings.sidebar.active-profile")
                .sheet(isPresented: $isQRPresented) {
                    PublicIdentityQRCodeSheet(
                        account: account,
                        displayName: account.displayName
                    )
                    .environment(\.locale, workspace.preferredLocale)
                }
            } else {
                Label(
                    L10n.string("No account", locale: locale),
                    systemImage: "person.crop.circle.badge.exclamationmark"
                )
                .foregroundStyle(.secondary)
            }
        }
    }
}

private struct SettingsSidebarAddProfileRow: View {
    @Environment(\.locale) private var locale
    let onAddProfile: () -> Void

    var body: some View {
        Button(action: onAddProfile) {
            Label(
                L10n.string("Add Profile", locale: locale),
                systemImage: "person.crop.circle.badge.plus"
            )
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("settings.sidebar.add-profile")
    }
}

private struct SettingsSidebarCategoryRow: View {
    @Environment(\.locale) private var locale
    let page: SettingsPage

    var body: some View {
        Label(page.title(in: locale), systemImage: page.systemImage)
            .accessibilityIdentifier(page.sidebarAccessibilityIdentifier)
    }
}

private struct SettingsSidebarDestructiveSection: View {
    @Environment(WorkspaceState.self) private var workspace
    @Environment(\.locale) private var locale
    let account: AccountItem
    let isDisabled: Bool

    @State private var isSigningOut = false

    var body: some View {
        Section {
            Label(
                SettingsPage.deleteProfile.title(in: locale),
                systemImage: SettingsPage.deleteProfile.systemImage
            )
            .foregroundStyle(WNColor.intentionErrorContent)
            .tag(SettingsPage.deleteProfile)
            .disabled(isDisabled)
            .accessibilityIdentifier(SettingsPage.deleteProfile.sidebarAccessibilityIdentifier)

            Button {
                isSigningOut = true
            } label: {
                Label(
                    L10n.string("Sign Out", locale: locale),
                    systemImage: "rectangle.portrait.and.arrow.right"
                )
                .foregroundStyle(WNColor.intentionErrorContent)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(isDisabled)
            .accessibilityIdentifier("settings.sidebar.sign-out")
            .sheet(isPresented: $isSigningOut) {
                SignOutSheet(account: account)
                    .environment(\.locale, workspace.preferredLocale)
            }
        }
    }
}

#Preview("Settings sidebar") {
    let workspace = WorkspaceState.preview()
    let coordinator = SettingsWindowCoordinator(workspace: workspace)
    SettingsSidebarView(coordinator: coordinator)
        .environment(workspace)
        .environment(SessionState())
        .frame(width: 260, height: 640)
}
