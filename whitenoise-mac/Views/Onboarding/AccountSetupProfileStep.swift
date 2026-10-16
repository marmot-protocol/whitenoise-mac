import MarmotKit
import SwiftUI
import UniformTypeIdentifiers

/// The profile step's screen: `whitenoise-ios`'s `IdentityProfileSetupView` in its account-setup
/// mode. While MarmotKit lets the profile be edited it is the sign-up form — a photo, a name and a
/// description — and Save publishes it; otherwise it explains why the profile could not be loaded
/// and offers a retry. Not Now skips the step when the step is optional.
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
        AccountSetupProfilePlan(snapshot: model.snapshot)
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
            AccountSetupCallout(
                titleKey: plan.titleKey,
                symbol: "person.crop.circle",
                isError: plan.isInterrupted || (!plan.canEdit && !model.isBusy),
                isLoading: model.isBusy && active == nil
            ) {
                ForEach(plan.messageKeys, id: \.self) { Text(L10n.string($0, locale: locale)) }
            }

            if plan.canEdit {
                AccountSetupProfileForm(
                    displayName: $displayName,
                    about: $about,
                    avatar: avatar,
                    isEnabled: isEnabled,
                    choosePhoto: {
                        photoError = nil
                        isFileImporterPresented = true
                    },
                    removePhoto: { avatar = nil }
                )
            }

            AccountSetupNoActionLines(step: .profile, snapshot: model.snapshot)
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

/// The form itself: the photo over its pill, then Name and About, as on the sign-up pane.
struct AccountSetupProfileForm: View {
    @Environment(\.locale) private var locale
    @Binding var displayName: String
    @Binding var about: String
    let avatar: SignUpProfileImage?
    var isEnabled = true
    let choosePhoto: () -> Void
    let removePhoto: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: OnboardingLayout.fieldSpacing) {
            VStack(spacing: OnboardingLayout.signUpAvatarToPickerSpacing) {
                ProfileDraftAvatarView(image: avatar, displayName: displayName, size: 96)

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

            PublicProfileNote()

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

#Preview("Add your profile") {
    let model = OnboardingCoordinator.preview(steps: [
        OnboardingStepStateFfi(
            step: .profile, status: .needsInput, findings: [], actions: [.editProfile, .continueWithout],
            checkedAt: nil
        )
    ])
    AccountSetupStepSheet(model: model, step: .profile)
}

#Preview("Couldn't load profile") {
    let model = OnboardingCoordinator.preview(steps: [
        OnboardingStepStateFfi(
            step: .profile, status: .retryableFailure,
            findings: [.init(issue: .timedOut, endpoint: "wss://relay.example.com")],
            actions: [.retry, .continueWithout], checkedAt: nil
        )
    ])
    AccountSetupStepSheet(model: model, step: .profile)
}
