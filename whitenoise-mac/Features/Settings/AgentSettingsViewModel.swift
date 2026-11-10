import Foundation
import MarmotKit
import Observation

struct AgentPublicationRecord: Equatable, Sendable {
    let kind: PublisherRecordFfi
    let text: String
}

struct AgentPublicationReceipt: Equatable, Sendable {
    let info: PublisherInfoFfi
    let acceptedChunkCount: UInt64
    let previewWarning: String?
    let send: SendSummaryFfi
}

@MainActor
@Observable
final class AgentSettingsViewModel {
    let publicNpub: String?
    private(set) var isPublishing = false
    private(set) var pendingPublisherInfo: PublisherInfoFfi?
    private(set) var acceptedChunkCount: UInt64 = 0
    private(set) var previewWarning: String?
    private(set) var error: String?

    @ObservationIgnored private let accountRef: String
    @ObservationIgnored private let runtime: (any MarmotRuntime)?
    @ObservationIgnored private var pendingPublisher: AgentTextPublisher?

    init(account: AccountItem, runtime: (any MarmotRuntime)? = nil) {
        publicNpub = account.npub
        accountRef = account.accountRef
        self.runtime = runtime
    }

    /// Publishes a host-produced agent transcript without handing exporter keys, account
    /// secrets, or framing state to Swift. A failed final send retains the opaque publisher so
    /// the exact sealed request can be retried through `retryFinish()`.
    func publish(
        groupIdHex: String,
        brokerCandidate: String,
        records: [AgentPublicationRecord]
    ) async throws -> AgentPublicationReceipt {
        guard let runtime, pendingPublisher == nil, !isPublishing else {
            throw MarmotKitError.RuntimeBusy
        }
        isPublishing = true
        error = nil
        acceptedChunkCount = 0
        previewWarning = nil
        defer { isPublishing = false }

        let publisher = try await runtime.openAgentPublisher(
            accountRef: accountRef,
            groupIdHex: groupIdHex,
            options: PublisherOptionsFfi(
                candidate: brokerCandidate,
                serverCertDer: nil,
                trust: .publicOnly
            )
        )
        pendingPublisher = publisher
        let info = publisher.info()
        pendingPublisherInfo = info

        do {
            for record in records {
                let acknowledgement = try await publisher.append(kind: record.kind, text: record.text)
                acceptedChunkCount = acknowledgement.chunkCount
                if let warning = acknowledgement.liveError {
                    previewWarning = warning
                }
            }
        } catch {
            await publisher.cancel()
            pendingPublisher = nil
            pendingPublisherInfo = nil
            self.error = UserFacingError.message(for: error)
            throw error
        }

        return try await finishPendingPublisher(info: info)
    }

    func retryFinish() async throws -> AgentPublicationReceipt {
        guard let info = pendingPublisherInfo, !isPublishing else {
            throw MarmotKitError.RuntimeBusy
        }
        isPublishing = true
        error = nil
        defer { isPublishing = false }
        return try await finishPendingPublisher(info: info)
    }

    func cancelPublisher() async {
        guard let publisher = pendingPublisher else { return }
        await publisher.cancel()
        pendingPublisher = nil
        pendingPublisherInfo = nil
        acceptedChunkCount = 0
        previewWarning = nil
        error = nil
    }

    private func finishPendingPublisher(info: PublisherInfoFfi) async throws -> AgentPublicationReceipt {
        guard let publisher = pendingPublisher else { throw MarmotKitError.RuntimeBusy }
        do {
            let send = try await publisher.finish()
            let receipt = AgentPublicationReceipt(
                info: info,
                acceptedChunkCount: acceptedChunkCount,
                previewWarning: previewWarning,
                send: send
            )
            pendingPublisher = nil
            pendingPublisherInfo = nil
            error = nil
            return receipt
        } catch {
            // MDK seals and retains the exact final request on this handle. Keep it alive so a
            // retry cannot create a second stream or change the final message bytes.
            self.error = UserFacingError.message(for: error)
            throw error
        }
    }

    static func preview() -> AgentSettingsViewModel {
        AgentSettingsViewModel(account: AccountItem.samples[0])
    }
}

nonisolated enum AIAgentConnector: String, CaseIterable, Identifiable {
    case hermes
    case openclaw
    case opencode
    case codex

    var id: Self { self }

    var name: String {
        switch self {
        case .hermes: L10n.string("Hermes")
        case .openclaw: L10n.string("OpenClaw")
        case .opencode: L10n.string("OpenCode")
        case .codex: L10n.string("Codex")
        }
    }

    var subtitle: String {
        switch self {
        case .hermes: L10n.string("Terminal agent by Nous Research")
        case .openclaw: L10n.string("Self-hosted personal AI assistant")
        case .opencode: L10n.string("Open-source coding agent")
        case .codex: L10n.string("OpenAI Codex CLI coding agent")
        }
    }

    func prompt(npub: String) -> String {
        switch self {
        case .hermes:
            String(
                format: L10n.string(
                    "This is an installation prompt for connecting this Hermes installation to White Noise through Marmot. Read the latest connector guide at https://github.com/marmot-protocol/mdk/blob/master/crates/agent-connector/README.md. Explain to me how the connector works and what the installation will change. Then propose the installation steps for my public npub: %@, and ask for my approval before making any changes. Once I approve, install and verify the connector, then reply with your agent npub."
                ),
                npub
            )
        case .openclaw:
            String(
                format: L10n.string(
                    "This is an installation prompt for connecting this OpenClaw instance to White Noise through Marmot. Read the latest connector guide at https://github.com/marmot-protocol/mdk/blob/master/crates/agent-connector/README.md. Explain to me how the connector works and what the installation will change. Then propose the installation steps for my public npub: %@, and ask for my approval before making any changes. Once I approve, install and verify the connector, then reply with your agent npub."
                ),
                npub
            )
        case .opencode:
            String(
                format: L10n.string(
                    "This is an installation prompt for connecting this OpenCode setup to White Noise through Marmot. Read the latest connector guide at https://github.com/marmot-protocol/mdk/blob/master/crates/agent-connector/README.md. Explain to me how the connector works and what the installation will change. Then propose the installation steps for my public npub: %@, and ask for my approval before making any changes. Once I approve, install and verify the connector, then reply with your agent npub."
                ),
                npub
            )
        case .codex:
            String(
                format: L10n.string(
                    "This is an installation prompt for connecting this Codex setup to White Noise through Marmot. Read the authoritative Codex harness guide at https://github.com/marmot-protocol/mdk/blob/master/integrations/codex/marmot/README.md and the evergreen connector guide at https://github.com/marmot-protocol/mdk/blob/master/crates/agent-connector/README.md. Explain to me how the connector works and what the installation will change. Confirm prerequisites: Codex CLI is installed, authenticated, and available on PATH, and this machine uses the same public relay set as my phone. Then propose the installation steps for my public npub: %@, and ask for my approval before making any changes. Once I approve, use the checksum-verified install-codex-marmot.sh release flow, bootstrap wn-agent for that npub with the allowed welcomer, and verify wn-codex --version. Then reply with your agent npub and ask me to invite it from White Noise and send a test message from this allowed npub over the configured relays. Do not report setup complete until wn-codex returns a reply through White Noise; if that round trip cannot be verified automatically, clearly mark device verification required."
                ),
                npub
            )
        }
    }

    static let documentationURL = URL(
        string: "https://github.com/marmot-protocol/mdk/blob/master/crates/agent-connector/README.md"
    )!
}
