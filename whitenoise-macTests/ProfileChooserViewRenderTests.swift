import AppKit
import SwiftUI
import Testing

@testable import whitenoise_mac

/// The chooser the detail pane shows after the active profile is deleted while others stay signed
/// in, hosted in a window so what it draws can be read back and its buttons clicked.
///
/// `.serialized` and `@MainActor` because hosting draws through AppKit, which off the main thread
/// takes the test host down.
@Suite(.serialized) @MainActor struct ProfileChooserViewRenderTests {
    private static let size = CGSize(width: 640, height: 560)

    /// The view under test, in English whatever language the test host last persisted. Each row's
    /// `CopyableKeyLabel` encodes its npub through the workspace.
    private static func chooser(
        _ accounts: [AccountItem], isBusy: Bool = false, onChoose: @escaping (AccountItem) -> Void = { _ in },
        onAddProfile: @escaping () -> Void = {}
    ) -> some View {
        ProfileChooserView(accounts: accounts, isBusy: isBusy, onChoose: onChoose, onAddProfile: onAddProfile)
            .environment(\.locale, Locale(identifier: "en"))
            .environment(WorkspaceState.preview())
    }

    @Test func itAsksForAProfileAndListsEverySignedInOne() async throws {
        let accounts = Array(AccountItem.samples.prefix(2))
        let host = HostedViewWindow(Self.chooser(accounts), size: Self.size)
        defer { host.close() }

        let drawn = try #require(await host.steadyDrawing())

        #expect(DrawnText.contains("Choose a profile", in: drawn))
        #expect(DrawnText.contains("Add Profile", in: drawn))
        for account in accounts {
            #expect(DrawnText.contains(account.displayName, in: drawn), "\(account.displayName) has no row")
        }
    }

    @Test func eachSignedInProfileAddsARow() async throws {
        let one = HostedViewWindow(Self.chooser(Array(AccountItem.samples.prefix(1))), size: Self.size)
        defer { one.close() }
        let three = HostedViewWindow(Self.chooser(Array(AccountItem.samples.prefix(3))), size: Self.size)
        defer { three.close() }

        let oneDrawn = try #require(await one.steadyDrawing())
        let threeDrawn = try #require(await three.steadyDrawing())

        #expect(DrawnPixels.inkedRows(threeDrawn) > DrawnPixels.inkedRows(oneDrawn))
    }

    /// Clicking down the pane reaches the profile's row before the Add Profile button, and each
    /// reports its own action: a row chooses its profile, the button adds one.
    @Test func aRowChoosesItsProfileAndTheButtonAddsOne() async throws {
        let account = try #require(AccountItem.samples.first)
        var chosen: [AccountItem.ID] = []
        var addRequests = 0
        let host = HostedViewWindow(
            Self.chooser([account], onChoose: { chosen.append($0.id) }, onAddProfile: { addRequests += 1 }),
            size: Self.size)
        defer { host.close() }
        _ = try #require(await host.steadyDrawing())

        var y: CGFloat = 4
        while y < Self.size.height, addRequests == 0 {
            host.click(at: CGPoint(x: Self.size.width / 2, y: y))
            _ = await host.settle(timeout: .milliseconds(50)) { addRequests > 0 }
            y += 6
        }

        #expect(chosen.first == account.id, "no click down the pane reached the profile's row")
        #expect(addRequests == 1)
    }

    /// While another account change is running the rows and the button take no clicks.
    @Test func aBusyChooserTakesNoClicks() async throws {
        let account = try #require(AccountItem.samples.first)
        var actions = 0
        let host = HostedViewWindow(
            Self.chooser([account], isBusy: true, onChoose: { _ in actions += 1 }, onAddProfile: { actions += 1 }),
            size: Self.size)
        defer { host.close() }
        _ = try #require(await host.steadyDrawing())

        var y: CGFloat = 4
        while y < Self.size.height {
            host.click(at: CGPoint(x: Self.size.width / 2, y: y))
            y += 6
        }
        _ = await host.settle(timeout: .milliseconds(200)) { actions > 0 }

        #expect(actions == 0)
    }
}
