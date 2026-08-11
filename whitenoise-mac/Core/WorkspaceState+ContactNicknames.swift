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
        #if DEBUG
            contactNicknameSnapshotBuildCount += 1
        #endif
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

        relabelChatRows(forAccountId: accountId, contactAccountIdHex: contact, nickname: nickname)
        relabelTimelineSenders(accountIdHex: contact, nickname: nickname)
        relabelComposeContacts(accountIdHex: contact, nickname: nickname)
        relabelContactDetailsTarget(accountIdHex: contact, nickname: nickname)
        relabelTimelineMentions(ofContactAccountIdHex: contact)

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

    /// Retitle the direct chats whose peer is this contact, and re-attribute any row whose
    /// last-message preview names them.
    ///
    /// Both in one pass over each list: a rename touches the title of the DM with that person and
    /// the "Name: message" line of every chat they last spoke in, and splitting them would walk the
    /// chat list twice and bump its generation twice. The title match is on `avatarSeed`, which
    /// carries the peer's account hex for a direct chat, so it never catches a group; the preview
    /// match is on the last sender, which can be any row.
    private func relabelChatRows(forAccountId accountId: String, contactAccountIdHex: String, nickname: String?) {
        // Returns nil when nothing moved, so an unrelated contact's nickname never churns the
        // chat-list generation (and with it the memoized sidebar filter).
        let relabeled: ([ChatItem]) -> [ChatItem]? = { chats in
            var next = chats
            var didChange = false
            for index in next.indices {
                var candidate = next[index]
                if candidate.isDirect,
                    ContactNicknames.normalizedHex(candidate.avatarSeed) == contactAccountIdHex
                {
                    candidate = candidate.applyingNickname(nickname)
                }
                candidate = candidate.relabelingPreviewSender(
                    accountIdHex: contactAccountIdHex,
                    nickname: nickname
                )
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
    /// so a rename has to reach rows already on screen. It is rewritten in place, exactly as a
    /// sender label is: each mention run carries the `nostr:` link the projection gave it, so the
    /// person a run names is recoverable from the rendered string without the source AST.
    ///
    /// This deliberately does *not* replay the window. A replay depends on a live timeline
    /// subscription that can hand back a snapshot — state that is routinely absent while the
    /// transcript is still on screen (between a listener teardown and its next subscribe, during
    /// a reconnect, or whenever the runtime has no materialized window to snapshot) — and in every
    /// such case the rename silently did nothing until the conversation was re-selected. Rewriting
    /// the runs depends on nothing but the rows themselves, is synchronous with the gesture, and
    /// costs less than the re-map a replay performed: no snapshot, no FFI, no re-parse, and no
    /// work at all for bubbles that never mention the renamed person.
    ///
    /// Every materialized window is relabeled, not just the selected chat's, for the reason
    /// `relabelTimelineSenders` does the same: a background window would otherwise keep the stale
    /// label until it is next projected. A chat-list preview's mention tokens are baked the same
    /// way and re-resolve on the row's next update — its attribution prefix, the part of that line
    /// a rename is visibly about, is patched immediately by `relabelChatRows` — and every other
    /// group's `mentionNamesCache` entry is stamped with the nickname set, so it rebuilds against
    /// the new label whenever it is next read.
    private func relabelTimelineMentions(ofContactAccountIdHex contact: String) {
        var didChangeSelectedChat = false
        for (groupIdHex, store) in messageTimelineStores {
            // The label is resolved through the same projection this window was built from, over
            // the same roster entry, so an in-place relabel and the next re-projection cannot
            // disagree. Without a roster there is no npub to relabel by and no published name to
            // fall back to, which is also the state in which the mention is already rendering as
            // truncated bech32 — nothing to do until enrichment warms the roster again.
            guard let members = groupMemberDetailsCache[groupIdHex],
                let member = members.first(where: { ContactNicknames.normalizedHex($0.memberIdHex) == contact }),
                !member.npub.isEmpty
            else { continue }
            let label = Self.mentionNames(from: [member], nicknames: activeContactNicknames)[member.npub]
            guard store.relabelMention(bech32: member.npub, name: label) else { continue }
            if case .chat(let selectedGroupIdHex) = selection, selectedGroupIdHex == groupIdHex {
                didChangeSelectedChat = true
            }
        }
        if didChangeSelectedChat {
            selectedChatRevision &+= 1
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
