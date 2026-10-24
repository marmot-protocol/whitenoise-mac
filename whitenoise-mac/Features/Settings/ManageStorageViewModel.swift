//
//  ManageStorageViewModel.swift
//  whitenoise-mac
//
//  One profile's Manage Storage state: what retained attachments hold on this Mac, largest
//  first, and the bulk removals MarmotKit 0.14 offers. Ported from whitenoise-ios's
//  `ManageStorageModel` (whitenoise-ios#1200).
//
//  The model lives on the account's `SettingsViewModel`, so it is bound to one account and one
//  runtime for its whole life — switching identities builds a new one rather than re-binding
//  this. Chat names and avatars come from the account's live chat list, which already follows
//  MDK's presented rows, so a chat whose picture arrives or that is renamed elsewhere updates in
//  place without a subscription of this screen's own.
//

import Foundation
import MarmotKit
import Observation

@MainActor
@Observable
final class ManageStorageViewModel {
    enum Scope: Hashable {
        case account
        case chat(String)

        var groupIdHex: String? {
            if case .chat(let groupIdHex) = self { return groupIdHex }
            return nil
        }
    }

    enum Operation: Equatable {
        case clearCache
        case removeOlder(Scope)
        case removeChat(String)
        case removeAttachment(String)
    }

    /// A listing entry that no longer reads locally: it is already gone.
    struct AttachmentNoLongerHeld: Error {}

    typealias ChatPages = StoragePageList<ChatAttachmentUsageFfi, ChatStorageCursor>
    typealias AttachmentPages = StoragePageList<RetainedAttachmentSummaryFfi, RetainedAttachmentsCursor>

    let accountRef: String
    let activeAccountIdHex: String
    private(set) var usageRefresh = ManageStoragePresentation.UsageRefresh()
    private(set) var chats = ChatPages(id: \.groupIdHex)
    private(set) var chatsFailed = false
    private(set) var isLoadingChats = false
    private(set) var attachments: [Scope: AttachmentPages] = [:]
    private(set) var attachmentsFailed: Set<Scope> = []
    private(set) var loadingAttachments: Set<Scope> = []
    private(set) var operation: Operation?
    /// The last operation that failed, shown beside the control that started it.
    private(set) var failedOperation: Operation?
    /// Advances whenever the listings start over, so views re-request pages and a page that was
    /// already in flight is dropped instead of appended to the fresh listing.
    ///
    /// Why a counter rather than cancelling a task: page loads are started by the load-more rows'
    /// own `.task`s, which belong to whichever sub-page is on screen, and a removal or a refresh
    /// restarts every listing at once. The model owns none of those tasks, so it cannot cancel
    /// them; the epoch is how their late results are recognized as belonging to the old listing.
    private(set) var epoch = 0
    /// Presented rows for listed chats the chat list does not carry, read once each.
    private var fallbackRows: [String: PresentedChatRowFfi] = [:]

    @ObservationIgnored private let runtime: (any MarmotRuntime)?
    @ObservationIgnored private weak var chatList: ChatListViewModel?
    @ObservationIgnored private let attachmentsDidChange: @MainActor () async -> Void

    /// - Parameter attachmentsDidChange: Runs after any removal was attempted. Bulk removals report
    ///   counts, not which attachments went, so the shell drops every decrypted copy it holds and
    ///   open conversations re-read through MDK.
    init(
        accountRef: String,
        activeAccountIdHex: String,
        runtime: (any MarmotRuntime)?,
        chatList: ChatListViewModel? = nil,
        attachmentsDidChange: @escaping @MainActor () async -> Void = {}
    ) {
        self.accountRef = accountRef
        self.activeAccountIdHex = activeAccountIdHex
        self.runtime = runtime
        self.chatList = chatList
        self.attachmentsDidChange = attachmentsDidChange
    }

    var usage: ManageStoragePresentation.Usage? { usageRefresh.usage }

    func chatUsage(_ groupIdHex: String) -> ChatAttachmentUsageFfi? {
        chats.items.first { $0.groupIdHex == groupIdHex }
    }

    func attachmentPages(_ scope: Scope) -> AttachmentPages {
        attachments[scope] ?? Self.emptyAttachmentPages()
    }

    /// The chat as the sidebar draws it — name, nickname overlay and avatar — or nil when MDK has
    /// no presented row for it.
    func chat(for groupIdHex: String, nicknames: ContactNicknames) -> ChatItem? {
        if let item = chatList?.chatItem(groupIdHex: groupIdHex, nicknames: nicknames) {
            return item
        }
        guard let presented = fallbackRows[groupIdHex] else { return nil }
        return ChatItem(
            presented: presented,
            activeAccountIdHex: activeAccountIdHex,
            nickname: presented.presentation.peerId.flatMap {
                nicknames.nickname(forContactAccountIdHex: $0)
            }
        )
    }

    /// Starts every figure and listing over.
    func load() async {
        reset()
        await refreshUsage()
        await loadMoreChats()
    }

    func refreshUsage() async {
        guard let runtime else { return }
        let epoch = epoch
        do {
            let value = try await runtime.attachmentStorageUsage(accountRef: accountRef)
            guard isCurrent(epoch) else { return }
            usageRefresh.succeeded(ManageStoragePresentation.Usage(value))
        } catch {
            guard !(error is CancellationError), isCurrent(epoch) else { return }
            usageRefresh.failedToRefresh()
        }
    }

    func loadMoreChats() async {
        guard !isLoadingChats, chats.hasMore, let runtime else { return }
        let epoch = epoch
        isLoadingChats = true
        defer { if self.epoch == epoch { isLoadingChats = false } }
        do {
            let page = try await runtime.attachmentStorageByChat(
                accountRef: accountRef, limit: ManageStoragePresentation.pageLimit, cursor: chats.cursor)
            guard isCurrent(epoch) else { return }
            await resolveFallbackRows(page.chats.map(\.groupIdHex))
            guard isCurrent(epoch) else { return }
            chats.append(page.chats, next: page.nextCursor)
            chatsFailed = false
        } catch {
            guard !(error is CancellationError), isCurrent(epoch) else { return }
            chatsFailed = true
        }
    }

    func loadMoreAttachments(_ scope: Scope) async {
        let pages = attachmentPages(scope)
        guard !loadingAttachments.contains(scope), pages.hasMore, let runtime else { return }
        let epoch = epoch
        loadingAttachments.insert(scope)
        defer { if self.epoch == epoch { loadingAttachments.remove(scope) } }
        do {
            let page = try await runtime.largestRetainedAttachments(
                accountRef: accountRef, groupIdHex: scope.groupIdHex,
                limit: ManageStoragePresentation.pageLimit, cursor: pages.cursor)
            guard isCurrent(epoch) else { return }
            if scope == .account {
                await resolveFallbackRows(page.attachments.map(\.groupIdHex))
                guard isCurrent(epoch) else { return }
            }
            var updated = attachmentPages(scope)
            updated.append(page.attachments, next: page.nextCursor)
            attachments[scope] = updated
            attachmentsFailed.remove(scope)
        } catch {
            guard !(error is CancellationError), isCurrent(epoch) else { return }
            attachmentsFailed.insert(scope)
        }
    }

    func clearCache() async {
        await perform(.clearCache) { runtime, accountRef in
            try await runtime.clearAvatarCache(accountRef: accountRef)
        }
    }

    /// Removes before the exact cutoff the confirmation named.
    func removeOlder(than cutoff: ManageStoragePresentation.RemovalCutoff, in scope: Scope) async {
        let receivedBefore = cutoff.receivedBefore
        await perform(.removeOlder(scope)) { runtime, accountRef in
            _ = try await runtime.removeAttachmentsOlderThan(
                accountRef: accountRef, receivedBefore: receivedBefore, groupIdHex: scope.groupIdHex)
        }
    }

    func removeAllAttachments(inChat groupIdHex: String) async {
        await perform(.removeChat(groupIdHex)) { runtime, accountRef in
            _ = try await runtime.removeChatAttachments(accountRef: accountRef, groupIdHex: groupIdHex)
        }
    }

    /// One listing entry goes through the same Remove as a message's downloads. An entry that no
    /// longer reads locally is already gone, and starting over drops its row.
    func remove(_ attachment: RetainedAttachmentSummaryFfi) async {
        let id = ManageStoragePresentation.attachmentID(attachment)
        await perform(.removeAttachment(id)) { runtime, accountRef in
            let assets = try await runtime.attachmentLocalAssets(
                accountRef: accountRef, groupIdHex: attachment.groupIdHex, targets: [attachment.target])
            guard let reference = assets.first?.reference else { throw AttachmentNoLongerHeld() }
            guard try await runtime.controlAttachment(accountRef: accountRef, reference: reference, control: .remove)
            else { throw AttachmentNoLongerHeld() }
        }
    }

    private func perform(
        _ operation: Operation,
        _ body: (any MarmotRuntime, String) async throws -> Void
    ) async {
        guard self.operation == nil, let runtime else { return }
        self.operation = operation
        failedOperation = nil
        defer { self.operation = nil }
        do {
            try await body(runtime, accountRef)
        } catch {
            failedOperation = operation
        }
        // A failed bulk call may still have removed some attachments.
        if operation != .clearCache {
            await attachmentsDidChange()
        }
        await load()
    }

    private func reset() {
        epoch &+= 1
        usageRefresh = ManageStoragePresentation.UsageRefresh()
        chats = ChatPages(id: \.groupIdHex)
        chatsFailed = false
        isLoadingChats = false
        attachments = [:]
        attachmentsFailed = []
        loadingAttachments = []
    }

    /// Chats the chat list does not carry (it keeps every chat this account has, so this is the
    /// rare row MDK has not presented there yet) are read once each; the placeholder title
    /// stands in meanwhile.
    private func resolveFallbackRows(_ groupIds: [String]) async {
        guard let runtime else { return }
        for groupIdHex in Set(groupIds)
        where fallbackRows[groupIdHex] == nil && chatList?.presentedRow(groupIdHex: groupIdHex) == nil {
            do {
                if let row = try await runtime.presentedChatListRow(accountRef: accountRef, groupIdHex: groupIdHex) {
                    fallbackRows[groupIdHex] = row
                }
            } catch {
                if error is CancellationError { return }
            }
        }
    }

    private func isCurrent(_ epoch: Int) -> Bool {
        !Task.isCancelled && self.epoch == epoch
    }

    private static func emptyAttachmentPages() -> AttachmentPages {
        AttachmentPages(id: ManageStoragePresentation.attachmentID)
    }
}

extension ManageStorageViewModel {
    static func preview() -> ManageStorageViewModel {
        ManageStorageViewModel(accountRef: "preview", activeAccountIdHex: "preview", runtime: nil)
    }

    #if DEBUG
        /// Fixed figures for previews. It has no runtime, so nothing reaches MDK.
        static func fixture(
            usage: AttachmentStorageUsageFfi,
            chats: [ChatAttachmentUsageFfi],
            attachments: [RetainedAttachmentSummaryFfi]
        ) -> ManageStorageViewModel {
            let model = preview()
            model.usageRefresh.succeeded(ManageStoragePresentation.Usage(usage))
            model.chats.append(chats, next: nil)
            var account = emptyAttachmentPages()
            account.append(attachments, next: nil)
            model.attachments[.account] = account
            for groupIdHex in Set(attachments.map(\.groupIdHex)) {
                var pages = emptyAttachmentPages()
                pages.append(attachments.filter { $0.groupIdHex == groupIdHex }, next: nil)
                model.attachments[.chat(groupIdHex)] = pages
            }
            return model
        }
    #endif
}
