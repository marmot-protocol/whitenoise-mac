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
    @Environment(\.locale) private var locale
    let coordinator: SettingsWindowCoordinator
    let account: AccountItem
    let devicesAvailable: Bool
    let isAccountMutationInProgress: Bool
    let preferredLocale: Locale

    private var selection: Binding<SettingsPage?> {
        Binding(
            get: { coordinator.parentPage },
            set: { destination in
                guard let destination else { return }
                select(destination)
            }
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            List(selection: selection) {
                Section {
                    SettingsSidebarActiveProfileRow(
                        account: account,
                        preferredLocale: preferredLocale
                    )
                    SettingsSidebarAddProfileRow(onAddProfile: coordinator.beginAddProfile)
                }

                ForEach(
                    Array(
                        SettingsPage.sidebarGroups.map {
                            Self.visiblePages(in: $0, devicesAvailable: devicesAvailable)
                        }.enumerated()
                    ),
                    id: \.offset
                ) { _, group in
                    Section {
                        ForEach(group) { page in
                            SettingsSidebarCategoryRow(
                                page: page,
                                hasOpenChild: coordinator.page != page && coordinator.parentPage == page,
                                onReselect: {
                                    coordinator.navigate(to: page)
                                }
                            )
                            .tag(page)
                        }
                    }
                }

                SettingsSidebarDestructiveSection(
                    account: account,
                    isDisabled: isAccountMutationInProgress,
                    preferredLocale: preferredLocale
                )
            }
            .listStyle(.sidebar)
            .textSelection(.disabled)
            .accessibilityIdentifier("settings.sidebar")

            Divider()

            SettingsVersionFooter()
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
        }

    }

    /// Navigates from the sidebar, refusing Delete Profile while an account mutation is active.
    func select(_ destination: SettingsPage) {
        if destination == .deleteProfile && isAccountMutationInProgress {
            return
        }
        coordinator.navigate(to: destination)
    }

    /// Devices is listed only when linking is available on the active runtime.
    static func visiblePages(in group: [SettingsPage], devicesAvailable: Bool) -> [SettingsPage] {
        group.filter { $0 != .devices || devicesAvailable }
    }
}

private struct SettingsSidebarActiveProfileRow: View {
    @Environment(\.locale) private var locale
    let account: AccountItem
    let preferredLocale: Locale
    @State private var isQRPresented = false

    var body: some View {
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
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.primary)
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
            .environment(\.locale, preferredLocale)
        }
    }
}

private struct SettingsSidebarAddProfileRow: View {
    @Environment(\.locale) private var locale
    let onAddProfile: () -> Void

    var body: some View {
        Button(action: onAddProfile) {
            Label {
                Text(L10n.string("Add Profile", locale: locale))
            } icon: {
                Image(systemName: "person.crop.circle.badge.plus")
                    .foregroundStyle(.secondary)
            }
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
    let hasOpenChild: Bool
    let onReselect: () -> Void

    private var label: some View {
        Label {
            Text(page.title(in: locale))
        } icon: {
            Image(systemName: page.systemImage)
                .foregroundStyle(.secondary)
        }
    }

    var body: some View {
        if hasOpenChild {
            // Clicking an already-selected parent row (for example Data Usage while viewing
            // Manage Storage) does not change `List(selection:)`, so wrap the active parent in a
            // plain button to return from the nested sub-page.
            Button(action: onReselect) {
                label
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier(page.sidebarAccessibilityIdentifier)
        } else {
            label
                .accessibilityIdentifier(page.sidebarAccessibilityIdentifier)
        }
    }
}

private struct SettingsSidebarDestructiveSection: View {
    @Environment(\.locale) private var locale
    let account: AccountItem
    let isDisabled: Bool
    let preferredLocale: Locale

    @State private var isSigningOut = false

    var body: some View {
        Section {
            Label {
                Text(SettingsPage.deleteProfile.title(in: locale))
            } icon: {
                Image(systemName: SettingsPage.deleteProfile.systemImage)
                    .foregroundStyle(.secondary)
            }
            .tag(SettingsPage.deleteProfile)
            .disabled(isDisabled)
            .selectionDisabled(isDisabled)
            .accessibilityIdentifier(SettingsPage.deleteProfile.sidebarAccessibilityIdentifier)

            Button {
                isSigningOut = true
            } label: {
                Label {
                    Text(L10n.string("Sign Out", locale: locale))
                        .foregroundStyle(WNColor.intentionErrorContent)
                } icon: {
                    Image(systemName: "rectangle.portrait.and.arrow.right")
                        .foregroundStyle(WNColor.intentionErrorContent)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(isDisabled)
            .accessibilityIdentifier("settings.sidebar.sign-out")
            .sheet(isPresented: $isSigningOut) {
                SignOutSheet(account: account)
                    .environment(\.locale, preferredLocale)
            }
        }
    }
}

#Preview("Settings sidebar") {
    let workspace = WorkspaceState.preview()
    let coordinator = SettingsWindowCoordinator(workspace: workspace)
    SettingsSidebarView(
        coordinator: coordinator,
        account: AccountItem.samples[0],
        devicesAvailable: true,
        isAccountMutationInProgress: false,
        preferredLocale: .current
    )
    .environment(workspace)
    .frame(width: 260, height: 640)
}
