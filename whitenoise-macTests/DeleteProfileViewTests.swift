import AppKit
import SwiftUI
import Testing

@testable import whitenoise_mac

/// The Delete Profile page's confirmation form as drawn: its hint and error rows come and go with
/// the model's state. Measured rather than inspected: the test host builds no accessibility tree.
///
/// `.serialized` and `@MainActor` because hosting switches `NSAppearance`-dependent drawing, which
/// off the main thread takes the test host down.
@Suite(.serialized) @MainActor
struct DeleteProfileViewTests {
    private let account = AccountItem.samples[0]

    private var challenge: String {
        AccountWipeConfirmation.challenge(
            displayName: account.displayName,
            accountRef: account.accountRef,
            fallback: L10n.string("WIPE")
        )
    }

    /// Stray spaces around the right name get a line saying why the button stays off; the exact
    /// name, or nothing typed yet, does not.
    @Test func onlyAPaddedNameDrawsTheWhitespaceHint() {
        let model = DeleteProfileViewModel(removeAccount: { _ in nil })
        let empty = formHeight(model)

        model.confirmation = challenge
        let exact = formHeight(model)

        model.confirmation = " \(challenge) "
        let padded = formHeight(model)

        #expect(exact == empty)
        #expect(padded > exact)
    }

    /// A refused deletion draws its reason under the field, and the next edit takes it away again.
    @Test func aFailedDeletionDrawsItsReasonUntilTheNextEdit() async {
        let model = DeleteProfileViewModel(removeAccount: { _ in "The relay refused." })
        model.confirmation = challenge
        let before = formHeight(model)

        let removed = await model.delete(account: account, challenge: challenge, isAccountMutationInProgress: false)
        let failed = formHeight(model)

        model.confirmation = String(challenge.dropLast())
        let edited = formHeight(model)

        #expect(!removed)
        #expect(failed > before)
        #expect(edited == before)
    }

    /// The whole page lays out around the form: identity, the six consequences, then the gate.
    @Test func thePageIsTallerThanItsConfirmationForm() {
        let model = DeleteProfileViewModel(removeAccount: { _ in nil })
        let page = Self.fittingSize(
            DeleteProfileSettingsView(model: model, account: account, isAccountMutationInProgress: false)
                .frame(width: 640)
        )

        #expect(page.height > formHeight(model))
    }

    private func formHeight(_ model: DeleteProfileViewModel) -> CGFloat {
        Self.fittingSize(
            DeleteProfileConfirmationForm(
                model: model,
                account: account,
                challenge: challenge,
                isAccountMutationInProgress: false
            )
            .frame(width: 520)
        ).height
    }

    private static func fittingSize(_ view: some View) -> CGSize {
        let host = NSHostingView(rootView: view.environment(WorkspaceState.preview()))
        host.layoutSubtreeIfNeeded()
        return host.fittingSize
    }
}
