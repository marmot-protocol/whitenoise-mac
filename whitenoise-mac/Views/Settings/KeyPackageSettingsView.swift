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
                        SettingsBusyLabel(
                            title: L10n.string("Refresh"),
                            systemImage: "arrow.clockwise",
                            isBusy: model.isRefreshing
                        )
                    }
                    .wnSecondaryButtonStyle()
                    .disabled(model.isRefreshing)

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
                SettingsSection {
                    Text(error.message)
                        .font(.subheadline)
                        .foregroundStyle(WNColor.intentionErrorContent)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .task(id: ObjectIdentifier(model)) {
            await model.loadLocalInventory()
        }
    }
}

struct KeyPackageInventoryRow: View {
    let entry: AccountKeyPackageInventoryEntryFfi

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                KeyPackageStateBadge(state: entry.localState)
                Spacer(minLength: 0)
                Text(
                    ByteCountFormatter.string(
                        fromByteCount: Int64(clamping: entry.record.keyPackageBytes),
                        countStyle: .file
                    )
                )
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(WNColor.backgroundContentSecondary)
            }

            KeyPackageValueRow(title: L10n.string("Event"), value: entry.record.eventIdHex)
            KeyPackageValueRow(title: "KeyPackageRef", value: entry.record.keyPackageRefHex)
            KeyPackageValueRow(title: L10n.string("Slot"), value: entry.record.keyPackageId)

            if !entry.record.sourceRelays.isEmpty {
                KeyPackageRelayList(relays: entry.record.sourceRelays)
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
                .font(.caption.weight(.semibold))
                .foregroundStyle(
                    event.isCurrent ? WNColor.intentionSuccessContent : WNColor.backgroundContentSecondary
                )

                Text(KeyPackageDisplay.date(event.createdAt))
                    .font(.caption)
                    .foregroundStyle(WNColor.backgroundContentSecondary)

                Spacer(minLength: 0)

                Text(
                    ByteCountFormatter.string(
                        fromByteCount: Int64(clamping: event.keyPackageBytes),
                        countStyle: .file
                    )
                )
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(WNColor.backgroundContentSecondary)
            }

            KeyPackageValueRow(title: L10n.string("Event"), value: event.eventIdHex)
            KeyPackageValueRow(title: "KeyPackageRef", value: event.keyPackageRefHex)

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
            .font(.caption.weight(.semibold))
            .foregroundStyle(state.foreground)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(state.badgeBackground, in: Capsule())
    }
}

struct KeyPackageValueRow: View {
    let title: String
    let value: String

    var body: some View {
        LabeledContent {
            Text(value.isEmpty ? L10n.string("Unknown") : DisplayText.short(value, head: 12, tail: 10))
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(WNColor.backgroundContentSecondary)
                .textSelection(.enabled)
        } label: {
            Text(title)
                .font(.caption.weight(.medium))
                .foregroundStyle(WNColor.backgroundContentSecondary)
        }
    }
}

struct KeyPackageRelayList: View {
    let relays: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(L10n.string("Source relays"))
                .font(.caption.weight(.medium))
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

    var foreground: Color {
        switch self {
        case .notLocal: WNColor.intentionSuccessContent
        case .current: WNColor.textPrimary
        case .pendingReplacement: WNColor.intentionWarningContent
        case .retainedPrivateMaterial, .otherOwned: WNColor.backgroundContentSecondary
        }
    }

    var badgeBackground: Color {
        switch self {
        case .notLocal: WNColor.intentionSuccessBackground
        case .current: WNColor.fillSecondary
        case .pendingReplacement: WNColor.intentionWarningBackground
        case .retainedPrivateMaterial, .otherOwned: WNColor.fillSecondary
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
