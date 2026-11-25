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
    let model: RelaySettingsViewModel
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
        return model.endpoints.contains { $0.id == key }
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
            && !model.isSaving
    }

    var body: some View {
        VStack(spacing: 0) {
            AddRelaySheetHeader()
            Divider()
            AddRelaySheetForm(
                relayURL: $relayURL,
                selectedRoles: $selectedRoles,
                isURLFocused: $isURLFocused,
                validationError: validationError,
                onSubmit: add
            )
            Divider()
            AddRelaySheetFooter(
                canAdd: canAdd,
                onCancel: { dismiss() },
                onAdd: add
            )
        }
        .frame(minWidth: 440, idealWidth: 480, minHeight: 360, idealHeight: 420)
        .onAppear { isURLFocused = true }
    }

    private var validationError: String? {
        if isDuplicate {
            return L10n.string("This account already uses this relay.")
        }
        if isMalformed {
            return L10n.string("Relay URLs must use wss:// (cleartext ws:// is allowed only for localhost).")
        }
        return nil
    }

    private func add() {
        guard canAdd else { return }
        let relay = normalizedURL
        let roles = selectedRoles
        dismiss()
        Task { await model.addRelay(relay, roles: roles) }
    }
}

private struct AddRelaySheetHeader: View {
    var body: some View {
        HStack {
            Text(L10n.string("Add relay"))
                .font(.title3.weight(.semibold))
                .foregroundStyle(WNColor.textPrimary)
                .accessibilityAddTraits(.isHeader)
            Spacer()
        }
        .padding(.horizontal, 20)
        .padding(.top, 16)
        .padding(.bottom, 12)
    }
}

private struct AddRelaySheetForm: View {
    @Binding var relayURL: String
    @Binding var selectedRoles: Set<RelayRole>
    var isURLFocused: FocusState<Bool>.Binding
    let validationError: String?
    let onSubmit: () -> Void

    var body: some View {
        Form {
            SettingsSection(
                title: L10n.string("Relay URL"),
                footer: validationError == nil ? L10n.string("Enter a relay URL beginning with wss://.") : nil
            ) {
                TextField(
                    L10n.string("Relay URL"),
                    text: $relayURL,
                    prompt: Text(L10n.string("wss://relay.example.com"))
                )
                .labelsHidden()
                .textFieldStyle(.roundedBorder)
                .focused(isURLFocused)
                .onSubmit(onSubmit)

                if let validationError {
                    Text(validationError)
                        .font(.caption)
                        .foregroundStyle(WNColor.intentionErrorContent)
                        .fixedSize(horizontal: false, vertical: true)
                }
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
}

private struct AddRelaySheetFooter: View {
    let canAdd: Bool
    let onCancel: () -> Void
    let onAdd: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Spacer()

            Button(L10n.string("Cancel"), action: onCancel)
                .wnSecondaryButtonStyle()
                .keyboardShortcut(.cancelAction)

            Button(L10n.string("Add"), action: onAdd)
                .wnPrimaryButtonStyle()
                .keyboardShortcut(.defaultAction)
                .disabled(!canAdd)
        }
        .wnSheetFooterButtons()
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }
}

#Preview {
    AddRelaySheet(model: RelaySettingsViewModel(accountRef: "preview", runtime: nil))
}
