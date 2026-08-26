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

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 10) {
                if let backAction {
                    Button(action: backAction) {
                        Image(systemName: "chevron.left")
                            .wnFont(.semiBold14)
                            .frame(width: 28, height: 28)
                    }
                    .buttonStyle(.wnSecondary)
                    .help(L10n.string("Back to settings"))
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
    let content: Content

    init(
        title: String,
        subtitle: String? = nil,
        errorSectionTitle: String? = nil,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.subtitle = subtitle
        self.errorSectionTitle = errorSectionTitle
        self.content = content()
    }

    var body: some View {
        VStack(spacing: 0) {
            SettingsHeader(title: title, subtitle: subtitle)
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
/// scrolling column. A page built from `WNCallout`, `WNCopyCard` and `SettingsLabeledField` needs
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
