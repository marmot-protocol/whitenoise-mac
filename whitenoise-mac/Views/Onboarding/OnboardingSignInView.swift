//
//  OnboardingSignInView.swift
//  whitenoise-mac
//
//  The second onboarding pane: paste a key, get in.
//

import SwiftUI

/// The sign-in pane.
///
/// `wn-ios-prototype` pushes this onto a `NavigationStack` — a titled screen with a `Private Key`
/// section, the key field, a line of hint-or-error under it, and the CTA pinned to the bottom
/// edge. Everything but the push survives the port: this is the same column in the same order,
/// inside `OnboardingScaffold`, which keeps the mark above it and puts a back control where the
/// nav bar's would have been.
///
/// Like the prototype, the field takes a private key only — `LoginIdentityDraft` decides that,
/// and an `npub1…` is refused there rather than handed to the core. The QR scanner the prototype
/// offers beside the field is left out — it exists because a phone cannot be pasted into
/// from a desktop, and here ⌘V and the field's own paste accessory cover it.
struct OnboardingSignInView: View {
    @Environment(WorkspaceState.self) private var workspace

    private var draft: LoginIdentityDraft {
        LoginIdentityDraft(workspace.loginIdentity)
    }

    private var isLoggingIn: Bool {
        workspace.authenticationActivity == .login
    }

    /// The field's own complaint first, the core's second — and the core's only while the field
    /// still holds nothing.
    ///
    /// `lastError` is cleared when the next attempt starts, not when the field changes, so on its
    /// own it outlives the key it is about: `login()` scrubs the field on failure (issue #32), and
    /// the replacement key pasted into the empty field it leaves behind would inherit the previous
    /// key's error. `LoginIdentityDraft.showsLastAttemptError` is what decides that the complaint
    /// is no longer about what is in the field.
    private var message: String? {
        if draft == .invalid {
            return L10n.string("That private key isn't valid. Check it and try again.")
        }
        return draft.showsLastAttemptError ? workspace.lastError : nil
    }

    var body: some View {
        @Bindable var workspace = workspace

        OnboardingScaffold(exit: .back { workspace.cancelLogin() }) {
            VStack(alignment: .leading, spacing: 8) {
                // Primary, and inset to the key's first character, as `whitenoise-ios` draws its
                // section label. The hint-or-error line below takes the same inset.
                Text(L10n.string("Private Key"))
                    .wnFont(.semiBold14)
                    .foregroundStyle(WNColor.backgroundContentPrimary)
                    .padding(.leading, OnboardingKeyField.textInset)

                OnboardingKeyField(
                    text: $workspace.loginIdentity,
                    isEnabled: !workspace.isAuthenticating,
                    onSubmit: submit
                )

                OnboardingMessageLine(
                    message: message,
                    hint: L10n.string("It starts with nsec."),
                    minimumHeight: OnboardingMessageLine.singleLineReservedHeight
                )
                .padding(.leading, OnboardingKeyField.textInset)
            }
        } actions: {
            OnboardingActionButton(
                title: L10n.string(isLoggingIn ? "Logging in..." : "Sign In"),
                tier: .primary,
                isLoading: isLoggingIn,
                action: submit
            )
            .disabled(!draft.isSubmittable || workspace.isAuthenticating)
            .accessibilityIdentifier("onboarding.submit-key")
        }
        .controlSize(.large)
        .wnButtonShape(.capsule)
    }

    private func submit() {
        guard draft.isSubmittable, !workspace.isAuthenticating else { return }
        Task { await workspace.login() }
    }
}
