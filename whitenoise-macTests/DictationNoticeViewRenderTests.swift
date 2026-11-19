import AppKit
import SwiftUI
import Testing

@testable import whitenoise_mac

@Suite(.serialized) @MainActor struct DictationNoticeViewRenderTests {
    private static let size = CGSize(width: 520, height: 60)

    /// A controller whose last start failed with `failure`, so it shows that notice.
    private static func controller(failingWith failure: DictationFailure) async -> ComposerDictationController {
        let controller = ComposerDictationController(
            engine: DictationEngine { _, _, _ in throw failure })
        controller.begin(localeIdentifiers: ["en"]) { _ in }
        let deadline = ContinuousClock.now + .seconds(5)
        while controller.notice == nil, ContinuousClock.now < deadline {
            await Task.yield()
        }
        return controller
    }

    @Test func dismissingTheNoticeClearsIt() async throws {
        let controller = await Self.controller(failingWith: .modelDownloading)
        let notice = try #require(controller.notice)
        let host = HostedViewWindow(
            DictationNoticeView(notice: notice, controller: controller).frame(width: Self.size.width),
            size: Self.size)
        defer { host.close() }

        // The dismiss button is the trailing control, inside the notice's 12pt padding.
        host.click(at: CGPoint(x: Self.size.width - 12 - 11, y: Self.size.height / 2))
        #expect(await host.settle { controller.notice == nil })
    }

    @Test func aDeniedMicrophoneOffersSystemSettings() async throws {
        let denied = await Self.controller(failingWith: .permissionDenied)
        let notice = try #require(denied.notice)
        let withAction = HostedViewWindow(
            DictationNoticeView(notice: notice, controller: denied).frame(width: Self.size.width),
            size: Self.size)
        defer { withAction.close() }
        let plain = HostedViewWindow(
            ComposerNotice(message: notice.message, onDismiss: {}).frame(width: Self.size.width),
            size: Self.size)
        defer { plain.close() }

        let button = L10n.string("Open System Settings")
        #expect(DrawnText.contains(button, in: try #require(withAction.snapshot())))
        #expect(!DrawnText.contains(button, in: try #require(plain.snapshot())))
    }
}
