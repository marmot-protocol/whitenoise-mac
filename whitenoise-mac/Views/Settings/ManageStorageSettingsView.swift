//
//  ManageStorageSettingsView.swift
//  whitenoise-mac
//
//  Settings → Storage → Manage Storage: what retained attachments hold on this Mac for the active
//  profile, largest first, and bulk removal. MDK owns the bytes; this page only reads and asks it
//  to remove. Ported from whitenoise-ios's `ManageStorageView` (whitenoise-ios#1200).
//
//  The drawer has no navigation stack, so the two steps inside this page — every attachment
//  largest first, and one chat's attachments — are this page swapping its own body, left by the
//  chevron `SettingsScaffold` draws, the way Relays opens a relay.
//

import MarmotKit
import SwiftUI

struct ManageStorageSettingsView: View {
    enum Destination: Equatable {
        case overview
        case largestAttachments
        case chat(String)
    }

    let model: ManageStorageViewModel
    let nicknames: ContactNicknames
    @State private var destination = Destination.overview

    var body: some View {
        Group {
            switch destination {
            case .overview:
                ManageStorageOverviewView(
                    model: model,
                    nicknames: nicknames,
                    openLargestAttachments: { destination = .largestAttachments },
                    openChat: { destination = .chat($0) }
                )
            case .largestAttachments:
                ManageStorageLargestAttachmentsView(model: model, nicknames: nicknames) {
                    destination = .overview
                }
            case .chat(let groupIdHex):
                ManageStorageChatView(model: model, nicknames: nicknames, groupIdHex: groupIdHex) {
                    destination = .overview
                }
            }
        }
        .disabled(model.operation != nil)
        .task { await model.load() }
        // Usage has no observer; re-read it while a background move or compaction can still change
        // it on its own.
        .task(id: "\(model.epoch)/\(model.usageRefresh.revision)") {
            guard let delay = model.usageRefresh.nextDelay else { return }
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            await model.refreshUsage()
        }
    }
}

/// The page itself: the figures, the cache, the account-wide removals, and every chat that holds
/// attachments, largest first.
struct ManageStorageOverviewView: View {
    let model: ManageStorageViewModel
    let nicknames: ContactNicknames
    let openLargestAttachments: () -> Void
    let openChat: (String) -> Void
    @State private var pendingRemoval: ManageStoragePresentation.RemovalCutoff?

    var body: some View {
        SettingsScaffold(
            title: L10n.string("Manage Storage"),
            back: SettingsBackDestination(route: .page(.storage), help: "Back to settings")
        ) {
            ManageStorageUsageSection(model: model)
            if let notice = model.usage?.migration {
                ManageStorageMigrationSection(notice: notice)
            }
            ManageStorageCacheSection(model: model)
            SettingsSection(
                title: L10n.string("Free Up Space"),
                footer: L10n.string(
                    "Removed attachments stay in their messages. You can download them again while they're still available."
                )
            ) {
                DetailsDisclosureRow(
                    title: L10n.string("Largest Attachments"),
                    systemImage: "arrow.up.arrow.down",
                    value: "",
                    action: openLargestAttachments
                )
                ManageStorageRemoveOlderMenu(
                    pendingRemoval: $pendingRemoval,
                    inProgress: model.operation == .removeOlder(.account)
                )
                .disabled(model.usage == nil || model.usage?.attachmentCount == 0)
                if model.failedOperation == .removeOlder(.account) {
                    SettingsStatusNote(
                        text: L10n.string("Couldn't remove attachments. Try again."), intention: .failure)
                }
            }
            ManageStorageChatsSection(model: model, nicknames: nicknames, openChat: openChat)
        }
        .manageStorageRemoveOlderConfirmation($pendingRemoval, scope: .account, model: model)
    }
}

private struct ManageStorageUsageSection: View {
    let model: ManageStorageViewModel

    var body: some View {
        SettingsSection(
            title: L10n.string("Storage Used"),
            footer: L10n.string("What this profile keeps on this device. Other profiles are counted separately.")
        ) {
            if let usage = model.usage {
                LabeledContent {
                    ManageStorageByteText(bytes: usage.attachmentBytes)
                } label: {
                    Text(L10n.string("Attachments"))
                    Text(L10n.plural("%lld attachments", usage.attachmentCount))
                }
                LabeledContent(L10n.string("Messages and Chat Data")) {
                    ManageStorageByteText(bytes: usage.chatDataBytes)
                }
                // Stale figures stay visible, but not as if they were current.
                if model.usageRefresh.failed {
                    ManageStorageRetryRow(message: L10n.string("Couldn't load storage usage")) {
                        Task { await model.refreshUsage() }
                    }
                }
            } else if model.usageRefresh.failed {
                ManageStorageRetryRow(message: L10n.string("Couldn't load storage usage")) {
                    Task { await model.load() }
                }
            } else {
                ManageStorageLoadingRow()
            }
        }
    }
}

private struct ManageStorageCacheSection: View {
    let model: ManageStorageViewModel

    var body: some View {
        SettingsSection(
            title: L10n.string("Cache"),
            footer: L10n.string("Pictures download again when you need them.")
        ) {
            LabeledContent(L10n.string("Profile and Group Pictures")) {
                if let usage = model.usage {
                    ManageStorageByteText(bytes: usage.cacheBytes)
                } else {
                    Text(verbatim: "—")
                        .foregroundStyle(WNColor.backgroundContentSecondary)
                }
            }
            Button {
                Task { await model.clearCache() }
            } label: {
                ManageStorageActionLabel(
                    title: L10n.string("Clear Cache"),
                    systemImage: "trash",
                    inProgress: model.operation == .clearCache
                )
            }
            .buttonStyle(.wnSecondary)
            .disabled(model.usage == nil || model.usage?.cacheBytes == 0)
            if model.failedOperation == .clearCache {
                SettingsStatusNote(text: L10n.string("Couldn't clear the cache. Try again."), intention: .failure)
            }
        }
    }
}

private struct ManageStorageChatsSection: View {
    let model: ManageStorageViewModel
    let nicknames: ContactNicknames
    let openChat: (String) -> Void

    var body: some View {
        SettingsSection(
            title: L10n.string("Chats"),
            footer: model.chats.items.isEmpty
                ? nil : L10n.string("An attachment shared in more than one chat counts in each.")
        ) {
            ForEach(model.chats.items, id: \.groupIdHex) { usage in
                Button {
                    openChat(usage.groupIdHex)
                } label: {
                    ManageStorageChatRow(
                        chat: model.chat(for: usage.groupIdHex, nicknames: nicknames),
                        groupIdHex: usage.groupIdHex,
                        usage: usage,
                        showsChevron: true
                    )
                }
                .buttonStyle(.plain)
            }
            if model.chatsFailed {
                ManageStorageRetryRow(message: L10n.string("Couldn't load chats")) {
                    Task { await model.loadMoreChats() }
                }
            } else if model.chats.hasMore {
                ManageStorageLoadingRow()
                    .task(id: "\(model.epoch)/\(model.chats.pageCount)") {
                        await model.loadMoreChats()
                    }
            } else if model.chats.items.isEmpty {
                Text(L10n.string("No downloaded attachments"))
                    .foregroundStyle(WNColor.backgroundContentSecondary)
            }
        }
    }
}

/// Every retained attachment for this profile, largest first.
struct ManageStorageLargestAttachmentsView: View {
    let model: ManageStorageViewModel
    let nicknames: ContactNicknames
    let onBack: () -> Void

    var body: some View {
        SettingsScaffold(title: L10n.string("Largest Attachments"), back: .dismissing(onBack)) {
            ManageStorageAttachmentsSection(model: model, nicknames: nicknames, scope: .account)
        }
    }
}

/// One chat's attachments, largest first, with bulk removal for that chat.
struct ManageStorageChatView: View {
    let model: ManageStorageViewModel
    let nicknames: ContactNicknames
    let groupIdHex: String
    let onBack: () -> Void
    @State private var pendingRemoval: ManageStoragePresentation.RemovalCutoff?
    @State private var confirmsRemoveAll = false

    var body: some View {
        let chat = model.chat(for: groupIdHex, nicknames: nicknames)
        let title = chat?.title ?? L10n.string("Conversation unavailable")
        let scope = ManageStorageViewModel.Scope.chat(groupIdHex)
        SettingsScaffold(title: title, back: .dismissing(onBack)) {
            if let usage = model.chatUsage(groupIdHex) {
                SettingsSection {
                    ManageStorageChatRow(chat: chat, groupIdHex: groupIdHex, usage: usage, showsChevron: false)
                }
            }
            SettingsSection(
                footer: L10n.string(
                    "Removed attachments stay in their messages. You can download them again while they're still available."
                )
            ) {
                // Outline, not red, like Storage's Clear Cache: the system confirmation it opens is
                // the step drawn as destructive.
                Button {
                    confirmsRemoveAll = true
                } label: {
                    ManageStorageActionLabel(
                        title: L10n.string("Remove All Attachments"),
                        systemImage: "trash",
                        inProgress: model.operation == .removeChat(groupIdHex)
                    )
                }
                .buttonStyle(.wnSecondary)
                ManageStorageRemoveOlderMenu(
                    pendingRemoval: $pendingRemoval,
                    inProgress: model.operation == .removeOlder(scope)
                )
                if model.failedOperation == .removeChat(groupIdHex) || model.failedOperation == .removeOlder(scope) {
                    SettingsStatusNote(
                        text: L10n.string("Couldn't remove attachments. Try again."), intention: .failure)
                }
            }
            ManageStorageAttachmentsSection(model: model, nicknames: nicknames, scope: scope)
        }
        .confirmationDialog(
            String(format: L10n.string("Remove all attachments in “%@”?"), PeerDisplayText.templateFragment(title)),
            isPresented: $confirmsRemoveAll,
            titleVisibility: .visible
        ) {
            Button(L10n.string("Remove All Attachments"), role: .destructive) {
                Task { await model.removeAllAttachments(inChat: groupIdHex) }
            }
            Button(L10n.string("Cancel"), role: .cancel) {}
        } message: {
            Text(
                L10n.string(
                    "Every downloaded attachment in this chat is removed from this device. Messages stay, and you can download attachments again while they're still available."
                ))
        }
        .manageStorageRemoveOlderConfirmation($pendingRemoval, scope: scope, model: model)
    }
}

private struct ManageStorageAttachmentsSection: View {
    let model: ManageStorageViewModel
    let nicknames: ContactNicknames
    let scope: ManageStorageViewModel.Scope

    var body: some View {
        let pages = model.attachmentPages(scope)
        SettingsSection(title: L10n.string("Largest First")) {
            ForEach(pages.items, id: \.self) { attachment in
                let id = ManageStoragePresentation.attachmentID(attachment)
                ManageStorageAttachmentRow(
                    attachment: attachment,
                    chatTitle: scope == .account
                        ? model.chat(for: attachment.groupIdHex, nicknames: nicknames)?.title
                            ?? L10n.string("Conversation unavailable")
                        : nil,
                    inProgress: model.operation == .removeAttachment(id),
                    failed: model.failedOperation == .removeAttachment(id)
                ) {
                    Task { await model.remove(attachment) }
                }
            }
            if model.attachmentsFailed.contains(scope) {
                ManageStorageRetryRow(message: L10n.string("Couldn't load attachments")) {
                    Task { await model.loadMoreAttachments(scope) }
                }
            } else if pages.hasMore {
                ManageStorageLoadingRow()
                    .task(id: "\(model.epoch)/\(pages.pageCount)") {
                        await model.loadMoreAttachments(scope)
                    }
            } else if pages.items.isEmpty {
                Text(L10n.string("No downloaded attachments"))
                    .foregroundStyle(WNColor.backgroundContentSecondary)
            }
        }
    }
}

struct ManageStorageMigrationSection: View {
    let notice: ManageStoragePresentation.MigrationNotice

    var body: some View {
        switch notice {
        case .moving(let remaining):
            SettingsSection(
                footer: L10n.string(
                    "Older attachments are moving out of the chat database in the background. Nothing is deleted.")
            ) {
                LabeledContent {
                    Text(String(format: L10n.string("%@ remaining"), ManageStoragePresentation.byteText(remaining)))
                        .foregroundStyle(WNColor.backgroundContentSecondary)
                } label: {
                    Label(L10n.string("Updating Attachment Storage"), systemImage: "arrow.triangle.2.circlepath")
                }
            }
        case .paused(let needed):
            SettingsSection(
                footer: L10n.string(
                    "Free up space on this device, or remove attachments below, to continue. Nothing is deleted automatically."
                )
            ) {
                LabeledContent {
                    Text(String(format: L10n.string("Needs %@ free"), ManageStoragePresentation.byteText(needed)))
                        .foregroundStyle(WNColor.backgroundContentSecondary)
                } label: {
                    Label(L10n.string("Attachment Storage Update Paused"), systemImage: "pause.circle")
                }
            }
        case .compacting:
            SettingsSection(
                footer: L10n.string("Returning freed space to your device. Chats may pause for a moment.")
            ) {
                LabeledContent {
                    ProgressView()
                        .controlSize(.small)
                } label: {
                    Label(L10n.string("Reclaiming Space"), systemImage: "arrow.down.right.and.arrow.up.left")
                }
            }
        }
    }
}

/// A chat named and drawn the way the sidebar draws it, with what its attachments add up to.
struct ManageStorageChatRow: View {
    let chat: ChatItem?
    let groupIdHex: String
    let usage: ChatAttachmentUsageFfi
    let showsChevron: Bool

    var body: some View {
        let title = chat?.title ?? L10n.string("Conversation unavailable")
        // Pending invitations keep avatar egress suppressed.
        let showsPicture = chat.map { !$0.pendingConfirmation } ?? false
        HStack(spacing: 10) {
            ProfileImageAvatarView(
                seed: chat?.avatarSeed ?? groupIdHex,
                initials: title,
                sanitizedPictureURL: showsPicture ? chat?.sanitizedPictureURL : nil,
                localImagePayload: showsPicture ? chat?.groupImagePayload : nil,
                size: 28,
                isSelected: false
            )
            .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .lineLimit(1)
                Text(L10n.plural("%lld attachments", usage.attachmentCount))
                    .wnFont(.medium10)
                    .foregroundStyle(WNColor.backgroundContentSecondary)
            }
            Spacer(minLength: 8)
            ManageStorageByteText(bytes: usage.bytes)
            if showsChevron {
                Image(systemName: "chevron.right")
                    .wnFont(.semiBold10)
                    .foregroundStyle(WNColor.backgroundContentTertiary)
            }
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

struct ManageStorageAttachmentRow: View {
    let attachment: RetainedAttachmentSummaryFfi
    let chatTitle: String?
    let inProgress: Bool
    let failed: Bool
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: ManageStoragePresentation.attachmentKind(attachment).systemImageName)
                .wnFont(.semiBold14)
                .foregroundStyle(WNColor.backgroundContentSecondary)
                .frame(width: 28, height: 28)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(ManageStoragePresentation.attachmentTitle(attachment))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(ManageStoragePresentation.attachmentSubtitle(attachment, chatTitle: chatTitle))
                    .wnFont(.medium10)
                    .foregroundStyle(WNColor.backgroundContentSecondary)
                    .lineLimit(1)
                if failed {
                    Text(L10n.string("Couldn't remove this attachment. Try again."))
                        .wnFont(.medium10)
                        .foregroundStyle(WNColor.backgroundContentDestructive)
                }
            }
            Spacer(minLength: 8)
            if inProgress {
                ProgressView()
                    .controlSize(.small)
            } else {
                ManageStorageByteText(bytes: attachment.byteCount)
            }
            Button(action: onRemove) {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .help(L10n.string("Remove"))
            .accessibilityLabel(Text(L10n.string("Remove")))
        }
        .accessibilityElement(children: .combine)
        .accessibilityAction(named: Text(L10n.string("Remove")), onRemove)
        .contextMenu {
            Button(L10n.string("Remove"), systemImage: "trash", role: .destructive, action: onRemove)
        }
    }
}

struct ManageStorageRemoveOlderMenu: View {
    @Binding var pendingRemoval: ManageStoragePresentation.RemovalCutoff?
    let inProgress: Bool

    var body: some View {
        Menu {
            ForEach(ManageStoragePresentation.RemovalAge.allCases, id: \.self) { age in
                Button(age.title) {
                    pendingRemoval = ManageStoragePresentation.RemovalCutoff(age: age, now: Date(), calendar: .current)
                }
            }
        } label: {
            ManageStorageActionLabel(
                title: L10n.string("Remove Older Attachments"),
                systemImage: "calendar.badge.minus",
                inProgress: inProgress
            )
        }
        .fixedSize()
    }
}

/// Keeps progress inside the control that started it, without changing its size.
struct ManageStorageActionLabel: View {
    let title: String
    let systemImage: String
    let inProgress: Bool

    var body: some View {
        HStack(spacing: 8) {
            if inProgress {
                ProgressView()
                    .controlSize(.small)
            }
            Label(title, systemImage: systemImage)
        }
    }
}

struct ManageStorageByteText: View {
    let bytes: UInt64

    var body: some View {
        Text(ManageStoragePresentation.byteText(bytes))
            .monospacedDigit()
            .foregroundStyle(WNColor.backgroundContentSecondary)
    }
}

struct ManageStorageLoadingRow: View {
    var body: some View {
        HStack {
            Spacer()
            ProgressView()
                .controlSize(.small)
            Spacer()
        }
        .accessibilityLabel(Text(L10n.string("Loading…")))
    }
}

struct ManageStorageRetryRow: View {
    let message: String
    let retry: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            SettingsStatusNote(text: message, intention: .failure)
            Button(L10n.string("Try Again"), action: retry)
                .buttonStyle(.wnSecondary)
        }
    }
}

extension View {
    fileprivate func manageStorageRemoveOlderConfirmation(
        _ cutoff: Binding<ManageStoragePresentation.RemovalCutoff?>,
        scope: ManageStorageViewModel.Scope,
        model: ManageStorageViewModel
    ) -> some View {
        modifier(ManageStorageRemoveOlderConfirmation(cutoff: cutoff, scope: scope, model: model))
    }
}

private struct ManageStorageRemoveOlderConfirmation: ViewModifier {
    @Binding var cutoff: ManageStoragePresentation.RemovalCutoff?
    let scope: ManageStorageViewModel.Scope
    let model: ManageStorageViewModel

    func body(content: Content) -> some View {
        content.confirmationDialog(
            L10n.string("Remove Older Attachments?"),
            isPresented: Binding(get: { cutoff != nil }, set: { if !$0 { cutoff = nil } }),
            titleVisibility: .visible,
            presenting: cutoff
        ) { cutoff in
            Button(L10n.string("Remove Attachments"), role: .destructive) {
                Task { await model.removeOlder(than: cutoff, in: scope) }
            }
            Button(L10n.string("Cancel"), role: .cancel) {}
        } message: { cutoff in
            Text(Self.message(for: cutoff, scope: scope))
        }
    }

    static func message(
        for cutoff: ManageStoragePresentation.RemovalCutoff, scope: ManageStorageViewModel.Scope
    ) -> String {
        let day = cutoff.text()
        let format =
            scope == .account
            ? L10n.string(
                "Attachments received before %@ are removed from this device in every chat. Messages stay, and you can download attachments again while they're still available."
            )
            : L10n.string(
                "Attachments in this chat received before %@ are removed from this device. Messages stay, and you can download attachments again while they're still available."
            )
        return String(format: format, day)
    }
}

#if DEBUG
    private enum ManageStoragePreviewData {
        static let mebibyte: UInt64 = 1_048_576

        static var attachments: [RetainedAttachmentSummaryFfi] {
            let now = UInt64(Date().timeIntervalSince1970)
            return [
                RetainedAttachmentSummaryFfi(
                    groupIdHex: "a1",
                    target: AttachmentLocalTargetFfi(messageIdHex: "m1", sourceMessageIdHex: "m1", attachmentIndex: 0),
                    byteCount: 182 * mebibyte, mediaType: "video/mp4", fileName: "Trailhead.mov",
                    receivedAt: now - 3_600),
                RetainedAttachmentSummaryFfi(
                    groupIdHex: "b2",
                    target: AttachmentLocalTargetFfi(messageIdHex: "m2", sourceMessageIdHex: "m2", attachmentIndex: 0),
                    byteCount: 24 * mebibyte, mediaType: "application/pdf", fileName: "Itinerary.pdf",
                    receivedAt: now - 9 * 86_400),
                RetainedAttachmentSummaryFfi(
                    groupIdHex: "a1",
                    target: AttachmentLocalTargetFfi(messageIdHex: "m3", sourceMessageIdHex: "m3", attachmentIndex: 1),
                    byteCount: 3 * mebibyte, mediaType: "image/jpeg", fileName: "", receivedAt: now - 40 * 86_400),
            ]
        }

        static func model(migration: AttachmentMigrationStateFfi = .paused) -> ManageStorageViewModel {
            ManageStorageViewModel.fixture(
                usage: AttachmentStorageUsageFfi(
                    mediaBytes: 209 * mebibyte, legacyBytes: 0, attachmentCount: 3,
                    databaseBytes: 18 * mebibyte, databaseFreeBytes: 0,
                    migration: migration, migrationBytes: 640 * mebibyte, cacheBytes: 6 * mebibyte),
                chats: [
                    ChatAttachmentUsageFfi(groupIdHex: "a1", bytes: 185 * mebibyte, attachmentCount: 2),
                    ChatAttachmentUsageFfi(groupIdHex: "b2", bytes: 24 * mebibyte, attachmentCount: 1),
                ],
                attachments: attachments
            )
        }
    }

    #Preview("Manage Storage") {
        ManageStorageSettingsView(model: ManageStoragePreviewData.model(), nicknames: .none)
            .environment(WorkspaceState.preview())
            .frame(width: 760, height: 820)
    }

    #Preview("Largest Attachments") {
        ManageStorageLargestAttachmentsView(model: ManageStoragePreviewData.model(), nicknames: .none) {}
            .environment(WorkspaceState.preview())
            .frame(width: 760, height: 520)
    }

    #Preview("One chat") {
        ManageStorageChatView(model: ManageStoragePreviewData.model(), nicknames: .none, groupIdHex: "a1") {}
            .environment(WorkspaceState.preview())
            .frame(width: 760, height: 620)
    }

    #Preview("Overview") {
        ManageStorageOverviewView(
            model: ManageStoragePreviewData.model(migration: .running), nicknames: .none,
            openLargestAttachments: {}, openChat: { _ in }
        )
        .environment(WorkspaceState.preview())
        .frame(width: 760, height: 820)
    }

    #Preview("Migration states") {
        Form {
            ManageStorageMigrationSection(notice: .moving(remainingBytes: 640 * ManageStoragePreviewData.mebibyte))
            ManageStorageMigrationSection(notice: .paused(neededBytes: 2 * ManageStoragePreviewData.mebibyte))
            ManageStorageMigrationSection(notice: .compacting)
        }
        .formStyle(.grouped)
        .frame(width: 560, height: 420)
    }

    #Preview("Rows") {
        Form {
            ManageStorageChatRow(
                chat: nil, groupIdHex: "a1",
                usage: ChatAttachmentUsageFfi(
                    groupIdHex: "a1", bytes: 185 * ManageStoragePreviewData.mebibyte, attachmentCount: 2),
                showsChevron: true)
            ManageStorageAttachmentRow(
                attachment: ManageStoragePreviewData.attachments[0], chatTitle: "Weekend Hike",
                inProgress: false, failed: true, onRemove: {})
            ManageStorageRemoveOlderMenu(pendingRemoval: .constant(nil), inProgress: true)
            ManageStorageActionLabel(title: "Clear Cache", systemImage: "trash", inProgress: false)
            ManageStorageByteText(bytes: 1_234_567)
            ManageStorageLoadingRow()
            ManageStorageRetryRow(message: "Couldn't load chats") {}
        }
        .formStyle(.grouped)
        .frame(width: 560, height: 420)
    }
#endif
