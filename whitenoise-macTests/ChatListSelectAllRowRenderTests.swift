import AppKit
import SwiftUI
import Testing

@testable import whitenoise_mac

/// `ChatListSelectAllRow` hosted in a real window: what its box says, and what its checkbox and
/// Done button do when clicked.
@Suite(.serialized) @MainActor struct ChatListSelectAllRowRenderTests {
    private static let size = CGSize(width: 320, height: 48)
    /// The checkbox: 4pt in from the leading edge, 20pt wide.
    private static let checkbox = CGPoint(x: 4 + 10, y: size.height / 2)
    /// Inside the Done button, the row's trailing control.
    private static let done = CGPoint(x: size.width - 20, y: size.height / 2)

    /// A model in selection mode over three visible chats, with `selected` picked.
    private static func model(selecting selected: [String]) -> ChatListSelectionViewModel {
        let model = ChatListSelectionViewModel(accountRef: "account", runtime: nil)
        model.updateVisibleChats(["a", "b", "c"])
        model.begin(with: "a")
        model.deselectAll()
        for id in selected { model.toggle(id) }
        return model
    }

    private static func host(_ model: ChatListSelectionViewModel) -> HostedViewWindow {
        HostedViewWindow(ChatListSelectAllRow(model: model).frame(width: size.width), size: size)
    }

    @Test func theBoxSaysSelectAllUntilSomethingIsSelected() async throws {
        let none = Self.host(Self.model(selecting: []))
        defer { none.close() }
        let some = Self.host(Self.model(selecting: ["a", "b"]))
        defer { some.close() }

        let selectAll = L10n.string("Select All")
        let twoSelected = L10n.plural("%lld selected", Int64(2))
        #expect(await none.settleDrawing { DrawnText.contains(selectAll, in: $0) } != nil)
        let drawing = try #require(await some.settleDrawing { DrawnText.contains(twoSelected, in: $0) })
        #expect(!DrawnText.contains(selectAll, in: drawing))
    }

    @Test func theCheckboxSelectsEveryChatThenClearsThem() async {
        let model = Self.model(selecting: ["b"])
        let host = Self.host(model)
        defer { host.close() }
        #expect(model.selectAllState == .partial)

        host.click(at: Self.checkbox)
        #expect(await host.settle { model.selectAllState == .all })

        host.click(at: Self.checkbox)
        #expect(await host.settle { model.selectAllState == .empty })
        #expect(model.isActive)
    }

    @Test func doneEndsSelectionMode() async {
        let model = Self.model(selecting: ["a", "c"])
        let host = Self.host(model)
        defer { host.close() }

        host.click(at: Self.done)
        #expect(await host.settle { !model.isActive })
        #expect(model.selectedIds.isEmpty)
    }
}
