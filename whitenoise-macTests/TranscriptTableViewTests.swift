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

    /// An older page lands below the loading row at the top. Holding that row still would move
    /// every message under it by a page; the reader's message must stay put instead.
    @Test func anOlderPageBelowTheLoadingRowLeavesTheReadersMessageInPlace() {
        let harness = TranscriptTableHarness(rows: [.loadingOlder] + TableTestRow.range(100..<160))
        harness.request(.top(id: "loading-older", inset: 0))
        let before = harness.offset(of: "row-101")

        harness.set(rows: [.loadingOlder] + TableTestRow.range(50..<160))

        #expect(before != nil)
        #expect(harness.offset(of: "row-101") == before)
    }

    /// A row resized from inside (a GIF adopting its decoded aspect ratio) changes no row value, so
    /// the cell's own reported height must reach the table, with the reader's row held still.
    @Test func aRowGrowingFromInsideGetsItsNewHeight() {
        let harness = TranscriptTableHarness(rows: TableTestRow.range(0..<80))
        harness.request(.top(id: "row-20", inset: 0))
        let before = harness.offset(of: "row-20")
        let heightBefore = harness.height(of: "row-22")

        harness.model.innerGrowth["row-22"] = 120
        // The cell reports its new height after it re-renders, and the table re-heights the row
        // on the turn after that.
        harness.settle(until: { harness.height(of: "row-22") != heightBefore })

        #expect(before != nil)
        #expect(harness.height(of: "row-22").map { $0 - (heightBefore ?? 0) } == 120)
        #expect(harness.offset(of: "row-20") == before)
    }

    /// Hosted media decides when to download from its cell's visibility, which SwiftUI cannot
    /// supply inside an AppKit scroll view; the table must report it for every hosted cell.
    /// A width change must not replace a visible row's live height with the sizing host's, which
    /// lacks the cell's own state (a decoded GIF would snap back to its placeholder).
    @Test func aVisibleRowKeepsItsLiveHeightAcrossAWidthChange() {
        let harness = TranscriptTableHarness(rows: TableTestRow.range(0..<80))
        harness.request(.top(id: "row-20", inset: 0))
        let measured = harness.height(of: "row-22")
        harness.model.liveOnlyGrowth = ["row-22"]
        harness.settle(until: { harness.height(of: "row-22") != measured })
        let live = harness.height(of: "row-22")

        harness.resize(width: 440)

        #expect(live.map { $0 - (measured ?? 0) } == 50)
        #expect(harness.height(of: "row-22") == live)
    }

    /// A row value change that does not resize the content (a delivery tick, a reaction count on
    /// another row's message, selection mode) must not swap a live cell's height for the sizing
    /// host's: the cell's natural height is unchanged, so it would never report the correction.
    @Test func aVisibleRowKeepsItsLiveHeightAcrossAValueChange() {
        let harness = TranscriptTableHarness(rows: TableTestRow.range(0..<80))
        harness.request(.top(id: "row-20", inset: 0))
        let measured = harness.height(of: "row-22")
        harness.model.liveOnlyGrowth = ["row-22"]
        harness.settle(until: { harness.height(of: "row-22") != measured })
        let live = harness.height(of: "row-22")

        harness.set(rows: TableTestRow.range(0..<80).map { $0.index == 22 ? $0.touched() : $0 })

        #expect(live.map { $0 - (measured ?? 0) } == 50)
        #expect(harness.height(of: "row-22") == live)
    }

    /// A value change that does resize a live row reaches the table through the cell's report.
    @Test func aVisibleRowValueChangeThatResizesItIsAdopted() {
        let harness = TranscriptTableHarness(rows: TableTestRow.range(0..<80))
        harness.request(.top(id: "row-20", inset: 0))
        let before = harness.offset(of: "row-20")
        let heightBefore = harness.height(of: "row-22")

        harness.set(rows: TableTestRow.range(0..<80).map { $0.index == 22 ? $0.growing(by: 3) : $0 })
        harness.settle(until: { harness.height(of: "row-22") != heightBefore })

        #expect(harness.height(of: "row-22").map { $0 > (heightBefore ?? 0) } == true)
        #expect(harness.offset(of: "row-20") == before)
    }

    @Test func cellsReportWhetherTheyAreOnScreen() {
        let harness = TranscriptTableHarness(rows: TableTestRow.range(0..<120))
        harness.request(.bottom)
        #expect(harness.cellVisibilityMatchesViewport)

        harness.request(.top(id: "row-10", inset: 0))
        #expect(harness.cellVisibilityMatchesViewport)
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
    var isChrome = false
    /// Changes the row's value without changing what it draws.
    var revision = 0
    var id: String { isChrome ? "loading-older" : "row-\(index)" }

    static let loadingOlder = TableTestRow(index: -1, lines: 1, isChrome: true)

    func growing(by extraLines: Int) -> TableTestRow {
        TableTestRow(index: index, lines: lines + extraLines, isChrome: isChrome, revision: revision)
    }

    func touched() -> TableTestRow {
        TableTestRow(index: index, lines: lines, isChrome: isChrome, revision: revision + 1)
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
    /// Extra height a row's content grows by from inside, without its row value changing.
    var innerGrowth: [String: CGFloat] = [:]
    var liveOnlyGrowth: Set<String> = []
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
            anchorsPosition: { !$0.isChrome },
            cell: { row in
                HarnessRowContent(model: model, row: row)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        )
    }
}

/// Reads the inner growth in its own body, as a GIF's state lives inside its view, so the hosted
/// row observes it and resizes without its row value changing.
struct HarnessRowContent: View {
    @Environment(\.transcriptCellVisibility) private var cellVisibility
    let model: TranscriptTableHarnessModel
    let row: TableTestRow

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(0..<row.lines, id: \.self) { line in
                Text("Row \(row.index), line \(line)")
            }
            Color.clear.frame(height: model.innerGrowth[row.id] ?? 0)
        }
        // Height only a live cell has, as a GIF's decoded aspect lives in the hosted view's state
        // and never reaches the off-screen sizing host.
        .padding(.bottom, cellVisibility != nil && model.liveOnlyGrowth.contains(row.id) ? 50 : 0)
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

    var tableView: NSTableView? {
        Self.find(NSTableView.self, in: host)
    }

    func height(of id: String) -> CGFloat? {
        guard let tableView, let index = model.rows.firstIndex(where: { $0.id == id }) else { return nil }
        return tableView.rect(ofRow: index + 1).height
    }

    /// Whether each hosted cell's visibility matches whether its row is in the viewport.
    var cellVisibilityMatchesViewport: Bool {
        guard let tableView, let clip = tableView.enclosingScrollView?.contentView else { return false }
        let visible = tableView.rows(in: clip.bounds)
        var matches = true
        var checked = 0
        tableView.enumerateAvailableRowViews { rowView, row in
            guard let cell = rowView.view(atColumn: 0) as? TranscriptHostingCell else { return }
            checked += 1
            if cell.visibility.isVisible != NSLocationInRange(row, visible) { matches = false }
        }
        return matches && checked > 0
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

    func resize(width: CGFloat) {
        window.setContentSize(NSSize(width: width, height: host.frame.height))
        host.frame = NSRect(x: 0, y: 0, width: width, height: host.frame.height)
        settle()
    }

    /// Settles until `condition` holds, for at most about two seconds.
    func settle(until condition: () -> Bool) {
        for _ in 0..<100 where !condition() {
            host.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
        settle()
    }

    private static func find<T: NSView>(_ type: T.Type, in view: NSView) -> T? {
        if let match = view as? T { return match }
        for subview in view.subviews {
            if let found = find(type, in: subview) { return found }
        }
        return nil
    }
}
