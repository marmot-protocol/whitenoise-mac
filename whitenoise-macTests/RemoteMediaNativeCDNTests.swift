// A tiny immutable first-party PNG exercises the actual public network adapter.
// This does not qualify configured proxies, GIF search or exact macOS 15.6.

import AppKit
import CryptoKit
import Foundation
import Testing

@testable import whitenoise_mac

@Suite(
    .serialized,
    .enabled(if: ProcessInfo.processInfo.environment["WN_REMOTE_MEDIA_NATIVE_CDN"] == "1"),
    .timeLimit(.minutes(1))
)
struct RemoteMediaNativeCDNTests {
    @MainActor @Test func nativePublicCDNPinnedImageFetchWorks() async throws {
        let url = try #require(
            URL(
                string: "https://raw.githubusercontent.com/marmot-protocol/whitenoise-android/"
                    + "4a1a8a8f7ebfe5235f5fec85401883d09ee74ab5/"
                    + "app/src/test/snapshots/composer_attachment_shelf_visual.png"))
        // No cache closure, fake DNS, fixture mapping, retry or alternate transport.
        let response = try await RemoteMediaTransport.live.fetch(url)
        let head = try #require(response.head)
        #expect(response.url == url)
        #expect(head.statusCode == 200)
        #expect(head.values(for: "content-type") == ["image/png"])
        #expect(
            head.values(for: "content-length") == ["1945"]
                || head.values(for: "transfer-encoding") == ["chunked"])
        try #require(response.body.count == 1945)
        let digest = SHA256.hash(data: response.body).map { String(format: "%02x", $0) }.joined()
        try #require(digest == "95f3d94ce721ce62e5cfefc8ee99923f257dc31cc565746053c84e47b9a09617")
        // Only the verified tiny source enters the native image codec.
        let image = try #require(NSBitmapImageRep(data: response.body))
        #expect(image.pixelsWide > 0 && image.pixelsHigh > 0)
    }
}
