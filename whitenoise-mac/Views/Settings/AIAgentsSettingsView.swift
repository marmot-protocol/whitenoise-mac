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
                .foregroundStyle(WNColor.backgroundContentSecondary)
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
                    SettingsValueRow(title: "npub", value: npub, isSelectable: true)
                } else {
                    Text(L10n.string("No active account."))
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
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) { isExpanded.toggle() }
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(connector.name)
                        Text(connector.subtitle)
                            .wnFont(.medium10)
                            .foregroundStyle(WNColor.backgroundContentSecondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                Button {
                    guard let npub else { return }
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(connector.prompt(npub: npub), forType: .string)
                } label: {
                    Image(systemName: "doc.on.doc")
                }
                .wnSecondaryButtonStyle()
                .disabled(npub == nil)
                .help(L10n.string("Copy"))
            }

            if isExpanded, let npub {
                Text(connector.prompt(npub: npub))
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 3)
    }
}

#Preview {
    AIAgentsSettingsView(model: .preview())
        .environment(WorkspaceState.preview())
        .frame(width: 760, height: 640)
}
