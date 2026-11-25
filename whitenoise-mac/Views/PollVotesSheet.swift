//
//  PollVotesSheet.swift
//  whitenoise-mac
//
//  The "View votes" sheet: every voter's effective selection in one poll, grouped by option, paged
//  from MarmotKit's `pollVotes`. Polls are not anonymous — every member can already read each
//  response and who sent it — and the sheet says so.
//

import MarmotKit
import SwiftUI

private struct PollVotesSheetModifier: ViewModifier {
    let conversationModel: ConversationViewModel
    let blockedUsersModel: BlockedUsersViewModel
    let voterDisplay: (String) -> ReactionReactorDisplay

    func body(content: Content) -> some View {
        // Read here rather than inside the sheet's builder, so a block or unblock while the sheet
        // is open re-runs this body and re-marks the voters.
        let blockedAccountIDs = blockedUsersModel.blockedAccountIDs
        content.sheet(
            item: Binding(
                get: { conversationModel.pollVotes },
                set: { if $0 == nil { conversationModel.dismissPollVotes() } }
            )
        ) { model in
            PollVotesSheet(
                model: model,
                blockedAccountIDs: blockedAccountIDs,
                voterDisplay: voterDisplay,
                onClose: { conversationModel.dismissPollVotes() }
            )
        }
    }
}

extension View {
    func pollVotesSheet(
        model: ConversationViewModel,
        blockedUsersModel: BlockedUsersViewModel,
        voterDisplay: @escaping (String) -> ReactionReactorDisplay
    ) -> some View {
        modifier(
            PollVotesSheetModifier(
                conversationModel: model,
                blockedUsersModel: blockedUsersModel,
                voterDisplay: voterDisplay
            ))
    }
}

/// Voters grouped under each option, with the poll's own tally as each option's count. Every
/// dependency arrives through `init`, so it previews from fixture pages.
struct PollVotesSheet: View {
    let model: PollVotesViewModel
    let blockedAccountIDs: Set<String>
    let voterDisplay: (String) -> ReactionReactorDisplay
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                Text(L10n.string("Votes")).font(.headline)
                Label(L10n.string("Votes in this poll are visible to everyone in the chat."), systemImage: "eye")
                    .font(.caption)
                    .foregroundStyle(WNColor.messageReceivedSecondaryContent)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 20)
            .padding(.top, 18)
            .padding(.bottom, 12)

            Divider()

            FittedSheetScrollView(maximumHeight: 440) {
                VStack(alignment: .leading, spacing: 0) {
                    PollVotesHeader(question: model.poll?.question, participants: model.poll?.participants ?? 0)
                    PollVotesList(model: model, blockedAccountIDs: blockedAccountIDs, voterDisplay: voterDisplay)
                }
            }

            Divider()

            HStack {
                Spacer()
                Button(L10n.string("Done"), action: onClose)
                    .wnSecondaryButtonStyle()
                    .keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
        }
        .frame(width: 380)
        .presentationSizing(.fitted)
        .onDisappear { model.cancel() }
    }
}

/// The sheet's scrolling content: voters under each option, then paging. Its own view so it can be
/// drawn outside the `ScrollView`, which an offscreen render leaves blank.
struct PollVotesList: View {
    let model: PollVotesViewModel
    let blockedAccountIDs: Set<String>
    let voterDisplay: (String) -> ReactionReactorDisplay

    var body: some View {
        LazyVStack(alignment: .leading, spacing: 18) {
            if model.votes.isEmpty {
                if model.showsNoVotes {
                    Text(L10n.string("No votes yet."))
                        .font(.subheadline)
                        .foregroundStyle(WNColor.messageReceivedSecondaryContent)
                }
            } else {
                ForEach(model.groups(blockedAccountIDs: blockedAccountIDs)) { group in
                    PollVoteGroupSection(group: group, voterDisplay: voterDisplay)
                }
            }
            PollVotesPagingFooter(model: model)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(20)
    }
}

private struct PollVotesHeader: View {
    let question: String?
    let participants: UInt64

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let question {
                VStack(alignment: .leading, spacing: 2) {
                    Text(PeerDisplayText.strippingBidiControls(question))
                        .font(.subheadline)
                        .foregroundStyle(WNColor.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                    Text(PollFooter.votes(participants))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(WNColor.messageReceivedSecondaryContent)
                }
            }

        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 20)
        .padding(.top, 18)
        .padding(.bottom, 12)
    }
}

private struct PollVoteGroupSection: View {
    let group: PollVoteGroup
    let voterDisplay: (String) -> ReactionReactorDisplay

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(PeerDisplayText.strippingBidiControls(group.option.label))
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(WNColor.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                Text(PollFooter.votes(group.option.votes))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(WNColor.messageReceivedSecondaryContent)
            }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)

            ForEach(group.voters) { voter in
                PollVoterRow(voter: voter, display: voterDisplay(voter.accountIdHex))
            }
        }
    }
}

private struct PollVoterRow: View {
    let voter: PollVoter
    let display: ReactionReactorDisplay

    var body: some View {
        HStack(spacing: 10) {
            ProfileImageAvatarView(
                seed: display.accountIdHex,
                initials: display.name,
                sanitizedPictureURL: display.sanitizedPictureURL,
                size: 28,
                isSelected: false
            )
            Text(display.isSelf ? L10n.string("You") : display.name)
                .font(.subheadline)
                .foregroundStyle(WNColor.textPrimary)
                .lineLimit(1)
            if voter.isBlocked {
                PollBlockedVoterBadge()
            }
            Spacer(minLength: 8)
            Text(DisplayText.messageTimestamp(for: Date(timeIntervalSince1970: TimeInterval(voter.votedAt))))
                .font(.caption.monospacedDigit())
                .foregroundStyle(WNColor.messageReceivedSecondaryContent)
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }
}

/// Marks a voter this account has blocked. They stay listed because the tally counts them.
private struct PollBlockedVoterBadge: View {
    var body: some View {
        Text(L10n.string("Blocked"))
            .font(.caption2.weight(.semibold))
            .foregroundStyle(WNColor.intentionErrorContent)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(WNColor.intentionErrorBackground, in: .capsule)
    }
}

private struct PollVotesPagingFooter: View {
    let model: PollVotesViewModel

    var body: some View {
        if model.isLoading {
            ProgressView()
                .controlSize(.small)
                .frame(maxWidth: .infinity)
        }
        if model.failed {
            Text(L10n.string("Couldn’t load votes."))
                .font(.subheadline)
                .foregroundStyle(WNColor.intentionErrorContent)
        }
        if model.failed || model.hasMoreAfter {
            Button(model.failed ? L10n.string("Retry") : L10n.string("Load more")) {
                if model.failed {
                    model.retry()
                } else {
                    model.loadMore()
                }
            }
            .wnSecondaryButtonStyle()
            .disabled(model.isLoading)
        }
    }
}

#Preview("Poll votes") {
    let poll = MessagePoll(
        question: "Where should we have lunch on Friday?",
        options: [
            .init(id: "0", label: "Tacos", votes: 2),
            .init(id: "1", label: "Ramen", votes: 2),
            .init(id: "2", label: "Pizza", votes: 0),
        ],
        kind: .multipleChoice,
        participants: 3,
        localSelection: ["0"],
        endsAt: nil,
        isOpen: true
    )
    let names = [
        String(repeating: "a", count: 64): "You",
        String(repeating: "b", count: 64): "Bob",
        String(repeating: "c", count: 64): "Carol",
    ]
    let page = PollVotePageFfi(
        votes: [
            PollVoteFfi(voterAccountIdHex: String(repeating: "a", count: 64), optionIds: ["0"], votedAt: 1_760_000_000),
            PollVoteFfi(
                voterAccountIdHex: String(repeating: "b", count: 64), optionIds: ["0", "1"], votedAt: 1_760_000_100),
            PollVoteFfi(voterAccountIdHex: String(repeating: "c", count: 64), optionIds: ["1"], votedAt: 1_760_000_200),
        ],
        hasMoreAfter: false
    )
    let model = PollVotesViewModel(pollEventId: "poll", poll: poll) { _, _ in page }
    model.start()
    return PollVotesSheet(
        model: model,
        blockedAccountIDs: [String(repeating: "c", count: 64)],
        voterDisplay: { accountIdHex in
            ReactionReactorDisplay(
                accountIdHex: accountIdHex,
                name: names[accountIdHex] ?? DisplayText.short(accountIdHex),
                sanitizedPictureURL: nil,
                isSelf: accountIdHex == String(repeating: "a", count: 64)
            )
        },
        onClose: {}
    )
    .environment(WorkspaceState.preview())
}

#Preview("Poll votes list") {
    let voter = String(repeating: "b", count: 64)
    let poll = MessagePoll(
        question: "Lunch?",
        options: [.init(id: "0", label: "Tacos", votes: 1), .init(id: "1", label: "Ramen", votes: 0)],
        kind: .singleChoice,
        participants: 1,
        localSelection: [],
        endsAt: nil,
        isOpen: true
    )
    let model = PollVotesViewModel(pollEventId: "poll", poll: poll) { _, _ in
        PollVotePageFfi(
            votes: [PollVoteFfi(voterAccountIdHex: voter, optionIds: ["0"], votedAt: 1_760_000_000)],
            hasMoreAfter: false
        )
    }
    model.start()
    return PollVotesList(
        model: model,
        blockedAccountIDs: [],
        voterDisplay: {
            ReactionReactorDisplay(
                accountIdHex: $0, name: "Bob", sanitizedPictureURL: nil, isSelf: false)
        }
    )
    .frame(width: 380)
    .environment(WorkspaceState.preview())
}
