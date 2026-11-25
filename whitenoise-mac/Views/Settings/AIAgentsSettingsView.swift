import AppKit
import SwiftUI

struct AIAgentsSettingsView: View {
    let model: AgentSettingsViewModel

    var body: some View {
        SettingsScaffold(title: L10n.string("AI Agents")) {
            SettingsSection(
                title: L10n.string("About AI Agents"),
                footer: L10n.string(
                    "White Noise works with AI agents. Your agent runs on your own machine or server as a separate Marmot account; you chat with it here like any contact, end-to-end encrypted."
                )
            ) {
                Text(
                    L10n.string(
                        "These are installation prompts. Choose your agent, copy its prompt, and paste it into that agent to connect it to White Noise. The prompt includes your npub (a public key, not a secret) and asks the agent to explain how the connector works before requesting your approval to install it. Only use an agent you run and trust; your private key is never included."
                    )
                )
                .font(.subheadline)
                .foregroundStyle(WNColor.backgroundContentSecondary)
                .fixedSize(horizontal: false, vertical: true)
            }

            SettingsSection(title: L10n.string("Connectors")) {
                ForEach(AIAgentConnector.allCases) { connector in
                    AIAgentConnectorSettingsRow(
                        connector: connector,
                        npub: model.publicNpub
                    )
                }
            }

            SettingsSection(title: L10n.string("Manual Setup")) {
                if let npub = model.publicNpub {
                    HStack(spacing: 8) {
                        SettingsValueRow(title: "npub", value: npub, monospaced: true, isSelectable: true)
                        AgentCopyActionButton(
                            value: npub,
                            actionDescription: L10n.string("Copy npub")
                        )
                    }
                } else {
                    Text(L10n.string("No active account."))
                        .font(.subheadline)
                        .foregroundStyle(WNColor.backgroundContentSecondary)
                }

                Link(destination: AIAgentConnector.documentationURL) {
                    Label(L10n.string("Agent connector documentation"), systemImage: "arrow.up.right.square")
                }
            }
        }
    }
}

private struct AIAgentConnectorSettingsRow: View {
    let connector: AIAgentConnector
    let npub: String?
    @State private var isExpanded = false

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            if let npub {
                Text(connector.prompt(npub: npub))
                    .font(.caption.monospaced())
                    .foregroundStyle(WNColor.backgroundContentSecondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 6)
            } else {
                Text(L10n.string("No active account."))
                    .font(.caption)
                    .foregroundStyle(WNColor.backgroundContentSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 6)
            }
        } label: {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(connector.name)
                        .font(.body)
                    Text(connector.subtitle)
                        .font(.caption)
                        .foregroundStyle(WNColor.backgroundContentSecondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                AgentCopyActionButton(
                    value: npub.map { connector.prompt(npub: $0) },
                    actionDescription: L10n.string("Copy")
                )
            }
        }
        .padding(.vertical, 3)
    }
}

private struct AgentCopyActionButton: View {
    @Environment(WorkspaceState.self) private var workspace: WorkspaceState?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let value: String?
    let actionDescription: String

    @State private var isConfirming = false
    @State private var resetTask: Task<Void, Never>?

    var body: some View {
        Button {
            guard let value else { return }
            if let workspace {
                workspace.copyText(value, concealed: false)
            } else {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(value, forType: .string)
            }
            AccessibilityNotification.Announcement(L10n.string("Copied")).post()
            resetTask?.cancel()
            setConfirming(true)
            resetTask = Task {
                try? await Task.sleep(for: CopyConfirmation.defaultDuration)
                guard !Task.isCancelled else { return }
                setConfirming(false)
            }
        } label: {
            Image(systemName: isConfirming ? "checkmark" : "doc.on.doc")
                .foregroundStyle(isConfirming ? WNColor.intentionSuccessContent : WNColor.textPrimary)
                .contentTransition(.symbolEffect(.replace))
        }
        .wnSecondaryButtonStyle()
        .disabled(value == nil)
        .help(actionDescription)
        .accessibilityLabel(actionDescription)
        .onDisappear {
            resetTask?.cancel()
            resetTask = nil
            isConfirming = false
        }
    }

    private func setConfirming(_ confirming: Bool) {
        if reduceMotion {
            isConfirming = confirming
        } else {
            withAnimation(.smooth(duration: 0.15)) {
                isConfirming = confirming
            }
        }
    }
}

#Preview {
    AIAgentsSettingsView(model: .preview())
        .environment(WorkspaceState.preview())
        .frame(width: 760, height: 640)
}

#if DEBUG
    #Preview("No active account") {
        AIAgentsSettingsView(model: .preview(publicNpub: nil))
            .environment(WorkspaceState.preview())
            .frame(width: 760, height: 640)
    }
#endif
