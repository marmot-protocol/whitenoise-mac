import MarmotKit
import SwiftUI
import UniformTypeIdentifiers

/// The profile step's screen: `whitenoise-ios`'s `IdentityProfileSetupView` in its account-setup
/// mode, laid out as the Sign Up pane is. While MarmotKit lets the profile be edited it *is* that
/// pane — the photo over its pill where the mark would be, the public-profile notice, Name and
/// About, and the button that publishes them — with the setup's back control and progress in the
/// header row, and Not Now under Save when the step is optional. Otherwise it explains why the
/// profile could not be loaded and offers a retry.
///
/// The photo is picked from a file and cropped in the same editor Settings → Profile uses, then
/// held here as the cropped JPEG until Save uploads it. Nothing is uploaded or published before
/// Save is pressed.
struct AccountSetupProfileStep: View {
    @Environment(\.locale) private var locale
    let model: OnboardingCoordinator
    @State private var displayName = ""
    @State private var about = ""
    @State private var avatar: SignUpProfileImage?
    @State private var isFileImporterPresented = false
    @State private var cropModel: AvatarCropViewModel?
    @State private var photoError: String?
    @State private var active: String?
    @State private var hasPrefilled = false

    private var plan: AccountSetupProfilePlan {
        AccountSetupProfilePlan(snapshot: model.settledSnapshot)
    }

    private var isEnabled: Bool { !model.isBusy && active == nil }

    private var hasSomethingToSave: Bool {
        AccountSetupProfilePlan.metadata(
            displayName: displayName,
            about: about,
            pictureURL: avatar.map { _ in "staged" },
            existing: plan.profile
        ) != nil
    }

    var body: some View {
        let plan = plan

        AccountSetupStepLayout {
            if plan.canEdit {
                AccountSetupProfileAvatar(
                    titleKey: plan.titleKey,
                    avatar: avatar,
                    displayName: displayName,
                    isEnabled: isEnabled,
                    choosePhoto: {
                        photoError = nil
                        isFileImporterPresented = true
                    },
                    removePhoto: { avatar = nil }
                )
            } else {
                AccountSetupStepTitle(step: .profile)
            }
        } content: {
            if plan.canEdit {
                // Only a proposal under review says anything above the form: that its details are
                // not shared yet. A fresh profile is Sign Up's pane, which needs no introduction.
                if plan.profile != nil || (model.isBusy && active == nil) {
                    AccountSetupProfileIntro(messageKeys: plan.messageKeys, isLoading: model.isBusy && active == nil)
                }
                AccountSetupProfileForm(displayName: $displayName, about: $about, isEnabled: isEnabled)
            } else {
                AccountSetupCallout(
                    titleKey: plan.titleKey,
                    symbol: "person.crop.circle",
                    isError: plan.isInterrupted || !model.isBusy,
                    isLoading: model.isBusy && active == nil
                ) {
                    ForEach(plan.messageKeys, id: \.self) { Text(L10n.string($0, locale: locale)) }
                }
            }

            AccountSetupNoActionLines(step: .profile, snapshot: model.settledSnapshot)
            AccountSetupErrorLine(message: photoError ?? model.error)
        } actions: {
            switch plan.primaryAction {
            case .save:
                AccountSetupStepButton(
                    titleKey: "Save",
                    model: model,
                    active: $active,
                    isEnabled: hasSomethingToSave
                ) {
                    await model.saveProfile(displayName: displayName, about: about, avatar: avatar)
                }
                .accessibilityIdentifier("onboarding.account-setup.save-profile")
            case .retry:
                AccountSetupStepButton(titleKey: "Try Again", model: model, active: $active) {
                    await model.retry(.profile)
                }
            case nil:
                EmptyView()
            }
            if plan.canSkip {
                AccountSetupStepButton(titleKey: "Not Now", tier: .secondary, model: model, active: $active) {
                    await model.skip(.profile)
                }
            }
            if plan.canCancelRepair {
                AccountSetupStepButton(
                    titleKey: "Discard Changes",
                    tier: .secondary,
                    model: model,
                    active: $active
                ) { await model.cancelRepair() }
            }
        }
        .fileImporter(
            isPresented: $isFileImporterPresented,
            allowedContentTypes: [.image],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                guard let url = urls.first else { return }
                cropModel = AvatarCropViewModel(
                    loadData: { try await AvatarImageCropSource.data(fromFileURL: url) },
                    commit: { data in
                        avatar = SignUpProfileImage(
                            attachment: try await AvatarImageCropper.attachment(fromCroppedImageData: data)
                        )
                    }
                )
            case .failure(let error):
                photoError = error.localizedDescription
            }
        }
        .avatarCropSheet($cropModel)
        .onAppear(perform: prefill)
    }

    /// Fills the form from the proposal under review, once, so reopening the screen does not
    /// overwrite what the user has typed since.
    private func prefill() {
        guard !hasPrefilled else { return }
        hasPrefilled = true
        guard let profile = plan.profile else { return }
        displayName = profile.displayName ?? profile.name ?? ""
        about = profile.about ?? ""
    }
}

/// The profile screen's hero, where Sign Up has its own: the draft avatar over the pill that
/// changes it, with Remove beside it once there is a photo. See `OnboardingSignUpAvatar`.
struct AccountSetupProfileAvatar: View {
    @Environment(\.locale) private var locale
    /// The step's title. Sign Up's pane draws none, so the editable screen keeps it visually, but
    /// VoiceOver still needs the heading every other step screen has; the avatar carries it.
    let titleKey: String
    let avatar: SignUpProfileImage?
    let displayName: String
    var isEnabled = true
    let choosePhoto: () -> Void
    let removePhoto: () -> Void

    var body: some View {
        VStack(spacing: OnboardingLayout.signUpAvatarToPickerSpacing) {
            ProfileDraftAvatarView(image: avatar, displayName: displayName, size: OnboardingLayout.signUpAvatarSize)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(L10n.string(titleKey, locale: locale))
                .accessibilityAddTraits(.isHeader)

            HStack(spacing: 8) {
                Button(action: choosePhoto) {
                    Text(L10n.string(avatar == nil ? "Add photo" : "Change photo", locale: locale))
                        .wnFont(.medium12)
                }
                .accessibilityIdentifier("onboarding.account-setup.photo")
                if avatar != nil {
                    Button(action: removePhoto) {
                        Text(L10n.string("Remove photo", locale: locale))
                            .wnFont(.medium12)
                    }
                }
            }
            .onboardingActionTier(.secondary)
            .controlSize(.small)
            .disabled(!isEnabled)
        }
        .frame(maxWidth: .infinity)
    }
}

/// A line under the avatar: that the details below are a proposal not yet shared, or — with a
/// spinner — that the step is being checked again.
struct AccountSetupProfileIntro: View {
    @Environment(\.locale) private var locale
    let messageKeys: [String]
    var isLoading = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            if isLoading {
                ProgressView().controlSize(.small)
            }
            VStack(spacing: 4) {
                ForEach(messageKeys, id: \.self) { Text(L10n.string($0, locale: locale)) }
            }
        }
        .wnFont(.medium12)
        .foregroundStyle(WNColor.backgroundContentSecondary)
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity)
        .fixedSize(horizontal: false, vertical: true)
    }
}

/// The form itself: the public-profile notice over Name and About, as on the sign-up pane.
struct AccountSetupProfileForm: View {
    @Environment(\.locale) private var locale
    @Binding var displayName: String
    @Binding var about: String
    var isEnabled = true

    var body: some View {
        VStack(alignment: .leading, spacing: OnboardingLayout.titleToFieldsSpacing) {
            PublicProfileNote()

            VStack(alignment: .leading, spacing: OnboardingLayout.fieldSpacing) {
                WNInput(
                    label: L10n.string("Name", locale: locale),
                    prompt: L10n.string("Enter your name", locale: locale),
                    text: $displayName,
                    isEnabled: isEnabled
                )
                .accessibilityIdentifier("onboarding.account-setup.name")

                WNInput(
                    label: L10n.string("About", locale: locale),
                    prompt: L10n.string("Introduce yourself", locale: locale),
                    text: $about,
                    lineLimit: OnboardingLayout.aboutFieldLineLimit,
                    isEnabled: isEnabled
                )
                .accessibilityIdentifier("onboarding.account-setup.about")
            }
        }
    }
}

#Preview("Add your profile") {
    let model = OnboardingCoordinator.preview(
        steps: [
            OnboardingStepStateFfi(
                step: .profile, status: .needsInput, findings: [], actions: [.editProfile, .continueWithout],
                checkedAt: nil
            ),
            OnboardingStepStateFfi(step: .follows, status: .pending, findings: [], actions: [], checkedAt: nil),
            OnboardingStepStateFfi(step: .relays, status: .pending, findings: [], actions: [], checkedAt: nil),
        ]
    )
    AccountSetupStepScreen(model: model, step: .profile)
        .frame(width: AccountSetupStepLayoutMetrics.previewSize.width, height: 680)
}

#Preview("Couldn't load profile") {
    let model = OnboardingCoordinator.preview(steps: [
        OnboardingStepStateFfi(
            step: .profile, status: .retryableFailure,
            findings: [.init(issue: .timedOut, endpoint: "wss://relay.example.com")],
            actions: [.retry, .continueWithout], checkedAt: nil
        )
    ])
    AccountSetupStepScreen(model: model, step: .profile)
        .frame(
            width: AccountSetupStepLayoutMetrics.previewSize.width,
            height: AccountSetupStepLayoutMetrics.previewSize.height
        )
}
