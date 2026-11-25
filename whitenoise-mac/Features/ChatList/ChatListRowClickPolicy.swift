import AppKit
import Foundation

/// Action produced by clicking a row in the chat sidebar while keeping open-conversation selection
/// distinct from batch selection (`ChatListSelectionViewModel`).
nonisolated enum ChatListRowClickAction: Equatable, Sendable {
    case openChat
    case beginSelection
    case toggleSelection
    case extendSelection(defaultAnchor: String?)
}

/// Pure click and native `List(selection:)` routing rules for the chat sidebar (N03, K10).
///
/// SwiftUI's single-selection `List(selection: Binding<String?>)` cannot preserve Finder/Mail
/// Command-click toggling on the already-open row or Shift-range anchoring from the open chat on
/// macOS, so row clicks route through this policy while `List(selection:)` owns native sidebar
/// highlight and keyboard arrow navigation when batch selection is inactive.
nonisolated enum ChatListRowClickPolicy {
    static func action(
        modifiers: NSEvent.ModifierFlags,
        isBatchSelectionActive: Bool,
        openChatId: String?
    ) -> ChatListRowClickAction {
        if modifiers.contains(.shift) {
            return .extendSelection(defaultAnchor: openChatId)
        }
        if isBatchSelectionActive {
            return .toggleSelection
        }
        if modifiers.contains(.command) {
            return .beginSelection
        }
        return .openChat
    }

    /// Whether a native `List(selection:)` update (such as arrow-key navigation) should open a
    /// chat. Suppressed while batch selection is active or when the list attempts to clear
    /// selection to `nil` so the open conversation and batch set never collide.
    static func shouldApplyNativeListSelection(
        newId: String?,
        currentOpenChatId: String?,
        isBatchSelectionActive: Bool
    ) -> Bool {
        guard !isBatchSelectionActive, let newId, newId != currentOpenChatId else { return false }
        return true
    }
}
