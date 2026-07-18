//
//  SharedChromeTests.swift
//  whitenoise-macTests
//

import Foundation
import Testing

struct SharedChromeTests {
    @Test func accountRailAndChatRowsShareUnreadCountBadgeChrome() throws {
        let source = try viewSource(named: "SidebarViews.swift")

        #expect(source.contains("private struct UnreadCountBadge: View"))
        #expect(occurrenceCount(of: "UnreadCountBadge(count:", in: source) == 2)
        #expect(occurrenceCount(of: ".background(Capsule().fill(MessagesPalette.sentBubble))", in: source) == 1)
    }

    @Test func attachmentRowsShareFixedWidthChrome() throws {
        let source = try viewSource(named: "MessageMediaViews.swift")

        #expect(occurrenceCount(of: ".attachmentRowChrome(isOutgoing: isOutgoing)", in: source) == 2)
        #expect(occurrenceCount(of: ".frame(width: 260, alignment: .leading)", in: source) == 1)
        #expect(
            occurrenceCount(
                of: ".fill(isOutgoing ? Color.white.opacity(0.12) : Color.primary.opacity(0.06))",
                in: source
            ) == 1
        )
    }

    private func viewSource(named fileName: String) throws -> String {
        let url =
            URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("whitenoise-mac")
            .appendingPathComponent("Views")
            .appendingPathComponent(fileName)
        return try String(contentsOf: url, encoding: .utf8)
    }

    private func occurrenceCount(of needle: String, in source: String) -> Int {
        source.components(separatedBy: needle).count - 1
    }
}
