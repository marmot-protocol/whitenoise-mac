//
//  SettingsScaffolds.swift
//  whitenoise-mac
//
//  The chrome every settings page is built from: the page header, the two page
//  scaffolds — native grouped `Form` rows, or a plain scrolling column — and the one
//  shape an error takes on any of them.
//

import SwiftUI

struct SettingsHeader: View {
    @Environment(\.locale) private var locale
    let title: String
    var subtitle: String?
    var backAction: (() -> Void)?
    /// What the chevron says it returns to, as a catalog *key* — a page reached from another
    /// settings page names that page, because "Back to settings" would describe the wrong
    /// destination.
    var backHelp: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 10) {
                if let backAction {
                    Button(action: backAction) {
                        Image(systemName: "chevron.backward")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .help(L10n.string(backHelp ?? "Back to settings", locale: locale))
                    .accessibilityLabel(Text(L10n.string(backHelp ?? "Back to settings", locale: locale)))
                }

                Text(title)
                    .font(.title3.weight(.semibold))

                Spacer()
            }

            if let subtitle {
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(WNColor.backgroundContentSecondary)
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 20)
        .padding(.bottom, 14)
    }
}

/// Where a nested settings page's back chevron goes, and what it announces.
///
/// One value rather than a closure beside a help string, so a page cannot return to one place
/// while naming another.
struct SettingsBackDestination {
    /// The two ways a settings sub-page is left, which is not the same as the two ways one is
    /// drawn — both routes wear the identical chevron.
    ///
    /// Key Packages is a `SettingsPage` in its own right that the drawer simply does not list,
    /// so leaving it is a page change. A relay's detail is not a page at all: Relays swaps its
    /// own body for it, so leaving is that page clearing its own state. Handing the scaffold a
    /// page for the first case keeps the caller from having to reach for `WorkspaceState`.
    enum Route {
        case page(SettingsPage)
        case action(() -> Void)
    }

    let route: Route
    /// A catalog *key*, not localized text: `SettingsHeader` localizes it against the active locale.
    let help: String

    /// Key Packages' parent. `wn-ios-prototype` reaches Key Packages from Developer Tools and
    /// from nowhere else, so this is the whole way out of that page.
    static var developerMode: SettingsBackDestination {
        SettingsBackDestination(route: .page(.developerMode), help: "Back to Developer Tools")
    }

    /// A sub-page its parent draws in place of itself, which leaves by clearing that state.
    /// It keeps the generic "Back to settings" because the page it returns to is the one the
    /// drawer still shows as selected.
    static func dismissing(_ dismiss: @escaping () -> Void) -> SettingsBackDestination {
        SettingsBackDestination(route: .action(dismiss), help: "Back to settings")
    }
}

struct SettingsNativeForm<Content: View>: View {
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        Form {
            content
        }
        .formStyle(.grouped)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

struct SettingsScaffold<Content: View>: View {
    @Environment(SettingsWindowCoordinator.self) private var settings: SettingsWindowCoordinator?
    let title: String
    var subtitle: String?
    var errorSectionTitle: String?
    /// Shown as a chevron before the title, for a page that is a step inside another page
    /// rather than a destination in the sidebar — Relays' relay detail and Key Packages are two
    /// of these.
    var back: SettingsBackDestination?
    let content: Content

    init(
        title: String,
        subtitle: String? = nil,
        errorSectionTitle: String? = nil,
        back: SettingsBackDestination? = nil,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.subtitle = subtitle
        self.errorSectionTitle = errorSectionTitle
        self.back = back
        self.content = content()
    }

    var body: some View {
        VStack(spacing: 0) {
            if back != nil {
                SettingsHeader(
                    title: title,
                    subtitle: subtitle,
                    backAction: back.map { destination in
                        switch destination.route {
                        case .page(let page): { settings?.navigate(to: page) }
                        case .action(let dismiss): dismiss
                        }
                    },
                    backHelp: back?.help
                )
                Divider()
            }

            SettingsNativeForm {
                content
                SettingsErrorSection(title: errorSectionTitle, error: settings?.lastError)
            }
        }
        .navigationTitle(title)
        .navigationSubtitle(subtitle ?? "")
        .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

private struct SettingsErrorSection: View {
    let title: String?
    let error: String?

    var body: some View {
        if let error {
            SettingsSection(title: title) {
                SettingsErrorView(error: error)
            }
        }
    }
}

/// The scaffold for a settings page that lays its own controls out rather than filling native
/// grouped `Form` rows: same header, same error surface, but the content sits in a plain
/// scrolling column.
struct SettingsStackScaffold<Content: View>: View {
    @Environment(SettingsWindowCoordinator.self) private var settings: SettingsWindowCoordinator?
    let title: String
    var subtitle: String?
    let content: Content

    init(
        title: String,
        subtitle: String? = nil,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.subtitle = subtitle
        self.content = content()
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    content

                    if let error = settings?.lastError {
                        SettingsErrorView(error: error)
                    }
                }
                // A form reads badly when its fields stretch the full width of a wide window,
                // so the column is capped and centred while the scroll view keeps the pane.
                .frame(maxWidth: 460, alignment: .leading)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 28)
                .padding(.vertical, 24)
            }
        }
        .navigationTitle(title)
        .navigationSubtitle(subtitle ?? "")
        .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

struct SettingsErrorView: View {
    let error: String?

    var body: some View {
        if let error {
            Text(error)
                .font(.subheadline)
                .foregroundStyle(WNColor.intentionErrorContent)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

#Preview("Settings scaffold") {
    SettingsScaffold(title: "Appearance", subtitle: "Choose the appearance and language White Noise uses.") {
        SettingsSection(title: "Example") {
            SettingsValueRow(title: "Mode", value: "System")
        }
    }
    .frame(width: 560, height: 320)
}
