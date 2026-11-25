import MarmotKit
import SwiftUI

/// Per-option confirmation and in-flight vote state derived purely from MDK's confirmed selection
/// and an optional pending local selection (T10, #1113).
nonisolated struct PollOptionVisualState: Equatable, Sendable {
    let isConfirmedSelection: Bool
    let isPendingChange: Bool

    static func resolve(
        optionID: String,
        confirmedSelection: Set<String>,
        pendingSelection: [String]?,
        isOpen: Bool
    ) -> Self {
        let isConfirmed = confirmedSelection.contains(optionID)
        guard isOpen, let pendingSelection else {
            return Self(isConfirmedSelection: isConfirmed, isPendingChange: false)
        }
        let isPending = pendingSelection.contains(optionID) != isConfirmed
        return Self(isConfirmedSelection: isConfirmed, isPendingChange: isPending)
    }
}

/// A poll in the transcript: its card on the author's side, with the sender's name above an
/// incoming one. Everything it draws arrives through `init`, so it previews without a workspace.
struct PollMessageRow: View {
    let poll: MessagePoll
    let isOutgoing: Bool
    /// Nil for an outgoing poll, which never names its sender.
    let senderName: String?
    let timeLabel: String
    /// Unconfirmed local vote selection currently in flight; nil when no vote is pending.
    var pendingSelection: [String]? = nil
    /// Nil when this account cannot vote here — the composer is closed, or the row never reached
    /// the group.
    let onVote: ((String) -> Void)?
    /// Opens the "View votes" sheet. Nil while nobody has voted, which hides the affordance.
    var onViewVotes: (() -> Void)? = nil

    var body: some View {
        VStack(alignment: isOutgoing ? .trailing : .leading, spacing: 6) {
            if let senderName, !isOutgoing {
                Text(senderName)
                    .font(MessageTypography.senderName)
                    .foregroundStyle(WNColor.messageReceivedSecondaryContent)
                    .padding(.horizontal, 4)
            }
            PollMessageCard(
                poll: poll,
                isOutgoing: isOutgoing,
                timeLabel: timeLabel,
                pendingSelection: pendingSelection,
                onVote: onVote,
                onViewVotes: onViewVotes
            )
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
    var pendingSelection: [String]? = nil
    let onVote: ((String) -> Void)?
    var onViewVotes: (() -> Void)? = nil

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
                pendingSelection: pendingSelection,
                onVote: onVote,
                onViewVotes: onViewVotes
            )
        }
    }
}

private struct PollMessageCardContent: View {
    let poll: MessagePoll
    let isOpen: Bool
    let isOutgoing: Bool
    let timeLabel: String
    let pendingSelection: [String]?
    let onVote: ((String) -> Void)?
    let onViewVotes: (() -> Void)?

    private var polarity: MessageBubblePolarity { MessageBubblePolarity(isOutgoing: isOutgoing) }

    var body: some View {
        let confirmed = Set(poll.localSelection)
        let showsPendingProgress = isOpen && pendingSelection != nil
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(PeerDisplayText.strippingBidiControls(poll.question))
                    .font(MessageTypography.bodySemibold)
                    .foregroundStyle(polarity.content)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                Label(
                    poll.isMultipleChoice
                        ? L10n.string("Poll · Select one or more") : L10n.string("Poll · Select one"),
                    systemImage: "chart.bar.xaxis"
                )
                .font(.caption)
                .foregroundStyle(polarity.secondaryContent)
            }

            ForEach(poll.options) { option in
                let visualState = PollOptionVisualState.resolve(
                    optionID: option.id,
                    confirmedSelection: confirmed,
                    pendingSelection: pendingSelection,
                    isOpen: isOpen
                )
                PollOptionRow(
                    option: option,
                    visualState: visualState,
                    isMultipleChoice: poll.isMultipleChoice,
                    fraction: PollPresentation.fraction(votes: option.votes, participants: poll.participants),
                    polarity: polarity,
                    onVote: isOpen ? onVote : nil
                )
            }

            if let onViewVotes, poll.participants > 0 {
                PollViewVotesButton(polarity: polarity, action: onViewVotes)
            }

            HStack(alignment: .firstTextBaseline, spacing: 8) {
                if showsPendingProgress {
                    ProgressView()
                        .controlSize(.mini)
                        .tint(polarity.secondaryContent)
                        .accessibilityLabel(L10n.string("Sending…"))
                }
                Text(PollFooter.text(poll: poll, isOpen: isOpen))
                Spacer(minLength: 8)
                Text(timeLabel)
                    .monospacedDigit()
            }
            .font(MessageTypography.footer)
            .foregroundStyle(polarity.secondaryContent)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(width: 300, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: MessageBubbleShape.cornerRadius, style: .continuous)
                .fill(polarity.fill)
        }
    }
}

/// The card's way into the voter list. Polls are not anonymous, so this shows who picked what.
private struct PollViewVotesButton: View {
    let polarity: MessageBubblePolarity
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(L10n.string("View votes"), systemImage: "person.2")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(polarity.content)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

private struct PollOptionRow: View {
    let option: MessagePoll.Option
    let visualState: PollOptionVisualState
    let isMultipleChoice: Bool
    let fraction: Double
    let polarity: MessageBubblePolarity
    let onVote: ((String) -> Void)?

    private var labelText: String {
        PeerDisplayText.strippingBidiControls(option.label)
    }

    private var accessibilityValueText: String {
        if visualState.isPendingChange {
            return "\(PollFooter.votes(option.votes)), \(L10n.string("Sending…"))"
        }
        return PollFooter.votes(option.votes)
    }

    var body: some View {
        let content = PollOptionRowContent(
            label: labelText,
            votes: option.votes,
            visualState: visualState,
            isMultipleChoice: isMultipleChoice,
            fraction: fraction,
            polarity: polarity
        )
        if let onVote {
            Button {
                onVote(option.id)
            } label: {
                content
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(labelText)
            .accessibilityValue(accessibilityValueText)
            .accessibilityAddTraits(visualState.isConfirmedSelection ? [.isButton, .isSelected] : .isButton)
        } else {
            content
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(labelText)
                .accessibilityValue(accessibilityValueText)
                .accessibilityAddTraits(visualState.isConfirmedSelection ? .isSelected : [])
        }
    }
}

private struct PollOptionRowContent: View {
    let label: String
    let votes: UInt64
    let visualState: PollOptionVisualState
    let isMultipleChoice: Bool
    let fraction: Double
    let polarity: MessageBubblePolarity

    private var symbol: String {
        switch (isMultipleChoice, visualState.isConfirmedSelection) {
        case (true, true): "checkmark.square.fill"
        case (true, false): "square"
        case (false, true): "checkmark.circle.fill"
        case (false, false): "circle"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                if visualState.isPendingChange {
                    ProgressView()
                        .controlSize(.mini)
                        .tint(polarity.content)
                        .accessibilityHidden(true)
                } else {
                    Image(systemName: symbol)
                        .foregroundStyle(
                            visualState.isConfirmedSelection ? polarity.content : polarity.secondaryContent
                        )
                        .accessibilityHidden(true)
                }
                Text(label)
                    .foregroundStyle(polarity.content)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                Text(votes, format: .number)
                    .monospacedDigit()
                    .foregroundStyle(polarity.secondaryContent)
                    .accessibilityHidden(true)
            }
            .font(.subheadline)

            ProgressView(value: min(1, max(0, fraction)), total: 1)
                .progressViewStyle(PollResultProgressStyle(polarity: polarity))
                .accessibilityHidden(true)
        }
        .contentShape(Rectangle())
    }
}

private struct PollResultProgressStyle: ProgressViewStyle {
    let polarity: MessageBubblePolarity

    func makeBody(configuration: Configuration) -> some View {
        let fraction = configuration.fractionCompleted ?? 0
        Capsule()
            .fill(AttachmentRowPalette.controlFill(isOutgoing: polarity == .sent))
            .frame(height: 4)
            .overlay(alignment: .leading) {
                GeometryReader { proxy in
                    Capsule()
                        .fill(polarity.content)
                        .frame(width: proxy.size.width * fraction)
                }
            }
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
        VStack(alignment: .leading, spacing: 0) {
            Text(L10n.string("New Poll"))
                .font(.title3.weight(.semibold))
                .padding(.horizontal, 20)
                .padding(.top, 20)
                .padding(.bottom, 8)

            Form {
                Section {
                    TextField(L10n.string("Ask a question"), text: $draft.question, axis: .vertical)
                        .labelsHidden()
                        .lineLimit(1...4)
                        .focused($focusedField, equals: .question)
                } header: {
                    Text(L10n.string("Question"))
                }

                Section {
                    ForEach(draft.options.indices, id: \.self) { index in
                        HStack(spacing: 8) {
                            TextField(
                                String(format: L10n.string("Option %lld"), Int64(index + 1)),
                                text: $draft.options[index]
                            )
                            .labelsHidden()
                            .focused($focusedField, equals: .option(index))
                            Button {
                                draft.removeOption(at: index)
                            } label: {
                                Label(L10n.string("Remove"), systemImage: "minus.circle")
                                    .labelStyle(.iconOnly)
                            }
                            .buttonStyle(.borderless)
                            .disabled(!draft.canRemoveOption)
                            .help(L10n.string("Remove"))
                            .accessibilityLabel(L10n.string("Remove"))
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
                } header: {
                    Text(L10n.string("Options"))
                }

                Section {
                    WNToggle(L10n.string("Allow Multiple Answers"), isOn: $draft.allowsMultipleAnswers)

                    Picker(L10n.string("Ends"), selection: $draft.duration) {
                        ForEach(PollDraft.Duration.allCases) { duration in
                            Text(PollComposerCopy.title(for: duration)).tag(duration)
                        }
                    }
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
            .frame(minHeight: 320, idealHeight: 360, maxHeight: 520)

            if let footerError = sendError ?? questionIssueMessage ?? optionsIssueMessage {
                Text(footerError)
                    .font(.subheadline)
                    .foregroundStyle(WNColor.intentionErrorContent)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 20)
                    .padding(.bottom, 12)
            }

            Divider()

            HStack {
                Button(L10n.string("Cancel"), action: onCancel)
                    .wnSecondaryButtonStyle()
                    .disabled(isSending)
                    .keyboardShortcut(.cancelAction)
                Spacer()
                if isSending {
                    ProgressView()
                        .controlSize(.small)
                }
                Button(L10n.string("Send"), action: send)
                    .wnPrimaryButtonStyle()
                    .disabled(isSending)
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
        }
        .disabled(isSending)
        // A focused field swallows Return before the Send button's default-action shortcut sees
        // it, so every field submits the poll itself; Tab moves between fields.
        .onSubmit(send)
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
            switch failure {
            case .missingQuestion, .questionTooLong:
                focusedField = .question
            case .tooFewOptions, .optionTooLong, .duplicateOption:
                break
            }
        case .success(let submission):
            isSending = true
            sendError = nil
            operation = Task {
                defer { isSending = false }
                do {
                    try await onSend(submission)
                } catch is CancellationError {
                    return
                } catch MarmotKitError.NoUsableRelay {
                    // Not worth retrying: it fails the same way until the chat's relays change.
                    sendError = UserFacingError.message(for: MarmotKitError.NoUsableRelay)
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
        PollMessageRow(
            poll: poll,
            isOutgoing: false,
            senderName: "Alice",
            timeLabel: "12:04",
            onVote: { _ in },
            onViewVotes: {}
        )
        PollMessageRow(poll: poll, isOutgoing: true, senderName: nil, timeLabel: "12:05", onVote: nil)
    }
    .padding()
    .frame(width: 640)
}

#Preview("Poll composer") {
    PollComposerSheet(onSend: { _ in }, onCancel: {})
}
