import MarmotKit
import SwiftUI

/// A poll in the transcript: its card on the author's side, with the sender's name above an
/// incoming one. Everything it draws arrives through `init`, so it previews without a workspace.
struct PollMessageRow: View {
    let poll: MessagePoll
    let isOutgoing: Bool
    /// Nil for an outgoing poll, which never names its sender.
    let senderName: String?
    let timeLabel: String
    /// Nil when this account cannot vote here — the composer is closed, or the row never reached
    /// the group.
    let onVote: ((String) -> Void)?

    var body: some View {
        VStack(alignment: isOutgoing ? .trailing : .leading, spacing: 6) {
            if let senderName, !isOutgoing {
                Text(senderName)
                    .wnFont(.medium10)
                    .foregroundStyle(WNColor.backgroundContentSecondary)
                    .padding(.horizontal, 4)
            }
            PollMessageCard(poll: poll, isOutgoing: isOutgoing, timeLabel: timeLabel, onVote: onVote)
        }
        .frame(maxWidth: .infinity, alignment: isOutgoing ? .trailing : .leading)
        .padding(isOutgoing ? .leading : .trailing, 72)
    }
}

/// The poll bubble. Redraws once at the deadline so an on-screen poll closes on time.
struct PollMessageCard: View {
    let poll: MessagePoll
    let isOutgoing: Bool
    let timeLabel: String
    let onVote: ((String) -> Void)?

    private var deadlineSchedule: [Date] {
        guard let endsAt = poll.endsAt, PollPresentation.isOpen(poll, now: .now) else { return [] }
        return [Date(timeIntervalSince1970: TimeInterval(endsAt) + 1)]
    }

    var body: some View {
        // The context date can be a future schedule entry, so read the real clock.
        TimelineView(.explicit(deadlineSchedule)) { _ in
            PollMessageCardContent(
                poll: poll,
                isOpen: PollPresentation.isOpen(poll, now: .now),
                isOutgoing: isOutgoing,
                timeLabel: timeLabel,
                onVote: onVote
            )
        }
    }
}

private struct PollMessageCardContent: View {
    let poll: MessagePoll
    let isOpen: Bool
    let isOutgoing: Bool
    let timeLabel: String
    let onVote: ((String) -> Void)?

    private var content: Color { MessagesPalette.bubbleContent(isOutgoing: isOutgoing) }
    private var detail: Color { AttachmentRowPalette.detailContent(isOutgoing: isOutgoing) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(PeerDisplayText.strippingBidiControls(poll.question))
                    .wnFont(.semiBold14)
                    .foregroundStyle(content)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                Label(
                    poll.isMultipleChoice
                        ? L10n.string("Poll · Select one or more") : L10n.string("Poll · Select one"),
                    systemImage: "chart.bar.xaxis"
                )
                .wnFont(.medium10)
                .foregroundStyle(detail)
            }

            ForEach(poll.options) { option in
                PollOptionRow(
                    option: option,
                    isSelected: poll.localSelection.contains(option.id),
                    isMultipleChoice: poll.isMultipleChoice,
                    fraction: PollPresentation.fraction(votes: option.votes, participants: poll.participants),
                    isOutgoing: isOutgoing,
                    onVote: isOpen ? onVote : nil
                )
            }

            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(PollFooter.text(poll: poll, isOpen: isOpen))
                Spacer(minLength: 8)
                Text(timeLabel)
                    .monospacedDigit()
            }
            .wnFont(.medium10)
            .foregroundStyle(detail)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(width: 300, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(MessagesPalette.bubbleFill(isOutgoing: isOutgoing))
        }
    }
}

private struct PollOptionRow: View {
    let option: MessagePoll.Option
    let isSelected: Bool
    let isMultipleChoice: Bool
    let fraction: Double
    let isOutgoing: Bool
    let onVote: ((String) -> Void)?

    private var content: Color { MessagesPalette.bubbleContent(isOutgoing: isOutgoing) }
    private var detail: Color { AttachmentRowPalette.detailContent(isOutgoing: isOutgoing) }

    private var symbol: String {
        switch (isMultipleChoice, isSelected) {
        case (true, true): "checkmark.square.fill"
        case (true, false): "square"
        case (false, true): "checkmark.circle.fill"
        case (false, false): "circle"
        }
    }

    var body: some View {
        Button {
            onVote?(option.id)
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: symbol)
                        .foregroundStyle(isSelected ? content : detail)
                        .accessibilityHidden(true)
                    Text(PeerDisplayText.strippingBidiControls(option.label))
                        .foregroundStyle(content)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 8)
                    Text(option.votes, format: .number)
                        .monospacedDigit()
                        .foregroundStyle(detail)
                        .accessibilityHidden(true)
                }
                .wnFont(.medium12)
                Capsule()
                    .fill(AttachmentRowPalette.controlFill(isOutgoing: isOutgoing))
                    .frame(height: 4)
                    .overlay(alignment: .leading) {
                        GeometryReader { proxy in
                            Capsule()
                                .fill(content)
                                .frame(width: proxy.size.width * fraction)
                        }
                    }
                    .accessibilityHidden(true)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(onVote == nil)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(PeerDisplayText.strippingBidiControls(option.label))
        .accessibilityValue(PollFooter.votes(option.votes))
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }
}

nonisolated enum PollFooter {
    static func votes(_ count: UInt64) -> String {
        L10n.plural("%lld votes", count)
    }

    static func text(poll: MessagePoll, isOpen: Bool, locale: Locale = AppLanguage.currentLocale) -> String {
        let votes = votes(poll.participants)
        if !isOpen {
            return "\(votes) · \(L10n.string("Final results"))"
        }
        if let endsAt = poll.endsAt {
            let date = Date(timeIntervalSince1970: TimeInterval(endsAt))
            let style = Date.FormatStyle(date: .abbreviated, time: .shortened).locale(locale)
            return "\(votes) · \(String(format: L10n.string("Ends %@"), date.formatted(style)))"
        }
        return votes
    }
}

/// Sheet for composing a group poll. It dismisses only after MDK accepts the poll.
struct PollComposerSheet: View {
    let onSend: (PollDraft.Submission) async throws -> Void
    let onCancel: () -> Void

    @State private var draft = PollDraft()
    @State private var issue: PollDraft.Issue?
    @State private var sendError: String?
    @State private var isSending = false
    @State private var operation: Task<Void, Never>?
    @FocusState private var focusedField: Field?

    private enum Field: Hashable {
        case question
        case option(Int)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(L10n.string("New Poll"))
                .wnFont(.semiBold18)

            VStack(alignment: .leading, spacing: 6) {
                Text(L10n.string("Question"))
                    .wnFont(.semiBold12)
                TextField(L10n.string("Ask a question"), text: $draft.question, axis: .vertical)
                    .lineLimit(1...4)
                    .focused($focusedField, equals: .question)
                PollComposerIssueText(message: questionIssueMessage)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text(L10n.string("Options"))
                    .wnFont(.semiBold12)
                ForEach(draft.options.indices, id: \.self) { index in
                    HStack(spacing: 8) {
                        TextField(
                            String(format: L10n.string("Option %lld"), Int64(index + 1)),
                            text: $draft.options[index]
                        )
                        .focused($focusedField, equals: .option(index))
                        .onSubmit {
                            if index + 1 < draft.options.count { focusedField = .option(index + 1) }
                        }
                        Button {
                            draft.removeOption(at: index)
                        } label: {
                            Image(systemName: "minus.circle")
                        }
                        .buttonStyle(.borderless)
                        .disabled(!draft.canRemoveOption)
                        .help(L10n.string("Remove"))
                    }
                }
                if draft.canAddOption {
                    Button {
                        draft.addOption()
                        focusedField = .option(draft.options.count - 1)
                    } label: {
                        Label(L10n.string("Add Option"), systemImage: "plus.circle")
                    }
                    .buttonStyle(.borderless)
                }
                PollComposerIssueText(message: optionsIssueMessage)
            }

            WNToggle(L10n.string("Allow Multiple Answers"), isOn: $draft.allowsMultipleAnswers)

            Picker(L10n.string("Ends"), selection: $draft.duration) {
                ForEach(PollDraft.Duration.allCases) { duration in
                    Text(PollComposerCopy.title(for: duration)).tag(duration)
                }
            }

            SettingsErrorView(error: sendError)

            HStack {
                Button(L10n.string("Cancel"), action: onCancel)
                    .disabled(isSending)
                    .keyboardShortcut(.cancelAction)
                Spacer()
                if isSending {
                    ProgressView()
                        .controlSize(.small)
                }
                Button(L10n.string("Send"), action: send)
                    .nativeGlassProminentButtonStyle()
                    .disabled(isSending)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .disabled(isSending)
        .padding(24)
        .frame(width: 440)
        .interactiveDismissDisabled(isSending)
        .onChange(of: draft) {
            issue = nil
            sendError = nil
        }
        .onAppear { focusedField = .question }
        .onDisappear {
            operation?.cancel()
            operation = nil
        }
    }

    private func send() {
        guard !isSending else { return }
        switch draft.validated(now: .now) {
        case .failure(let failure):
            issue = failure
        case .success(let submission):
            isSending = true
            sendError = nil
            operation = Task {
                defer { isSending = false }
                do {
                    try await onSend(submission)
                } catch is CancellationError {
                    return
                } catch {
                    sendError = L10n.string("Couldn’t send the poll. Try again.")
                }
            }
        }
    }

    private var questionIssueMessage: String? {
        switch issue {
        case .missingQuestion: L10n.string("Enter a question.")
        case .questionTooLong: L10n.string("This question is too long.")
        default: nil
        }
    }

    private var optionsIssueMessage: String? {
        switch issue {
        case .tooFewOptions: L10n.string("Add at least two options.")
        case .optionTooLong: L10n.string("One of the options is too long.")
        case .duplicateOption: L10n.string("Each option must be different.")
        default: nil
        }
    }
}

private struct PollComposerIssueText: View {
    let message: String?

    var body: some View {
        if let message {
            Text(message)
                .wnFont(.medium10)
                .foregroundStyle(WNColor.backgroundContentDestructive)
        }
    }
}

nonisolated enum PollComposerCopy {
    static func title(for duration: PollDraft.Duration) -> String {
        switch duration {
        case .none: L10n.string("Never")
        case .oneHour: L10n.string("1 Hour")
        case .oneDay: L10n.string("1 Day")
        case .oneWeek: L10n.string("1 Week")
        }
    }
}

#Preview("Poll rows") {
    let poll = MessagePoll(
        question: "Where should we have lunch on Friday?",
        options: [
            .init(id: "0", label: "Tacos", votes: 3),
            .init(id: "1", label: "Ramen", votes: 1),
            .init(id: "2", label: "Pizza", votes: 0),
        ],
        kind: .singleChoice,
        participants: 4,
        localSelection: ["0"],
        endsAt: nil,
        isOpen: true
    )
    VStack(spacing: 12) {
        PollMessageRow(poll: poll, isOutgoing: false, senderName: "Alice", timeLabel: "12:04", onVote: { _ in })
        PollMessageRow(poll: poll, isOutgoing: true, senderName: nil, timeLabel: "12:05", onVote: nil)
    }
    .padding()
    .frame(width: 640)
}

#Preview("Poll composer") {
    PollComposerSheet(onSend: { _ in }, onCancel: {})
}
