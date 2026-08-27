//
//  HelpImproveWhiteNoiseSheet.swift
//  whitenoise-mac
//
//  The one-time data-sharing choice, offered over Chats the first time an identity gets there.
//
//  Ported from `wn-ios-prototype`'s Diagnostics & Improvements prompt, which puts the ask in one
//  compact card rather than a step inside sign-up: the introduction above the grouped controls, both
//  switches directly reachable with no further navigation, the privacy detail below them, and a
//  single dismissal because the choices apply the moment they are flipped. There is no Save, and no
//  Cancel — leaving both off is a valid answer, and `Done` only closes what is already written.
//
//  The two switches are `DataSharingToggleRows`, the same rows Privacy & Security shows, so this
//  offers exactly the settings it claims to and cannot drift from them. What the prompt itself owns
//  is the copy explaining the ask.
//

import SwiftUI

struct HelpImproveWhiteNoiseSheet: View {
    @Environment(WorkspaceState.self) private var workspace

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            choices
            Divider()
            footer
        }
        .frame(width: 480, height: 440)
    }

    /// The prototype's leading toolbar Close, drawn where this app puts a sheet's dismissal: the
    /// trailing end of the header, as `MessageEditHistorySheet` and `ProfileImagePickerSheet` do.
    /// `help:` takes the catalog *key* — `GlassCircleCloseButton` localizes it itself.
    ///
    /// `.outline`, the secondary tier — `WnIconButton.outline` on the same four tokens as
    /// `WNSecondaryButtonStyle` — rather than the glass disc, which reads as a primary action and
    /// would compete with `Done` below. That is also the tier `WNElevatedButtonStyle`'s own note
    /// asks for here: the raised tier is for a button standing on a bare pane, and inside a sheet
    /// one more elevation fights the chrome it already sits in.
    private var header: some View {
        HStack {
            Text(L10n.string("Help Improve White Noise"))
                .wnFont(.semiBold14)
            Spacer()
            GlassCircleCloseButton(appearance: .outline) {
                workspace.dismissImprovementsPrompt()
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var choices: some View {
        Form {
            Section {
                DataSharingToggleRows()
            } header: {
                Text(
                    L10n.string(
                        "Help us make messaging without a central point of control more reliable. Both of these are optional, and you can change them in Settings at any time."
                    )
                )
                .wnFont(.medium12)
                .foregroundStyle(WNColor.backgroundContentPrimary)
                .textCase(nil)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.bottom, 8)
            } footer: {
                Text(
                    L10n.string(
                        "Telemetry never includes messages, media, contacts, profile details, or keys. Audit logs obscure identifiers and are sent securely to White Noise for troubleshooting."
                    )
                )
                .wnFont(.medium10)
                .foregroundStyle(WNColor.backgroundContentSecondary)
                .fixedSize(horizontal: false, vertical: true)
            }

            // A build with no telemetry or audit credentials refuses the write and reports why.
            // Without this the switch would spring back under the pointer with no explanation.
            SettingsErrorView(error: workspace.lastError)
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
    }

    /// `WNPrimaryButton` rather than a bare `Button` on a glass style: the component owns the type
    /// rung, the interior padding and the border shape together, which is the whole reason it
    /// exists — a call site that picked the style alone draws a differently-sized primary.
    ///
    /// `.small`, the quiet end of the scale: the sheet's content is two switches and three
    /// sentences, and a full-height `Create profile`-sized slab under them claimed more of the
    /// card than the decision warrants. The tier is unchanged — still the glass primary — so it
    /// is the same button onboarding ends on, drawn at the rung this row actually needs.
    private var footer: some View {
        HStack {
            Spacer()
            WNPrimaryButton(size: .small) {
                workspace.dismissImprovementsPrompt()
            } label: {
                Text(L10n.string("Done")).frame(minWidth: 96)
            }
            .wnButtonShape(.capsule)
            .keyboardShortcut(.defaultAction)
        }
        .padding(16)
    }
}

#Preview {
    HelpImproveWhiteNoiseSheet()
        .environment(WorkspaceState.preview())
}
