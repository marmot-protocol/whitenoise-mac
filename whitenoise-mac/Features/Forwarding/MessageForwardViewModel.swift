//
//  MessageForwardViewModel.swift
//  whitenoise-mac
//
//  One open "Forward To" sheet. Fetches every attachment the forwarded messages carry before
//  anything is sent, asks before leaving any unavailable file behind, then re-sends each message
//  to the chosen chat: text as text, attachments through that chat's normal attachment send.
//

import Foundation
import MarmotKit
import Observation

/// What the forward sheet needs from the rest of the app, as closures so the model can be built
/// without a workspace in previews and tests.
struct MessageForwardDependencies {
    /// The decrypted bytes for one attachment of a source message, or nil when they cannot be had.
    var fetchAttachment: @MainActor (MessageMediaAttachment, MessageItem) async -> MessageMediaDownload?
    /// Sends `text` to `chat` as a new message. Throws when the core refused it.
    var sendText: @MainActor (_ text: String, _ chat: ChatItem) async throws -> Void
    /// Hands an attachment message to `chat`'s pending-media send and waits for it to be admitted
    /// (or to fail, which leaves a retryable failed bubble in that chat).
    var sendMedia: @MainActor (_ message: PendingOutgoingMediaMessage, _ chat: ChatItem) async -> Void
    /// Surfaces a send error the way every other send does.
    var reportError: @MainActor (String) -> Void
    /// Closes the sheet and ends the message selection after a successful forward.
    var finish: @MainActor () -> Void
}

/// Files a forward could not fetch, shown to the user before anything is sent.
struct MessageForwardUnavailableFiles: Equatable {
    let chat: ChatItem
    let plan: MessageForwardPlan

    /// Whether anything is left to send once the unavailable files are left out.
    var canForwardRemainder: Bool {
        plan.hasContent
    }

    var fileList: String {
        plan.unavailableFileNames.joined(separator: "\n")
    }

    var message: String {
        let format =
            canForwardRemainder
            ? L10n.string("These files aren’t available and will be left out:\n%@")
            : L10n.string("These files aren’t available, so there is nothing to forward:\n%@")
        return String(format: format, fileList)
    }
}

@MainActor
@Observable
final class MessageForwardViewModel: Identifiable {
    enum Phase: Equatable {
        case choosing
        /// Fetching the attachments of the messages being forwarded to `chatId`.
        case preparing(chatId: String)
        case confirmingUnavailableFiles(MessageForwardUnavailableFiles)
        case sending(chatId: String)
    }

    let id = UUID()
    /// The messages being forwarded, in transcript order.
    let messages: [MessageItem]
    private(set) var phase: Phase = .choosing

    @ObservationIgnored private let dependencies: MessageForwardDependencies
    /// The one forward in flight. Cancelling it (the sheet closed) stops the forward before its
    /// next send; a send already handed to the core is not taken back.
    @ObservationIgnored private var task: Task<Void, Never>?

    init(messages: [MessageItem], dependencies: MessageForwardDependencies) {
        self.messages = messages.filter(\.canForward)
        self.dependencies = dependencies
    }

    var isBusy: Bool {
        switch phase {
        case .choosing, .confirmingUnavailableFiles: false
        case .preparing, .sending: true
        }
    }

    /// The chat whose row should show progress.
    var busyChatId: String? {
        switch phase {
        case .preparing(let chatId), .sending(let chatId): chatId
        case .choosing, .confirmingUnavailableFiles: nil
        }
    }

    var unavailableFiles: MessageForwardUnavailableFiles? {
        guard case .confirmingUnavailableFiles(let files) = phase else { return nil }
        return files
    }

    /// Fetches what the messages carry, then forwards to `chat` straight away when every file is
    /// available, or stops to ask when some are not.
    func forward(to chat: ChatItem) {
        guard phase == .choosing, chat.canUseComposer, !messages.isEmpty else { return }
        phase = .preparing(chatId: chat.id)
        task = Task { [weak self] in
            guard let self else { return }
            let plan = await MessageForwardPlan.make(
                messages: messages,
                fetch: dependencies.fetchAttachment
            )
            guard !Task.isCancelled else { return }
            if plan.isComplete {
                await send(plan, to: chat)
            } else {
                phase = .confirmingUnavailableFiles(MessageForwardUnavailableFiles(chat: chat, plan: plan))
            }
        }
    }

    /// The user accepted leaving the unavailable files out.
    func forwardAvailableFiles() {
        guard let files = unavailableFiles, files.canForwardRemainder else {
            dismissUnavailableFiles()
            return
        }
        // Moves out of `.confirmingUnavailableFiles` synchronously, so the alert's own dismissal,
        // which lands after this action, cannot reset a forward that has already started.
        phase = .sending(chatId: files.chat.id)
        task = Task { [weak self] in
            await self?.send(files.plan, to: files.chat)
        }
    }

    /// The user declined (or there was nothing left to send): back to the chat list.
    func dismissUnavailableFiles() {
        guard case .confirmingUnavailableFiles = phase else { return }
        phase = .choosing
    }

    /// The sheet is closing.
    func cancel() {
        task?.cancel()
        task = nil
    }

    /// Waits for the forward in flight, if any. For tests.
    func waitUntilIdle() async {
        await task?.value
    }

    private func send(_ plan: MessageForwardPlan, to chat: ChatItem) async {
        phase = .sending(chatId: chat.id)
        do {
            // One message at a time, in transcript order: each send is admitted before the next
            // starts, so the forwarded copies keep the order the originals had.
            for message in plan.messages {
                try Task.checkCancellation()
                if message.attachments.isEmpty {
                    try await dependencies.sendText(message.text, chat)
                } else {
                    await dependencies.sendMedia(
                        PendingOutgoingMediaMessage(attachments: message.attachments, caption: message.text),
                        chat
                    )
                }
            }
        } catch is CancellationError {
            return
        } catch {
            dependencies.reportError(error.localizedDescription)
            phase = .choosing
            return
        }
        phase = .choosing
        dependencies.finish()
    }
}

extension MessageForwardViewModel {
    /// The model for the forward the workspace has open, or nil when none is open or no account is.
    static func live(workspace: WorkspaceState) -> MessageForwardViewModel? {
        guard workspace.isForwardPickerPresented,
            let client = workspace.client,
            let account = workspace.activeAccount
        else { return nil }
        let ids = Set(workspace.forwardingMessageIds)
        let messages = workspace.selectedMessages.filter { ids.contains($0.id) }
        guard !messages.isEmpty else { return nil }
        return MessageForwardViewModel(
            messages: messages,
            dependencies: .live(workspace: workspace, account: account, client: client)
        )
    }
}

extension MessageForwardDependencies {
    static func live(
        workspace: WorkspaceState,
        account: AccountItem,
        client: any MarmotRuntime
    ) -> MessageForwardDependencies {
        MessageForwardDependencies(
            fetchAttachment: { [weak workspace] attachment, message in
                await workspace?.resolvedMediaDownload(attachment, for: message)
            },
            sendText: { text, chat in
                let clientToken = UUID().uuidString.lowercased()
                do {
                    _ = try await client.sendTextWithClientToken(
                        accountRef: account.accountRef,
                        groupIdHex: chat.id,
                        text: text,
                        clientToken: clientToken
                    )
                } catch {
                    // A cancelled host await can race durable local admission. Resolve that
                    // ambiguity with the same token instead of creating a duplicate forward.
                    if let status = try? client.localSendStatus(
                        accountRef: account.accountRef,
                        groupIdHex: chat.id,
                        clientToken: clientToken
                    ) {
                        switch status {
                        case .queued, .engineOwned, .completed:
                            return
                        case .rejected:
                            break
                        }
                    }
                    throw error
                }
            },
            sendMedia: { [weak workspace] message, chat in
                guard let workspace else { return }
                workspace.beginPendingOutgoingMediaSend(
                    message,
                    adoptedUploads: [:],
                    for: WorkspaceState.ComposerDraftKey(accountId: account.id, chatId: chat.id),
                    account: account,
                    client: client
                )
                await workspace.pendingOutgoingMediaSendTasks[message.id]?.value
            },
            reportError: { [weak workspace] description in
                workspace?.lastError = description
            },
            finish: { [weak workspace] in
                workspace?.cancelForwarding()
                workspace?.cancelMessageSelection()
            }
        )
    }

    /// Fetches nothing and sends nothing. For previews.
    static let inert = MessageForwardDependencies(
        fetchAttachment: { _, _ in nil },
        sendText: { _, _ in },
        sendMedia: { _, _ in },
        reportError: { _ in },
        finish: {}
    )
}
