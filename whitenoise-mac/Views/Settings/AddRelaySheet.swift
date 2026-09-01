//
//  AddRelaySheet.swift
//  whitenoise-mac
//
//  Adding a relay: a URL, what the account should use it for, and one press that publishes both.
//
//  `wn-ios-prototype`'s `AddRelaySheet`, kept whole: "a URL field, the helper ... and a `Use For`
//  selection. Every new relay role starts selected. Add remains system-disabled for a duplicate,
//  malformed, or empty URL and for an empty role selection." Add applies immediately — nothing is
//  staged, which is why this sheet has no Save of its own and closes on the press.
//
//  The one difference is the rule the helper states. The prototype accepts `wss://` only; this app
//  also accepts cleartext `ws://` on a loopback host so a local development relay is usable, and
//  says so — `RelayURLValidator` is the authority, and the helper is its sentence.
//

import SwiftUI

struct AddRelaySheet: View {
    @Environment(WorkspaceState.self) private var workspace
    @Environment(\.dismiss) private var dismiss

    @State private var relayURL = ""
    /// "Every new relay role starts selected."
    @State private var selectedRoles = Set(RelayRole.allCases)
    @FocusState private var isURLFocused: Bool

    /// The URL as it would be stored: trimmed, with any trailing slash dropped.
    private var normalizedURL: String {
        RelayURLValidator.normalized(relayURL)
    }

    private var isDuplicate: Bool {
        let key = RelayURLValidator.identity(normalizedURL)
        guard !key.isEmpty else { return false }
        return workspace.relayEndpoints.contains { $0.id == key }
    }

    /// Malformed only once something has been typed, so an untouched field is not scolded.
    private var isMalformed: Bool {
        !normalizedURL.isEmpty && !RelayURLValidator.isAcceptable(normalizedURL)
    }

    private var canAdd: Bool {
        !normalizedURL.isEmpty
            && !isMalformed
            && !isDuplicate
            && !selectedRoles.isEmpty
            && !workspace.isSavingRelays
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            form
            Divider()
            footer
        }
        // Tall enough for the field, both role groups and their footers at the longest of the
        // ten languages (the two explanations wrap to two lines in six of them), and no taller —
        // at 480 the sheet closed on 100pt of empty space under the last footer.
        .frame(width: 480, height: 440)
        .onAppear { isURLFocused = true }
    }

    private var header: some View {
        HStack {
            Text(L10n.string("Add relay"))
                .wnFont(.semiBold14)
            Spacer()
            GlassCircleCloseButton(appearance: .outline) {
                dismiss()
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var form: some View {
        Form {
            SettingsSection(title: L10n.string("Relay URL"), footer: urlFooter) {
                TextField(
                    L10n.string("Relay URL"),
                    text: $relayURL,
                    prompt: Text(L10n.string("wss://relay.example.com"))
                )
                .labelsHidden()
                .textFieldStyle(.roundedBorder)
                .focused($isURLFocused)
                .onSubmit(add)
            }

            // The same one-section-per-role shape `RelayDetailSettingsView` uses, so the choice
            // made here and the choice edited later are visibly the same choice.
            ForEach(Array(RelayRole.allCases.enumerated()), id: \.element) { index, role in
                SettingsSection(
                    title: index == 0 ? L10n.string("Use for") : nil,
                    footer: role.explanation
                ) {
                    WNToggle(
                        role.label,
                        systemImage: role.symbol,
                        isOn: Binding(
                            get: { selectedRoles.contains(role) },
                            set: { isSelected in
                                if isSelected {
                                    selectedRoles.insert(role)
                                } else {
                                    selectedRoles.remove(role)
                                }
                            }
                        )
                    )
                }
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
    }

    /// The helper under the field, or what is wrong with what has been typed. One line, in the
    /// place the reader is already looking, rather than an alert after the press.
    private var urlFooter: String {
        if isDuplicate {
            return L10n.string("This account already uses this relay.")
        }
        if isMalformed {
            return L10n.string("Relay URLs must use wss:// (cleartext ws:// is allowed only for localhost).")
        }
        return L10n.string("Enter a relay URL beginning with wss://.")
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Spacer()

            // Elevated rather than the outlined tier, and capsule to match `Add`: the two sit
            // side by side, so a ringed 8pt rect beside a pill read as two unrelated controls
            // rather than one choice offered twice. Pepi called this on 2026-08-31, which
            // narrows `WNElevatedButtonStyle`'s "a sheet's Cancel wants the outlined tier" —
            // see the note there.
            Button(L10n.string("Cancel")) {
                dismiss()
            }
            .buttonStyle(.wnElevated)
            .wnButtonShape(.capsule)
            .keyboardShortcut(.cancelAction)

            WNPrimaryButton(size: .small, action: add) {
                Text(L10n.string("Add")).frame(minWidth: 72)
            }
            .wnButtonShape(.capsule)
            .keyboardShortcut(.defaultAction)
            .disabled(!canAdd)
        }
        .padding(16)
    }

    private func add() {
        guard canAdd else { return }
        let relay = normalizedURL
        let roles = selectedRoles
        dismiss()
        Task { await workspace.addRelay(relay, roles: roles) }
    }
}

#Preview {
    AddRelaySheet()
        .environment(WorkspaceState.preview())
}
