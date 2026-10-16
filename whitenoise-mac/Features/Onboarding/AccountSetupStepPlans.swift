import Foundation
import MarmotKit

/// What the profile step's review screen offers for one snapshot. Ported from `whitenoise-ios`'s
/// `AccountSetupProfilePresentation`: a profile that can be edited shows the form and saves it; a
/// lookup that failed offers a retry; an optional step offers Not Now; a publication that was
/// interrupted can only be finished.
struct AccountSetupProfilePlan: Equatable {
    enum Action: Equatable { case save, retry }

    /// The profile a pending proposal would publish, to pre-fill the form with.
    let profile: UserProfileMetadataFfi?
    let canEdit: Bool
    let canRetry: Bool
    let canSkip: Bool
    let canCancelRepair: Bool
    let isInterrupted: Bool
    private let lookupIssue: OnboardingIssueFfi?

    init(snapshot: OnboardingSnapshotFfi?) {
        let step = snapshot?.steps.first { $0.step == .profile }
        let actions = step?.actions ?? []
        let proposal = snapshot?.proposal.flatMap { $0.step == .profile ? $0 : nil }
        profile = proposal?.profile
        isInterrupted = proposal != nil && !actions.contains(.approveRepair) && !actions.contains(.cancelRepair)
        canEdit = !isInterrupted && (actions.contains(.editProfile) || actions.contains(.approveRepair))
        canRetry = actions.contains(.retry)
        canSkip = !isInterrupted && actions.contains(.continueWithout)
        canCancelRepair = actions.contains(.cancelRepair)
        lookupIssue = step?.findings.lazy.map(\.issue).first { [.timedOut, .unreachable, .malformed].contains($0) }
    }

    var primaryAction: Action? {
        if canEdit { return .save }
        return canRetry ? .retry : nil
    }

    /// Whether the screen has no button to offer: no Save or Try Again, no Not Now, no Discard.
    var offersNoAction: Bool { primaryAction == nil && !canSkip && !canCancelRepair }

    var titleKey: String {
        if isInterrupted { return "Your profile update didn’t finish" }
        if profile != nil { return "Review your profile" }
        return canEdit ? "Add your profile" : "Couldn’t load your profile"
    }

    /// The lines under the title, in order.
    var messageKeys: [String] {
        if isInterrupted { return ["We couldn’t finish sharing your changes. Try again to complete the update."] }
        if profile != nil {
            return [
                "These changes haven’t been shared yet. Check the details below, then save to update your public profile."
            ]
        }
        if canEdit { return [AccountSetupGuide.descriptionKey(.profile)] }
        let lookup: String =
            switch lookupIssue {
            case .timedOut: "The service we checked took too long to respond."
            case .unreachable: "We couldn’t connect to the service that provides your profile."
            case .malformed: "We found profile information, but couldn’t read it."
            default: "We couldn’t get your profile details."
            }
        return [
            lookup,
            canSkip ? "Try again, or continue signing in without changing your profile." : "Try again to continue.",
        ]
    }

    /// The metadata Save publishes, or nil when the form holds nothing to publish. The single Name
    /// field is authoritative for both Nostr spellings whenever it is filled, as on iOS; fields the
    /// form does not show are carried over from the proposal it was pre-filled from.
    static func metadata(
        displayName: String,
        about: String,
        pictureURL: String?,
        existing: UserProfileMetadataFfi?
    ) -> UserProfileMetadataFfi? {
        let name = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        let about = about.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty || !about.isEmpty || pictureURL != nil else { return nil }
        return UserProfileMetadataFfi(
            name: name.isEmpty ? existing?.name : name,
            displayName: name.isEmpty ? existing?.displayName : name,
            about: about.isEmpty ? nil : about,
            picture: pictureURL ?? existing?.picture,
            banner: existing?.banner,
            nip05: existing?.nip05,
            lud16: existing?.lud16
        )
    }
}

/// What a relay step's review screen offers for one snapshot — the relays step or the message
/// inbox step. Ported from `whitenoise-ios`'s `AccountSetupRelayStepPresentation`, keeping its
/// choice of primary and secondary actions; MDK's typed relay-repair preview and "Suggest a Fix"
/// are not offered here yet.
struct AccountSetupRelayPlan: Equatable {
    enum Action: Hashable {
        case approve, useDefaults, retry, discard, edit, discovery, searchDefaults
    }

    /// One address in a list the screen shows, with the uses the relays step gives it.
    struct Entry: Equatable, Identifiable {
        let address: String
        let reads: Bool
        let writes: Bool
        var id: String { address }

        /// A catalog key, or nil on the inbox step, where relays have no roles.
        var roleKey: String? {
            switch (reads, writes) {
            case (true, true): "Read and write"
            case (false, true): "Write only"
            case (true, false): "Read only"
            case (false, false): nil
            }
        }
    }

    let step: OnboardingStepFfi
    let actions: [OnboardingActionFfi]
    let proposal: OnboardingRepairProposalFfi?
    let findings: [OnboardingFindingFfi]

    init(snapshot: OnboardingSnapshotFfi?, step: OnboardingStepFfi) {
        self.step = step
        let state = snapshot?.steps.first { $0.step == step }
        actions = state?.actions ?? []
        findings = state?.findings ?? []
        proposal = snapshot?.proposal.flatMap { $0.step == step ? $0 : nil }
    }

    var isInbox: Bool { step == .inboxRelays }

    /// A proposal MarmotKit neither lets the user approve nor withdraw: its publication started
    /// and has to be finished with a retry.
    var isInterrupted: Bool { proposal != nil && !allows(.approveRepair) && !allows(.cancelRepair) }

    var canEdit: Bool {
        guard !isInterrupted else { return false }
        return proposal == nil ? allows(.editRelays) : allows(.cancelRepair)
    }

    var canDiscover: Bool { !isInterrupted && allows(.editDiscoveryRelays) }

    /// Searching the default relays for existing settings, offered when defaults are not.
    var canSearchDefaults: Bool { proposal == nil && canDiscover && !allows(.useRecommendedRelays) }

    var primaryAction: Action? {
        if isInterrupted { return allows(.retry) ? .retry : nil }
        if proposal != nil, allows(.approveRepair) { return .approve }
        if allows(.useRecommendedRelays) { return .useDefaults }
        if canSearchDefaults { return .searchDefaults }
        if allows(.retry) { return .retry }
        return canEdit ? .edit : nil
    }

    /// Whether the screen has no button to offer, as when MarmotKit only asks for a signer to be
    /// reconnected.
    var offersNoAction: Bool { primaryAction == nil && secondaryActions.isEmpty }

    var secondaryActions: [Action] {
        let primary = primaryAction
        var result: [Action] = []
        // Searching only the defaults narrows the lookup, so a broader retry stays on offer.
        if primary == .searchDefaults, allows(.retry) { result.append(.retry) }
        if canEdit, primary != .edit { result.append(.edit) }
        if canDiscover, primary != .discovery { result.append(.discovery) }
        if proposal != nil, allows(.cancelRepair) { result.append(.discard) }
        return result
    }

    func titleKey(_ action: Action, isPrimary: Bool) -> String {
        switch action {
        case .approve: isInbox ? "Use These Relays" : "Save Relay Changes"
        case .useDefaults: "Use Default Relays"
        case .retry: "Try Again"
        case .discard: "Discard Changes"
        case .edit:
            isInbox ? (proposal == nil && !isPrimary ? "Choose Inbox Relays" : "Edit Inbox Relays") : "Edit Relays"
        case .discovery: isInbox ? "Look on Another Relay" : "Find Existing Relay Settings"
        case .searchDefaults: "Search Default Relays"
        }
    }

    var statusTitleKey: String {
        if isInterrupted { return "Your relay update didn’t finish" }
        if proposal != nil { return "Review your relay changes" }
        if isInbox { return "Your inbox relays" }
        if allows(.useRecommendedRelays) { return "Set up your relays" }
        return allows(.editRelays) ? "Your relays need attention" : "Couldn’t find your relay settings"
    }

    /// The explanation under the status title, in order.
    var messageKeys: [String] {
        if isInterrupted {
            return [
                isInbox
                    ? "Your previous update hasn’t finished. Try again to finish publishing it."
                    : "Your relay changes haven’t finished publishing. Try again to complete the update."
            ]
        }
        var keys: [String] = []
        if isInbox {
            keys.append("Inbox relays receive invitations to new chats and groups.")
        } else if proposal != nil {
            keys.append("Check the addresses and their uses before saving.")
        } else if allows(.useRecommendedRelays) {
            keys.append(
                "We couldn’t find a usable relay list for your profile. You can use the defaults below, or search a relay you’ve used before."
            )
        } else if allows(.editRelays) {
            keys.append(
                "Your current relay settings don’t let this profile publish information. Edit your relay list, or search another relay for your existing settings."
            )
        } else {
            keys.append(
                "We couldn’t finish checking your relay settings. Try again, or search a relay you’ve used with this profile. Searching won’t publish changes."
            )
        }
        if canSearchDefaults {
            keys.append("Search these relays for your existing settings. This won’t publish changes to your profile.")
        } else if let publication = publicationKey {
            keys.append(publication)
        }
        return keys
    }

    /// What pressing the primary publishes, said before it is pressed.
    private var publicationKey: String? {
        switch (isInbox, proposal == nil) {
        case (true, true) where allows(.useRecommendedRelays):
            "Continuing adds any of these addresses that are missing to your public profile. Relays already listed there are kept."
        case (true, false):
            "Saving publishes these addresses as your inbox relay list. It replaces the previous list, removing any entries not included here."
        case (false, true) where allows(.useRecommendedRelays):
            "Using defaults adds any missing addresses below to your public relay list. Existing entries are kept."
        case (false, false):
            "Saving publishes this as your public relay list. It replaces the previous list, removing any entries not included here."
        default: nil
        }
    }

    /// The addresses the screen lists under a heading: the proposal under review, the relays a
    /// search would look on, or the defaults Use Default Relays would add.
    func addressList(defaultRelays: [String], searchRelays: [String]) -> (headerKey: String, entries: [Entry])? {
        if let proposal {
            return (isInbox ? "Proposed inbox relays" : "Proposed relays", Self.entries(proposal, isInbox: isInbox))
        }
        if canSearchDefaults {
            return ("Relays to search", searchRelays.map { Entry(address: $0, reads: false, writes: false) })
        }
        if allows(.useRecommendedRelays) {
            return (
                "Default relays",
                defaultRelays.map { Entry(address: $0, reads: !isInbox, writes: !isInbox) }
            )
        }
        return nil
    }

    static func entries(_ proposal: OnboardingRepairProposalFfi, isInbox: Bool) -> [Entry] {
        var order: [String] = []
        for address in proposal.readRelays + proposal.writeRelays where !order.contains(address) {
            order.append(address)
        }
        return order.map { address in
            Entry(
                address: address,
                reads: !isInbox && proposal.readRelays.contains(address),
                writes: !isInbox && proposal.writeRelays.contains(address)
            )
        }
    }

    private func allows(_ action: OnboardingActionFfi) -> Bool { actions.contains(action) }
}

/// The relay list being edited on a relay step's review screen, before it is proposed.
///
/// MDK caps an explicit selection at 16 unique addresses across both roles, and the relays step
/// needs at least one write relay so the profile can publish; the inbox step has no roles.
struct AccountSetupRelayDraft: Equatable {
    struct Entry: Equatable, Identifiable {
        let id: UUID
        var address: String
        var reads: Bool
        var writes: Bool

        init(id: UUID = UUID(), address: String = "", reads: Bool = true, writes: Bool = true) {
            self.id = id
            self.address = address
            self.reads = reads
            self.writes = writes
        }

        var isValidAddress: Bool {
            RelayURLValidator.classify(normalizedAddress).isAcceptable
        }

        var normalizedAddress: String {
            address.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    enum Problem: Error, Equatable {
        case empty, invalidAddress, missingUse, noWriteRelay, tooMany

        /// A catalog key.
        var messageKey: String {
            switch self {
            case .empty: "Add a relay before continuing."
            case .invalidAddress: "Enter a valid relay URL, like wss://relay.example.com."
            case .missingUse: "Choose Read, Write, or both."
            case .noWriteRelay: "Choose at least one write relay so your profile can publish information."
            case .tooMany: "The relay list is too large."
            }
        }
    }

    static let selectionLimit = 16

    var entries: [Entry]

    init(entries: [Entry] = []) {
        self.entries = entries
    }

    /// The draft a proposal under review becomes when the user chooses to edit it instead.
    init(proposal: OnboardingRepairProposalFfi?, step: OnboardingStepFfi) {
        guard let proposal else {
            entries = [Entry()]
            return
        }
        let isInbox = step == .inboxRelays
        entries = AccountSetupRelayPlan.entries(proposal, isInbox: isInbox).map {
            Entry(address: $0.address, reads: isInbox || $0.reads, writes: isInbox || $0.writes)
        }
        if entries.isEmpty { entries = [Entry()] }
    }

    /// The read and write lists to propose, or the first problem that stops them.
    func selection(for step: OnboardingStepFfi) -> Result<(reads: [String], writes: [String]), Problem> {
        let filled = entries.filter { !$0.normalizedAddress.isEmpty }
        guard !filled.isEmpty else { return .failure(.empty) }
        guard filled.allSatisfy(\.isValidAddress) else { return .failure(.invalidAddress) }
        var reads: [String] = []
        var writes: [String] = []
        for entry in filled {
            let address = entry.normalizedAddress
            if step == .inboxRelays {
                if !reads.contains(address) { reads.append(address) }
                continue
            }
            guard entry.reads || entry.writes else { return .failure(.missingUse) }
            if entry.reads, !reads.contains(address) { reads.append(address) }
            if entry.writes, !writes.contains(address) { writes.append(address) }
        }
        guard Set(reads + writes).count <= Self.selectionLimit else { return .failure(.tooMany) }
        if step != .inboxRelays, writes.isEmpty { return .failure(.noWriteRelay) }
        return .success((reads, writes))
    }
}
