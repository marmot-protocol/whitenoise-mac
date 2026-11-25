import Testing

@testable import whitenoise_mac

/// The hover strip's presentation lifetime (#1022): the reaction picker has to stay reachable while
/// the pointer travels from its trigger into it, stay bound to the message that opened it, and
/// close when that message's row stops offering it. `MessageBubble` owns this value and the
/// strip's popover bindings read and write it directly, so these are the transitions the view
/// performs.
@Suite struct MessageInlineActionPresentationTests {
    private static let message = "message-a"
    private static let other = "message-b"

    private static func eligibility(
        messageID: String = message,
        supportsChatActions: Bool = true,
        canReact: Bool = true,
        isSelectionMode: Bool = false
    ) -> MessageInlineActionPresentation.Eligibility {
        .init(
            messageID: messageID,
            supportsChatActions: supportsChatActions,
            canReact: canReact,
            isSelectionMode: isSelectionMode
        )
    }

    /// Hovering, clicking React, then leaving the row on the way into the picker: the row's hover
    /// ends before the pointer reaches the popover, and the strip (the popover's anchor) has to
    /// outlive it.
    @Test func thePickerKeepsItsStripWhileThePointerLeavesTheRowForIt() {
        var presentation = MessageInlineActionPresentation()
        presentation.isHoveringRow = true
        #expect(presentation.showsStrip(supportsChatActions: true))

        presentation.setPresented(true, .reactionPicker, for: Self.message)
        presentation.isHoveringRow = false
        presentation.isHoveringStrip = false

        #expect(presentation.showsStrip(supportsChatActions: true))
        #expect(presentation.isPresented(.reactionPicker, for: Self.message))
    }

    /// Escape or an outside click writes `false` through the popover binding. Once the picker is
    /// closed and the pointer has gone, the strip goes too.
    @Test func closingThePickerAfterThePointerLeftHidesTheStrip() {
        var presentation = MessageInlineActionPresentation()
        presentation.setPresented(true, .reactionPicker, for: Self.message)

        presentation.setPresented(false, .reactionPicker, for: Self.message)

        #expect(!presentation.isPresented(.reactionPicker, for: Self.message))
        #expect(!presentation.showsStrip(supportsChatActions: true))
    }

    /// A short bubble's strip overhangs its row. Pointing at the overhang keeps the strip up,
    /// so the React control can be reached before any popover exists.
    @Test func pointingAtTheStripAloneKeepsItShown() {
        var presentation = MessageInlineActionPresentation()
        presentation.isHoveringStrip = true

        #expect(presentation.showsStrip(supportsChatActions: true))
        #expect(!presentation.showsStrip(supportsChatActions: false))
    }

    /// SwiftUI may write `false` to a popover's binding that is not the open one, for example
    /// while it resolves another presentation. That must not close the picker that is open.
    @Test func resettingTheOtherPopoversBindingLeavesThePickerOpen() {
        var presentation = MessageInlineActionPresentation()
        presentation.setPresented(true, .reactionPicker, for: Self.message)

        presentation.setPresented(false, .overflow, for: Self.message)

        #expect(presentation.isPresented(.reactionPicker, for: Self.message))
    }

    /// The open picker belongs to the message that opened it. Another message's binding reads it
    /// as closed, cannot close it, and a pick made for another message is refused.
    @Test func thePickerIsBoundToTheMessageThatOpenedIt() {
        var presentation = MessageInlineActionPresentation()
        presentation.setPresented(true, .reactionPicker, for: Self.message)

        #expect(!presentation.isPresented(.reactionPicker, for: Self.other))
        #expect(!presentation.acceptsReactionPick(for: Self.other))
        #expect(presentation.acceptsReactionPick(for: Self.message))

        presentation.setPresented(false, .reactionPicker, for: Self.other)
        #expect(presentation.isPresented(.reactionPicker, for: Self.message))
    }

    /// Once the picker has closed, a late pick from its content sends nothing.
    @Test func aClosedPickerAcceptsNoPick() {
        var presentation = MessageInlineActionPresentation()
        presentation.setPresented(true, .reactionPicker, for: Self.message)
        presentation.setPresented(false, .reactionPicker, for: Self.message)

        #expect(!presentation.acceptsReactionPick(for: Self.message))
    }

    @Test func openingTheOverflowMenuReplacesThePicker() {
        var presentation = MessageInlineActionPresentation()
        presentation.setPresented(true, .reactionPicker, for: Self.message)

        presentation.setPresented(true, .overflow, for: Self.message)

        #expect(presentation.isPresented(.overflow, for: Self.message))
        #expect(!presentation.isPresented(.reactionPicker, for: Self.message))
    }

    /// The row still offers everything: an update to its message (a receipt, a new reaction)
    /// leaves the picker open.
    @Test func anUnchangedRowKeepsThePickerOpen() {
        var presentation = MessageInlineActionPresentation()
        presentation.setPresented(true, .reactionPicker, for: Self.message)

        presentation.reconcile(with: Self.eligibility())

        #expect(presentation.isPresented(.reactionPicker, for: Self.message))
    }

    /// A row that now shows another message closes the picker instead of retargeting it.
    @Test func aRowShowingAnotherMessageClosesThePicker() {
        var presentation = MessageInlineActionPresentation()
        presentation.setPresented(true, .reactionPicker, for: Self.message)

        presentation.reconcile(with: Self.eligibility(messageID: Self.other))

        #expect(!presentation.isPresented(.reactionPicker, for: Self.message))
        #expect(!presentation.isPresented(.reactionPicker, for: Self.other))
        #expect(!presentation.showsStrip(supportsChatActions: true))
    }

    /// A message that can no longer take reactions, for example because it was deleted, loses
    /// its picker but keeps an open overflow menu, which may still offer other actions.
    @Test func losingReactionsClosesOnlyThePicker() {
        var picker = MessageInlineActionPresentation()
        picker.setPresented(true, .reactionPicker, for: Self.message)
        picker.reconcile(with: Self.eligibility(canReact: false))
        #expect(!picker.isPresented(.reactionPicker, for: Self.message))

        var overflow = MessageInlineActionPresentation()
        overflow.setPresented(true, .overflow, for: Self.message)
        overflow.reconcile(with: Self.eligibility(canReact: false))
        #expect(overflow.isPresented(.overflow, for: Self.message))
    }

    @Test(arguments: [
        (supportsChatActions: false, isSelectionMode: false),
        (supportsChatActions: true, isSelectionMode: true),
    ])
    func aRowThatStopsOfferingActionsClosesEveryPopover(supportsChatActions: Bool, isSelectionMode: Bool) {
        for popover in [MessageInlineActionPresentation.Popover.reactionPicker, .overflow] {
            var presentation = MessageInlineActionPresentation()
            presentation.setPresented(true, popover, for: Self.message)

            presentation.reconcile(
                with: Self.eligibility(supportsChatActions: supportsChatActions, isSelectionMode: isSelectionMode))

            #expect(!presentation.isPresented(popover, for: Self.message))
        }
    }
}
