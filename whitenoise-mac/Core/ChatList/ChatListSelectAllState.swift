/// How much of the list a selection covers, as the Select All row's checkbox shows it.
nonisolated enum ChatListSelectAllState: Equatable, Sendable {
    case empty
    case partial
    case all
}
