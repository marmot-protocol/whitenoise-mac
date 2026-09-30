import Foundation

/// MDK's validated tally for one kind-1068 poll, as the timeline shows it. The core projects this
/// only for a well-formed poll; a row without one renders the "can't be displayed" notice instead.
nonisolated struct MessagePoll: Hashable, Sendable {
    enum Kind: Hashable, Sendable {
        case singleChoice
        case multipleChoice
    }

    struct Option: Hashable, Sendable, Identifiable {
        let id: String
        let label: String
        var votes: UInt64
    }

    let question: String
    var options: [Option]
    let kind: Kind
    /// Distinct voters, not the sum of option votes: a multiple-choice voter counts once.
    var participants: UInt64
    /// The option ids this account has selected, in option order.
    var localSelection: [String]
    let endsAt: UInt64?
    /// MDK's verdict at the time the row was read. See `PollPresentation.isOpen` for the clock.
    let isOpen: Bool

    var isMultipleChoice: Bool { kind == .multipleChoice }
}
