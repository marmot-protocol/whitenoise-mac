//
//  TopNoticeViews.swift
//  whitenoise-mac
//
//  The notices that belong to the window rather than to a screen: they are true
//  wherever the user happens to be, so they hang off the shell's top edge
//  instead of being repeated on each surface.
//
//  The two are shaped by how long each of them is true. Being offline is a standing
//  condition with no dismiss button, so it takes the top edge as a band the shell lays out
//  above everything else — a floating card there would cover the pane title and the
//  conversation header for as long as the network stays down. A background-task failure is
//  transient and dismissible, so it stays a floating card: shifting the whole transcript
//  down and back up for a few seconds costs more than it earns.
//

import SwiftUI

/// "Waiting for internet connection"
///
/// It carries the warning intent's palette and its filled triangle, like the `WnSystemNotice`
/// it is ported from, and like Flutter it is a flush full-width band rather than a card: it is
/// laid out above the shell's content, which is what keeps it off the pane title and the
/// conversation header underneath.
///
/// The band therefore owns the strip the traffic lights float in. That is deliberate — it is the
/// one region no screen draws text into, so taking it costs nothing, and it means the app below
/// shifts by only the few points the band is taller than the clearance it replaces. What the
/// buttons must never do is land on the wording, so the content is centred out of their strip.
struct OfflineNoticeBand: View {
    @Environment(\.locale) private var locale

    var body: some View {
        HStack(spacing: 0) {
            // Equal-weight spacers centre the message while it fits, and the leading minimum
            // slides it right of the traffic lights instead of under them once the window is
            // too narrow for centring to clear them on its own.
            Spacer(minLength: MessagesLayout.windowTrafficLightZoneWidth)

            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.subheadline.weight(.semibold))
                Text(L10n.string("Waiting for internet connection", locale: locale))
                    .font(.subheadline.weight(.semibold))
            }
            // One colour for glyph and title, paired with the background by the intent rather
            // than picked per element — the warning content colour is what
            // `intentionWarningBackground` is drawn to be read against.
            .foregroundStyle(WNColor.intentionWarningContent)

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .frame(
            maxWidth: .infinity,
            minHeight: MessagesLayout.windowTopNoticeBandMinimumHeight
        )
        .background(WNColor.intentionWarningBackground)
        // A hairline, not a stroked rectangle: three of the band's four edges are the window's
        // own, and only the seam with the content below it needs drawing.
        .overlay(alignment: .bottom) {
            WNColor.borderTertiary
                .frame(height: 1)
        }
    }
}

/// Failures from background tasks — subscription listeners, observability refresh,
/// read-marking.
///
/// Surfaced here rather than on the per-screen error view because they are not tied to anything
/// the user just did: on a login or new-chat form they would read as a rejection of the button
/// that was pressed.
struct BackgroundStatusBanner: View {
    @Environment(WorkspaceState.self) private var workspace
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        if let status = workspace.backgroundStatus {
            BackgroundStatusBannerContent(status: status) {
                workspace.clearBackgroundStatus()
            }
            // Hung off the top of the shell's *content*, which the offline band has already
            // pushed down, so the two never draw over one another.
            .padding(.top, 12)
            .transition(reduceMotion ? .opacity : .move(edge: .top).combined(with: .opacity))
            .animation(reduceMotion ? .none : .smooth(duration: 0.2), value: workspace.backgroundStatus)
        }
    }
}

struct BackgroundStatusBannerContent: View {
    let status: String
    let onDismiss: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(WNColor.intentionWarningContent)
                .accessibilityHidden(true)
            Text(status)
                .font(.subheadline)
                .foregroundStyle(.primary)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            .help(L10n.string("Dismiss"))
            .accessibilityLabel(L10n.string("Dismiss"))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(maxWidth: 520)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(WNColor.borderTertiary, lineWidth: 1)
        }
        .shadow(color: WNColor.shadow.opacity(0.08), radius: 8, y: 2)
    }
}

#Preview("Offline notice band") {
    OfflineNoticeBand()
        .frame(width: 600)
}

#Preview("Background status banner") {
    BackgroundStatusBannerContent(
        status: "Couldn’t reach your relays. Check your connection and try again.",
        onDismiss: {}
    )
    .padding()
}
