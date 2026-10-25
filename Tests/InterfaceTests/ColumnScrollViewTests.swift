import AppKit
import Testing

@testable import Interface

/// A view that records the scroll events it gets, as their horizontal deltas.
@MainActor
private final class SidewaysLog: NSView {
    var deltas: [Double] = []
    override func scrollWheel(with event: NSEvent) { deltas.append(event.scrollingDeltaX) }
}

/// A column's scroll view, 100 points wide, in a view standing in for the columns' scroll view,
/// holding a one-column table of 40 rows.
@MainActor
private func column(in columns: NSView) -> (ColumnScrollView, NSTableView) {
    let scrollView = ColumnScrollView(frame: NSRect(x: 0, y: 0, width: 100, height: 200))
    let table = NSTableView()
    let tableColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("name"))
    tableColumn.minWidth = 40
    tableColumn.width = 260
    tableColumn.resizingMask = .autoresizingMask
    table.addTableColumn(tableColumn)
    table.headerView = nil
    table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
    scrollView.documentView = table
    scrollView.hasVerticalScroller = true
    columns.addSubview(scrollView)
    scrollView.layoutSubtreeIfNeeded()
    return (scrollView, table)
}

/// A sideways trackpad gesture over a column, and its momentum, go up to the columns' scroll
/// view, so the browser scrolls, as in Finder; a vertical one stays in the column, and so does
/// a sideways drift once it has started. A mouse wheel's sideways click goes up on its own.
@MainActor @Test func aSidewaysScrollOverAColumnGoesUpToTheColumns() throws {
    let columns = SidewaysLog()
    let (scrollView, _) = column(in: columns)

    for event in [
        try scrollEvent(phase: .mayBegin), try scrollEvent(dx: 10, phase: .began),
        try scrollEvent(dx: 4, dy: 6, phase: .changed), try scrollEvent(phase: .ended),
        try scrollEvent(dx: 3, momentum: .begin), try scrollEvent(momentum: .end),
    ] {
        scrollView.scrollWheel(with: event)
    }
    #expect(columns.deltas == [10, 4, 0, 3, 0])

    columns.deltas = []
    for event in [
        try scrollEvent(dy: 10, phase: .began), try scrollEvent(dx: 8, dy: 1, phase: .changed),
        try scrollEvent(phase: .ended), try scrollEvent(dy: 3, momentum: .begin),
        try scrollEvent(momentum: .end),
    ] {
        scrollView.scrollWheel(with: event)
    }
    #expect(columns.deltas.isEmpty)

    scrollView.scrollWheel(with: try scrollEvent(dx: 5))
    scrollView.scrollWheel(with: try scrollEvent(dy: 5))
    #expect(columns.deltas == [5])
}

/// A column has no horizontal scroller or sideways bounce, and its clip stays at the table's
/// left edge whatever asks it to move.
@MainActor @Test func aColumnCannotScrollSideways() {
    let (scrollView, table) = column(in: NSView())
    #expect(!scrollView.hasHorizontalScroller)
    #expect(scrollView.horizontalScrollElasticity == .none)

    table.tableColumns[0].width = 2000
    scrollView.contentView.scroll(to: NSPoint(x: 300, y: 0))
    #expect(scrollView.contentView.bounds.minX == 0)
    scrollView.contentView.setBoundsOrigin(NSPoint(x: 300, y: 0))
    #expect(scrollView.contentView.bounds.minX == 0)
}

/// A table column set wider than the column comes back to its visible width once the column is
/// resized, and so it does when a legacy vertical scroller takes room: the table is exactly as
/// wide as what shows of it.
@MainActor @Test func aColumnsTableAlwaysFillsItsVisibleWidth() {
    let (scrollView, table) = column(in: NSView())
    #expect(table.frame.width == scrollView.contentView.bounds.width)

    table.tableColumns[0].width = 2000
    scrollView.setFrameSize(NSSize(width: 150, height: 200))
    scrollView.layoutSubtreeIfNeeded()
    #expect(table.frame.width == scrollView.contentView.bounds.width)
    #expect(scrollView.contentView.bounds.width == 150)

    scrollView.scrollerStyle = .legacy
    scrollView.layoutSubtreeIfNeeded()
    #expect(table.frame.width == scrollView.contentView.bounds.width)
    #expect(scrollView.contentView.bounds.width < 150)
}
