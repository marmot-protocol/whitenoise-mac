//
//  ContentView.swift
//  whitenoise-mac
//
//  Created by Jeff Gardner on 26/05/2026.
//

import AppKit
import SwiftUI

private struct TimestampReferenceDateKey: EnvironmentKey {
    static let defaultValue = Date()
}

extension EnvironmentValues {
    var timestampReferenceDate: Date {
        get { self[TimestampReferenceDateKey.self] }
        set { self[TimestampReferenceDateKey.self] = newValue }
    }
}

struct ContentView: View {
    @Environment(WorkspaceState.self) private var workspace
    @Environment(SessionState.self) private var session
    @State private var timestampReferenceDate = Date()

    var body: some View {
        @Bindable var workspace = workspace

        MessengerShellView()
            // Attached here, not on the conversation pane: a chat-list delete is most likely with
            // no chat selected, and the sidebar row menu cannot host its own dialog.
            .chatDestructiveActionsConfirmation()
            // Group changes made from the panes ask here. Sheets that make one host their own.
            .groupChangeAdvisoryAlert(session.accountScope?.groupChangeAdvisory)
            // A device-link request can arrive whatever the user is looking at, and wants an answer
            // while both screens show the code.
            .deviceLinkSheet(
                session.accountScope?.deviceLinking,
                locale: workspace.preferredLocale,
                suggestionAllowed: session.accountScope.map {
                    $0.onboarding.canEnterChats && $0.onboarding.hasShownIncompleteSetup
                } == true
            )
            .deviceUnlinkAlert(
                session.deviceUnlinks,
                accountName: { account(forUnlinked: $0)?.displayName },
                onRemove: { notice in
                    Task {
                        await session.deviceUnlinks.finishLeaving(notice.accountIdHex)
                        let removal = await AccountExit.removeUnlinkedAccount(
                            accountIdHex: notice.accountIdHex, in: workspace)
                        // Didn't go: the notice comes back, so Delete Everything can be tried again.
                        // Otherwise it went, and the report says if anything was left undone.
                        if let account = removal.leftBehind {
                            session.deviceUnlinks.present(account)
                        } else {
                            session.reportWipe(removal.outcome)
                        }
                    }
                },
                onLater: { notice in
                    // The app left the account when the event arrived; this only retries that if it
                    // failed then.
                    if let account = account(forUnlinked: notice), !account.signedOut {
                        Task {
                            await AccountExit.leaveSignedOutAccount(accountIdHex: notice.accountIdHex, in: workspace)
                        }
                    }
                }
            )
            .accountWipeReportAlert(session)
            .profileLinkRequestAlert(session.linkRequests) { request in
                reviewLinkRequest(request)
            }
            .task(
                id: LinkRequestsObserveKey(
                    runtime: runtimeIdentity, signedIn: workspace.signedInAccounts.map(\.accountIdHex))
            ) {
                guard let client = workspace.client else { return }
                await session.linkRequests.observe(client, accounts: { workspace.signedInAccounts })
            }
            // Also re-run once an alert closes, so a second profile's request gets its turn.
            .task(
                id: LinkRequestAlertKey(
                    pending: session.linkRequests.pending, active: workspace.activeAccountId,
                    showing: session.linkRequests.alert != nil)
            ) {
                session.linkRequests.presentIfNeeded(
                    activeAccountIdHex: workspace.activeAccount?.accountIdHex, accounts: workspace.signedInAccounts)
            }
            .task(id: runtimeIdentity) {
                guard let client = workspace.client else { return }
                await session.deviceUnlinks.observe(client) { accountIdHex in
                    // MDK already signed it out: leave it now, as Sign Out does, so the removed
                    // profile's chats stop showing while the notice waits for an answer.
                    await AccountExit.leaveSignedOutAccount(accountIdHex: accountIdHex, in: workspace)
                }
            }
            // A profile unlinked in an earlier launch (or left with Later) is still here, signed out
            // and shown nowhere else, so its notice comes back once a launch.
            .task(id: workspace.accounts.filter(\.unlinked).map(\.accountIdHex)) {
                session.deviceUnlinks.remind(about: workspace.accounts)
            }
            // App-wide default: static text is selectable, so anything on screen — a startup
            // failure message, a relay URL, an npub, a profile field — can be selected and
            // copied without the view having to opt in. `.textSelection` propagates through the
            // environment, so this single application covers every descendant.
            //
            // The one deliberate exception is the chat transcript, which re-disables it and
            // re-enables per bubble on hover; see ConversationView (whitenoise-mac#205).
            .textSelection(.enabled)
            .frame(minWidth: 940, minHeight: 620)
            .preferredColorScheme(workspace.preferredColorScheme)
            .environment(\.locale, workspace.preferredLocale)
            .environment(\.timestampReferenceDate, timestampReferenceDate)
            // End Group runs in a per-group model, outside `hasInFlightGroupCommit`; surfaces that
            // start a group commit read this to hold off until it is done.
            .environment(\.endingGroupIds, session.accountScope?.endingGroupIds ?? [])
            // A bulk leave from the chat list publishes one commit per chat; the same surfaces wait
            // it out.
            .environment(\.isBulkLeavingChats, session.accountScope?.chatListSelection.isLeaving == true)
            .environment(
                \.openURL,
                OpenURLAction { url in
                    workspace.handleMessageLinkOpen(url)
                }
            )
            // The app-wide tint is `fillPrimary`, the primary action's fill on every White Noise
            // client: near-black in light appearance, white in dark. It is deliberately not a hue —
            // the palette's only blue is `intentionInfoContent`, reserved for links and search
            // hits, and the twelve accent sets are reserved for identifying people.
            .tint(WNColor.fillPrimary)
            // The default foreground for anything that does not name a color: text and glyphs that
            // inherit rather than choose. Without this they fall back to AppKit's `labelColor`,
            // which is close to `backgroundContentPrimary` but is not part of the palette — so an
            // unstyled glyph on a `fillSecondary` control would be right only by coincidence.
            // `fillContentSecondary` happens to be the same value, which is why those controls read
            // correctly by inheritance.
            .foregroundStyle(WNColor.backgroundContentPrimary)
            .nativeWindowGlassBackground()
            .onOpenURL { url in
                workspace.handleDeepLinkURL(url)
            }
            .onAppear {
                applyAppearance(workspace.appearancePreference)
            }
            .onChange(of: workspace.appearancePreference) { _, preference in
                applyAppearance(preference)
            }
            .onChange(of: workspace.languagePreference) { _, _ in
                workspace.refreshTimelineDisplayItems(
                    referenceDate: timestampReferenceDate,
                    locale: workspace.preferredLocale
                )
            }
            .onReceive(
                NotificationCenter.default.publisher(
                    for: NSLocale.currentLocaleDidChangeNotification
                )
            ) { _ in
                workspace.refreshSystemLanguageIfNeeded()
                workspace.refreshTimelineDisplayItems(
                    referenceDate: timestampReferenceDate,
                    locale: workspace.preferredLocale
                )
            }
            .onReceive(
                NotificationCenter.default.publisher(for: .NSCalendarDayChanged)
            ) { _ in
                refreshTimestampReferenceDate(now: Date())
            }
            .onReceive(
                NotificationCenter.default.publisher(
                    for: NSApplication.didBecomeActiveNotification
                )
            ) { _ in
                let foregroundStartedAt = DispatchTime.now().uptimeNanoseconds
                refreshTimestampReferenceDateIfNeeded()
                workspace.refreshSystemLanguageIfNeeded()
                // The app just regained focus. Flush any read-marking that was deferred
                // while it was in the background so the selected chat clears its unread
                // state now that the user may be looking at it again.
                Task {
                    await workspace.handleConversationVisibilityChange(visibleMessageIds: visibleConversationMessageIds)
                    workspace.recordForegroundLocalReady(since: foregroundStartedAt)
                    await workspace.refreshAccountProfiles()
                }
            }
            .onReceive(
                NotificationCenter.default.publisher(
                    for: NSApplication.willTerminateNotification
                )
            ) { _ in
                workspace.flushComposerDraftPersistenceSynchronouslyForTermination()
            }
            .onReceive(
                NotificationCenter.default.publisher(
                    for: NSWindow.didBecomeKeyNotification
                )
            ) { _ in
                Task {
                    await workspace.handleConversationVisibilityChange(visibleMessageIds: visibleConversationMessageIds)
                }
            }
            .sheet(isPresented: $workspace.isGlobalMessageSearchPresented) {
                GlobalMessageSearchView()
                    .environment(workspace)
                    .environment(\.locale, workspace.preferredLocale)
            }
            // Presented here rather than from the messenger shell for the same reason as the
            // search sheet: `\.locale` is injected at this root, and a sheet is a separate
            // presentation that does not inherit it, so both have to re-inject it themselves.
            .sheet(isPresented: $workspace.isImprovementsPromptPresented) {
                if let model = session.accountScope?.settingsModel.diagnostics {
                    HelpImproveWhiteNoiseSheet(model: model) {
                        workspace.dismissImprovementsPrompt()
                    }
                    .environment(\.locale, workspace.preferredLocale)
                }
            }
            .onReceive(
                NotificationCenter.default.publisher(
                    for: NSWindow.didDeminiaturizeNotification
                )
            ) { _ in
                Task {
                    await workspace.handleConversationVisibilityChange(visibleMessageIds: visibleConversationMessageIds)
                }
            }
    }

    /// The open transcript's on-screen messages, so regaining focus marks only what the user can
    /// see. Nil without a projected conversation, which keeps the legacy path marking the latest.
    private var visibleConversationMessageIds: Set<String>? {
        session.accountScope?.selectedConversationModel?.readableMessageIds
    }

    /// Review on another profile's link request: switch to it. Its own `DeviceLinkingViewModel`
    /// reads the request and presents it, so comparing and linking run as that profile.
    private func reviewLinkRequest(_ request: ProfileLinkRequestsMonitor.Request) {
        guard
            let account = workspace.signedInAccounts.first(where: {
                $0.accountIdHex.lowercased() == request.accountIdHex
            })
        else { return }
        workspace.selectAccount(account)
    }

    /// Which runtime is installed. Delete All Local Data replaces the runtime at the same storage
    /// root, so the root path alone would leave the monitors on the old one.
    private var runtimeIdentity: ObjectIdentifier? {
        workspace.client.map { ObjectIdentifier($0 as AnyObject) }
    }

    private func account(forUnlinked notice: DeviceUnlinkMonitor.Notice) -> AccountItem? {
        workspace.accounts.first { $0.accountIdHex.lowercased() == notice.accountIdHex }
    }

    private func applyAppearance(_ preference: AppearancePreference) {
        NativeAppearanceController.apply(preference)
    }

    private func refreshTimestampReferenceDateIfNeeded(now: Date = Date()) {
        guard !Calendar.autoupdatingCurrent.isDate(timestampReferenceDate, inSameDayAs: now) else { return }
        refreshTimestampReferenceDate(now: now)
    }

    private func refreshTimestampReferenceDate(now: Date) {
        timestampReferenceDate = now
        workspace.refreshTimelineDisplayItems(referenceDate: now, locale: workspace.preferredLocale)
    }
}

#Preview {
    ContentView()
        .environment(WorkspaceState.preview())
}

/// Re-checks whether another profile's link request should raise the alert: when requests change
/// or the active profile does (its own requests are its model's).
private struct LinkRequestAlertKey: Equatable {
    let pending: [String: [String]]
    let active: String?
    let showing: Bool
}

private struct LinkRequestsObserveKey: Equatable {
    let runtime: ObjectIdentifier?
    let signedIn: [String]
}
