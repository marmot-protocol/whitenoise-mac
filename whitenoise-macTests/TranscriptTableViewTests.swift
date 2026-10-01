//
//  TranscriptTableViewTests.swift
//  whitenoise-macTests
//

import AppKit
import SwiftUI
import Testing

@testable import whitenoise_mac

/// The transcript table's contract, exercised in a real offscreen window: whatever happens to the
/// rows, the row the reader is looking at stays exactly where it was on screen, unless they are
/// following the live edge, where the foot stays pinned. These are the guarantees the SwiftUI
/// lazy stack could not give, and the reason the transcript is a table view.
@Suite(.serialized)
@MainActor
struct TranscriptTableViewTests {
    @Test func olderRowsInsertedAboveLeaveTheReadersRowInPlace() {
        let harness = TranscriptTableHarness(rows: TableTestRow.range(100..<160))
        harness.request(.top(id: "row-120", inset: 0))
        let before = harness.offset(of: "row-120")

        harness.set(rows: TableTestRow.range(50..<160))

        #expect(before.map { abs($0) <= 0.5 } == true)
        #expect(harness.offset(of: "row-120") != nil)
        #expect(harness.offset(of: "row-120") == before)
    }

    @Test func aGrowingRowAboveLeavesTheReadersRowInPlace() {
        let harness = TranscriptTableHarness(rows: TableTestRow.range(0..<80))
        harness.request(.top(id: "row-50", inset: 0))
        let before = harness.offset(of: "row-50")

        harness.set(rows: TableTestRow.range(0..<80).map { $0.index == 40 ? $0.growing(by: 6) : $0 })

        #expect(before != nil)
        #expect(harness.offset(of: "row-50") == before)
    }

    @Test func anArrivalWhileFollowingKeepsTheFootPinned() {
        let harness = TranscriptTableHarness(rows: TableTestRow.range(0..<60), followsBottom: true)
        harness.request(.bottom)
        #expect(harness.distanceFromBottom.map { $0 <= 0.5 } == true)

        harness.set(rows: TableTestRow.range(0..<61))
        #expect(harness.distanceFromBottom.map { $0 <= 0.5 } == true)

        harness.set(rows: TableTestRow.range(0..<61).map { $0.index == 60 ? $0.growing(by: 10) : $0 })
        #expect(harness.distanceFromBottom.map { $0 <= 0.5 } == true)
    }

    @Test func anArrivalWhileReadingHigherUpLeavesTheReadersRowInPlace() {
        let harness = TranscriptTableHarness(rows: TableTestRow.range(0..<60), followsBottom: true)
        harness.request(.top(id: "row-20", inset: 0))
        let before = harness.offset(of: "row-20")

        harness.set(rows: TableTestRow.range(0..<61))

        #expect(before != nil)
        #expect(harness.offset(of: "row-20") == before)
    }

    @Test func aShortTranscriptSitsAtTheFoot() {
        let harness = TranscriptTableHarness(rows: TableTestRow.range(0..<2))

        #expect(harness.distanceFromBottom.map { $0 <= 0.5 } == true)
        #expect(harness.offset(of: "row-0").map { $0 > 200 } == true)
    }
}

struct TableTestRow: Identifiable, Equatable {
    let index: Int
    let lines: Int
    var id: String { "row-\(index)" }

    func growing(by extraLines: Int) -> TableTestRow {
        TableTestRow(index: index, lines: lines + extraLines)
    }

    static func range(_ range: Range<Int>) -> [TableTestRow] {
        range.map { TableTestRow(index: $0, lines: 1 + $0 % 5) }
    }
}

@MainActor
@Observable
final class TranscriptTableHarnessModel {
    var rows: [TableTestRow]
    var request: TranscriptScrollRequest?
    let followsBottom: Bool

    init(rows: [TableTestRow], followsBottom: Bool) {
        self.rows = rows
        self.followsBottom = followsBottom
    }
}

struct TranscriptTableHarnessView: View {
    let model: TranscriptTableHarnessModel

    var body: some View {
        TranscriptTableView(
            rows: model.rows,
            scrollRequest: model.request,
            followsBottom: model.followsBottom,
            onViewportChanged: { _ in },
            onLiveScrollChanged: { _ in },
            onScrollRequestApplied: { _ in },
            cell: { row in
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(0..<row.lines, id: \.self) { line in
                        Text("Row \(row.index), line \(line)")
                    }
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        )
    }
}

@MainActor
final class TranscriptTableHarness {
    let model: TranscriptTableHarnessModel
    let window: NSWindow
    let host: NSHostingView<TranscriptTableHarnessView>

    init(rows: [TableTestRow], followsBottom: Bool = false) {
        model = TranscriptTableHarnessModel(rows: rows, followsBottom: followsBottom)
        host = NSHostingView(rootView: TranscriptTableHarnessView(model: model))
        host.frame = NSRect(x: 0, y: 0, width: 520, height: 600)
        window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host
        window.orderBack(nil)
        settle()
    }

    func set(rows: [TableTestRow]) {
        model.rows = rows
        settle()
    }

    func request(_ target: TranscriptScrollTarget) {
        model.request = TranscriptScrollRequest(target: target)
        settle()
    }

    private var tableView: NSTableView? {
        Self.find(NSTableView.self, in: host)
    }

    /// The row's top edge relative to the viewport's top edge.
    func offset(of id: String) -> CGFloat? {
        guard let tableView, let clip = tableView.enclosingScrollView?.contentView,
            let index = model.rows.firstIndex(where: { $0.id == id })
        else { return nil }
        return tableView.rect(ofRow: index + 1).minY - clip.bounds.minY
    }

    var distanceFromBottom: CGFloat? {
        guard let tableView, let clip = tableView.enclosingScrollView?.contentView else { return nil }
        return tableView.bounds.height - clip.bounds.maxY
    }

    func settle() {
        for _ in 0..<5 {
            host.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
    }

    private static func find<T: NSView>(_ type: T.Type, in view: NSView) -> T? {
        if let match = view as? T { return match }
        for subview in view.subviews {
            if let found = find(type, in: subview) { return found }
        }
        return nil
    }
}
