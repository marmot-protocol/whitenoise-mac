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

/// Whether a transcript cell is on screen. A cell's `NSHostingView` sits in an AppKit scroll view,
/// so SwiftUI's `onScrollVisibilityChange` never fires inside it; the table reports each cell's
/// visibility through this object instead. Read through `onTranscriptVisibilityChange`.
@MainActor
@Observable
final class TranscriptCellVisibility {
    var isVisible = false
}

extension EnvironmentValues {
    /// The hosting table cell's visibility, when the view is inside one.
    @Entry var transcriptCellVisibility: TranscriptCellVisibility? = nil
}

/// `onScrollVisibilityChange` for views that may be hosted in a transcript table cell: inside a
/// cell it follows the table's report of that cell, elsewhere SwiftUI's scroll visibility. The
/// table's off-screen sizing host has neither, so measuring a row never starts its downloads.
struct TranscriptVisibilityChangeModifier: ViewModifier {
    @Environment(\.transcriptCellVisibility) private var cellVisibility
    let threshold: Double
    let action: (Bool) -> Void

    func body(content: Content) -> some View {
        if let cellVisibility {
            content.onChange(of: cellVisibility.isVisible, initial: true) { _, isVisible in
                action(isVisible)
            }
        } else {
            content.onScrollVisibilityChange(threshold: threshold, action)
        }
    }
}

extension View {
    func onTranscriptVisibilityChange(threshold: Double = 0.01, _ action: @escaping (Bool) -> Void) -> some View {
        modifier(TranscriptVisibilityChangeModifier(threshold: threshold, action: action))
    }
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
    /// Whether a row may anchor the reader's position. Chrome that does not travel with the
    /// messages (loading indicators, the foot) must not: an older page lands below a loading row,
    /// so holding that row still would move every message under it.
    var anchorsPosition: (Row) -> Bool = { _ in true }
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
    let visibility = TranscriptCellVisibility()
    /// The row this cell currently hosts.
    var rowId: String?

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
    /// Rows that currently have a cell in the table, kept from the table's add/remove callbacks:
    /// AppKit forbids asking the table for a row's view from inside `heightOfRow`.
    private var liveCellIds: Set<String> = []
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

    /// Hosts the row in a reused cell. The content takes the row's identity, so a cell recycled for
    /// another message starts fresh (its `@State`, `onAppear`/`onDisappear`) rather than carrying
    /// the previous message's. It is laid out at its natural height and reports that height:
    /// anything that resizes a row from inside, such as a GIF adopting its decoded aspect ratio,
    /// reaches the height cache that way, since the row's value does not change.
    private func configure(_ cell: TranscriptHostingCell, row: Row) {
        guard let configuration else { return }
        let id = row.id
        if let previous = cell.rowId, previous != id, cell.superview != nil {
            liveCellIds.remove(previous)
            liveCellIds.insert(id)
        }
        cell.rowId = id
        cell.host.rootView = AnyView(
            configuration.cell(row)
                .fixedSize(horizontal: false, vertical: true)
                .onGeometryChange(for: CGFloat.self) { proxy in
                    proxy.size.height
                } action: { [weak self] height in
                    self?.cellReported(height: height, for: id)
                }
                .frame(maxHeight: .infinity, alignment: .top)
                .id(id)
                .environment(\.transcriptCellVisibility, cell.visibility)
        )
    }

    /// A visible cell's natural height differs from the cached one: adopt it and re-height the
    /// row on the next turn, under the same anchor or foot pin as any other change.
    private func cellReported(height: CGFloat, for id: String) {
        let height = max(1, ceil(height))
        guard let cached = heights[id] else { return }
        let width = columnWidth
        guard abs(cached.height - height) > 0.5 else {
            if cached.width != width {
                heights[id] = CachedHeight(row: cached.row, width: width, height: cached.height)
            }
            return
        }
        heights[id] = CachedHeight(row: cached.row, width: width, height: height)
        // Next run-loop turn: outside the geometry callback that reported it, so the table does not
        // re-tile in the middle of SwiftUI's update.
        // Deliberately not `DispatchQueue.main.async`: a run-loop block also runs inside a nested
        // run loop, which a main-queue block does not while another main-queue job is running.
        RunLoop.main.perform { [weak self] in
            MainActor.assumeIsolated { self?.reheightRow(id: id) }
        }
    }

    private func reheightRow(id: String) {
        guard let tableView, let index = rows.firstIndex(where: { $0.id == id }) else { return }
        let pinnedToBottom = isAtBottom && followsBottom
        let anchor = pinnedToBottom ? nil : currentAnchor()
        tableView.noteHeightOfRows(withIndexesChanged: IndexSet([Self.fillerRow, index + 1]))
        tableView.layoutSubtreeIfNeeded()
        if pinnedToBottom {
            scrollToBottom()
        } else if let anchor {
            restore(anchor)
        }
    }

    // MARK: Heights

    private var columnWidth: CGFloat {
        tableView?.tableColumns.first?.width ?? scrollView?.contentView.bounds.width ?? 0
    }

    /// The row's height at the current column width, measured once and cached. After a width
    /// change, a row with a live cell keeps its height until that cell reports its natural height
    /// at the new width (`cellReported`): the cell knows state the off-screen sizing host does not,
    /// such as a GIF's decoded aspect ratio, which a fresh measurement would reset. During a live
    /// resize, off-screen rows keep their last height until the resize ends.
    private func height(of row: Row) -> CGFloat {
        let width = columnWidth
        if let cached = heights[row.id], cached.row == row {
            if cached.width == width || liveCellIds.contains(row.id) { return cached.height }
            if tableView?.inLiveResize == true, !isVisible(row.id) { return cached.height }
        }
        let measured = measure(row, width: width)
        heights[row.id] = CachedHeight(row: row, width: width, height: measured)
        return measured
    }

    private func measure(_ row: Row, width: CGFloat) -> CGFloat {
        guard let configuration, width > 0 else { return 1 }
        // Fixing the content's width makes `fittingSize` report its height at that width.
        sizingHost.rootView = AnyView(configuration.cell(row).frame(width: width).id(row.id))
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
        let anchorsPosition = configuration?.anchorsPosition ?? { _ in true }
        var fallback: Anchor?
        for tableRow in range.location..<(range.location + range.length) where tableRow != Self.fillerRow {
            let rect = tableView.rect(ofRow: tableRow)
            guard rect.maxY > visible.minY, tableRow - 1 < rows.count else { continue }
            let row = rows[tableRow - 1]
            let anchor = Anchor(id: row.id, offset: rect.minY - visible.minY)
            if anchorsPosition(row) { return anchor }
            if fallback == nil { fallback = anchor }
        }
        return fallback
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
        updateCellVisibility(visibleRange: range)
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

    /// Marks each hosted cell visible or not, writing only on change so a cell's media views are
    /// told once when it enters or leaves the viewport.
    private func updateCellVisibility(visibleRange: NSRange) {
        tableView?.enumerateAvailableRowViews { rowView, tableRow in
            guard let cell = rowView.view(atColumn: 0) as? TranscriptHostingCell else { return }
            let isVisible = NSLocationInRange(tableRow, visibleRange)
            if cell.visibility.isVisible != isVisible { cell.visibility.isVisible = isVisible }
        }
    }

    func tableView(_ tableView: NSTableView, didAdd rowView: NSTableRowView, forRow row: Int) {
        guard let cell = rowView.view(atColumn: 0) as? TranscriptHostingCell, let id = cell.rowId else { return }
        liveCellIds.insert(id)
    }

    func tableView(_ tableView: NSTableView, didRemove rowView: NSTableRowView, forRow row: Int) {
        guard let cell = rowView.view(atColumn: 0) as? TranscriptHostingCell else { return }
        if let id = cell.rowId { liveCellIds.remove(id) }
        if cell.visibility.isVisible { cell.visibility.isVisible = false }
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
