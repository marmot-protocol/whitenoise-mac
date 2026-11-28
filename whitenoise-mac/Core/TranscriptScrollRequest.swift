import CoreGraphics
import Foundation

/// Where a `TranscriptTableView` should put a row when asked to scroll.
nonisolated enum TranscriptScrollTarget: Equatable {
    /// The foot of the transcript.
    case bottom
    /// A row's top edge `inset` points below the viewport's top edge.
    case top(id: String, inset: CGFloat)
    /// A row centred in the viewport.
    case center(id: String)
}

/// A one-shot scroll command. A new `id` makes the same target apply again.
nonisolated struct TranscriptScrollRequest: Equatable {
    let id = UUID()
    let target: TranscriptScrollTarget
}
