//
//  WindowTopNoticeLayoutTests.swift
//  whitenoise-macTests
//
//  Guards on where the window-level offline notice sits.
//
//  The bug these exist to catch: the notice shipped as a card floating on the shell's top
//  edge, so with the sidebar open it covered the pane title and the conversation header for
//  as long as the network stayed down. Being offline is a standing condition, so the notice
//  is laid out above the content instead — and the two numbers that make that safe are the
//  traffic-light measurements below.
//

import CoreGraphics
import Foundation
import Testing

@testable import whitenoise_mac

@Suite(.serialized)
struct WindowTopNoticeLayoutTests {
    /// Measured with `standardWindowButton` on a `.fullSizeContentView` window: the buttons run
    /// from 9pt to 23pt below the window's top edge, and from 9pt to 69pt in from its leading
    /// edge. The band takes that strip, so it has to cover them rather than be crossed by them.
    private let trafficLightBottomEdge: CGFloat = 23
    private let trafficLightTrailingEdge: CGFloat = 69

    @MainActor
    @Test func noticeBandCoversTheTrafficLightStripItTakesOver() {
        #expect(MessagesLayout.windowTopNoticeBandMinimumHeight > trafficLightBottomEdge)
        // And the wording is held out of the buttons' own column, so a window too narrow for
        // centring to clear them slides the text right instead of putting it underneath.
        #expect(MessagesLayout.windowTrafficLightZoneWidth > trafficLightTrailingEdge)
    }

    @MainActor
    @Test func headersDropTheirTitlebarClearanceUnderTheNoticeBand() {
        // Without the band, a header on the window's top edge pads itself past the buttons.
        #expect(
            MessagesLayout.sidebarTitlebarPadding(hasWindowTopNoticeBand: false)
                == MessagesLayout.sidebarTitlebarTopPadding
        )
        #expect(MessagesLayout.sidebarTitlebarTopPadding > trafficLightBottomEdge)

        // With it, the band already holds them, and keeping the full clearance would open a
        // hole between the band and the pane title.
        #expect(
            MessagesLayout.sidebarTitlebarPadding(hasWindowTopNoticeBand: true)
                == MessagesLayout.sidebarTitlebarPaddingBelowNoticeBand
        )
        #expect(
            MessagesLayout.sidebarTitlebarPaddingBelowNoticeBand
                < MessagesLayout.sidebarTitlebarTopPadding
        )
    }

    @Test func shellLaysTheOfflineNoticeAboveItsContentRatherThanOverIt() throws {
        // The regression is a layout relationship between private SwiftUI views, which only a
        // source contract can hold: the notice must be a sibling the shell stacks above its
        // content. Hanging it back off the top edge as an overlay is what put it on the title.
        let shellSource = try String(
            contentsOf:
                URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("whitenoise-mac")
                .appendingPathComponent("Views")
                .appendingPathComponent("MessengerShellView.swift"),
            encoding: .utf8
        )

        let bodyStart = try #require(
            shellSource.range(of: "struct MessengerShellView: View {")?.upperBound
        )
        let rest = shellSource[bodyStart...]
        let bodyEnd = try #require(rest.range(of: "\nprivate struct ")?.lowerBound)
        let body = String(shellSource[bodyStart..<bodyEnd])

        let bandIndex = try #require(body.range(of: "OfflineNoticeBand()")?.lowerBound)
        let stackIndex = try #require(body.range(of: "VStack(spacing: 0) {")?.lowerBound)
        #expect(stackIndex < bandIndex, "the notice must be stacked above the content")
        // Whitespace-normalized so the assertion pins the relationship rather than an
        // indentation level.
        let normalized = body.components(separatedBy: .whitespacesAndNewlines).joined()
        #expect(!normalized.contains(".overlay(alignment:.top){OfflineNoticeBand()"))

        // And the headers it pushes down have to be told the strip is taken, or they keep
        // padding past traffic lights that are now inside the band.
        #expect(body.contains(".environment(\\.hasWindowTopNoticeBand, workspace.isOffline)"))
    }
}
