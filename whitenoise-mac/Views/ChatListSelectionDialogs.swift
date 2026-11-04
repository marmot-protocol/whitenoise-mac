import SwiftUI

/// The bulk-leave confirmation and the bulk-action alerts for chat-list selection. A dialog rather
/// than iOS's sheet: on the Mac a confirmation is an alert, and the leave runs after it closes, so
/// a step-down advisory can prompt from the account's shared alert host in `ContentView`.
struct ChatListSelectionDialogs: ViewModifier {
    @Environment(\.locale) private var locale
    let model: ChatListSelectionViewModel?

    func body(content: Content) -> some View {
        if let model {
            content
                .confirmationDialog(
                    L10n.plural("Leave %lld chats?", Int64(model.pendingLeave?.count ?? 0), locale: locale),
                    isPresented: Binding(
                        get: { model.pendingLeave != nil },
                        set: { presented in
                            if !presented { model.pendingLeave = nil }
                        }
                    ),
                    titleVisibility: .visible,
                    presenting: model.pendingLeave
                ) { confirmation in
                    Button(
                        L10n.plural("Leave %lld chats", Int64(confirmation.count), locale: locale),
                        role: .destructive
                    ) {
                        model.confirmLeave(confirmation)
                    }
                    Button(L10n.string("Cancel", locale: locale), role: .cancel) {}
                } message: { _ in
                    Text(
                        L10n.string(
                            "You'll stop receiving new messages in these chats. Their history will stay on this device until you delete it.",
                            locale: locale
                        )
                    )
                }
                .alert(
                    model.alert?.title ?? "",
                    isPresented: Binding(
                        get: { model.alert != nil },
                        set: { presented in
                            if !presented { model.alert = nil }
                        }
                    ),
                    presenting: model.alert
                ) { _ in
                    Button(L10n.string("OK", locale: locale), role: .cancel) {}
                } message: { alert in
                    Text(alert.message)
                }
        } else {
            content
        }
    }
}
