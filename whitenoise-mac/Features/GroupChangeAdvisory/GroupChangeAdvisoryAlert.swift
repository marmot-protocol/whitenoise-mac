//
//  GroupChangeAdvisoryAlert.swift
//  whitenoise-mac
//
//  The consent alert for a group change MDK refused as advisory.
//

import SwiftUI

extension View {
    /// Presents `prompter`'s pending consent request. Each prompter has exactly one host: the
    /// account's shared prompter is hosted in `ContentView` for changes made from the panes, and a
    /// sheet that makes a change owns its own prompter and hosts it itself, because a window
    /// cannot show an alert from under a sheet and an unanswered prompt would hold the change open.
    func groupChangeAdvisoryAlert(_ prompter: GroupChangeAdvisoryPrompter?) -> some View {
        modifier(GroupChangeAdvisoryAlertModifier(prompter: prompter))
    }
}

private struct GroupChangeAdvisoryAlertModifier: ViewModifier {
    let prompter: GroupChangeAdvisoryPrompter?

    func body(content: Content) -> some View {
        let prompt = prompter?.prompt
        content.alert(
            prompt?.title ?? "",
            isPresented: Binding(
                get: { prompt != nil },
                set: { presented in
                    // Buttons resolve first; this only covers a dismissal without one.
                    guard !presented, let id = prompt?.id else { return }
                    Task { @MainActor in prompter?.resolve(id: id, approved: false) }
                }
            ),
            presenting: prompt
        ) { prompt in
            Button(L10n.string("Continue anyway"), role: .destructive) {
                prompter?.resolve(id: prompt.id, approved: true)
            }
            Button(L10n.string("Wait"), role: .cancel) {
                prompter?.resolve(id: prompt.id, approved: false)
            }
        } message: { prompt in
            Text(prompt.message)
        }
    }
}

#Preview {
    let prompter = GroupChangeAdvisoryPrompter()
    Text(verbatim: "Group Info")
        .frame(width: 420, height: 240)
        .groupChangeAdvisoryAlert(prompter)
        .task { _ = await prompter.requestConsent(for: .catchingUp, isInvite: false) }
}
