import MarmotKit
import SwiftUI

/// A relay step's screen — the relays step or the message inbox step. `whitenoise-ios`'s
/// `AccountSetupRelayStepView`: it says where the step stands, lists the addresses in play (a
/// proposal under review, the defaults, or the relays a search would look on), and offers what
/// MarmotKit allows — use the defaults, save or discard a proposal, edit the list, search another
/// relay for existing settings, or retry. iOS opens the editor and the search as sheets of their
/// own; here they replace the screen's column, with Cancel back to the overview.
struct AccountSetupRelayStep: View {
    let model: OnboardingCoordinator
    let step: OnboardingStepFfi

    enum Mode: Equatable { case overview, editing, searching }

    @State private var mode: Mode
    @State private var draft: AccountSetupRelayDraft

    /// `initialMode` opens the editor or the search directly, for a preview; the screen always
    /// starts on the overview.
    init(model: OnboardingCoordinator, step: OnboardingStepFfi, initialMode: Mode = .overview) {
        self.model = model
        self.step = step
        _mode = State(initialValue: initialMode)
        _draft = State(
            initialValue: initialMode == .editing
                ? AccountSetupRelayDraft(proposal: nil, step: step) : AccountSetupRelayDraft()
        )
    }

    var body: some View {
        switch mode {
        case .overview:
            AccountSetupRelayOverview(model: model, step: step) { proposal in
                draft = AccountSetupRelayDraft(proposal: proposal, step: step)
                mode = .editing
            } search: {
                mode = .searching
            }
        case .editing:
            AccountSetupRelayEditorPane(model: model, step: step, draft: $draft) { mode = .overview }
        case .searching:
            AccountSetupRelaySearchPane(model: model, step: step) { mode = .overview }
        }
    }
}

/// Where the relay step stands, the addresses in play, and the step's actions.
private struct AccountSetupRelayOverview: View {
    @Environment(\.locale) private var locale
    let model: OnboardingCoordinator
    let step: OnboardingStepFfi
    /// Opens the editor, seeded with the proposal that was withdrawn to edit it, if any.
    let edit: (OnboardingRepairProposalFfi?) -> Void
    let search: () -> Void
    @State private var active: String?

    private var defaultRelays: [String] {
        step == .inboxRelays ? MarmotClient.seedRelays : MarmotClient.accountRelays
    }

    var body: some View {
        let plan = AccountSetupRelayPlan(snapshot: model.snapshot, step: step)

        AccountSetupStepLayout(step: step) {
            AccountSetupCallout(
                titleKey: plan.statusTitleKey,
                symbol: "network",
                isError: plan.isInterrupted || model.error != nil,
                isLoading: model.isBusy && active == nil
            ) {
                ForEach(plan.messageKeys, id: \.self) { Text(L10n.string($0, locale: locale)) }
                if plan.proposal == nil, !plan.findings.isEmpty {
                    Divider()
                    AccountSetupFindingLines(findings: plan.findings)
                }
            }

            if let list = plan.addressList(defaultRelays: defaultRelays, searchRelays: MarmotClient.seedRelays) {
                AccountSetupRelayAddressList(headerKey: list.headerKey, entries: list.entries)
            }

            AccountSetupNoActionLines(step: step, snapshot: model.snapshot)
            AccountSetupErrorLine(message: model.error)
        } actions: {
            AccountSetupRelayActions(plan: plan, model: model, active: $active) { action in
                await perform(action, plan: plan)
            }
        }
    }

    private func perform(_ action: AccountSetupRelayPlan.Action, plan: AccountSetupRelayPlan) async {
        switch action {
        case .approve: await model.approveRepair()
        case .useDefaults: await model.useRecommendedRelays(step: step)
        case .retry: await model.retry(step)
        case .discard: await model.cancelRepair()
        case .searchDefaults: await model.searchDefaultRelays()
        case .discovery: search()
        case .edit:
            // Editing a proposal withdraws it first, keeping its addresses in the draft; nothing
            // is published until the edited list is reviewed and saved.
            if plan.proposal != nil {
                await model.cancelRepair()
                guard model.error == nil else { return }
            }
            edit(plan.proposal)
        }
    }
}

/// A relay step's buttons: its primary action, then the secondary ones under it.
struct AccountSetupRelayActions: View {
    let plan: AccountSetupRelayPlan
    let model: OnboardingCoordinator
    @Binding var active: String?
    let perform: (AccountSetupRelayPlan.Action) async -> Void

    var body: some View {
        if let primary = plan.primaryAction {
            AccountSetupStepButton(titleKey: plan.titleKey(primary, isPrimary: true), model: model, active: $active) {
                await perform(primary)
            }
        }
        ForEach(plan.secondaryActions, id: \.self) { action in
            AccountSetupStepButton(
                titleKey: plan.titleKey(action, isPrimary: false),
                tier: .secondary,
                model: model,
                active: $active
            ) { await perform(action) }
        }
    }
}

/// The relay list editor: Review Changes proposes the edited list, which the overview then shows
/// for approval.
private struct AccountSetupRelayEditorPane: View {
    @Environment(\.locale) private var locale
    let model: OnboardingCoordinator
    let step: OnboardingStepFfi
    @Binding var draft: AccountSetupRelayDraft
    let close: () -> Void
    @State private var problem: AccountSetupRelayDraft.Problem?
    @State private var active: String?

    var body: some View {
        AccountSetupStepLayout(step: step) {
            AccountSetupCallout(titleKey: "Choose your relay list", symbol: "network") {
                Text(
                    L10n.string(
                        step == .inboxRelays
                            ? "Inbox relays receive invitations to new chats and groups."
                            : "Add the relays you want to use. Keep at least one write relay so your profile can publish information.",
                        locale: locale
                    )
                )
                Text(
                    L10n.string(
                        step == .inboxRelays
                            ? "This replaces your message inbox relay list, including entries you leave out. Nothing is published until you review and approve it."
                            : "This will replace your public relay list, including entries you leave out. You’ll review the full list before anything is published.",
                        locale: locale
                    )
                )
            }

            AccountSetupRelayDraftEditor(
                draft: $draft,
                showsRoles: step != .inboxRelays,
                isEnabled: !model.isBusy && active == nil
            )
            .onChange(of: draft) { _, _ in problem = nil }

            AccountSetupErrorLine(message: problem.map { L10n.string($0.messageKey, locale: locale) } ?? model.error)
        } actions: {
            AccountSetupStepButton(titleKey: "Review Changes", model: model, active: $active) {
                switch draft.selection(for: step) {
                case .failure(let found):
                    problem = found
                case .success(let selection):
                    await model.proposeRelays(step: step, read: selection.reads, write: selection.writes)
                    if model.error == nil { close() }
                }
            }
            AccountSetupStepButton(titleKey: "Cancel", tier: .secondary, model: model, active: $active) {
                close()
            }
        }
    }
}

/// Searching one relay the user names for the profile's existing settings. Publishes nothing.
private struct AccountSetupRelaySearchPane: View {
    @Environment(\.locale) private var locale
    let model: OnboardingCoordinator
    let step: OnboardingStepFfi
    let close: () -> Void
    @State private var relay = ""
    @State private var searchError: String?
    @State private var active: String?

    var body: some View {
        AccountSetupStepLayout(step: step) {
            AccountSetupCallout(
                titleKey: searchError == nil
                    ? "Search a relay you’ve used before" : "Couldn’t find your relay settings",
                symbol: "magnifyingglass",
                isError: searchError != nil,
                isLoading: model.isBusy
            ) {
                if let searchError {
                    Text(searchError)
                } else {
                    Text(
                        L10n.string(
                            step == .relays
                                ? "Enter a relay address from another app where you use this profile. We’ll look there for your existing relay settings."
                                : "Choose a relay you’ve used with this profile. We’ll look there for your existing settings without publishing anything.",
                            locale: locale
                        )
                    )
                }
                Divider()
                Text(
                    L10n.string(
                        "Searching won’t publish changes to your profile or replace your relay list.", locale: locale
                    )
                )
            }

            WNInput(
                label: L10n.string("Relay URL", locale: locale),
                prompt: "wss://relay.example.com",
                text: $relay,
                isEnabled: !model.isBusy && active == nil,
                disablesAutocorrection: true,
                focusOnAppear: true
            )
            .onChange(of: relay) { _, _ in searchError = nil }
        } actions: {
            AccountSetupStepButton(
                titleKey: "Search Relay",
                model: model,
                active: $active,
                isEnabled: !relay.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ) {
                let trimmed = relay.trimmingCharacters(in: .whitespacesAndNewlines)
                guard RelayURLValidator.classify(trimmed).isAcceptable else {
                    searchError = L10n.string("Enter a valid relay URL, like wss://relay.example.com.", locale: locale)
                    return
                }
                await model.setDiscoveryRelays([trimmed])
                let status = model.snapshot?.steps.first { $0.step == step }?.status
                if model.error == nil, status != .retryableFailure {
                    close()
                } else {
                    searchError =
                        model.error
                        ?? L10n.string("Couldn’t find your settings. Try another relay.", locale: locale)
                }
            }
            AccountSetupStepButton(titleKey: "Cancel", tier: .secondary, model: model, active: $active) {
                close()
            }
        }
    }
}

/// A heading over the addresses a relay step shows, each with the uses it would have.
struct AccountSetupRelayAddressList: View {
    @Environment(\.locale) private var locale
    let headerKey: String
    let entries: [AccountSetupRelayPlan.Entry]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(L10n.string(headerKey, locale: locale))
                .wnFont(.semiBold12)
                .foregroundStyle(WNColor.backgroundContentSecondary)
                .accessibilityAddTraits(.isHeader)
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                    if index > 0 { Divider() }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(verbatim: entry.address)
                            .wnFont(.medium12)
                            .foregroundStyle(WNColor.backgroundContentPrimary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .textSelection(.enabled)
                        if let roleKey = entry.roleKey {
                            Text(L10n.string(roleKey, locale: locale))
                                .wnFont(.medium10)
                                .foregroundStyle(WNColor.backgroundContentTertiary)
                        }
                    }
                    .padding(.vertical, 8)
                    .accessibilityElement(children: .combine)
                }
            }
            .modifier(AccountSetupCardChrome(padding: 12))
        }
    }
}

/// The relay list being edited: one address field per relay with its Read and Write uses, a
/// remove button, and Add Relay under them.
struct AccountSetupRelayDraftEditor: View {
    @Environment(\.locale) private var locale
    @Binding var draft: AccountSetupRelayDraft
    let showsRoles: Bool
    var isEnabled = true

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach($draft.entries) { $entry in
                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .bottom, spacing: 8) {
                        WNInput(
                            label: L10n.string("Relay URL", locale: locale),
                            prompt: "wss://relay.example.com",
                            text: $entry.address,
                            isEnabled: isEnabled,
                            disablesAutocorrection: true
                        )
                        Button {
                            draft.entries.removeAll { $0.id == entry.id }
                        } label: {
                            Image(systemName: "minus.circle")
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(WNColor.backgroundContentSecondary)
                        .help(L10n.string("Remove", locale: locale))
                        .accessibilityLabel(L10n.string("Remove", locale: locale))
                        .disabled(draft.entries.count == 1)
                        .padding(.bottom, 10)
                    }
                    if showsRoles {
                        HStack(spacing: 16) {
                            Toggle(L10n.string("Read", locale: locale), isOn: $entry.reads)
                            Toggle(L10n.string("Write", locale: locale), isOn: $entry.writes)
                        }
                        .toggleStyle(.checkbox)
                        .wnFont(.medium12)
                    }
                }
            }
            Button {
                draft.entries.append(AccountSetupRelayDraft.Entry())
            } label: {
                Label(L10n.string("Add Relay", locale: locale), systemImage: "plus")
                    .wnFont(.medium12)
            }
            .onboardingActionTier(.secondary)
            .controlSize(.small)
            .disabled(draft.entries.count >= AccountSetupRelayDraft.selectionLimit)
        }
        .disabled(!isEnabled)
    }
}

#Preview("Relays: use defaults") {
    let model = OnboardingCoordinator.preview(steps: [
        OnboardingStepStateFfi(
            step: .relays, status: .needsInput,
            findings: [.init(issue: .missing, endpoint: nil)],
            actions: [.useRecommendedRelays, .editRelays, .editDiscoveryRelays, .retry], checkedAt: nil
        )
    ])
    AccountSetupStepScreen(model: model, step: .relays)
}

#Preview("Relays: review proposal") {
    let model = OnboardingCoordinator.preview(
        steps: [
            OnboardingStepStateFfi(
                step: .relays, status: .needsInput, findings: [],
                actions: [.approveRepair, .cancelRepair], checkedAt: nil
            )
        ],
        proposal: OnboardingRepairProposalFfi(
            step: .relays, revision: 1, previousEventId: nil,
            readRelays: ["wss://relay.example.com", "wss://read.example.com"],
            writeRelays: ["wss://relay.example.com"], profile: nil, follows: nil, relayRepair: nil
        )
    )
    AccountSetupStepScreen(model: model, step: .relays)
}

#Preview("Relays: edit") {
    let model = OnboardingCoordinator.preview(steps: [
        OnboardingStepStateFfi(
            step: .relays, status: .needsInput, findings: [],
            actions: [.editRelays, .editDiscoveryRelays], checkedAt: nil
        )
    ])
    AccountSetupRelayStep(model: model, step: .relays, initialMode: .editing)
        .frame(width: 940, height: 620)
        .background(WNColor.backgroundPrimary)
        .controlSize(.large)
        .wnButtonShape(.capsule)
}

#Preview("Relays: search") {
    let model = OnboardingCoordinator.preview(steps: [
        OnboardingStepStateFfi(
            step: .inboxRelays, status: .retryableFailure, findings: [],
            actions: [.retry, .editDiscoveryRelays], checkedAt: nil
        )
    ])
    AccountSetupRelayStep(model: model, step: .inboxRelays, initialMode: .searching)
        .frame(width: 940, height: 620)
        .background(WNColor.backgroundPrimary)
        .controlSize(.large)
        .wnButtonShape(.capsule)
}
