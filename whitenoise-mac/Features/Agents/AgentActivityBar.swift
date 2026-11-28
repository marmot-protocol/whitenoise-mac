import SwiftUI

/// Sits above the composer while an agent in the chat is working or waiting: Stop for the running
/// turn, how many approvals and questions wait, and the session's controls.
struct AgentActivityBar: View {
    let runningTurn: AgentItem?
    let session: AgentItem?
    let waitingCount: Int
    let failure: String?
    let actions: AgentRowActions
    let onDismissFailure: () -> Void
    @State private var isSessionPresented = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let failure {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle")
                    Text(verbatim: failure).lineLimit(2)
                    Spacer(minLength: 0)
                    Button(L10n.string("Dismiss"), action: onDismissFailure)
                        .buttonStyle(.borderless)
                }
                .font(.caption)
                .foregroundStyle(WNColor.intentionErrorContent)
            }
            HStack(spacing: 10) {
                if let runningTurn {
                    ProgressView().controlSize(.small)
                    Text(verbatim: AgentItemPresentation.title(for: runningTurn))
                        .font(.callout.weight(.medium))
                        .lineLimit(1)
                    AgentStopButton(item: runningTurn, actions: actions)
                        .keyboardShortcut(".", modifiers: .command)
                }
                if waitingCount > 0 {
                    Label(
                        String(format: L10n.string("Waiting for you: %@"), String(waitingCount)),
                        systemImage: "exclamationmark.bubble"
                    )
                    .font(.callout)
                    .foregroundStyle(WNColor.intentionWarningContent)
                }
                Spacer(minLength: 0)
                if let session, case .session(let body) = session.body {
                    Button {
                        isSessionPresented.toggle()
                    } label: {
                        Label(L10n.string("Agent Session"), systemImage: "slider.horizontal.3")
                    }
                    .controlSize(.small)
                    .popover(isPresented: $isSessionPresented, arrowEdge: .top) {
                        VStack(alignment: .leading, spacing: 10) {
                            Text(verbatim: AgentItemPresentation.title(for: session))
                                .font(.headline)
                            if !session.text.isEmpty {
                                Text(verbatim: session.text)
                                    .font(.caption)
                                    .foregroundStyle(WNColor.backgroundContentSecondary)
                            }
                            AgentSessionControls(item: session, session: body, actions: actions)
                        }
                        .padding(14)
                        .frame(width: 360, alignment: .leading)
                    }
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background { GlassCapsuleBackground() }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(L10n.string("Agent"))
    }
}

#if DEBUG
    #Preview("Agent activity bar") {
        let transcript = AgentPreviewFixtures.transcript
        AgentActivityBar(
            runningTurn: transcript.runningTurn,
            session: transcript.session,
            waitingCount: transcript.waiting.count,
            failure: nil,
            actions: .inert,
            onDismissFailure: {}
        )
        .padding()
        .frame(width: 640)
    }
#endif
