//
//  WNEmptyState.swift
//  whitenoise-mac
//
//  The one shape every "there is nothing here" pane takes.
//

import SwiftUI

/// A placeholder pane: a symbol, a title, a sentence saying what would put something here, and
/// optionally the control that does it.
///
/// The app had five of these written out by hand and no two agreed — some carried a
/// description, some only a title, one placed its action inside the pane and the rest left the
/// user to find it in the toolbar. `ContentUnavailableView` already draws the right thing; what
/// was missing was a single place deciding *what to give it*, which is what this is.
///
/// The description is not optional by oversight. A placeholder with a title alone names the
/// state and stops — "No chats" — where the sentence is the part that says what to do about it,
/// which is the whole job of an empty pane on a screen someone has just arrived at. The iOS
/// prototype's chat list uses the two-part form throughout for the same reason.
struct WNEmptyState<Actions: View>: View {
    let title: String
    let systemImage: String
    let description: String
    @ViewBuilder var actions: Actions

    var body: some View {
        ContentUnavailableView {
            Label(title, systemImage: systemImage)
        } description: {
            Text(description)
        } actions: {
            actions
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

extension WNEmptyState where Actions == EmptyView {
    /// The common case: a state the user cannot act on from here, or whose action already sits
    /// in the toolbar beside the pane.
    init(title: String, systemImage: String, description: String) {
        self.init(title: title, systemImage: systemImage, description: description) {
            EmptyView()
        }
    }
}

#Preview {
    WNEmptyState(
        title: "No chats yet",
        systemImage: "bubble.left.and.bubble.right",
        description: "Start a conversation and it will show up here."
    ) {
        WNPrimaryButton("New Chat", systemImage: "square.and.pencil") {}
    }
    .frame(width: 520, height: 420)
}
