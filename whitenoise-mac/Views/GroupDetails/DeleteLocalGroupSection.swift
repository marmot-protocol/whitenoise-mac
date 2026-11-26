import SwiftUI

struct DeleteLocalGroupSection: View {
    let model: GroupSafetyViewModel
    var groupIsBusy = false
    let onForgotten: () -> Void
    @State private var showsConfirmation = false
    @State private var error: String?
    @State private var isDeleting = false

    var body: some View {
        Section {
            DetailsDestructiveRow(
                title: L10n.string("Delete Local Group"), systemImage: "trash", isInProgress: isDeleting
            ) {
                error = nil
                showsConfirmation = true
            }
            .disabled(groupIsBusy || model.isModerating)
            .sheet(isPresented: $showsConfirmation) {
                VStack(alignment: .leading, spacing: 16) {
                    Text(L10n.string("Delete local group?")).font(.headline)
                    Text(
                        L10n.string(
                            "This deletes the group’s history from this Mac. Other members keep their history. To rejoin on this Mac, ask a member for a new invitation."
                        )
                    )
                    .fixedSize(horizontal: false, vertical: true)
                    SettingsErrorView(error: error)
                    HStack {
                        if isDeleting { ProgressView().controlSize(.small) }
                        Spacer()
                        Button(L10n.string("Cancel"), role: .cancel) { showsConfirmation = false }
                            .keyboardShortcut(.cancelAction)
                            .disabled(isDeleting)
                        Button(L10n.string("Delete Local Group"), role: .destructive) {
                            Task { await forgetGroup() }
                        }
                        .disabled(groupIsBusy || model.isModerating)
                    }
                    .controlSize(.large)
                    .buttonBorderShape(.capsule)
                }
                .padding(20)
                .frame(width: 420)
                .interactiveDismissDisabled(isDeleting)
            }
        } footer: {
            SettingsFooterText(L10n.string("Deletes this chat's local history from this device."))
        }
    }

    private func forgetGroup() async {
        guard !groupIsBusy, !isDeleting, !model.isModerating else { return }
        isDeleting = true
        defer { isDeleting = false }
        error = nil
        do {
            if try await model.forgetLocally() {
                showsConfirmation = false
                onForgotten()
            }
        } catch {
            self.error = UserFacingError.message(for: error)
        }
    }
}

#if DEBUG
    #Preview {
        Form {
            DeleteLocalGroupSection(
                model: GroupSafetyViewModel(
                    accountRef: "preview", groupIdHex: "group",
                    runtime: FakeMarmotRuntime(accounts: [], storageRootPath: NSTemporaryDirectory()))
            ) {}
        }
        .formStyle(.grouped)
    }
#endif
