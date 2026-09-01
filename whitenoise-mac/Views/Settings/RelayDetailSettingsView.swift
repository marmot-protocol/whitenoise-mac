//
//  RelayDetailSettingsView.swift
//  whitenoise-mac
//
//  One relay: what it is, what this account uses it for, and the way to stop using it.
//
//  `wn-ios-prototype`'s `RelayDetailView`, which the settings drawer reaches by swapping the
//  Relays page's body rather than by pushing — there is no navigation stack in the drawer, so
//  the way back is the chevron `SettingsScaffold` draws beside the title.
//
//  Two rules from `docs/screens/settings.md` are the whole design here:
//
//  * "Relay Details is the sole role-editing surface" — the overview names a relay and its URL,
//    and this page is where `Use for` is decided.
//  * "Relay-detail role changes apply immediately" — each toggle publishes its list on the spot.
//
//  Where it departs: the prototype confirms turning off a role's last relay and then permits the
//  degraded state. The core refuses to publish an empty relay list, so that confirmation would
//  be a promise the next call breaks. The toggle is disabled instead and its footer says what to
//  do — add another relay first. Removal follows the same rule, and its confirmation is the
//  prototype's consequence-aware alert for every relay that *can* be removed.
//

import SwiftUI

struct RelayDetailSettingsView: View {
    @Environment(WorkspaceState.self) private var workspace
    let relay: RelayEndpointItem
    let onBack: () -> Void

    @State private var isRemovePresented = false

    /// The roles that have no other relay, which is what disables both the toggle and Remove.
    private var lockedRoles: [RelayRole] {
        workspace.relaySettings.rolesDependingOnly(on: relay.url)
    }

    var body: some View {
        // The relay's name is the page title, so the prototype's `Name` row is not repeated
        // underneath it — the header is that row. `URL` and `Status` are what remain of its
        // details section.
        SettingsScaffold(
            title: relay.displayName,
            backAction: onBack
        ) {
            SettingsSection(
                footer: relay.isInsecure
                    ? L10n.string(
                        "This relay uses cleartext ws://, so the metadata this account sends it is not "
                            + "encrypted in transit.")
                    : nil
            ) {
                SettingsValueRow(
                    title: L10n.string("URL"),
                    value: relay.url,
                    monospaced: true,
                    truncatesMiddle: true,
                    isSelectable: true
                )
                LabeledContent(L10n.string("Status")) {
                    RelayPublishStateLabel(state: relay.publishState)
                }
            }

            // One section per role rather than one `Use for` section with two toggles: each role
            // explains itself differently, and a group's footer is where an explanation belongs
            // (see `SettingsGroupedForm`). The section titled `Use for` is the first of them.
            ForEach(Array(RelayRole.allCases.enumerated()), id: \.element) { index, role in
                RelayRoleToggleSection(
                    relay: relay,
                    role: role,
                    title: index == 0 ? L10n.string("Use for") : nil,
                    isLocked: lockedRoles.contains(role)
                )
            }

            SettingsSection(footer: removalFooter) {
                Button(role: .destructive) {
                    isRemovePresented = true
                } label: {
                    Text(L10n.string("Remove relay"))
                }
                .disabled(!lockedRoles.isEmpty || workspace.isSavingRelays)
            }
        }
        .confirmationDialog(
            String(format: L10n.string("Remove %@?"), relay.displayName),
            isPresented: $isRemovePresented,
            titleVisibility: .visible
        ) {
            Button(L10n.string("Remove relay"), role: .destructive) {
                // Back to the list first: this page is a view of a relay that is about to stop
                // existing, and the removal itself is a round trip. Returning now means the
                // reader watches the list they acted on rather than a detail page for something
                // being deleted — the prototype's "confirmation first dismisses the alert and
                // returns to Relays, then removes the endpoint".
                onBack()
                Task { await workspace.removeRelay(relay.url) }
            }
            Button(L10n.string("Cancel"), role: .cancel) {}
        } message: {
            Text(L10n.string("This account will stop using this relay."))
        }
    }

    /// Why Remove is unavailable, or what removing costs.
    private var removalFooter: String {
        guard !lockedRoles.isEmpty else {
            return L10n.string("This account will stop using this relay.")
        }
        return String(
            format: L10n.string(
                "This is the only relay for %@. Add another relay before removing this one."),
            ListFormatter.localizedString(byJoining: lockedRoles.map(\.label))
        )
    }
}

/// One role's toggle, with the role's own explanation under it.
struct RelayRoleToggleSection: View {
    @Environment(WorkspaceState.self) private var workspace
    let relay: RelayEndpointItem
    let role: RelayRole
    var title: String?
    /// Whether this is the role's only relay, which makes turning it off impossible rather than
    /// merely consequential.
    let isLocked: Bool

    var body: some View {
        SettingsSection(title: title, footer: footer) {
            WNToggle(
                role.label,
                systemImage: role.symbol,
                isOn: Binding(
                    get: { relay.roles.contains(role) },
                    set: { isEnabled in
                        Task {
                            await workspace.setRelayRole(role, isEnabled: isEnabled, forRelay: relay.url)
                        }
                    }
                )
            )
            .disabled(isDisabled)
        }
    }

    /// A locked toggle is only disabled while it is *on*: the state it cannot leave. Assigning
    /// the role stays available, which is what makes a second relay for it reachable at all.
    private var isDisabled: Bool {
        workspace.isSavingRelays || (isLocked && relay.roles.contains(role))
    }

    private var footer: String {
        guard isLocked, relay.roles.contains(role) else { return role.explanation }
        return role.explanation + " "
            + String(
                format: L10n.string("%@ needs at least one relay, and this is the only one."),
                role.label
            )
    }
}

/// The relay's publish state, spelled out beside `Status`.
struct RelayPublishStateLabel: View {
    let state: RelayPublishState

    var body: some View {
        Label(state.label, systemImage: state.symbol)
            .wnFont(.medium12)
            .foregroundStyle(
                state == .published ? WNColor.intentionSuccessContent : WNColor.intentionWarningContent
            )
    }
}
