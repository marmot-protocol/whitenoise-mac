//
//  WindowTitlebarClearance.swift
//  whitenoise-mac
//
//  Who owns the strip of window behind the traffic lights.
//
//  In a `.hiddenTitleBar` window the buttons float over the content, so every header that starts
//  at the window's top edge pads itself past them. A window-level notice band (see
//  `TopNoticeViews`) changes that: the band takes the strip, the buttons sit inside the band, and
//  the headers it pushes down must drop the clearance or they leave a hole under it.
//
//  The band is a sibling in the shell's stack, so it cannot lay the headers out directly — it
//  announces itself through the environment instead, and each header asks for its padding rather
//  than hard-coding one of the two values.
//

import SwiftUI

private struct WindowTopNoticeBandKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// Whether a window-level notice band currently holds the window's top edge — and with it the
    /// traffic lights.
    var hasWindowTopNoticeBand: Bool {
        get { self[WindowTopNoticeBandKey.self] }
        set { self[WindowTopNoticeBandKey.self] = newValue }
    }
}

extension View {
    /// Pads a header that starts at the window's top edge clear of the traffic lights, or clear of
    /// the notice band that has taken their strip.
    func sidebarTitlebarClearance() -> some View {
        modifier(SidebarTitlebarClearance())
    }
}

private struct SidebarTitlebarClearance: ViewModifier {
    @Environment(\.hasWindowTopNoticeBand) private var hasWindowTopNoticeBand

    func body(content: Content) -> some View {
        content.padding(
            .top,
            MessagesLayout.sidebarTitlebarPadding(hasWindowTopNoticeBand: hasWindowTopNoticeBand)
        )
    }
}
