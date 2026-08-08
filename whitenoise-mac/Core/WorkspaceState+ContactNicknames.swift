//
//  WorkspaceState+ContactNicknames.swift
//  whitenoise-mac
//
//  Private per-contact nicknames: a local, owner-scoped display-name override. Setting one
//  publishes nothing — the value is folded into the same projections that resolve published
//  names, and persisted in protected, backup-excluded per-owner files.
//

import Foundation
import MarmotKit
import OSLog

private let contactNicknameLogger = Logger(subsystem: "com.whitenoise.storage", category: "ContactNicknames")

@MainActor
extension WorkspaceState {
    // MARK: - Load

    func loadContactNicknames() {
        guard let contactNicknameStore else { return }
        do {
            contactNicknamesByOwner = try contactNicknameStore.loadAll()
        } catch {
            contactNicknameLogger.error(
                "Failed to load protected contact-nickname state: \(error.localizedDescription, privacy: .public)"
            )
        }
        invalidateContactNicknameCache()
    }

    // MARK: - Reads

    /// The active account's nickname map. Every projection reads through this, so the override
    /// lands on chat rows, sender labels, member rows, and recipient search from one place.
    var activeContactNicknames: ContactNicknames {
        // Read the observed map before the memo so a SwiftUI body that resolves a nickname stays
        // subscribed to nickname writes even when the snapshot itself is cached.
        _ = contactNicknamesByOwner
        return contactNicknames(forOwnerAccountIdHex: activeAccount?.accountIdHex ?? "")
    }

    /// One specific owner's nickname map. The notification path needs this: an update can target
    /// a background account, and resolving from `activeAccount` there would render one account's
    /// private label on another account's banner.
    func contactNicknames(forOwnerAccountIdHex ownerAccountIdHex: String) -> ContactNicknames {
        guard let owner = ContactNicknames.normalizedHex(ownerAccountIdHex) else { return .none }
        let stamp = ContactNicknameStamp(ownerAccountIdHex: owner, revision: contactNicknameRevision)
        if let cached = cachedContactNicknames?.value(at: stamp) { return cached }
        let value = ContactNicknames(
            ownerAccountIdHex: owner,
            byContactIdHex: contactNicknamesByOwner[owner] ?? [:]
        )
        cachedContactNicknames = NicknameStamped(stamp: stamp, value: value)
        return value
    }

    /// Which nickname set the active account resolves against right now. Projections that fold
    /// nicknames in stamp themselves with this and re-check it instead of rebuilding: the map
    /// itself is never compared, only an account id and a counter.
    ///
    /// Reads the observed map for the same reason `activeContactNicknames` does — a SwiftUI body
    /// that gets a memoized projection back must still be subscribed to the next nickname write.
    var contactNicknameStamp: ContactNicknameStamp {
        _ = contactNicknamesByOwner
        return ContactNicknameStamp(
            ownerAccountIdHex: ContactNicknames.normalizedHex(activeAccount?.accountIdHex ?? "") ?? "",
            revision: contactNicknameRevision
        )
    }

    func contactNickname(forContactAccountIdHex contactAccountIdHex: String) -> String? {
        activeContactNicknames.nickname(forContactAccountIdHex: contactAccountIdHex)
    }

    /// Whether the nickname affordance applies to this contact at all. False for one of this
    /// device's own accounts — their local label wins — and while no account is active.
    func canSetContactNickname(forContactAccountIdHex contactAccountIdHex: String) -> Bool {
        contactNicknameOwner(forContactAccountIdHex: contactAccountIdHex) != nil
    }

    // MARK: - Write

    /// Sets or clears the active account's private nickname for a contact. A value the
    /// display-name sanitizer rejects (empty, whitespace/control-only) clears the entry, so
    /// "save an empty field" and an explicit Remove land on one code path.
    func setContactNickname(_ rawNickname: String?, forContactAccountIdHex contactAccountIdHex: String) {
        guard let owner = contactNicknameOwner(forContactAccountIdHex: contactAccountIdHex),
            let contact = ContactNicknames.normalizedHex(contactAccountIdHex)
        else { return }

        var byContact = contactNicknamesByOwner[owner] ?? [:]
        byContact[contact] = ContactNicknames.sanitized(rawNickname)
        guard byContact != (contactNicknamesByOwner[owner] ?? [:]) else { return }

        contactNicknamesByOwner[owner] = byContact.isEmpty ? nil : byContact
        invalidateContactNicknameCache()
        persistContactNicknames(forOwnerAccountIdHex: owner)
        applyContactNicknameChange(forContactAccountIdHex: contact)
    }

    // MARK: - Cleanup

    /// Forget every nickname an account authored. Called on account removal, where the owner is
    /// gone and its private labels have no meaning; ordinary sign-out deliberately retains them,
    /// like pinned chats and hidden messages.
    func purgeContactNicknames(ownerAccountIdHex: String) {
        guard let owner = ContactNicknames.normalizedHex(ownerAccountIdHex) else { return }
        contactNicknamesByOwner[owner] = nil
        invalidateContactNicknameCache()
        do {
            try contactNicknameStore?.remove(forOwnerAccountIdHex: owner)
        } catch {
            contactNicknameLogger.error(
                "Failed to purge contact-nickname state for an account: \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    /// Forget every nickname on the device — part of the "Delete All Local Data" reset.
    func clearAllContactNicknames() {
        contactNicknamesByOwner = [:]
        invalidateContactNicknameCache()
        do {
            try contactNicknameStore?.removeAll()
        } catch {
            contactNicknameLogger.error(
                "Failed to clear contact-nickname state: \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    // MARK: - Projection

    /// Apply a nickname change to everything already materialized, so a user gesture lands
    /// immediately instead of waiting for the next projection. No FFI: every input is either the
    /// in-memory nickname map or a view model already in hand.
    func applyContactNicknameChange(forContactAccountIdHex contactAccountIdHex: String) {
        guard let accountId = activeAccountId,
            let contact = ContactNicknames.normalizedHex(contactAccountIdHex)
        else { return }
        let nickname = activeContactNicknames.nickname(forContactAccountIdHex: contact)

        relabelDirectChats(forAccountId: accountId, peerAccountIdHex: contact, nickname: nickname)
        relabelTimelineSenders(accountIdHex: contact, nickname: nickname)
        relabelComposeContacts(accountIdHex: contact, nickname: nickname)
        relabelContactDetailsTarget(accountIdHex: contact, nickname: nickname)
        replayTimelineForMentionsOf(contactAccountIdHex: contact)

        if nickname == nil {
            // Clearing a nickname hands the label back to whatever the peer published, so this
            // is exactly when a missing kind:0 starts mattering again. The gate may be holding
            // this id in a cooldown — possibly the long one `refreshPeerProfile` applies
            // *because* it was nicknamed — so drop that admission state before asking.
            peerProfileRefreshGate.remove(contact)
            requestPeerProfileRefresh(contact)
        }
    }

    // MARK: - Private

    private func contactNicknameOwner(forContactAccountIdHex contactAccountIdHex: String) -> String? {
        ContactNicknames.owner(
            activeAccountIdHex: activeAccount?.accountIdHex,
            localAccountIdsHex: accounts.map(\.accountIdHex),
            contactAccountIdHex: contactAccountIdHex
        )
    }

    private func invalidateContactNicknameCache() {
        contactNicknameRevision &+= 1
        cachedContactNicknames = nil
    }

    private func persistContactNicknames(forOwnerAccountIdHex owner: String) {
        guard let contactNicknameStore else { return }
        do {
            let byContact = contactNicknamesByOwner[owner] ?? [:]
            if byContact.isEmpty {
                try contactNicknameStore.remove(forOwnerAccountIdHex: owner)
            } else {
                try contactNicknameStore.write(byContact, forOwnerAccountIdHex: owner)
            }
        } catch {
            contactNicknameLogger.error(
                "Failed to persist contact-nickname state: \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    /// Retitle the direct chats whose peer is this contact. `avatarSeed` is the peer's account
    /// hex for a direct chat, so this touches exactly those rows and never a group.
    private func relabelDirectChats(forAccountId accountId: String, peerAccountIdHex: String, nickname: String?) {
        // Returns nil when nothing moved, so an unrelated contact's nickname never churns the
        // chat-list generation (and with it the memoized sidebar filter).
        let relabeled: ([ChatItem]) -> [ChatItem]? = { chats in
            var next = chats
            var didChange = false
            for index in next.indices {
                guard next[index].isDirect,
                    ContactNicknames.normalizedHex(next[index].avatarSeed) == peerAccountIdHex
                else { continue }
                let candidate = next[index].applyingNickname(nickname)
                guard candidate != next[index] else { continue }
                next[index] = candidate
                didChange = true
            }
            return didChange ? next : nil
        }

        // Route through the setters so the chat-list generation bumps and the memoized sidebar
        // filter recomputes against the new titles.
        if let chats = relabeled(chatsByAccount[accountId] ?? []) {
            setChats(chats, forAccountId: accountId)
        }
        if let archived = relabeled(archivedChatsByAccount[accountId] ?? []) {
            setArchivedChats(archived, forAccountId: accountId)
        }
    }

    /// Relabel this sender in every materialized timeline window, not just the selected chat: a
    /// background chat's cached window would otherwise keep the stale label until reprojection.
    private func relabelTimelineSenders(accountIdHex: String, nickname: String?) {
        var didChangeSelectedChat = false
        for (groupIdHex, store) in messageTimelineStores {
            guard store.relabelSender(accountIdHex: accountIdHex, nickname: nickname) else { continue }
            if case .chat(let selectedGroupIdHex) = selection, selectedGroupIdHex == groupIdHex {
                didChangeSelectedChat = true
            }
        }
        if didChangeSelectedChat {
            selectedChatRevision &+= 1
        }
    }

    /// A mention token is baked into the bubble's rendered Markdown when the window is projected,
    /// so — unlike a sender label — it cannot be patched into rows already on screen: the source
    /// AST the attributed string came from is not retained. Replay the open window instead, the
    /// same in-memory snapshot replay a late-arriving profile uses.
    ///
    /// Gated on the contact being in this conversation's roster, so renaming someone the open
    /// chat could not possibly mention costs one roster scan rather than a transcript re-map.
    /// Other conversations need nothing here: their `mentionNamesCache` entry is stamped with the
    /// nickname set, so whenever one is next projected it resolves against the new label. The
    /// same is true of chat-list previews, which re-resolve on their next row update.
    private func replayTimelineForMentionsOf(contactAccountIdHex contact: String) {
        guard let client, let account = activeAccount,
            let groupIdHex = activeTimelineGroupId,
            selectedChat?.id == groupIdHex,
            let members = groupMemberDetailsCache[groupIdHex],
            members.contains(where: { ContactNicknames.normalizedHex($0.memberIdHex) == contact })
        else { return }

        // Not cancelling any in-flight replay: a second rename's replay reads the same post-write
        // state, so the two can only agree, and cancelling one mid-snapshot would drop a repaint.
        contactNicknameMentionReplayTask = Task { [weak self] in
            await self?.replaySelectedTimelineWindow(account: account, client: client)
        }
    }

    private func relabelComposeContacts(accountIdHex: String, nickname: String?) {
        guard
            let index = composeContacts.firstIndex(where: {
                ContactNicknames.normalizedHex($0.accountIdHex) == accountIdHex
            })
        else { return }
        let existing = composeContacts[index]
        let published = existing.publishedDisplayName ?? existing.displayName
        composeContacts[index] = ComposeContact(
            accountIdHex: existing.accountIdHex,
            npub: existing.npub,
            displayName: nickname ?? published,
            publishedDisplayName: nickname == nil ? nil : published,
            pictureURL: existing.pictureURL,
            lastActivity: existing.lastActivity
        )
    }

    private func relabelContactDetailsTarget(accountIdHex: String, nickname: String?) {
        guard let existing = contactDetailsTarget,
            ContactNicknames.normalizedHex(existing.accountIdHex) == accountIdHex
        else { return }
        let published = existing.publishedDisplayName ?? existing.displayName
        contactDetailsTarget = NewChatRecipient(
            sourceQuery: existing.sourceQuery,
            memberRef: existing.memberRef,
            accountIdHex: existing.accountIdHex,
            npub: existing.npub,
            displayName: nickname ?? published,
            publishedDisplayName: nickname == nil ? nil : published,
            pictureURL: existing.pictureURL
        )
    }
}
