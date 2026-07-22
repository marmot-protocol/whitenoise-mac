//
//  WorkspaceState+GlobalMessageSearch.swift
//  whitenoise-mac
//
//  Cancellable, account-wide search over MDK's materialized timeline projection.
//

import Foundation
import MarmotKit

struct GlobalMessageSearchResult: Identifiable, Equatable, Sendable {
    let messageId: String
    let groupId: String
    let chatTitle: String
    let senderName: String
    let timelineAt: UInt64
    let snippet: GlobalMessageSearchSnippet

    var id: String { "\(groupId):\(messageId)" }
}

struct GlobalMessageSearchSnippet: Equatable, Sendable {
    let leading: String
    let match: String
    let trailing: String
}

struct GlobalMessageNavigationTarget: Equatable, Sendable {
    let requestId: UUID
    let groupId: String
    let messageId: String
}

nonisolated struct GlobalMessageSearchScope: Sendable {
    let groupId: String
    let title: String
}

nonisolated enum GlobalMessageSearchText {
    private static let searchableScalars = CharacterSet.alphanumerics.union(.nonBaseCharacters)
    private static let snippetLeadLength = 32
    private static let snippetMatchLength = 96
    private static let snippetTailLength = 160

    static func tokens(in query: String) -> [String] {
        let normalized = normalize(query)
        var tokens: [String] = []
        var current = String.UnicodeScalarView()

        func flush() {
            guard !current.isEmpty else { return }
            tokens.append(String(current))
            current = String.UnicodeScalarView()
        }

        for scalar in normalized.unicodeScalars {
            if searchableScalars.contains(scalar) {
                current.append(scalar)
            } else {
                flush()
            }
        }
        flush()
        return tokens
    }

    static func matches(_ text: String, tokens: [String]) -> Bool {
        guard !tokens.isEmpty else { return false }
        let normalized = normalize(text)
        var searchStart = normalized.startIndex
        for token in tokens {
            guard let range = normalized.range(of: token, range: searchStart..<normalized.endIndex) else {
                return false
            }
            searchStart = range.upperBound
        }
        return true
    }

    static func snippet(from text: String, tokens: [String]) -> GlobalMessageSearchSnippet {
        let flat = PeerDisplayText.strippingBidiControls(text)
            .replacingOccurrences(of: "[\\r\\n\\t]+", with: " ", options: .regularExpression)
        guard let first = tokens.first,
            let matchRange = flat.range(
                of: first,
                options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive]
            )
        else {
            return GlobalMessageSearchSnippet(
                leading: boundedPrefix(flat, length: snippetTailLength),
                match: "",
                trailing: ""
            )
        }

        let leadStart =
            flat.index(
                matchRange.lowerBound,
                offsetBy: -snippetLeadLength,
                limitedBy: flat.startIndex
            ) ?? flat.startIndex
        let tailEnd =
            flat.index(
                matchRange.upperBound,
                offsetBy: snippetTailLength,
                limitedBy: flat.endIndex
            ) ?? flat.endIndex
        let visibleMatchEnd =
            flat.index(
                matchRange.lowerBound,
                offsetBy: snippetMatchLength,
                limitedBy: matchRange.upperBound
            ) ?? matchRange.upperBound
        let leadingEllipsis = leadStart == flat.startIndex ? "" : "…"
        let trailingEllipsis = tailEnd == flat.endIndex ? "" : "…"
        let elidedMatch = visibleMatchEnd == matchRange.upperBound ? "" : "…"
        return GlobalMessageSearchSnippet(
            leading: leadingEllipsis + String(flat[leadStart..<matchRange.lowerBound]),
            match: String(flat[matchRange.lowerBound..<visibleMatchEnd]),
            trailing: elidedMatch + String(flat[matchRange.upperBound..<tailEnd]) + trailingEllipsis
        )
    }

    private static func normalize(_ text: String) -> String {
        text.precomposedStringWithCanonicalMapping.lowercased()
    }

    private static func boundedPrefix(_ text: String, length: Int) -> String {
        guard let end = text.index(text.startIndex, offsetBy: length, limitedBy: text.endIndex) else {
            return text
        }
        return String(text[..<end]) + "…"
    }
}

nonisolated enum GlobalMessageSearchEngine {
    static let resultLimit = 50
    static let pageLimit: UInt32 = 200

    private struct Hit {
        let record: TimelineMessageRecordFfi
        let chatTitle: String
    }

    static func search(
        client: any MarmotRuntime,
        accountRef: String,
        localAccountId: String,
        localDisplayName: String,
        scopes: [GlobalMessageSearchScope],
        query: String,
        checkCancellation: @escaping @Sendable () throws -> Void
    ) throws -> [GlobalMessageSearchResult] {
        let tokens = GlobalMessageSearchText.tokens(in: query)
        guard !tokens.isEmpty else { return [] }

        var newestHits: [Hit] = []
        newestHits.reserveCapacity(resultLimit)

        for scope in scopes {
            try checkCancellation()
            var before: UInt64?
            var beforeMessageId: String?

            while true {
                try checkCancellation()
                let page = try client.timelineMessages(
                    accountRef: accountRef,
                    query: TimelineMessageQueryFfi(
                        groupIdHex: scope.groupId,
                        search: nil,
                        before: before,
                        beforeMessageId: beforeMessageId,
                        after: nil,
                        afterMessageId: nil,
                        limit: pageLimit
                    )
                )

                for record in page.messages.reversed() {
                    try checkCancellation()
                    guard record.kind == 9,
                        !record.deleted,
                        record.invalidationStatus == nil,
                        GlobalMessageSearchText.matches(record.plaintext, tokens: tokens)
                    else { continue }
                    retainNewest(Hit(record: record, chatTitle: scope.title), in: &newestHits)
                }

                guard page.hasMoreBefore, let oldest = page.messages.first else { break }
                if newestHits.count == resultLimit,
                    let cutoff = newestHits.last,
                    !isNewer(oldest, than: cutoff.record)
                {
                    break
                }
                let nextBefore = oldest.timelineAt
                let nextBeforeMessageId = oldest.messageIdHex
                guard nextBefore != before || nextBeforeMessageId != beforeMessageId else { break }
                before = nextBefore
                beforeMessageId = nextBeforeMessageId
            }
        }

        try checkCancellation()
        let senderIds = Set(newestHits.map(\.record.sender))
        var senderNames: [String: String] = [
            localAccountId: PeerDisplayText.sanitize(localDisplayName) ?? abbreviated(localAccountId)
        ]
        for senderId in senderIds where senderId != localAccountId {
            try checkCancellation()
            let profile = try? client.userProfile(accountIdHex: senderId)
            senderNames[senderId] =
                firstNonBlank([
                    PeerDisplayText.sanitize(profile?.displayName),
                    PeerDisplayText.sanitize(profile?.name),
                    PeerDisplayText.sanitize(client.displayName(accountIdHex: senderId)),
                ]) ?? abbreviated(senderId)
        }

        return newestHits.map { hit in
            let record = hit.record
            return GlobalMessageSearchResult(
                messageId: record.messageIdHex,
                groupId: record.groupIdHex,
                chatTitle: hit.chatTitle,
                senderName: senderNames[record.sender] ?? abbreviated(record.sender),
                timelineAt: record.timelineAt,
                snippet: GlobalMessageSearchText.snippet(from: record.plaintext, tokens: tokens)
            )
        }
    }

    private static func retainNewest(_ hit: Hit, in hits: inout [Hit]) {
        guard
            !hits.contains(where: {
                $0.record.groupIdHex == hit.record.groupIdHex
                    && $0.record.messageIdHex == hit.record.messageIdHex
            })
        else { return }
        hits.append(hit)
        hits.sort { isNewer($0.record, than: $1.record) }
        if hits.count > resultLimit {
            hits.removeLast(hits.count - resultLimit)
        }
    }

    private static func isNewer(_ lhs: TimelineMessageRecordFfi, than rhs: TimelineMessageRecordFfi) -> Bool {
        if lhs.timelineAt != rhs.timelineAt { return lhs.timelineAt > rhs.timelineAt }
        return lhs.messageIdHex > rhs.messageIdHex
    }

    private static func firstNonBlank(_ values: [String?]) -> String? {
        values.lazy.compactMap { value in
            let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed?.isEmpty == false ? trimmed : nil
        }.first
    }

    private static func abbreviated(_ value: String) -> String {
        guard value.count > 12 else { return value }
        return "\(value.prefix(8))…\(value.suffix(4))"
    }
}

@MainActor
extension WorkspaceState {
    func presentGlobalMessageSearch() {
        guard activeAccount != nil else { return }
        isGlobalMessageSearchPresented = true
        globalMessageSearchError = nil
    }

    func dismissGlobalMessageSearch() {
        isGlobalMessageSearchPresented = false
        invalidateGlobalMessageSearch(clearQuery: true)
    }

    func scheduleGlobalMessageSearch() {
        globalMessageSearchTask?.cancel()
        globalMessageSearchTask = nil
        globalMessageSearchGeneration &+= 1
        let generation = globalMessageSearchGeneration
        globalMessageSearchResults = []
        globalMessageSearchError = nil

        let query = globalMessageSearchQuery
        guard !GlobalMessageSearchText.tokens(in: query).isEmpty else {
            isSearchingAllMessages = false
            return
        }
        guard let client, let account = activeAccount else {
            isSearchingAllMessages = false
            return
        }

        let scopes = activeChats.map { GlobalMessageSearchScope(groupId: $0.id, title: $0.title) }
        let visibleGroupIds = Set(scopes.map(\.groupId))
        isSearchingAllMessages = true
        globalMessageSearchTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(250))
                guard let self else { return }
                let results = try await self.runOffMainCancellable { checkCancellation in
                    try GlobalMessageSearchEngine.search(
                        client: client,
                        accountRef: account.accountRef,
                        localAccountId: account.accountIdHex,
                        localDisplayName: account.displayName,
                        scopes: scopes,
                        query: query,
                        checkCancellation: checkCancellation
                    )
                }
                guard self.globalMessageSearchGeneration == generation,
                    self.activeAccountId == account.id,
                    Set(self.activeChats.map(\.id)) == visibleGroupIds,
                    self.globalMessageSearchQuery == query,
                    self.isGlobalMessageSearchPresented
                else { return }
                self.globalMessageSearchResults = results
                self.isSearchingAllMessages = false
                self.globalMessageSearchTask = nil
            } catch is CancellationError {
                return
            } catch {
                guard let self, self.globalMessageSearchGeneration == generation else { return }
                self.globalMessageSearchError = error.localizedDescription
                self.isSearchingAllMessages = false
                self.globalMessageSearchTask = nil
            }
        }
    }

    func invalidateGlobalMessageSearch(clearQuery: Bool, restartIfPresented: Bool = false) {
        globalMessageSearchTask?.cancel()
        globalMessageSearchTask = nil
        globalMessageSearchGeneration &+= 1
        globalMessageSearchResults = []
        globalMessageSearchError = nil
        isSearchingAllMessages = false
        if clearQuery {
            globalMessageSearchQuery = ""
        } else if restartIfPresented, isGlobalMessageSearchPresented {
            scheduleGlobalMessageSearch()
        }
    }

    func openGlobalMessageSearchResult(_ result: GlobalMessageSearchResult) async {
        guard let account = activeAccount,
            let chat = activeChats.first(where: { $0.id == result.groupId })
        else {
            invalidateGlobalMessageSearch(clearQuery: false, restartIfPresented: true)
            return
        }

        dismissGlobalMessageSearch()
        if selectedChat?.id != chat.id {
            selectChat(chat)
        }
        await loadMessages(groupIdHex: chat.id)

        while activeAccountId == account.id,
            selectedChat?.id == chat.id,
            !selectedTimelineContainsMessage(result.messageId),
            selectedTimelinePaging.hasMoreBefore
        {
            let previousFirstId = selectedMessageIDs.first
            await loadOlderMessages(groupIdHex: chat.id)
            guard selectedMessageIDs.first != previousFirstId else { break }
        }

        guard activeAccountId == account.id, selectedChat?.id == chat.id else { return }
        guard selectedTimelineContainsMessage(result.messageId) else {
            lastError = L10n.string("The selected message is no longer available.")
            return
        }
        pendingMessageNavigation = GlobalMessageNavigationTarget(
            requestId: UUID(),
            groupId: chat.id,
            messageId: result.messageId
        )
    }

    func completePendingMessageNavigation(_ target: GlobalMessageNavigationTarget) {
        guard pendingMessageNavigation == target else { return }
        pendingMessageNavigation = nil
    }
}
