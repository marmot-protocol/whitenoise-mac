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
    let title: String
    var subtitle: String?
    var backAction: (() -> Void)?
    /// What the chevron says it returns to, as a catalog *key* — a page reached from another
    /// settings page names that page, because "Back to settings" would describe the wrong
    /// destination. It stays a key because `GlassCircleCloseButton` localizes its own help.
    var backHelp: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            // The app's one back control, not a second one built here. `GroupViews` and the
            // compose pane already answer "how do I get back" with this circle, and the drawer's
            // sub-page is the same question a third time; a ringed 28pt rect beside them was a
            // fourth affordance for one idea. The prototype reaches Relay Details through a
            // native `NavigationLink`, so what ports is the *bare* system chevron — unboxed —
            // and this is that chevron's mac form. `help:` takes a catalog key: the component
            // localizes it.
            HStack(spacing: 12) {
                if let backAction {
                    GlassCircleCloseButton(
                        symbol: "chevron.backward",
                        help: backHelp ?? "Back to settings",
                        appearance: .outline,
                        action: backAction
                    )
                }

                Text(title)
                    .wnFont(.semiBold18)

                Spacer()
            }

            if let subtitle {
                Text(subtitle)
                    .wnFont(.medium12)
                    .foregroundStyle(WNColor.backgroundContentSecondary)
            }
        }
        .padding(.horizontal, 28)
        .padding(.top, 24)
        .padding(.bottom, 18)
        .background {
            GlassToolbarBackground()
        }
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
    /// A catalog *key*, not localized text: `GlassCircleCloseButton` calls `L10n.string` on
    /// what it is handed, so resolving it here would localize it twice.
    let help: String

    /// Key Packages' parent. `wn-ios-prototype` reaches Key Packages from Developer Tools and
    /// from nowhere else, so this is the whole way out of that page.
    static var developerMode: SettingsBackDestination {
        SettingsBackDestination(route: .page(.developerMode), help: "Back to Developer mode")
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
        .scrollContentBackground(.hidden)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

struct SettingsScaffold<Content: View>: View {
    @Environment(WorkspaceState.self) private var workspace
    let title: String
    var subtitle: String?
    var errorSectionTitle: String?
    /// Shown as a chevron before the title, for a page that is a step inside another page
    /// rather than a destination in the drawer — Relays' relay detail and Key Packages are the
    /// two of these. The drawer has no navigation stack, so a sub-page is the parent page
    /// swapping its own body, and this is the way back.
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
            SettingsHeader(
                title: title,
                subtitle: subtitle,
                backAction: back.map { destination in
                    switch destination.route {
                    case .page(let page): { workspace.showSettingsPage(page) }
                    case .action(let dismiss): dismiss
                    }
                },
                backHelp: back?.help
            )
            Divider()

            SettingsNativeForm {
                content
                errorSection
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    @ViewBuilder
    private var errorSection: some View {
        if let error = workspace.lastError {
            SettingsSection(title: errorSectionTitle) {
                SettingsErrorView(error: error)
            }
        }
    }
}

/// The scaffold for a settings page that lays its own controls out rather than filling native
/// grouped `Form` rows: same header, same error surface, but the content sits in a plain
/// scrolling column. A page built from `WNCallout`, `WNCopyCard` and `WNInput` needs
/// this — those controls draw their own box, and a grouped `Section` would put a second one
/// around each.
struct SettingsStackScaffold<Content: View>: View {
    @Environment(WorkspaceState.self) private var workspace
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
            SettingsHeader(title: title, subtitle: subtitle)
            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    content

                    if let error = workspace.lastError {
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
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

struct SettingsErrorView: View {
    let error: String?

    var body: some View {
        if let error {
            Text(error)
                .wnFont(.medium12)
                .foregroundStyle(WNColor.backgroundContentDestructive)
                .textSelection(.enabled)
        }
    }
}
