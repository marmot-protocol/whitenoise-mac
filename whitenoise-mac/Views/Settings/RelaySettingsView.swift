//
//  RelaySettingsView.swift
//  whitenoise-mac
//
//  The Relays page: one list of every relay this account uses, a step into any of them, and
//  the two actions that change the set — add one, or go back to the defaults.
//
//  Ported from `wn-ios-prototype`'s `RelaysPrototypeView` (`docs/screens/settings.md` §Relays),
//  which settles four things this page used to do differently:
//
//  * **One union list, not a list per kind.** The page opened on a `Picker` that swapped the
//    rows between the NIP-65 list and the inbox list, so half the account's relays were always
//    invisible and a relay in both lists looked like two relays. The prototype's rule: "A
//    native `Form` presents one union list of configured relay endpoints. The main list is the
//    complete overview."
//  * **Roles live in the detail.** "Every collapsed relay row uses the same restrained two-line
//    hierarchy: relay name, then the complete URL" — role assignment stays out of the overview
//    and `RelayDetailSettingsView` is the only place it is edited.
//  * **No Save button.** Adding, removing and role changes apply immediately, each publishing
//    the list it touches. The old draft-plus-Save flow could not survive its own edit window:
//    see the comment it needed about an edit made while a save was in flight.
//  * **Consequences up front.** Removal and Restore Defaults both confirm, and both say what
//    they cost.
//
//  Where this page departs from the prototype, it is because the core cannot back it: there is
//  no per-relay connection state and no read-only relay here (see `RelayConfiguration.swift`),
//  and an empty relay list is refused, so the last relay of a role is not something the reader
//  is offered a confirmation for — the affordance is disabled and the reason is given.
//

import SwiftUI

struct RelaySettingsView: View {
    @Environment(WorkspaceState.self) private var workspace
    /// The relay whose detail is open, as `RelayEndpointItem.id`. Held as an id rather than as
    /// the item so the detail always re-reads the live snapshot after a role change, and falls
    /// back to the list when the relay it was showing is gone.
    @State private var openRelayID: String?

    private var openRelay: RelayEndpointItem? {
        guard let openRelayID else { return nil }
        return workspace.relayEndpoints.first { $0.id == openRelayID }
    }

    var body: some View {
        if let openRelay {
            RelayDetailSettingsView(relay: openRelay) {
                openRelayID = nil
            }
        } else {
            RelayListSettingsView { relay in
                openRelayID = relay.id
            }
        }
    }
}

/// The overview: what needs attention, every endpoint, and the two set-level actions.
struct RelayListSettingsView: View {
    @Environment(WorkspaceState.self) private var workspace
    @State private var isAddRelayPresented = false
    @State private var isRestoreDefaultsPresented = false
    let openRelay: (RelayEndpointItem) -> Void

    private var endpoints: [RelayEndpointItem] {
        workspace.relayEndpoints
    }

    var body: some View {
        SettingsScaffold(
            title: L10n.string("Relays"),
            subtitle: L10n.string("Manage the relay lists published for this account.")
        ) {
            if workspace.relaySettings.relaysNeedAttention {
                SettingsSection {
                    RelayAttentionRow(summary: workspace.relaySettings.relayAttentionSummary)
                }
            }

            SettingsSection(
                footer: L10n.string(
                    "Relays let this account publish its profile and receive invitations to new chats.")
            ) {
                if endpoints.isEmpty {
                    Text(L10n.string("No relays configured."))
                        .wnFont(.medium12)
                        .foregroundStyle(WNColor.backgroundContentSecondary)
                } else {
                    ForEach(endpoints) { relay in
                        RelayEndpointRow(relay: relay) {
                            openRelay(relay)
                        }
                    }
                }

                Button {
                    isAddRelayPresented = true
                } label: {
                    Label(L10n.string("Add relay"), systemImage: "plus.circle")
                }
                .disabled(workspace.isSavingRelays || workspace.activeAccount == nil)
            }

            SettingsSection(footer: L10n.string("Restores the relays a new account starts on.")) {
                Button(role: .destructive) {
                    isRestoreDefaultsPresented = true
                } label: {
                    Text(L10n.string("Restore default relays"))
                }
                .disabled(
                    workspace.isSavingRelays
                        || workspace.activeAccount == nil
                        || workspace.relaySettings.isDefaultRelayConfiguration
                )

                if workspace.isSavingRelays {
                    HStack(spacing: 8) {
                        ProgressView()
                            .controlSize(.small)
                        Text(L10n.string("Publishing relay lists..."))
                            .wnFont(.medium12)
                            .foregroundStyle(WNColor.backgroundContentSecondary)
                    }
                }
            }
        }
        .sheet(isPresented: $isAddRelayPresented) {
            AddRelaySheet()
        }
        .confirmationDialog(
            L10n.string("Restore default relays?"),
            isPresented: $isRestoreDefaultsPresented,
            titleVisibility: .visible
        ) {
            Button(L10n.string("Restore defaults"), role: .destructive) {
                Task { await workspace.restoreDefaultRelays() }
            }
            Button(L10n.string("Cancel"), role: .cancel) {}
        } message: {
            Text(
                L10n.string(
                    "This replaces both relay lists for this account with the defaults. Relays you added "
                        + "will be removed."
                )
            )
        }
    }
}

/// The orange notice above the list when a role has no usable relay.
///
/// The prototype's inline callout, drawn as a row rather than as a `WNCallout`: it sits inside
/// the same grouped `Form` the relays do, and a callout brings its own box — a second card
/// inside the first. A tinted glyph, a title, and the detail underneath is what the prototype's
/// `Label` is, and it is what this is.
struct RelayAttentionRow: View {
    let summary: String

    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text(L10n.string("Relays need attention"))

                Text(summary)
                    .wnFont(.medium10)
                    .foregroundStyle(WNColor.backgroundContentSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } icon: {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(WNColor.intentionWarningContent)
        }
        .accessibilityElement(children: .combine)
    }
}

/// One relay in the overview: its name, its complete URL, and how the lists it belongs to are
/// doing. Pressing it opens the relay's detail.
///
/// The prototype's `relayRow`, with the chevron a macOS row needs to read as a way in — the
/// drawer has no navigation stack to draw one for us. Two lines and nothing else: the roles are
/// deliberately absent here (see this file's header).
struct RelayEndpointRow: View {
    let relay: RelayEndpointItem
    let action: () -> Void

    /// The row's only hover feedback. A grouped `Form` row cannot be given a hover fill without
    /// fighting its own insets, and the chevron is the part that says "this goes somewhere" —
    /// so the chevron is what answers the pointer.
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(relay.displayName)

                        if relay.isInsecure {
                            Image(systemName: "lock.open.trianglebadge.exclamationmark")
                                .wnFont(.semiBold10)
                                .foregroundStyle(WNColor.intentionWarningContent)
                        }
                    }

                    Text(relay.url)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(WNColor.backgroundContentSecondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                Spacer(minLength: 8)

                RelayPublishStateBadge(state: relay.publishState)

                Image(systemName: "chevron.right")
                    .wnFont(.semiBold10)
                    .foregroundStyle(
                        isHovering ? WNColor.backgroundContentSecondary : WNColor.backgroundContentTertiary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("\(relay.displayName), \(relay.url)"))
        .accessibilityValue(Text(accessibilityValue))
        .accessibilityAddTraits(.isButton)
        .accessibilityHint(Text(L10n.string("Opens this relay's details.")))
    }

    private var accessibilityValue: String {
        var values = [relay.publishState.label]
        if relay.isInsecure {
            values.append(L10n.string("Insecure"))
        }
        return ListFormatter.localizedString(byJoining: values)
    }
}

/// Whether the lists a relay belongs to have reached the network, as a glyph and a word.
///
/// This is the honest replacement for the prototype's Connected / Reconnecting / Disconnected
/// dot: nothing here can see a socket, but the core does say which relay lists it has managed
/// to publish. Everything normal is one quiet green check; the state worth reading is named.
struct RelayPublishStateBadge: View {
    let state: RelayPublishState

    var body: some View {
        switch state {
        case .published:
            Image(systemName: state.symbol)
                .foregroundStyle(WNColor.intentionSuccessContent)
                .help(state.label)
                .accessibilityHidden(true)
        case .notPublished:
            Label(state.label, systemImage: state.symbol)
                .wnFont(.medium10)
                .foregroundStyle(WNColor.intentionWarningContent)
                .accessibilityHidden(true)
        }
    }
}
