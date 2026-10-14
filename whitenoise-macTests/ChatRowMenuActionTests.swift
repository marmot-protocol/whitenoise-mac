//
//  ChatRowMenuActionTests.swift
//  whitenoise-macTests
//

import AppKit
import Testing

@testable import whitenoise_mac

@MainActor
struct ChatRowMenuActionTests {
    /// The menu repaints template images in its own monochrome, so a template icon would lose the
    /// color that is the whole point of these items.
    @Test func menuIconsAreNonTemplateDiscs() {
        for action in ChatRowMenuAction.allCases {
            let icon = action.menuIcon
            #expect(!icon.isTemplate, "\(action) would be repainted monochrome")
            #expect(icon.size == NSSize(width: 16, height: 16))
        }
    }

    /// Each pair shares the iOS swipe action's tint, so toggling an item does not change color.
    @Test func togglePairsShareATint() {
        let pairs: [(ChatRowMenuAction, ChatRowMenuAction)] = [
            (.markUnread, .clearUnread), (.mute, .unmute), (.pin, .unpin), (.archive, .unarchive),
            (.leave, .deleteLocally),
        ]
        for (a, b) in pairs {
            #expect(a.tint == b.tint, "\(a) and \(b)")
        }
        #expect(ChatRowMenuAction.pin.tint == .systemOrange)
        #expect(ChatRowMenuAction.archive.tint == .systemGray)
        #expect(ChatRowMenuAction.leave.tint == WNNSColor.fillDestructive)
    }

    /// The titles are the catalog keys the menu already shipped with, so no translation changes.
    @Test func titlesKeepTheShippedCatalogKeys() {
        #expect(
            ChatRowMenuAction.allCases.map(\.titleKey) == [
                "Mark as Unread", "Clear Unread Reminder", "Mute", "Unmute", "Pin to Top", "Unpin",
                "Archive", "Unarchive", "Leave Chat", "Delete From This Device",
            ])
    }
}
