import AppKit
import SwiftUI

/// Where a `TranscriptTableView` should put a row when asked to scroll.
nonisolated enum TranscriptScrollTarget: Equatable {
    /// The foot of the transcript.
    case bottom
    /// A row's top edge `inset` points below the viewport's top edge.
    case top(id: String, inset: CGFloat)
    /// A row centred in the viewport.
    case center(id: String)
}

/// A one-shot scroll command. A new `id` makes the same target apply again.
nonisolated struct TranscriptScrollRequest: Equatable {
    let id = UUID()
    let target: TranscriptScrollTarget
}

/// What the transcript reports after it scrolls or its rows change: the rows on screen, in order,
/// and whether the viewport reaches the foot of the content.
nonisolated struct TranscriptViewport: Equatable {
    let visibleRowIds: [String]
    let isAtBottom: Bool
}

/// The chat transcript as an `NSTableView` hosting SwiftUI rows.
///
/// SwiftUI's `LazyVStack` keeps no row heights: it estimates rows it has not built and corrects
/// them on screen, so scrolling back through variable-height rows reflowed what the reader was
/// looking at and could spin the main thread for seconds (whitenoise-mac#205, and the scroll-up
/// hang the unread-divider work hit). A table view gives the transcript what native chat
/// timelines rely on:
///
/// - **Measured once, cached.** Each row is measured at the column width in one off-screen
///   `NSHostingView` the first time the table asks for its height, and cached against the row's
///   value and that width. A row whose content changes, or a new width, is a miss.
/// - **The reader stays put.** Before rows change, the coordinator records the first visible row
///   and its offset; after the table reloads, it moves the scroll origin so that row sits exactly
///   where it was, in the same pass, before anything draws. Older pages, edits above, and late
///   corrections therefore never move what is on screen. While following the live edge it pins
///   the foot instead.
/// - **Only visible rows are hosted.** Cells are reused, and while the window is being resized only
///   visible rows are re-measured; the rest catch up when the resize ends, under the same anchor.
struct TranscriptTableView<Row: Identifiable & Equatable, Cell: View>: NSViewRepresentable
where Row.ID == String {
    let rows: [Row]
    /// Applied once per request `id`, after the rows of the same update.
    let scrollRequest: TranscriptScrollRequest?
    /// Whether the transcript should stay pinned to its foot when content changes while the
    /// reader is there. False keeps the top visible row where it is instead.
    let followsBottom: Bool
    let onViewportChanged: (TranscriptViewport) -> Void
    let onLiveScrollChanged: (Bool) -> Void
    let onScrollRequestApplied: (UUID) -> Void
    @ViewBuilder let cell: (Row) -> Cell

    func makeCoordinator() -> TranscriptTableCoordinator<Row, Cell> {
        TranscriptTableCoordinator()
    }

    func makeNSView(context: Context) -> NSScrollView {
        let coordinator = context.coordinator
        coordinator.configuration = self
        let tableView = TranscriptNSTableView()
        tableView.headerView = nil
        tableView.style = .plain
        tableView.backgroundColor = .clear
        tableView.selectionHighlightStyle = .none
        tableView.intercellSpacing = .zero
        tableView.gridStyleMask = []
        tableView.usesAutomaticRowHeights = false
        tableView.allowsColumnReordering = false
        tableView.allowsColumnResizing = false
        tableView.focusRingType = .none
        tableView.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        let column = NSTableColumn(identifier: TranscriptTableCoordinator<Row, Cell>.columnIdentifier)
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)
        tableView.dataSource = coordinator
        tableView.delegate = coordinator
        tableView.onLiveResizeEnded = { [weak coordinator] in coordinator?.liveResizeEnded() }

        let scrollView = NSScrollView()
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.documentView = tableView
        scrollView.contentView.postsBoundsChangedNotifications = true
        coordinator.attach(scrollView: scrollView, tableView: tableView)
        coordinator.apply(rows: rows, followsBottom: followsBottom, scrollRequest: scrollRequest)
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        let coordinator = context.coordinator
        coordinator.configuration = self
        coordinator.apply(rows: rows, followsBottom: followsBottom, scrollRequest: scrollRequest)
    }

    static func dismantleNSView(_ scrollView: NSScrollView, coordinator: TranscriptTableCoordinator<Row, Cell>) {
        coordinator.detach()
    }
}

/// Reports the end of a live resize, so off-screen rows can be re-measured once rather than on
/// every frame of the drag.
final class TranscriptNSTableView: NSTableView {
    var onLiveResizeEnded: (() -> Void)?

    override func viewDidEndLiveResize() {
        super.viewDidEndLiveResize()
        onLiveResizeEnded?()
    }

    // The transcript is not a selectable list; clicks belong to the rows' own controls.
    override func validateProposedFirstResponder(_ responder: NSResponder, for event: NSEvent?) -> Bool {
        true
    }
}

/// A reusable cell hosting one SwiftUI row.
final class TranscriptHostingCell: NSTableCellView {
    let host = NSHostingView(rootView: AnyView(EmptyView()))

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        host.translatesAutoresizingMaskIntoConstraints = false
        // The table owns row heights; the hosted view fills whatever the row is given.
        host.sizingOptions = []
        addSubview(host)
        NSLayoutConstraint.activate([
            host.leadingAnchor.constraint(equalTo: leadingAnchor),
            host.trailingAnchor.constraint(equalTo: trailingAnchor),
            host.topAnchor.constraint(equalTo: topAnchor),
            host.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }
}

@MainActor
final class TranscriptTableCoordinator<Row: Identifiable & Equatable, Cell: View>: NSObject,
    NSTableViewDataSource, NSTableViewDelegate
where Row.ID == String {
    static var columnIdentifier: NSUserInterfaceItemIdentifier { NSUserInterfaceItemIdentifier("transcript") }
    private static var cellIdentifier: NSUserInterfaceItemIdentifier {
        NSUserInterfaceItemIdentifier("transcript-cell")
    }

    var configuration: TranscriptTableView<Row, Cell>?
    private weak var scrollView: NSScrollView?
    private weak var tableView: NSTableView?
    private var rows: [Row] = []
    /// Table row 0 is a filler that keeps a short transcript at the foot of the viewport, as a
    /// chat should be; data rows start at 1.
    private static var fillerRow: Int { 0 }
    private var heights: [String: CachedHeight] = [:]
    private let sizingHost = NSHostingView(rootView: AnyView(EmptyView()))
    private var appliedRequestId: UUID?
    private var followsBottom = false
    private var isAtBottom = false
    private var lastViewport: TranscriptViewport?
    private var measuredWidth: CGFloat = 0
    private var observers: [NSObjectProtocol] = []

    private struct CachedHeight {
        let row: Row
        let width: CGFloat
        let height: CGFloat
    }

    private struct Anchor {
        let id: String
        let offset: CGFloat
    }

    func attach(scrollView: NSScrollView, tableView: NSTableView) {
        self.scrollView = scrollView
        self.tableView = tableView
        let center = NotificationCenter.default
        observers.append(
            center.addObserver(
                forName: NSView.boundsDidChangeNotification,
                object: scrollView.contentView,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.viewportMoved() }
            })
        observers.append(
            center.addObserver(
                forName: NSView.frameDidChangeNotification,
                object: scrollView.contentView,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.containerResized() }
            })
        observers.append(
            center.addObserver(
                forName: NSScrollView.willStartLiveScrollNotification,
                object: scrollView,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.report { $0.onLiveScrollChanged(true) } }
            })
        observers.append(
            center.addObserver(
                forName: NSScrollView.didEndLiveScrollNotification,
                object: scrollView,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.report { $0.onLiveScrollChanged(false) } }
            })
        scrollView.contentView.postsFrameChangedNotifications = true
    }

    func detach() {
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
    }

    // MARK: Data

    func apply(rows newRows: [Row], followsBottom: Bool, scrollRequest: TranscriptScrollRequest?) {
        self.followsBottom = followsBottom
        guard let tableView else { return }
        if newRows != rows {
            let sameIds = newRows.count == rows.count && zip(newRows, rows).allSatisfy { $0.id == $1.id }
            let pinnedToBottom = isAtBottom && followsBottom
            let anchor = pinnedToBottom ? nil : currentAnchor()
            if sameIds {
                let changed = IndexSet(newRows.indices.filter { newRows[$0] != rows[$0] }.map { $0 + 1 })
                rows = newRows
                for tableRow in changed {
                    if let cell = tableView.view(atColumn: 0, row: tableRow, makeIfNecessary: false)
                        as? TranscriptHostingCell
                    {
                        configure(cell, row: rows[tableRow - 1])
                    }
                }
                tableView.noteHeightOfRows(withIndexesChanged: changed.union(IndexSet(integer: Self.fillerRow)))
            } else {
                rows = newRows
                let liveIds = Set(rows.map(\.id))
                heights = heights.filter { liveIds.contains($0.key) }
                tableView.reloadData()
            }
            tableView.layoutSubtreeIfNeeded()
            if pinnedToBottom {
                scrollToBottom()
            } else if let anchor {
                restore(anchor)
            }
        }
        if let scrollRequest, scrollRequest.id != appliedRequestId {
            appliedRequestId = scrollRequest.id
            tableView.layoutSubtreeIfNeeded()
            perform(scrollRequest.target)
            let id = scrollRequest.id
            report { $0.onScrollRequestApplied(id) }
        }
        viewportMoved()
    }

    // MARK: NSTableViewDataSource / NSTableViewDelegate

    func numberOfRows(in tableView: NSTableView) -> Int {
        rows.count + 1
    }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        if row == Self.fillerRow {
            let content = rows.reduce(CGFloat(0)) { $0 + height(of: $1) }
            return max(1, (scrollView?.contentView.bounds.height ?? 0) - content)
        }
        return height(of: rows[row - 1])
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard row != Self.fillerRow else { return NSView() }
        let cell =
            tableView.makeView(withIdentifier: Self.cellIdentifier, owner: nil) as? TranscriptHostingCell
            ?? {
                let cell = TranscriptHostingCell()
                cell.identifier = Self.cellIdentifier
                return cell
            }()
        configure(cell, row: rows[row - 1])
        return cell
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        false
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        let rowView = NSTableRowView()
        rowView.isGroupRowStyle = false
        rowView.selectionHighlightStyle = .none
        return rowView
    }

    private func configure(_ cell: TranscriptHostingCell, row: Row) {
        guard let configuration else { return }
        cell.host.rootView = AnyView(configuration.cell(row))
    }

    // MARK: Heights

    private var columnWidth: CGFloat {
        tableView?.tableColumns.first?.width ?? scrollView?.contentView.bounds.width ?? 0
    }

    /// The row's height at the current column width, measured once and cached. While the window
    /// is being resized only rows on screen are re-measured; others keep their last height until
    /// the resize ends.
    private func height(of row: Row) -> CGFloat {
        let width = columnWidth
        if let cached = heights[row.id], cached.row == row {
            if cached.width == width { return cached.height }
            if tableView?.inLiveResize == true, !isVisible(row.id) { return cached.height }
        }
        let measured = measure(row, width: width)
        heights[row.id] = CachedHeight(row: row, width: width, height: measured)
        return measured
    }

    private func measure(_ row: Row, width: CGFloat) -> CGFloat {
        guard let configuration, width > 0 else { return 1 }
        // Fixing the content's width makes `fittingSize` report its height at that width.
        sizingHost.rootView = AnyView(configuration.cell(row).frame(width: width))
        return max(1, ceil(sizingHost.fittingSize.height))
    }

    private func isVisible(_ id: String) -> Bool {
        lastViewport?.visibleRowIds.contains(id) ?? false
    }

    private func containerResized() {
        guard let tableView else { return }
        let width = columnWidth
        let pinnedToBottom = isAtBottom && followsBottom
        let anchor = pinnedToBottom ? nil : currentAnchor()
        if width != measuredWidth {
            measuredWidth = width
            tableView.noteHeightOfRows(withIndexesChanged: IndexSet(integersIn: 0..<tableView.numberOfRows))
        } else {
            tableView.noteHeightOfRows(withIndexesChanged: IndexSet(integer: Self.fillerRow))
        }
        tableView.layoutSubtreeIfNeeded()
        if pinnedToBottom {
            scrollToBottom()
        } else if let anchor {
            restore(anchor)
        }
    }

    func liveResizeEnded() {
        guard let tableView else { return }
        let pinnedToBottom = isAtBottom && followsBottom
        let anchor = pinnedToBottom ? nil : currentAnchor()
        tableView.noteHeightOfRows(withIndexesChanged: IndexSet(integersIn: 0..<tableView.numberOfRows))
        tableView.layoutSubtreeIfNeeded()
        if pinnedToBottom {
            scrollToBottom()
        } else if let anchor {
            restore(anchor)
        }
    }

    // MARK: Scrolling

    private func currentAnchor() -> Anchor? {
        guard let tableView, let scrollView, !rows.isEmpty else { return nil }
        let visible = scrollView.contentView.bounds
        let range = tableView.rows(in: visible)
        guard range.length > 0 else { return nil }
        for tableRow in range.location..<(range.location + range.length) where tableRow != Self.fillerRow {
            let rect = tableView.rect(ofRow: tableRow)
            if rect.maxY > visible.minY {
                return Anchor(id: rows[tableRow - 1].id, offset: rect.minY - visible.minY)
            }
        }
        return nil
    }

    private func restore(_ anchor: Anchor) {
        guard let tableView, let index = rows.firstIndex(where: { $0.id == anchor.id }) else { return }
        scroll(toY: tableView.rect(ofRow: index + 1).minY - anchor.offset)
    }

    private func perform(_ target: TranscriptScrollTarget) {
        guard let tableView, let scrollView else { return }
        switch target {
        case .bottom:
            scrollToBottom()
        case .top(let id, let inset):
            guard let index = rows.firstIndex(where: { $0.id == id }) else { return }
            scroll(toY: tableView.rect(ofRow: index + 1).minY - inset)
        case .center(let id):
            guard let index = rows.firstIndex(where: { $0.id == id }) else { return }
            let rect = tableView.rect(ofRow: index + 1)
            scroll(toY: rect.midY - scrollView.contentView.bounds.height / 2)
        }
    }

    private func scrollToBottom() {
        guard let tableView, let scrollView else { return }
        scroll(toY: tableView.bounds.height - scrollView.contentView.bounds.height)
    }

    private func scroll(toY y: CGFloat) {
        guard let tableView, let scrollView else { return }
        let maxY = max(0, tableView.bounds.height - scrollView.contentView.bounds.height)
        let clamped = min(max(0, y), maxY)
        scrollView.contentView.scroll(to: NSPoint(x: 0, y: clamped))
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    private func viewportMoved() {
        guard let tableView, let scrollView else { return }
        let visible = scrollView.contentView.bounds
        let range = tableView.rows(in: visible)
        var ids: [String] = []
        if range.length > 0 {
            for tableRow in range.location..<(range.location + range.length) where tableRow != Self.fillerRow {
                guard tableRow - 1 < rows.count else { continue }
                ids.append(rows[tableRow - 1].id)
            }
        }
        isAtBottom = tableView.bounds.height - visible.maxY <= 2
        let viewport = TranscriptViewport(visibleRowIds: ids, isAtBottom: isAtBottom)
        guard viewport != lastViewport else { return }
        lastViewport = viewport
        report { $0.onViewportChanged(viewport) }
    }

    /// Hands a report to the SwiftUI side on the next main-queue turn. Reports raised while the
    /// table applies an update (including the bounds change its own scroll causes) would
    /// otherwise write SwiftUI state during a view update; the main queue keeps them in order.
    private func report(_ send: @escaping (TranscriptTableView<Row, Cell>) -> Void) {
        DispatchQueue.main.async { [weak self] in
            guard let configuration = self?.configuration else { return }
            send(configuration)
        }
    }

    func tableViewColumnDidResize(_ notification: Notification) {
        containerResized()
    }
}

#Preview {
    struct PreviewRow: Identifiable, Equatable {
        let id: String
        let text: String
    }
    let rows = (0..<40).map { index in
        PreviewRow(
            id: "row-\(index)",
            text: String(repeating: "Message \(index). ", count: 1 + index % 6)
        )
    }
    return TranscriptTableView(
        rows: rows,
        scrollRequest: TranscriptScrollRequest(target: .bottom),
        followsBottom: true,
        onViewportChanged: { _ in },
        onLiveScrollChanged: { _ in },
        onScrollRequestApplied: { _ in },
        cell: { row in
            Text(row.text)
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    )
    .frame(width: 480, height: 480)
}
