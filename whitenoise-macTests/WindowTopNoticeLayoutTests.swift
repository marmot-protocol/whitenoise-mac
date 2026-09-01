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

    /// The notice is laid out *above* the content, and the two numbers that make that safe hold
    /// together.
    ///
    /// The bug this exists to catch: the notice shipped as a card floating on the shell's top edge,
    /// so with the sidebar open it covered the pane title and the conversation header for as long
    /// as the network stayed down. Being offline is a standing condition, so the band takes the
    /// strip and the headers below it drop the clearance they no longer need — and what makes that
    /// safe is that the band alone still clears the traffic lights, with the header starting below
    /// them rather than under them.
    @MainActor
    @Test func theNoticeBandTakesTheTitlebarStripAndStillClearsTheTrafficLights() {
        let bandHeight = MessagesLayout.windowTopNoticeBandMinimumHeight
        let paddingUnderBand = MessagesLayout.sidebarTitlebarPaddingBelowNoticeBand

        // The band covers the buttons on its own — it is not merely part of a total that does.
        #expect(bandHeight > trafficLightBottomEdge)

        // A header drawn under the band starts below the traffic lights, which is the whole reason
        // it is allowed to drop its own clearance. Were the notice hung back off the top edge as an
        // overlay, this sum would be the header's distance from the window top and the band would
        // be sitting on top of it instead.
        #expect(bandHeight + paddingUnderBand > trafficLightBottomEdge)

        // And it is genuinely a reduction, not the same clearance under a new name: the point of
        // the band holding the strip is that the gap between it and the pane title closes.
        #expect(paddingUnderBand < MessagesLayout.sidebarTitlebarTopPadding)
        #expect(paddingUnderBand >= 0)
    }
}
