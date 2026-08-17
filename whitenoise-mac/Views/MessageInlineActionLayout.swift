import CoreGraphics

/// Geometry for the hover action strip that sits beside a message bubble.
///
/// The strip is an overlay anchored to the bubble's edge and pushed outward by its own width, so
/// the offset has to be derived from exactly the same conditions `MessageInlineActions` uses to
/// decide which controls to render. A control added to the row without being counted here slides
/// the whole strip back over the bubble it belongs to.
nonisolated enum MessageInlineActionLayout {
    static let controlDiameter: CGFloat = 40
    static let controlSpacing: CGFloat = 4
    /// Breathing room between the strip and the bubble edge.
    static let bubbleGap: CGFloat = 8

    static func actionCount(for message: MessageItem) -> Int {
        var count = 0
        count += message.canReact ? 1 : 0
        count += message.canReply ? 1 : 0
        count += message.canDownloadMediaAttachments ? 1 : 0
        count += message.supportsChatActions ? 1 : 0
        return count
    }

    static func offset(for message: MessageItem) -> CGFloat {
        let count = actionCount(for: message)
        let controlWidth = CGFloat(count) * controlDiameter
        let spacingWidth = CGFloat(max(count - 1, 0)) * controlSpacing
        return controlWidth + spacingWidth + bubbleGap
    }
}
