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
    @State private var timestampReferenceDate = Date()

    var body: some View {
        @Bindable var workspace = workspace

        MessengerShellView()
            // Attached here, not on the conversation pane: a chat-list delete is most likely with
            // no chat selected, and the sidebar row menu cannot host its own dialog.
            .chatDestructiveActionsConfirmation()
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
                    await workspace.handleConversationVisibilityChange()
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
                Task { await workspace.handleConversationVisibilityChange() }
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
                HelpImproveWhiteNoiseSheet()
                    .environment(workspace)
                    .environment(\.locale, workspace.preferredLocale)
            }
            .onReceive(
                NotificationCenter.default.publisher(
                    for: NSWindow.didDeminiaturizeNotification
                )
            ) { _ in
                Task { await workspace.handleConversationVisibilityChange() }
            }
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
