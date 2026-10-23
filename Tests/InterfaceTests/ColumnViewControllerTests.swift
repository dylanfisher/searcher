import AppKit
import Base
import Foundation
import TestSupport
import Testing

@testable import Browser
@testable import Interface

/// `/r` holds a folder `docs`, a folder `other` and a file `a.txt`; `/r/docs` holds a folder
/// `sub` and a file `x.txt`; `/r/docs/sub` holds two FLAC files.
private let tree: [String: [DirectoryEntry]] = [
    "/": [folder("r")],
    "/r": [folder("docs"), folder("other"), file("a.txt")],
    "/r/docs": [folder("sub"), file("x.txt")],
    "/r/docs/sub": [file("one.flac"), file("two.flac")],
    "/r/other": [file("o.txt")],
]

/// A pane at `/r` in column mode, shown by a column view that is never put in a window, `width`
/// points wide, with its first column loaded. The pane's changes reach the view as
/// `PaneViewController` passes them on.
@MainActor
private struct Fixture {
    let pane: Pane
    let controller: ColumnViewController

    init(width: Double = 800, iconCache: TypeIconCache = TypeIconCache { _ in NSImage() }) async {
        pane = Pane(
            location: Location(path: "/r"),
            service: ListingService(lister: StubLister(tree), rootVolumeName: { "Test Disk" }),
            systemActions: StubSystemActions(), settings: untouchedSettings(), isFocused: true,
            viewMode: .column)
        let controller = ColumnViewController(pane: pane, iconCache: iconCache, formatter: .init())
        controller.startMonitor = { _ in }
        self.controller = controller
        pane.onChange = { [weak controller] in controller?.paneDidChange() }
        controller.view.frame = NSRect(x: 0, y: 0, width: width, height: 400)
        controller.view.layoutSubtreeIfNeeded()
        await settle { trail.focused.pane.state.isLoaded }
    }

    var trail: ColumnTrail {
        guard let trail = pane.columnTrail else {
            preconditionFailure("the pane isn't in column mode")
        }
        return trail
    }

    var tables: [ListingTableView] { controller.columnControllers.map(\.tableView) }

    /// Selects `name` alone in the column at `index`, as a click or a key does, and waits for the
    /// column it opens to load.
    func select(_ name: String, inColumn index: Int) async {
        let pane = trail.columns[index].pane
        pane.select(Selection([ExactName(name)], cursor: ExactName(name)))
        await settle { trail.columns.allSatisfy { $0.pane.state.isLoaded } }
    }

    /// Opens `/r/docs/sub` in three columns, the first one focused.
    func openThreeColumns() async {
        await select("docs", inColumn: 0)
        await select("sub", inColumn: 1)
    }
}

@MainActor @Test func aThreeColumnTrailShowsThreeSingleColumnTablesWithItsRowsAndSelection()
    async throws
{
    let fixture = await Fixture()

    await fixture.openThreeColumns()

    #expect(fixture.tables.count == 3)
    for (column, table) in zip(fixture.trail.columns, fixture.tables) {
        let listing = try #require(column.pane.state.listing)
        #expect(table.numberOfRows == listing.count)
        #expect(table.selectedRowIndexes == column.pane.selection.rows(in: listing))
        #expect(table.tableColumns.count == 1)
        #expect(table.headerView == nil)
    }
    #expect(rowNames(fixture.tables[2]) == ["one.flac", "two.flac"])
    // a.txt, docs, other.
    #expect(fixture.tables[0].selectedRowIndexes == [1])
    #expect(fixture.tables[1].selectedRowIndexes == [0])
    #expect(fixture.tables[2].selectedRowIndexes == [])
}

@MainActor @Test func selectingAFolderAddsItsColumnAndDropsTheColumnsRightOfIt() async throws {
    let fixture = await Fixture()
    await fixture.openThreeColumns()
    let first = fixture.tables[0]

    await fixture.select("other", inColumn: 0)

    #expect(fixture.tables.count == 2)
    #expect(fixture.tables[0] === first)
    #expect(rowNames(fixture.tables[1]) == ["o.txt"])
    #expect(fixture.controller.columnControllers.allSatisfy { $0.view.superview != nil })

    await fixture.select("a.txt", inColumn: 0)

    #expect(fixture.tables.count == 1)
    #expect(fixture.tables[0] === first)
}

@MainActor @Test func theFocusedColumnIsScrolledIntoViewWhenArrowsMovePastTheEdge() async throws {
    // Room for two columns.
    let fixture = await Fixture(width: ColumnViewController.columnWidth * 2 + 20)
    await fixture.openThreeColumns()
    let scrollView = try #require(fixture.controller.view as? NSScrollView)
    let third = fixture.controller.columnControllers[2].view
    #expect(!scrollView.documentVisibleRect.contains(third.frame))

    fixture.trail.moveRight()
    fixture.trail.moveRight()

    #expect(fixture.trail.focusedIndex == 2)
    #expect(scrollView.documentVisibleRect.contains(third.frame))

    fixture.trail.moveLeft()
    fixture.trail.moveLeft()

    let first = fixture.controller.columnControllers[0].view
    #expect(scrollView.documentVisibleRect.contains(first.frame))
}

@MainActor @Test func twoFlacFilesInAColumnShareOneIcon() async throws {
    let maker = IconMaker()
    let fixture = await Fixture(iconCache: TypeIconCache(makeIcon: maker.icon(for:)))
    await fixture.openThreeColumns()

    let controller = fixture.controller.columnControllers[2]
    let table = controller.tableView
    let icons = try (0..<2).map { row in
        let view = controller.tableView(table, viewFor: table.tableColumns[0], row: row)
        return try #require((view as? NSTableCellView)?.imageView?.image)
    }
    #expect(icons[0] === icons[1])
    #expect(maker.calls[.init(filenameExtension: "flac")!] == 1)
}

@MainActor @Test func eachColumnTellsItsPaneHowManyRowsFit() async throws {
    let fixture = await Fixture()
    await fixture.openThreeColumns()
    fixture.controller.view.layoutSubtreeIfNeeded()

    for column in fixture.trail.columns {
        #expect(column.pane.visibleRowCount > 5)
    }
}

@MainActor @Test func eachColumnStartsAMonitorForItsOwnPaneOnce() async throws {
    let pane = Pane(
        location: Location(path: "/r"), service: ListingService(lister: StubLister(tree)),
        systemActions: StubSystemActions(), settings: untouchedSettings(), isFocused: true,
        viewMode: .column)
    var started: [Pane] = []
    let controller = ColumnViewController(
        pane: pane, iconCache: TypeIconCache { _ in NSImage() }, formatter: .init())
    controller.startMonitor = { started.append($0) }
    pane.onChange = { [weak controller] in controller?.paneDidChange() }
    let trail = try #require(pane.columnTrail)
    await settle { trail.focused.pane.state.isLoaded }

    trail.focused.pane.select(Selection([ExactName("docs")], cursor: ExactName("docs")))
    await settle { trail.columns.allSatisfy { $0.pane.state.isLoaded } }

    #expect(started.count == 2)
    #expect(started.map(\.location.path) == ["/r", "/r/docs"])
    #expect(zip(started, trail.columns).allSatisfy { $0 === $1.pane })
}

/// A column shows names only, so the parts of the row label the list reads from its other
/// columns come from the entry.
@MainActor @Test func aColumnRowsLabelReadsItsNameKindSizeAndDate() async throws {
    let fixture = await Fixture()
    await fixture.openThreeColumns()
    let table = fixture.tables[1]
    fixture.controller.view.layoutSubtreeIfNeeded()
    table.layoutSubtreeIfNeeded()

    let rowView = try #require(table.rowView(atRow: 1, makeIfNecessary: false))
    let label = try #require(rowView.accessibilityLabel())

    #expect(label.hasPrefix("x.txt, "))
    #expect(label.contains(", 1 byte, modified "))
}

@MainActor @Test func makingAColumnsTableFirstResponderFocusesItsColumn() async throws {
    let fixture = await Fixture()
    await fixture.openThreeColumns()
    let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 800, height: 400), styleMask: [.titled],
        backing: .buffered, defer: true)
    window.isReleasedWhenClosed = false
    window.contentView?.addSubview(fixture.controller.view)

    #expect(window.makeFirstResponder(fixture.tables[2]))

    #expect(fixture.trail.focusedIndex == 2)
    #expect(fixture.pane.location == Location(path: "/r/docs/sub"))
}

/// The views and children of the shown columns, and nothing else: a column, its separator and
/// its spinner each.
@MainActor
private func expectOnlyShownColumns(in controller: ColumnViewController) {
    let shown = controller.columnControllers
    #expect(controller.children.count == shown.count)
    #expect(zip(controller.children, shown).allSatisfy { $0 === $1 })
    let subviews = controller.columnsView.subviews
    #expect(subviews.count == shown.count * 3)
    #expect(subviews.filter { $0 is NSProgressIndicator }.count == shown.count)
    #expect(shown.allSatisfy { column in subviews.contains { $0 === column.view } })
    #expect(subviews.filter { $0 is NSBox }.count == shown.count)
}

/// A truncated column's view leaves the column view, and its controller, table and pane go.
@MainActor @Test func droppedColumnsLeaveTheViewAndAreFreed() async throws {
    let fixture = await Fixture()
    await fixture.select("docs", inColumn: 0)
    weak let docsController = fixture.controller.columnControllers[1]
    weak let docsTable = fixture.controller.columnControllers[1].tableView
    weak let docsPane = fixture.trail.columns[1].pane
    expectOnlyShownColumns(in: fixture.controller)

    await fixture.select("other", inColumn: 0)
    weak let otherController = fixture.controller.columnControllers[1]
    weak let otherPane = fixture.trail.columns[1].pane
    #expect(fixture.trail.columns.map(\.pane.location.path) == ["/r", "/r/other"])
    expectOnlyShownColumns(in: fixture.controller)

    await fixture.select("a.txt", inColumn: 0)
    #expect(fixture.trail.columns.count == 1)
    expectOnlyShownColumns(in: fixture.controller)

    await settle {
        docsController == nil && docsTable == nil && docsPane == nil && otherController == nil
            && otherPane == nil
    }
    #expect(docsController == nil && docsTable == nil && docsPane == nil)
    #expect(otherController == nil && otherPane == nil)
}

/// `/r/docs/sub` open in three columns, where `/r` and `/r/docs` listed at once and
/// `/r/docs/sub` stays in flight until the test releases it, so only the third column is
/// loading. The column view's spinners wait on `clock`.
@MainActor
private struct LoadingThirdColumn {
    let lister = GatedLister(tree.mapValues { .batches([$0]) })
    let clock = ManualClock()
    let pane: Pane
    let controller: ColumnViewController
    let trail: ColumnTrail

    init() async throws {
        lister.release("/r")
        lister.release("/r/docs")
        pane = Pane(
            location: Location(path: "/r"),
            service: ListingService(lister: lister, clock: clock, rootVolumeName: { "Test Disk" }),
            systemActions: StubSystemActions(), settings: untouchedSettings(), isFocused: true,
            viewMode: .column)
        let controller = ColumnViewController(
            pane: pane, iconCache: TypeIconCache { _ in NSImage() }, formatter: .init(),
            clock: clock)
        controller.startMonitor = { _ in }
        pane.onChange = { [weak controller] in controller?.paneDidChange() }
        controller.view.frame = NSRect(x: 0, y: 0, width: 800, height: 400)
        self.controller = controller
        let trail = try #require(pane.columnTrail)
        self.trail = trail
        await settle { trail.focused.pane.state.isLoaded }
        trail.columns[0].pane.select(Selection([ExactName("docs")], cursor: ExactName("docs")))
        await settle { trail.columns.count == 2 && trail.columns[1].pane.state.isLoaded }
        trail.columns[1].pane.select(Selection([ExactName("sub")], cursor: ExactName("sub")))
    }

    func spinners() throws -> [NSProgressIndicator] {
        try (0..<trail.columns.count).map { try #require(controller.spinner(forColumnAt: $0)) }
    }
}

@MainActor @Test func eachColumnShowsItsOwnSpinnerOnceItsLoadPassesTheDelay() async throws {
    let fixture = try await LoadingThirdColumn()
    #expect(fixture.trail.columns.count == 3)
    let spinners = try fixture.spinners()
    #expect(spinners.allSatisfy { $0.isHidden })

    // Real time passing doesn't show a spinner; only the injected clock does.
    try await Task.sleep(for: .milliseconds(300))
    #expect(spinners.allSatisfy { $0.isHidden })

    fixture.clock.advance(by: LoadTimeouts.spinnerDelay)
    await settle { !spinners[2].isHidden }
    #expect(spinners[0].isHidden)
    #expect(spinners[1].isHidden)
    #expect(fixture.controller.columnControllers[2].view.frame.contains(spinners[2].frame))

    fixture.lister.release("/r/docs/sub")
    await settle { fixture.trail.columns[2].pane.state.isLoaded }
    #expect(spinners.allSatisfy { $0.isHidden })
}

/// A shown spinner sits in the browser's view, but VoiceOver's browser holds only the columns.
@MainActor @Test func aShownColumnSpinnerIsNotOneOfTheBrowsersChildren() async throws {
    let fixture = try await LoadingThirdColumn()
    let spinners = try fixture.spinners()
    fixture.clock.advance(by: LoadTimeouts.spinnerDelay)
    await settle { !spinners[2].isHidden }

    let children = try #require(
        fixture.controller.columnsView.accessibilityChildren() as? [NSView])
    let columns = fixture.controller.columnControllers.map(\.view)
    #expect(children.count == columns.count)
    #expect(zip(children, columns).allSatisfy { $0 === $1 })

    fixture.lister.release("/r/docs/sub")
    await settle { fixture.trail.columns[2].pane.state.isLoaded }
}
