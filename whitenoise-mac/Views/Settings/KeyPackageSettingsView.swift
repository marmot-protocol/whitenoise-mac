//
//  KeyPackageSettingsView.swift
//  whitenoise-mac
//
//  Local KeyPackage inventory and the relay history observed by an explicit refresh.
//  MarmotKit owns lifecycle/provenance; this screen only formats the typed records.
//

import MarmotKit
import SwiftUI

struct KeyPackageSettingsView: View {
    let model: KeyPackageSettingsViewModel

    var body: some View {
        SettingsScaffold(
            title: L10n.string("Key Packages"),
            subtitle: L10n.string("Manage the KeyPackages this identity has published for invites."),
            back: .developerMode
        ) {
            SettingsSection {
                HStack(spacing: 10) {
                    Button {
                        Task { await model.refresh() }
                    } label: {
                        Label(L10n.string("Refresh"), systemImage: "arrow.clockwise")
                    }
                    .wnSecondaryButtonStyle()
                    .disabled(model.isRefreshing)

                    if model.isRefreshing {
                        ProgressView()
                            .controlSize(.small)
                    }

                    Spacer()
                }
            }

            SettingsSection(title: L10n.string("Key Packages")) {
                if model.isLoading && model.inventory.isEmpty {
                    ProgressView()
                        .frame(maxWidth: .infinity, minHeight: 120)
                } else if model.inventory.isEmpty {
                    ContentUnavailableView(L10n.string("No key packages"), systemImage: "key.slash")
                        .frame(minHeight: 180)
                } else {
                    ForEach(model.inventory, id: \.stableDisplayID) { entry in
                        KeyPackageInventoryRow(entry: entry)
                    }
                }
            }

            SettingsSection(title: L10n.string("Relay Event History")) {
                if model.relayEvents.isEmpty {
                    ContentUnavailableView(L10n.string("No key packages"), systemImage: "clock.arrow.circlepath")
                        .frame(minHeight: 140)
                } else {
                    ForEach(model.relayEvents, id: \.eventIdHex) { event in
                        KeyPackageRelayEventRow(event: event)
                    }
                }
            }

            if let error = model.error {
                Text(error.message)
                    .foregroundStyle(WNColor.backgroundContentDestructive)
            }
        }
        .task {
            await model.loadLocalInventory()
        }
    }
}

struct KeyPackageInventoryRow: View {
    let entry: AccountKeyPackageInventoryEntryFfi

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "key.fill")
                    .wnFont(.semiBold16)
                    .foregroundStyle(WNColor.fillContentPrimary)
                    .frame(width: 30, height: 30)
                    .background {
                        Circle().fill(WNColor.fillPrimary)
                    }

                VStack(alignment: .leading, spacing: 5) {
                    KeyPackageStateBadge(state: entry.localState)
                    KeyPackageValueRow(title: L10n.string("Event"), value: entry.record.eventIdHex)
                    KeyPackageValueRow(title: "KeyPackageRef", value: entry.record.keyPackageRefHex)
                    KeyPackageValueRow(title: L10n.string("Slot"), value: entry.record.keyPackageId)
                    Text(
                        ByteCountFormatter.string(
                            fromByteCount: Int64(clamping: entry.record.keyPackageBytes),
                            countStyle: .file
                        )
                    )
                    .wnFont(.medium10.monospacedDigit())
                    .foregroundStyle(WNColor.backgroundContentSecondary)
                }

                Spacer()
            }

            if !entry.record.sourceRelays.isEmpty {
                KeyPackageRelayList(relays: entry.record.sourceRelays)
                    .padding(.leading, 42)
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(entry.localState.accessibilityLabel)
    }
}

struct KeyPackageRelayEventRow: View {
    let event: AccountKeyPackageRelayEventFfi

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Label(
                    event.isCurrent ? L10n.string("Current") : L10n.string("Superseded"),
                    systemImage: event.isCurrent ? "checkmark.circle.fill" : "clock.arrow.circlepath"
                )
                .wnFont(.semiBold10)
                .foregroundStyle(event.isCurrent ? Color.green : WNColor.backgroundContentSecondary)

                Text(KeyPackageDisplay.date(event.createdAt))
                    .wnFont(.medium10)
                    .foregroundStyle(WNColor.backgroundContentSecondary)
            }

            KeyPackageValueRow(title: L10n.string("Event"), value: event.eventIdHex)
            KeyPackageValueRow(title: "KeyPackageRef", value: event.keyPackageRefHex)
            Text(
                ByteCountFormatter.string(
                    fromByteCount: Int64(clamping: event.keyPackageBytes),
                    countStyle: .file
                )
            )
            .wnFont(.medium10.monospacedDigit())
            .foregroundStyle(WNColor.backgroundContentSecondary)

            if !event.sourceRelays.isEmpty {
                KeyPackageRelayList(relays: event.sourceRelays)
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }
}

struct KeyPackageStateBadge: View {
    let state: AccountKeyPackageLocalStateFfi

    var body: some View {
        Label(state.displayLabel, systemImage: state.symbol)
            .wnFont(.semiBold10)
            .foregroundStyle(state.tint)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(state.tint.opacity(0.12), in: Capsule())
    }
}

struct KeyPackageValueRow: View {
    let title: String
    let value: String

    var body: some View {
        HStack(spacing: 6) {
            Text(title)
                .wnFont(.semiBold10)
                .foregroundStyle(WNColor.backgroundContentSecondary)
            Text(value.isEmpty ? L10n.string("Unknown") : DisplayText.short(value, head: 12, tail: 10))
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(WNColor.backgroundContentSecondary)
                .textSelection(.enabled)
        }
    }
}

struct KeyPackageRelayList: View {
    let relays: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(L10n.string("Source relays"))
                .wnFont(.semiBold10)
                .foregroundStyle(WNColor.backgroundContentSecondary)
            ForEach(relays, id: \.self) { relay in
                Text(relay)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(WNColor.backgroundContentSecondary)
                    .textSelection(.enabled)
            }
        }
    }
}

private enum KeyPackageDisplay {
    static func date(_ timestamp: UInt64) -> String {
        Date(timeIntervalSince1970: TimeInterval(Int64(clamping: timestamp)))
            .formatted(date: .abbreviated, time: .shortened)
    }
}

private extension AccountKeyPackageInventoryEntryFfi {
    var stableDisplayID: String {
        [record.keyPackageRefHex, record.eventIdHex, record.keyPackageId].joined(separator: ":")
    }
}

private extension AccountKeyPackageLocalStateFfi {
    var displayLabel: String {
        switch self {
        case .notLocal: L10n.string("Observed on relays")
        case .current: L10n.string("Current on this device")
        case .pendingReplacement: L10n.string("Pending replacement on this device")
        case .retainedPrivateMaterial: L10n.string("Retained on this device")
        case .otherOwned: L10n.string("Owned by this device")
        }
    }

    var accessibilityLabel: String { displayLabel }

    var symbol: String {
        switch self {
        case .notLocal: "checkmark.icloud.fill"
        case .current: "macbook"
        case .pendingReplacement: "arrow.triangle.2.circlepath"
        case .retainedPrivateMaterial: "archivebox.fill"
        case .otherOwned: "key.fill"
        }
    }

    var tint: Color {
        switch self {
        case .notLocal: .green
        case .current: MessagesPalette.sentBubble
        case .pendingReplacement: .orange
        case .retainedPrivateMaterial, .otherOwned: WNColor.backgroundContentSecondary
        }
    }
}

#Preview("Key Packages") {
    KeyPackageSettingsView(model: .preview())
        .environment(WorkspaceState.preview())
        .frame(width: 760, height: 640)
}

#Preview("Key Package Inventory Row") {
    KeyPackageInventoryRow(
        entry: AccountKeyPackageInventoryEntryFfi(record: .preview, localState: .current)
    )
    .padding()
    .frame(width: 520)
}

#Preview("Key Package Relay Event") {
    KeyPackageRelayEventRow(
        event: AccountKeyPackageRelayEventFfi(
            accountIdHex: "abcdef",
            keyPackageId: "slot-1",
            keyPackageRefHex: "0123456789abcdef",
            eventIdHex: "fedcba9876543210",
            createdAt: 1_700_000_000,
            keyPackageBytes: 512,
            sourceRelays: ["wss://relay.example.com"],
            isCurrent: true
        )
    )
    .padding()
    .frame(width: 520)
}

private extension AccountKeyPackageFfi {
    static let preview = AccountKeyPackageFfi(
        accountRef: "preview",
        accountIdHex: "abcdef",
        keyPackageId: "slot-1",
        keyPackageRefHex: "0123456789abcdef",
        eventIdHex: "fedcba9876543210",
        publishedAt: 1_700_000_000,
        keyPackageBytes: 512,
        sourceRelays: ["wss://relay.example.com"],
        local: true,
        relay: true
    )
}
