//
//  ProfileSettingsView.swift
//  whitenoise-mac
//
//  The Profile page: the public profile other people see for this identity, its
//  identity header, and the actions that publish what is typed into it.
//

import SwiftUI

/// Settings → Profile: the sign-up form again, for a profile that already exists.
///
/// The two screens ask the same question — a face, a name, an address, a line about yourself — and
/// until now answered it in two different vocabularies: the sign-up pane in `WNInput`'s filled
/// pills under a large avatar, this page in outlined form rows under a camera badge. They are one
/// form now, drawn once (`WNInput`) at one shape (`.capsule`, handed to the whole column the way
/// `OnboardingSignUpView` hands it to its own).
///
/// **The page has no edit mode.** It opened read-only for one release, behind an Edit button, which
/// is `wn-ios-prototype`'s shape — its `ProfileSettingsView` swaps `Text` for `TextField` on a
/// press. The argument for it was that this page publishes to the global network, so a form that is
/// always live invites a stray keystroke into a public record; the argument does not survive
/// contact with the page, because a keystroke publishes nothing. Save does, and Save is still a
/// press. What the mode actually cost was a button standing between the reader and every field on
/// the screen.
///
/// So the fields are live, and **the actions are the mode**: Cancel and Save appear only once the
/// draft has moved off what is published, and go away again when it has not — see
/// `WorkspaceState.hasUnsavedProfileEdits`. That is `whitenoise`'s `edit_profile_screen.dart`,
/// which has no Edit button either and gates its footer on `hasUnsavedChanges`.
///
/// **The photo affordance moved off the avatar.** It used to be a camera badge on the face; it is
/// the pill under it now, which is what the sign-up hero already draws — same control, same two
/// labels, now on both screens.
struct ProfileSettingsView: View {
    @Environment(WorkspaceState.self) private var workspace

    var body: some View {
        @Bindable var workspace = workspace

        SettingsStackScaffold(
            title: L10n.string("Profile"),
            subtitle: L10n.string("Publish the profile other people see for this identity.")
        ) {
            if let account = workspace.activeAccount {
                ProfileIdentityHeaderView(
                    account: account,
                    displayName: profilePreviewName(fallback: account)
                )
            }

            PublicProfileNote()

            WNInput(
                label: L10n.string("Name"),
                prompt: L10n.string("Enter your name"),
                text: $workspace.profileDraft.displayName,
                isEnabled: workspace.isProfileFormEnabled
            )
            .accessibilityIdentifier("settings.profile.name")

            ProfileNostrAddressField()

            WNInput(
                label: L10n.string("About"),
                prompt: L10n.string("Introduce yourself"),
                text: $workspace.profileDraft.about,
                lineLimit: OnboardingLayout.aboutFieldLineLimit,
                isEnabled: workspace.isProfileFormEnabled
            )
            .accessibilityIdentifier("settings.profile.about")

            ProfileEditingActions()
        }
        .wnButtonShape(.capsule)
        .sheet(isPresented: $workspace.isProfileImagePickerPresented) {
            ProfileImagePickerSheet()
                // Sheets are hosted outside this view's hierarchy and inherit nothing from it, so
                // the app-language locale has to be handed over again.
                .environment(\.locale, workspace.preferredLocale)
        }
    }

    private func profilePreviewName(fallback account: AccountItem) -> String {
        firstNonBlank([
            workspace.profileDraft.displayName,
            account.displayName,
        ]) ?? account.displayName
    }
}

/// The address field, and the one thing on this page that is a claim rather than a preference.
///
/// Split out because it is the only field here with state of its own to read — the seal, the
/// validity of what is typed, and the footer that says what a valid one looks like. See
/// `NostrAddressVerification` for why the seal is a network answer and not a fixture.
struct ProfileNostrAddressField: View {
    @Environment(WorkspaceState.self) private var workspace

    var body: some View {
        @Bindable var workspace = workspace

        WNInput(
            label: L10n.string("Verified Nostr Address"),
            prompt: L10n.string("name@example.com"),
            text: $workspace.profileDraft.nip05,
            isEnabled: workspace.isProfileFormEnabled,
            disablesAutocorrection: true,
            accessibilityValue: accessibilityValue,
            validationMessage: validationMessage
        ) {
            VerifiedNostrAddressSeal(verification: workspace.profileNostrAddressSeal)
        }
        .accessibilityIdentifier("settings.profile.nostr-address")
    }

    /// Only for a value that cannot be published.
    ///
    /// It used to be gated on the edit mode as well, so that a read-only page could not show a
    /// complaint about a value nobody was changing. With the mode gone the gate is the value
    /// itself: what is published always parses, so the only way to see this is to have typed it.
    private var validationMessage: String? {
        guard !workspace.isProfileNostrAddressDraftValid else { return nil }
        return L10n.string("Enter an address like name@example.com.")
    }

    /// The seal is decorative — `accessibilityHidden` below — so the verdict is spoken here
    /// instead, once, after the value.
    private var accessibilityValue: String {
        let address = workspace.profileDraft.nip05.trimmingCharacters(in: .whitespacesAndNewlines)
        switch workspace.profileNostrAddressSeal {
        case .none:
            return address
        case .checking:
            return "\(address), \(L10n.string("Checking"))"
        case .verified:
            return "\(address), \(L10n.string("Verified"))"
        case .unverified:
            return "\(address), \(L10n.string("Not verified"))"
        }
    }
}

/// The seal on a verified address: Apple's `checkmark.seal.fill`, and nothing at all otherwise.
///
/// **Absence is the unverified state.** No second glyph, no colour swap — `wn-ios-prototype` is
/// explicit that verification is never communicated by colour alone, and a grey seal beside a
/// green one is exactly that. `.checking` draws a spinner rather than a seal, because a seal that
/// might yet disappear is a claim being made before it is known.
struct VerifiedNostrAddressSeal: View {
    let verification: NostrAddressVerification

    var body: some View {
        content
            // The row it sits in already speaks the verdict as the field's accessibility value;
            // announcing it twice is the duplicate the prototype's spec calls out.
            .accessibilityHidden(true)
    }

    @ViewBuilder
    private var content: some View {
        switch verification {
        case .verified:
            Image(systemName: "checkmark.seal.fill")
                .wnFont(.medium14)
                // On `fillSecondary` ground, so the ink comes from the fill family.
                .foregroundStyle(WNColor.fillContentSecondary)
                .frame(width: 20, height: 20)
        case .checking:
            ProgressView()
                .controlSize(.small)
                .frame(width: 20, height: 20)
        case .none, .unverified:
            EmptyView()
        }
    }
}

/// The page's actions: **Cancel** beside **Save**, and only once there is something to cancel or
/// save.
///
/// **There is no Edit button, and these are not always here.** Both of those are the same decision.
/// The row used to be Edit profile in the form's top-right corner — `wn-ios-prototype`'s `Edit` and
/// `Done`, which are `.primaryAction` on a pushed screen's navigation bar. A phone has a bar to put
/// them in; a window does not, so that corner was simply the first row of a scrolling column, and
/// the result was a control standing between the reader and the fields, plus a pair of small
/// buttons above the form they commit.
///
/// `whitenoise`'s `edit_profile_screen.dart` has neither: the fields are live and the footer is
/// gated on `hasUnsavedChanges`. This is that, with Cancel joining Save because a live form needs a
/// way back to what is published. Appearing on the first keystroke is also what tells you the form
/// *is* live — the affordance the Edit button used to be is now the reaction to using it.
///
/// **Under the fields, full width, at the height an onboarding action draws.** Save publishes the
/// same profile `Create profile` publishes, so it draws at the same `OnboardingLayout.actionHeight`.
/// Neither style stretches to a proposed height — a `ButtonStyle` ignores `.frame(height:)` — so
/// each tier's label claims that height minus its own chrome. `ProfileActionMetrics` holds both
/// numbers and `SettingsProfileTests` re-measures them.
struct ProfileEditingActions: View {
    @Environment(WorkspaceState.self) private var workspace

    private var isBusy: Bool {
        workspace.isSavingProfile || workspace.isUploadingProfileImage
    }

    var body: some View {
        VStack(spacing: ProfileActionMetrics.spacing) {
            if workspace.hasUnsavedProfileEdits {
                HStack(spacing: ProfileActionMetrics.spacing) {
                    Button {
                        workspace.discardProfileEdits()
                    } label: {
                        ProfileActionLabel(title: L10n.string("Cancel"), tier: .secondary)
                    }
                    .buttonStyle(.wnSecondary)
                    .disabled(isBusy)
                    .accessibilityIdentifier("settings.profile.cancel")

                    Button {
                        Task { await workspace.saveProfile() }
                    } label: {
                        ProfileActionLabel(
                            title: workspace.isSavingProfile
                                ? L10n.string("Saving...") : L10n.string("Save"),
                            tier: .primary
                        )
                    }
                    .wnPrimaryButtonStyle()
                    .disabled(isBusy || !workspace.canSaveProfileEdits)
                    .accessibilityIdentifier("settings.profile.save")
                }
                // The row arrives on a keystroke, so it slides the page rather than appearing on
                // it. `.blurReplace` or a fade would read as a flicker at the bottom edge of a
                // form somebody is typing into.
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }

            if workspace.isLoadingSettings {
                ProgressView()
                    .controlSize(.small)
                    .frame(maxWidth: .infinity)
            }
        }
        // Set here rather than on each button: `wnPrimaryButtonStyle()` is a `ViewModifier` that
        // reads `\.controlSize` from the environment it is *placed* in, so a `.controlSize` applied
        // to the `Button` underneath it is written too late for the chrome to see. This is the same
        // place the onboarding panes name it — once, on the container the actions sit in.
        .controlSize(.large)
        // Only paid for when there is a row to hold off the fields. Held unconditionally it would
        // be 8pt of dead air under the About field on the page as it usually stands, which is
        // read-only in everything but name.
        .padding(.top, workspace.hasUnsavedProfileEdits ? ProfileActionMetrics.fieldsToActionsSpacing : 0)
        .animation(.easeOut(duration: 0.18), value: workspace.hasUnsavedProfileEdits)
    }
}

/// One action's label: full width, one line, and tall enough that the button around it comes out
/// `ProfileActionMetrics.height`.
///
/// Internal rather than nested so the size test can stand one up on its own and measure what the
/// two styles actually draw around it.
struct ProfileActionLabel: View {
    enum Tier {
        case primary
        case secondary
    }

    let title: String
    let tier: Tier

    var body: some View {
        Text(title)
            .lineLimit(1)
            // Named here rather than left to the control size, because only one of the two tiers
            // goes through `WNPrimaryButton` — `.wnSecondary` inherits whatever font the column had
            // — and a pair in one row has to be one typeface at one size.
            .wnFont(WNPrimaryButtonSize.large.font)
            .frame(maxWidth: .infinity, minHeight: ProfileActionMetrics.labelHeight(for: tier))
    }
}

/// The numbers that make this page's actions one size.
///
/// Values, so they can be asserted without standing a view up — and so each compensation is a
/// named quantity somebody can re-measure rather than a literal buried in a `frame`.
///
/// Not `nonisolated`: `WNPrimaryButtonSize.font` reads the `WNTextStyle` ladder, which inherits the
/// module's MainActor default.
enum ProfileActionMetrics {
    /// How tall every action on this page draws, both tiers.
    ///
    /// `OnboardingLayout.actionHeight` by reference rather than by coincidence: the sign-up pane
    /// asks for a face, a name and a line about yourself and publishes them with one full-width
    /// button, and this page is that same form with a mode on it. Its Save should not be a
    /// different-sized button from the Create profile that first wrote the same record.
    static let height: CGFloat = OnboardingLayout.actionHeight

    /// Between Cancel and Save. The gap the panes put between two stacked actions, so a pair that
    /// sits side by side here reads as the same pair.
    static let spacing: CGFloat = OnboardingLayout.actionSpacing

    /// What the scaffold's 16pt row gap is topped up by, so the actions read as the row that closes
    /// the form rather than as one more field in it — 24 in total.
    ///
    /// A step above `OnboardingLayout.contentToActionsSpacing`, which holds a pane's CTA off its
    /// form at 16, and deliberately: that pane already has a 32pt reserved error line sitting in
    /// the gap, and this column has nothing between the About field and the buttons.
    static let fieldsToActionsSpacing: CGFloat = 8

    /// What the glass primary draws around its label at `.large`.
    ///
    /// The onboarding panes measured this first and
    /// `OnboardingTests.bothActionTiersDrawTheSameHeight` keeps re-measuring it; the number is read
    /// from there rather than copied, so there is one place it can move.
    static let primaryChromeHeight: CGFloat = OnboardingLayout.primaryActionChromeHeight

    /// What `.wnSecondary` draws around its label at `.large` — twice `WNSecondaryButtonStyle`'s
    /// own vertical padding, the ring being an inset stroke that adds nothing to the height.
    ///
    /// **4pt more than the glass tier's, which is why neither number can be reasoned about from
    /// the other.** The two styles step their interiors on different tables — `controlSize` for
    /// this one, the native glass metrics for that one — so the gap between them changes with the
    /// rung and even changes sign: at `.small`, where these actions used to be drawn, the glass was
    /// the *taller* of the two. `SettingsProfileTests.bothProfileActionsDrawTheSameHeight`
    /// re-measures both through `ImageRenderer` and fails if either table moves under us.
    static let secondaryChromeHeight: CGFloat = 16

    /// The minimum height an action's *label* must claim for its button to come out `height` tall.
    static func labelHeight(for tier: ProfileActionLabel.Tier) -> CGFloat {
        switch tier {
        case .primary: height - primaryChromeHeight
        case .secondary: height - secondaryChromeHeight
        }
    }
}

/// The top of the profile form: the avatar, centred and large enough to be the subject of the
/// page, and — while editing — the one control that changes it. This is `OnboardingSignUpAvatar`
/// on the screen that first asks for a face.
///
/// The name is not repeated here: the Name field is the next thing on the page and carries the
/// same value live.
///
/// **The npub card and its QR tile used to sit under the avatar and no longer do.** They are not
/// part of the profile being published — a public key is issued, not edited — and this page is a
/// form with an Edit button on it now, so a pair of read-only identity chips wedged between the
/// avatar and the first field read as controls the form had forgotten to enable. Both are still
/// one page away, together, in Settings → Keys under **Public Identity**, which is where an
/// identity's key material already lives.
struct ProfileIdentityHeaderView: View {
    @Environment(WorkspaceState.self) private var workspace
    let account: AccountItem
    let displayName: String

    private let avatarSize: CGFloat = 96

    private var hasPhoto: Bool {
        workspace.profileDraft.sanitizedPictureURL != nil
    }

    var body: some View {
        VStack(spacing: 12) {
            ProfileImageAvatarView(
                seed: account.accountIdHex,
                initials: displayName,
                sanitizedPictureURL: workspace.profileDraft.sanitizedPictureURL,
                isOwnAccountImage: true,
                size: avatarSize,
                isSelected: false
            )

            // Always offered, now that the page has no read-only mode to withhold it in. Closed
            // during an upload, the way the sign-up hero is — see `OnboardingSignUpAvatar`.
            // `beginProfileImageSelection()` refuses a second selection while one is in flight and
            // sets no error, so without this the popover and the file panel both open and the
            // chosen file is dropped in silence, with nothing on this page drawing the upload it
            // was dropped for.
            ProfileImageSourceMenu(
                destination: .activeAccount,
                appearance: .pushButton,
                // `isProfileFormEnabled` for the same reason the fields carry it: a picture chosen
                // during the load writes `profileDraft.picture`, and the load replaces the draft.
                isEnabled: workspace.isProfileFormEnabled && !workspace.isUploadingProfileImage
            ) {
                Text(L10n.string(hasPhoto ? "Change photo" : "Add photo"))
                    .wnFont(.medium12)
            }
            .buttonStyle(.wnElevated)
            .controlSize(.small)
            .accessibilityIdentifier("settings.profile.photo")

            if workspace.isUploadingProfileImage {
                ProgressView()
                    .controlSize(.small)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.bottom, 8)
    }
}
