//
//  RelaySettingsView.swift
//  whitenoise-mac
//
//  The Relays page: the relay lists this account publishes, the rows that edit them,
//  and what the relays actually report back.
//

import SwiftUI

struct RelaySettingsView: View {
    @Environment(WorkspaceState.self) private var workspace

    var body: some View {
        @Bindable var workspace = workspace

        SettingsScaffold(
            title: L10n.string("Relays"),
            subtitle: L10n.string("Manage the relay lists published for this account.")
        ) {
            Section {
                RelayDiagnosticsView(settings: workspace.relaySettings)
            }

            Section(L10n.string("Relays")) {
                if workspace.relayDraft.isEmpty {
                    ContentUnavailableView("No relays", systemImage: "antenna.radiowaves.left.and.right")
                        .frame(minHeight: 160)
                } else {
                    ForEach(workspace.relayDraft, id: \.self) { relay in
                        RelayRow(url: relay, isInsecure: workspace.isInsecureRelay(relay)) {
                            workspace.removeRelayDraftURL(relay)
                        }
                    }
                }
            }

            Section(L10n.string("Add Relay")) {
                HStack(spacing: 8) {
                    TextField(
                        L10n.string(""), text: $workspace.newRelayURL, prompt: Text(L10n.string("wss://relay.example"))
                    )
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
                    .onSubmit {
                        workspace.addRelayDraftURL()
                    }
                    .frame(maxWidth: .infinity)

                    Picker(L10n.string("Relay list"), selection: $workspace.selectedRelaySection) {
                        ForEach(RelaySettingsSection.allCases) { section in
                            Text(section.label).tag(section)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(width: 96)
                    .onChange(of: workspace.selectedRelaySection) { _, section in
                        workspace.selectRelaySection(section)
                    }

                    Button {
                        workspace.addRelayDraftURL()
                    } label: {
                        Label(L10n.string("Add"), systemImage: "plus")
                    }
                    .buttonStyle(.wnSecondary)
                    .help(L10n.string("Add relay"))
                }
            }

            Section {
                HStack(spacing: 10) {
                    Button {
                        Task { await workspace.saveRelaySettings() }
                    } label: {
                        Label(
                            workspace.isSavingRelays ? L10n.string("Saving...") : L10n.string("Save relays"),
                            systemImage: "checkmark.circle")
                    }
                    .nativeGlassProminentButtonStyle()
                    .disabled(workspace.isSavingRelays || workspace.activeAccount == nil)

                    Button {
                        workspace.restoreRelayDraftDefaults()
                    } label: {
                        Label(L10n.string("Restore defaults"), systemImage: "arrow.counterclockwise")
                    }
                    .buttonStyle(.wnSecondary)
                    .disabled(workspace.isSavingRelays)

                    if workspace.isLoadingSettings {
                        ProgressView()
                            .controlSize(.small)
                    }

                    Spacer()
                }
            }

        }
    }
}

struct RelayDiagnosticsView: View {
    let settings: RelaySettingsSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: settings.isComplete ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(settings.isComplete ? .green : .orange)
                Text(L10n.string("Published Relay Lists"))
                    .wnFont(.semiBold12)
                Spacer()
                Text(settings.isComplete ? L10n.string("Complete") : L10n.string("Missing"))
                    .wnFont(.semiBold10)
                    .foregroundStyle(WNColor.backgroundContentSecondary)
            }

            RelayDiagnosticsRow(
                title: L10n.string("NIP-65"), systemImage: "list.bullet", relays: settings.publishedNip65)
            RelayDiagnosticsRow(
                title: L10n.string("Inbox"), systemImage: "tray.and.arrow.down", relays: settings.publishedInbox)

            if !settings.missing.isEmpty {
                Text(String(format: L10n.string("Missing: %@"), settings.missing.joined(separator: ", ")))
                    .wnFont(.medium10)
                    .foregroundStyle(WNColor.intentionWarningContent)
            }
        }
        .padding(.vertical, 4)
    }
}

struct RelayDiagnosticsRow: View {
    let title: String
    let systemImage: String
    let relays: [String]

    var body: some View {
        DisclosureGroup {
            if relays.isEmpty {
                Text(L10n.string("Not published"))
                    .wnFont(.medium10)
                    .foregroundStyle(WNColor.backgroundContentSecondary)
            } else {
                ForEach(relays, id: \.self) { relay in
                    Text(relay)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(WNColor.backgroundContentSecondary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: systemImage)
                    .wnFont(.medium10)
                    .foregroundStyle(WNColor.backgroundContentSecondary)
                    .frame(width: 18)
                Text(title)
                Spacer()
                // Drawn on `fillSecondary`, so it takes a `fillContent*` token rather than a
                // `backgroundContent*` one. `fillContentTertiary` is the de-emphasized step of that
                // family — the right weight for a count beside its own row title, and the same
                // `500`/`400` ramp steps this already rendered at.
                Text(verbatim: "\(relays.count)")
                    .wnFont(.medium10.monospacedDigit())
                    .foregroundStyle(WNColor.fillContentTertiary)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(WNColor.fillSecondary, in: Capsule())
                    .overlay(Capsule().strokeBorder(WNColor.borderTertiary, lineWidth: 1))
            }
            .wnFont(.medium12)
        }
    }
}

struct RelayRow: View {
    let url: String
    var isInsecure: Bool = false
    let remove: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: isInsecure ? "lock.open.trianglebadge.exclamationmark" : "network")
                .wnFont(.semiBold10)
                .foregroundStyle(isInsecure ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
                .frame(width: 20)
                .help(
                    isInsecure
                        ? L10n.string("Insecure cleartext relay (ws://). Relay metadata is not encrypted in transit.")
                        : "")

            VStack(alignment: .leading, spacing: 2) {
                Text(url)
                    .font(.system(.callout, design: .monospaced))
                    .textSelection(.enabled)

                if isInsecure {
                    Text(
                        RelayURLValidator.classify(url) == .insecureLoopback
                            ? "Insecure — cleartext ws:// (loopback only)"
                            : "Insecure — cleartext ws:// (public host)"
                    )
                    .wnFont(.medium10)
                    .foregroundStyle(WNColor.intentionWarningContent)
                }
            }

            Spacer()

            Button(action: remove) {
                Image(systemName: "minus.circle")
            }
            .buttonStyle(.plain)
            .foregroundStyle(WNColor.backgroundContentSecondary)
            .help(L10n.string("Remove relay"))
        }
        .padding(.vertical, 4)
    }
}
