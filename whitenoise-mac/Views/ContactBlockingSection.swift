import SwiftUI

/// Block-list controls for a surface that is already about one resolved account.
/// The subscription belongs to `AccountScope`; this view only presents its live state.
struct ContactBlockingSection: View {
    let model: BlockedUsersViewModel?
    let accountID: String
    /// Adds Block and Report when this build can reach the White Noise team.
    var reporter: ModerationReporter? = nil

    @State private var pendingIntent: Bool?

    var body: some View {
        Section {
            if let error = model?.error {
                SettingsErrorView(error: error)
                Button(L10n.string("Retry")) {
                    retry()
                }
                .disabled(model?.mutatingUserIDs.isEmpty == false)
            }

            if let model, model.mutatingUserIDs.contains(accountID.lowercased()) {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text(
                        model.isBlocked(accountID: accountID)
                            ? L10n.string("Unblock User")
                            : L10n.string("Block User")
                    )
                    .foregroundStyle(WNColor.backgroundContentSecondary)
                }
            } else {
                Button(role: isBlocked ? nil : .destructive) {
                    pendingIntent = !isBlocked
                } label: {
                    Label(
                        isBlocked ? L10n.string("Unblock User") : L10n.string("Block User"),
                        systemImage: isBlocked
                            ? "person.crop.circle.badge.checkmark"
                            : "hand.raised"
                    )
                }
                .disabled(model?.canMutate(accountID: accountID) != true)
            }
        } footer: {
            Text(
                L10n.string(
                    "Blocking hides this person’s messages and prevents sending to them in direct chats. Existing history is retained."
                )
            )
        }
        .confirmationDialog(
            pendingIntent == true
                ? L10n.string("Block this user?")
                : L10n.string("Unblock this user?"),
            isPresented: Binding(
                get: { pendingIntent != nil },
                set: { isPresented in
                    if !isPresented { pendingIntent = nil }
                }
            ),
            titleVisibility: .visible
        ) {
            if pendingIntent == true, let reporter = availableReporter, let reportedAccountId {
                Button(L10n.string("Block and Report"), role: .destructive) {
                    reporter.startBlocking(accountIdHex: reportedAccountId, reporting: true)
                }
            }
            if let intent = pendingIntent {
                Button(
                    intent ? L10n.string("Block User") : L10n.string("Unblock User"),
                    role: intent ? .destructive : nil
                ) {
                    Task { await model?.setBlocked(intent, accountID: accountID) }
                }
            }
            Button(L10n.string("Cancel"), role: .cancel) {}
        } message: {
            if pendingIntent == true {
                BlockUserConfirmationMessage(reportsToTeam: availableReporter != nil)
            }
        }
    }

    /// The reporter, when this build can reach the White Noise team about this contact's key.
    private var availableReporter: ModerationReporter? {
        guard let reporter, reporter.isAvailable, reportedAccountId != nil else { return nil }
        return reporter
    }

    /// Only a well-formed key can be reported, matching the message path.
    private var reportedAccountId: String? {
        MessageModerationEligibility.normalizedAccountId(accountID)
    }

    private var isBlocked: Bool {
        model?.isBlocked(accountID: accountID) == true
    }

    private func retry() {
        if let uncertainIntent = model?.uncertainIntent,
            uncertainIntent.accountID == accountID.lowercased()
        {
            Task {
                await model?.setBlocked(uncertainIntent.blocked, accountID: uncertainIntent.accountID)
            }
        } else {
            model?.start()
        }
    }
}

struct BlockedContactNotice: View {
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "hand.raised.fill")
                .foregroundStyle(WNColor.backgroundContentDestructive)
            VStack(alignment: .leading, spacing: 2) {
                Text(L10n.string("You blocked this user"))
                    .wnFont(.semiBold12)
                Text(
                    L10n.string(
                        "Blocking hides this person’s messages and prevents sending to them in direct chats. Existing history is retained."
                    )
                )
                .wnFont(.medium10)
                .foregroundStyle(WNColor.backgroundContentSecondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }
}

struct BlockedConversationComposerNotice: View {
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "hand.raised.fill")
                .foregroundStyle(WNColor.backgroundContentDestructive)
            VStack(alignment: .leading, spacing: 2) {
                Text(L10n.string("You blocked this user"))
                    .wnFont(.semiBold12)
                Text(
                    L10n.string(
                        "Blocking hides this person’s messages and prevents sending to them in direct chats. Existing history is retained."
                    )
                )
                .wnFont(.medium10)
                .foregroundStyle(WNColor.backgroundContentSecondary)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

#Preview("Block control loading") {
    Form {
        ContactBlockingSection(model: nil, accountID: "peer")
    }
    .frame(width: 520, height: 260)
}

#Preview("Blocked contact notice") {
    BlockedContactNotice()
        .frame(width: 520)
}

#Preview("Blocked conversation composer") {
    BlockedConversationComposerNotice()
        .padding()
        .frame(width: 620)
}
