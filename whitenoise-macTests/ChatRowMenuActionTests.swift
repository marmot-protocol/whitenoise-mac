//
//  ChatRowMenuActionTests.swift
//  whitenoise-macTests
//

import AppKit
import Testing

@testable import whitenoise_mac

@MainActor
struct ChatRowMenuActionTests {
    @Test func everyMenuActionHasAnAvailableSystemSymbol() {
        for action in ChatRowMenuAction.allCases {
            #expect(NSImage(systemSymbolName: action.systemImage, accessibilityDescription: nil) != nil)
        }
    }

    /// The titles are the catalog keys the menu already shipped with, so no translation changes.
    @Test func titlesKeepTheShippedCatalogKeys() {
        #expect(
            ChatRowMenuAction.allCases.map(\.titleKey) == [
                "Mark as Unread", "Clear Unread Reminder", "Mute", "Unmute", "Pin to Top", "Unpin",
                "Archive", "Unarchive", "Leave Chat", "Delete From This Device", "Select",
            ])
    }
}
