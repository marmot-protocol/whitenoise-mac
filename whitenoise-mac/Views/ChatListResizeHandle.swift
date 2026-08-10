//
//  ChatListResizeHandle.swift
//  whitenoise-mac
//
//  The divider between the chat-list drawer and the detail pane, made draggable.
//

import AppKit
import SwiftUI

/// `GlassSeparator` plus a grab area: hovering it shows a resize cursor and a grabber at the
/// pointer, and pressing and dragging resizes the drawer through `ChatListWidthPolicy`.
///
/// The separator keeps its 1pt width in layout; everything interactive is an *overlay*, which
/// is not clipped to the parent's bounds. Widening the strip therefore reaches a few points
/// into the drawer and the detail pane — into the chat rows' outer padding, never their
/// content — instead of opening a gutter between the two panes that would show the window
/// background through the seam.
struct ChatListResizeHandle: View {
    @Environment(WorkspaceState.self) private var workspace
    @State private var isPointerInside = false
    /// Vertical position of the grabber within the strip, quantized to 4pt so sweeping the
    /// pointer along a tall divider writes state a handful of times instead of once per pixel.
    /// Kept through a drag that leaves the strip, so the grabber does not blink out mid-resize.
    @State private var grabberY: CGFloat?
    /// Drawer width when the current press began. Every frame of the drag is measured against
    /// this rather than against the live width, so the resolved snap cannot feed back into the
    /// next frame's translation.
    @State private var widthAtPressStart: CGFloat?
    /// Mirrors whether this view currently owns a pushed `NSCursor`, so the push/pop pairing
    /// survives the pointer leaving the strip mid-drag (when the cursor must stay) and the
    /// drawer being hidden while hovered (when it must not leak).
    @State private var hasPushedCursor = false

    private var isEngaged: Bool { isPointerInside || widthAtPressStart != nil }

    var body: some View {
        GlassSeparator()
            .overlay {
                if isEngaged {
                    Rectangle()
                        .fill(WNColor.borderPrimary)
                }
            }
            .overlay {
                Color.clear
                    .frame(width: MessagesLayout.chatListResizeGrabWidth)
                    .contentShape(.rect)
                    .overlay(alignment: .top) {
                        if isEngaged, let grabberY {
                            ChatListResizeGrabber()
                                .offset(y: grabberY - MessagesLayout.chatListResizeGrabberHeight / 2)
                        }
                    }
                    .onContinuousHover(coordinateSpace: .local) { phase in
                        switch phase {
                        case .active(let location):
                            isPointerInside = true
                            let quantized = (location.y / 4).rounded() * 4
                            if grabberY != quantized { grabberY = quantized }
                        case .ended:
                            isPointerInside = false
                            if widthAtPressStart == nil { grabberY = nil }
                        }
                        syncCursor()
                    }
                    // `.global`: the handle moves as the drawer resizes, so a local
                    // translation would be measured against a start point that has itself
                    // slid out from under the pointer.
                    .gesture(
                        DragGesture(minimumDistance: 0, coordinateSpace: .global)
                            .onChanged { value in
                                let start = widthAtPressStart ?? workspace.chatListDrawerWidth
                                if widthAtPressStart == nil {
                                    widthAtPressStart = start
                                    syncCursor()
                                }
                                workspace.resizeChatListDrawer(
                                    toProposedWidth: start + value.translation.width
                                )
                            }
                            .onEnded { _ in
                                widthAtPressStart = nil
                                if !isPointerInside { grabberY = nil }
                                syncCursor()
                            }
                    )
                    .accessibilityElement()
                    .accessibilityIdentifier("chat.list.resize.handle")
                    .accessibilityLabel(L10n.string("Resize chat list"))
                    .accessibilityAdjustableAction { direction in
                        switch direction {
                        case .increment:
                            workspace.stepChatListDrawerWidth(.wider)
                        case .decrement:
                            workspace.stepChatListDrawerWidth(.narrower)
                        @unknown default:
                            break
                        }
                    }
                    .onDisappear {
                        isPointerInside = false
                        widthAtPressStart = nil
                        grabberY = nil
                        syncCursor()
                    }
            }
    }

    private func syncCursor() {
        let shouldShowResizeCursor = isEngaged
        if shouldShowResizeCursor, !hasPushedCursor {
            NSCursor.resizeLeftRight.push()
            hasPushedCursor = true
        } else if !shouldShowResizeCursor, hasPushedCursor {
            NSCursor.pop()
            hasPushedCursor = false
        }
    }
}

/// The pill that appears under the pointer on the divider — the visible answer to "is this
/// draggable?", since a 1pt hairline gives no other affordance.
private struct ChatListResizeGrabber: View {
    var body: some View {
        Capsule(style: .continuous)
            .fill(WNColor.fillSecondary)
            .overlay {
                Capsule(style: .continuous)
                    .strokeBorder(WNColor.borderPrimary, lineWidth: 1)
            }
            .frame(width: 5, height: MessagesLayout.chatListResizeGrabberHeight)
            .allowsHitTesting(false)
    }
}
