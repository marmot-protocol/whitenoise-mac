import AppKit
import SwiftUI

/// One action in a chat row's right-click menu — the Mac's counterpart to the iOS chat list's
/// swipe actions. A swipe is not a desktop gesture, so the same glyphs and tints ride on the
/// native context menu instead: every item keeps its title, and its icon is the colored disc the
/// iOS swipe slot draws.
///
/// Glyphs and tints mirror `whitenoise-ios`'s `ChatListSwipeAction`: blue for read state, indigo
/// for muting, orange for pinning, gray for the archive, red for leaving or dropping the chat.
nonisolated enum ChatRowMenuAction: String, CaseIterable, Identifiable, Sendable {
    case markUnread
    case clearUnread
    case mute
    case unmute
    case pin
    case unpin
    case archive
    case unarchive
    case leave
    case deleteLocally

    var id: String { rawValue }

    var systemImage: String {
        switch self {
        case .markUnread: "message.badge.fill"
        case .clearUnread: "message.fill"
        case .mute: "bell.slash.fill"
        case .unmute: "bell.fill"
        case .pin: "pin.fill"
        case .unpin: "pin.slash.fill"
        case .archive: "archivebox.fill"
        case .unarchive: "tray.and.arrow.up.fill"
        case .leave: "rectangle.portrait.and.arrow.right"
        case .deleteLocally: "trash.fill"
        }
    }

    var titleKey: String {
        switch self {
        case .markUnread: "Mark as Unread"
        case .clearUnread: "Clear Unread Reminder"
        case .mute: "Mute"
        case .unmute: "Unmute"
        case .pin: "Pin to Top"
        case .unpin: "Unpin"
        case .archive: "Archive"
        case .unarchive: "Unarchive"
        case .leave: "Leave Chat"
        case .deleteLocally: "Delete From This Device"
        }
    }
}

extension ChatRowMenuAction {
    /// An `NSColor` rather than a `Color`: the disc is drawn into an `NSImage`, and
    /// `NSColor(SwiftUI.Color)` would freeze a dynamic token to one appearance.
    var tint: NSColor {
        switch self {
        case .markUnread, .clearUnread: .systemBlue
        case .mute, .unmute: .systemIndigo
        case .pin, .unpin: .systemOrange
        case .archive, .unarchive: .systemGray
        case .leave, .deleteLocally: WNNSColor.fillDestructive
        }
    }

    /// The menu item's icon: a white glyph on a tinted disc.
    ///
    /// It has to be a non-template `NSImage`. SwiftUI hands a menu's SF Symbols to AppKit as
    /// templates, which the menu repaints in its own monochrome — any `foregroundStyle` or
    /// rendering mode is discarded. A bitmap marked `isTemplate = false` is drawn as is. The
    /// drawing handler runs at draw time, so the system tints resolve for the menu's appearance.
    var menuIcon: NSImage {
        let diameter = ChatRowMenuIconMetrics.diameter
        let tint = tint
        let systemImage = systemImage
        let image = NSImage(size: NSSize(width: diameter, height: diameter), flipped: false) { rect in
            tint.setFill()
            NSBezierPath(ovalIn: rect).fill()
            let configuration = NSImage.SymbolConfiguration(
                pointSize: ChatRowMenuIconMetrics.glyphPointSize,
                weight: .semibold
            )
            .applying(NSImage.SymbolConfiguration(paletteColors: [.white]))
            if let glyph = NSImage(systemSymbolName: systemImage, accessibilityDescription: nil)?
                .withSymbolConfiguration(configuration)
            {
                let origin = NSPoint(
                    x: rect.midX - glyph.size.width / 2,
                    y: rect.midY - glyph.size.height / 2
                )
                glyph.draw(at: origin, from: .zero, operation: .sourceOver, fraction: 1)
            }
            return true
        }
        image.isTemplate = false
        return image
    }
}

nonisolated enum ChatRowMenuIconMetrics {
    /// The height of a menu item's standard icon slot, so a colored item lines up with the
    /// plain ones in the Mute submenu.
    static let diameter: CGFloat = 16
    static let glyphPointSize: CGFloat = 8
}

/// A menu item's label: the action's title beside its colored disc.
struct ChatRowMenuLabel: View {
    let action: ChatRowMenuAction

    var body: some View {
        Label {
            Text(L10n.string(action.titleKey))
        } icon: {
            Image(nsImage: action.menuIcon)
        }
    }
}

#Preview("ChatRowMenuLabel") {
    VStack(alignment: .leading, spacing: 8) {
        ForEach(ChatRowMenuAction.allCases) { action in
            ChatRowMenuLabel(action: action)
                .labelStyle(.titleAndIcon)
        }
    }
    .padding()
}
