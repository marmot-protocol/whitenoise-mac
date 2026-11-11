import Foundation

/// The mute lengths a chat can be silenced for. One list, shared by a row's context menu and the
/// selection bar, so muting one chat and muting several offer the same choices.
nonisolated enum ChatMuteDuration: CaseIterable, Identifiable, Sendable {
    case oneHour
    case eightHours
    case oneWeek
    case indefinitely

    var id: Self { self }

    /// `nil` mutes until the user turns notifications back on.
    var interval: TimeInterval? {
        switch self {
        case .oneHour: 60 * 60
        case .eightHours: 8 * 60 * 60
        case .oneWeek: 7 * 24 * 60 * 60
        case .indefinitely: nil
        }
    }

    var titleKey: String {
        switch self {
        case .oneHour: "For 1 Hour"
        case .eightHours: "For 8 Hours"
        case .oneWeek: "For 1 Week"
        case .indefinitely: "Until I Turn It Back On"
        }
    }

    var systemImage: String {
        switch self {
        case .oneHour, .eightHours: "clock"
        case .oneWeek: "calendar"
        case .indefinitely: "infinity"
        }
    }

    /// The absolute deadline MDK stores, or `nil` for an indefinite mute.
    func mutedUntilMs(from now: Date) -> Int64? {
        interval.map { Int64((now.timeIntervalSince1970 + $0) * 1_000) }
    }
}
