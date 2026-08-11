import Foundation

struct TimelinePagingState: Equatable {
    var hasMoreBefore: Bool
    var hasMoreAfter: Bool
    var isLoadingBefore: Bool
    var isLoadingAfter: Bool

    static let empty = TimelinePagingState(
        hasMoreBefore: false,
        hasMoreAfter: false,
        isLoadingBefore: false,
        isLoadingAfter: false
    )
}
