//
//  KeyPackageSettingsView.swift
//  whitenoise-mac
//
//  The Key Packages page: the KeyPackages this identity has published so other people
//  can invite it.
//
//  A destination of Developer mode, not a drawer row: `wn-ios-prototype` reaches Key Packages
//  from an isolated row inside Developer Tools and from nowhere else, so the chevron in the
//  header is the way back and every row here can speak plainly to a developer — the detail
//  that used to be gated on `developerMode` is unconditional, because the page cannot be
//  opened with the toggle off.
//

import SwiftUI

struct KeyPackageSettingsView: View {
    @Environment(WorkspaceState.self) private var workspace

    var body: some View {
        SettingsScaffold(
            title: L10n.string("Key Packages"),
            subtitle: L10n.string("Manage the KeyPackages this identity has published for invites."),
            back: .developerMode
        ) {
            SettingsSection {
                HStack(spacing: 10) {
                    Button {
                        Task { await workspace.publishNewKeyPackage() }
                    } label: {
                        Label(
                            workspace.isPublishingKeyPackage
                                ? L10n.string("Publishing...") : L10n.string("Publish new"), systemImage: "plus.circle")
                    }
                    .nativeGlassProminentButtonStyle()
                    .disabled(workspace.isPublishingKeyPackage || workspace.activeAccount == nil)

                    Button {
                        Task { await workspace.republishKeyPackage() }
                    } label: {
                        Label(
                            workspace.isRepublishingKeyPackage
                                ? L10n.string("Republishing...") : L10n.string("Republish latest"),
                            systemImage: "arrow.triangle.2.circlepath")
                    }
                    .buttonStyle(.wnSecondary)
                    .disabled(workspace.isRepublishingKeyPackage || workspace.activeAccount == nil)

                    if workspace.isLoadingSettings {
                        ProgressView()
                            .controlSize(.small)
                    }

                    Spacer()
                }
            }

            SettingsSection(title: L10n.string("Published Key Packages")) {
                if workspace.keyPackages.isEmpty {
                    ContentUnavailableView("No key packages", systemImage: "key.slash")
                        .frame(minHeight: 220)
                } else {
                    ForEach(workspace.keyPackages) { package in
                        KeyPackageRow(package: package) {
                            Task { await workspace.deleteKeyPackage(package) }
                        }
                        .disabled(workspace.deletingKeyPackageId == package.id)
                    }
                }
            }

        }
        .task(id: workspace.activeAccountId) {
            await workspace.loadKeyPackages()
        }
    }
}

struct KeyPackageRow: View {
    @Environment(WorkspaceState.self) private var workspace
    let package: KeyPackageItem
    let delete: () -> Void

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
                    HStack(spacing: 8) {
                        if package.isLocal {
                            statusBadge(
                                L10n.string("Local"),
                                systemImage: "macbook",
                                tint: MessagesPalette.sentBubble
                            )
                        }
                        if package.isRelayDiscovered {
                            statusBadge(
                                L10n.string("Synced"),
                                systemImage: "checkmark.icloud.fill",
                                tint: .green
                            )
                        }
                        if !package.isLocal && !package.isRelayDiscovered {
                            statusBadge(
                                L10n.string("Unknown"),
                                systemImage: "questionmark.circle",
                                tint: .secondary
                            )
                        }
                        Text(package.publishedLabel)
                            .wnFont(.medium10)
                            .foregroundStyle(WNColor.backgroundContentSecondary)
                    }

                    keyValue(L10n.string("Event"), package.eventIdHex)
                    keyValue("KeyPackageRef", package.keyPackageRefHex)
                    keyValue(L10n.string("Slot"), package.keyPackageId)
                    Text(L10n.plural("%llu bytes", package.keyPackageBytes))
                        .wnFont(.medium10.monospacedDigit())
                        .foregroundStyle(WNColor.backgroundContentSecondary)
                }

                Spacer()

                Button(action: delete) {
                    Image(systemName: "trash")
                }
                .buttonStyle(.plain)
                .foregroundStyle(WNColor.backgroundContentDestructive)
                .help(L10n.string("Delete key package"))
                .disabled(package.eventIdHex.isEmpty || workspace.deletingKeyPackageId != nil)
            }

            if !package.sourceRelays.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text(L10n.string("Source relays"))
                        .wnFont(.semiBold10)
                        .foregroundStyle(WNColor.backgroundContentSecondary)
                    ForEach(package.sourceRelays, id: \.self) { relay in
                        Text(relay)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(WNColor.backgroundContentSecondary)
                            .textSelection(.enabled)
                    }
                }
                .padding(.leading, 42)
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(String(format: L10n.string("%@, %@"), package.sourceLabel, package.publishedLabel))
    }

    private func statusBadge(_ title: String, systemImage: String, tint: Color) -> some View {
        Label(title, systemImage: systemImage)
            .wnFont(.semiBold10)
            .foregroundStyle(tint)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(tint.opacity(0.12), in: Capsule())
    }

    private func keyValue(_ title: String, _ value: String) -> some View {
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
