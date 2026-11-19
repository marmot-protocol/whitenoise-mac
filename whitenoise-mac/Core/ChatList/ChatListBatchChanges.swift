import Foundation

/// What a chat-list bulk action did to the account's chats, handed to the shell once the batch
/// ends so it can bring its legacy chat state along.
///
/// The two sets are kept apart because they ask different things of the shell: a chat the account
/// *left* keeps its history on this device, so an open conversation stays open, while a chat whose
/// local copy was *deleted* is gone, so an open conversation has to close.
nonisolated struct ChatListBatchChanges: Equatable {
    /// Chats this account left in the batch.
    var departedGroupIds: Set<String> = []
    /// Chats whose local copy the batch deleted from this device.
    var deletedGroupIds: Set<String> = []

    /// A batch that changed chats in place (archive, mute) without removing any.
    static let none = ChatListBatchChanges()

    /// Every chat the account no longer belongs to or no longer holds.
    var removedGroupIds: Set<String> { departedGroupIds.union(deletedGroupIds) }
}
