import AppKit
import Base
import BrowserTestSupport
import Foundation
import TestSupport
import Testing

@testable import Browser
@testable import Interface

private func link(_ name: String) -> DirectoryEntry {
    DirectoryEntry(
        name: name, type: .symbolicLink, size: nil, modified: testDate, isHidden: false,
        isDataless: false)
}

private func kindText(_ type: DirectoryEntry.FileType, _ pathExtension: Substring) async -> String {
    await Task.detached { EntryKind(type, pathExtension: pathExtension).text }.value
}

/// A controller showing a pane at `/folder` whose lister holds `entries`, once the pane has loaded
/// them. The pane's changes reach the controller as `PaneViewController` passes them on.
///
/// Dates in UTC and English, so the expected text doesn't depend on the machine. Sizes follow the
/// system locale, which `ByteCountFormatter` gives no way to change: the tests use sizes without a
/// decimal part, so the region doesn't change them, but the unit words assume an English language.
@MainActor
func controller(
    showing entries: [DirectoryEntry], lister: StubLister = StubLister([:]),
    iconCache: TypeIconCache = TypeIconCache(), tableView: ListingTableView = ListingTableView()
) async -> ListingViewController {
    lister.set("/folder", to: entries)
    let pane = Pane(
        location: Location(path: "/folder"), service: ListingService(lister: lister),
        systemActions: StubSystemActions(), settings: untouchedSettings())
    let formatter = EntryCellFormatter(
        locale: Locale(identifier: "en_US"), timeZone: TimeZone(identifier: "UTC")!)
    let controller = ListingViewController(
        pane: pane, iconCache: iconCache, formatter: formatter, tableView: tableView)
    pane.onChange = { [weak controller] in controller?.paneDidChange() }
    controller.view.frame = NSRect(x: 0, y: 0, width: 800, height: 400)
    await settle { pane.state.isLoaded }
    return controller
}

@MainActor
private func cell(_ controller: ListingViewController, row: Int, column: Int) throws
    -> NSTableCellView
{
    let table = controller.tableView
    let view = controller.tableView(table, viewFor: table.tableColumns[column], row: row)
    return try #require(view as? NSTableCellView)
}

/// Each row's cell text, column by column in the table's column order.
@MainActor
private func cellText(_ controller: ListingViewController) throws -> [[String]] {
    let table = controller.tableView
    return try (0..<table.numberOfRows).map { row in
        try table.tableColumns.indices.map { column in
            try #require(cell(controller, row: row, column: column).textField).stringValue
        }
    }
}

@MainActor
private func names(_ controller: ListingViewController) throws -> [String] {
    try cellText(controller).map { $0[0] }
}

/// Changes the sort descriptors as a click on the header of the column titled `title` does: the
/// clicked column's prototype goes first, or the first descriptor reverses if it is that column's.
///
/// A real click can't be sent: the header tracks the press in a nested run loop, which stops the
/// main run loop that the test runner's async main runs on, and the test process exits.
@MainActor
private func clickHeader(_ controller: ListingViewController, titled title: String) throws {
    let table = controller.tableView
    let column = try #require(table.tableColumns.first { $0.title == title })
    let prototype = try #require(column.sortDescriptorPrototype)
    var descriptors = table.sortDescriptors
    if descriptors.first?.key == prototype.key {
        descriptors[0] = try #require(descriptors[0].reversedSortDescriptor as? NSSortDescriptor)
    } else {
        descriptors = [prototype] + descriptors.filter { $0.key != prototype.key }
    }
    table.sortDescriptors = descriptors
}

@MainActor @Test func fixedListingShowsEachColumnsText() async throws {
    let controller = await controller(showing: [
        file("song.mp3", size: 4_000_000), folder("Documents"), file("empty", size: 0),
        link("shortcut"), file("notes.txt", size: 500),
    ])

    let date = "Sep 13, 2020 at 12:26\u{202F}PM"
    let folderKind = await kindText(.directory, "")
    let dataKind = await kindText(.regular, "")
    let linkKind = await kindText(.symbolicLink, "")
    let textKind = await kindText(.regular, "txt")
    let mp3Kind = await kindText(.regular, "mp3")
    #expect(
        controller.tableView.tableColumns.map(\.title) == ["Name", "Size", "Date Modified", "Kind"])
    #expect(controller.tableView.numberOfRows == 5)
    #expect(
        try cellText(controller) == [
            ["Documents", "--", date, folderKind],
            ["empty", "Zero bytes", date, dataKind],
            ["notes.txt", "500 bytes", date, textKind],
            ["shortcut", "--", date, linkKind],
            ["song.mp3", "4 MB", date, mp3Kind],
        ])
}

@MainActor @Test func todayAndYesterdayAreRelative() throws {
    let utc = TimeZone(identifier: "UTC")!
    let formatter = EntryCellFormatter(locale: Locale(identifier: "en_US"), timeZone: utc)
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = utc
    let noon = try #require(
        calendar.date(byAdding: .hour, value: 12, to: calendar.startOfDay(for: .now)))
    #expect(formatter.date(noon) == "Today at 12:00\u{202F}PM")
    #expect(formatter.date(noon.addingTimeInterval(-86_400)) == "Yesterday at 12:00\u{202F}PM")
}

@MainActor @Test func sizeHeaderClickSortsThePaneBySizeAndASecondClickReverses() async throws {
    let controller = await controller(showing: [
        file("big", size: 3_000), folder("b folder"), file("small", size: 10),
        folder("a folder"), file("mid", size: 200),
    ])
    #expect(try names(controller) == ["a folder", "b folder", "big", "mid", "small"])

    // The first click puts the largest first, as in Finder. Ties stay in ascending name order.
    try clickHeader(controller, titled: "Size")
    #expect(controller.pane.sortColumn == .size)
    #expect(controller.pane.sortAscending == false)
    await settle { controller.listing?.column == .size }
    #expect(try names(controller) == ["big", "mid", "small", "a folder", "b folder"])

    try clickHeader(controller, titled: "Size")
    #expect(controller.pane.sortAscending == true)
    await settle { controller.listing?.ascending == true }
    #expect(try names(controller) == ["a folder", "b folder", "small", "mid", "big"])
}

@MainActor @Test func aSortKeepsTheSelectedEntrySelectedAndScrolledIntoView() async throws {
    // By name "e0000" is the first row; by size, largest first, it is the last.
    let entries = (0..<2_000).map { file(String(format: "e%04d", $0), size: Int64($0)) }
    let controller = await controller(showing: entries)
    let table = controller.tableView
    controller.pane.select(Selection([ExactName("e0000")], cursor: ExactName("e0000")))
    #expect(table.selectedRowIndexes == [0])

    try clickHeader(controller, titled: "Size")
    await settle {
        table.selectedRowIndexes == [1_999]
            && table.visibleRect.intersects(table.rect(ofRow: 1_999))
    }

    #expect(controller.pane.selection.members == .only([ExactName("e0000")]))
    #expect(controller.listing?[1_999].name == "e0000")
}

@MainActor @Test func columnsResizeAndReorder() async {
    let controller = await controller(showing: [])
    let table = controller.tableView
    #expect(table.allowsColumnReordering)
    #expect(table.allowsColumnResizing)
    #expect(table.tableColumns.count == 4)
    for column in table.tableColumns {
        #expect(column.resizingMask.contains(.userResizingMask), "\(column.title)")
    }
}

/// Counts the calls to `reloadData`.
private final class ReloadCountingTableView: ListingTableView {
    var reloads = 0

    override func reloadData() {
        reloads += 1
        super.reloadData()
    }
}

/// The name column's text in the row views the table has made.
@MainActor
private func shownNames(_ controller: ListingViewController) -> [String] {
    let table = controller.tableView
    return (0..<table.numberOfRows).compactMap { row in
        let view = table.view(atColumn: 0, row: row, makeIfNecessary: false)
        return (view as? NSTableCellView)?.textField?.stringValue
    }
}

/// `reloadData` would drop the row views and lay out new ones, most of a 23 ms pass on W2.
@MainActor @Test func aNewListingOfTheFolderRefreshesTheRowsOnScreenAndKeepsTheSelectionByName()
    async throws
{
    let table = ReloadCountingTableView()
    let lister = StubLister([:])
    let controller = await controller(
        showing: [file("a", size: 1), file("b", size: 3), file("c", size: 2)], lister: lister,
        tableView: table)
    try clickHeader(controller, titled: "Size")
    await settle { controller.listing?.column == .size }
    controller.view.layoutSubtreeIfNeeded()
    #expect(shownNames(controller) == ["b", "c", "a"])
    table.selectRowIndexes([0], byExtendingSelection: false)
    await settle { controller.pane.selection.isSettled }
    #expect(controller.pane.selection.members == .only([ExactName("b")]))

    lister.set(
        "/folder",
        to: [
            file("d", size: 4), file("b", size: 3), file("0", size: 0), file("c", size: 2),
            file("e", size: 1),
        ])
    table.reloads = 0
    controller.pane.reload()
    await settle { controller.tableView.numberOfRows == 5 }
    controller.view.layoutSubtreeIfNeeded()

    #expect(table.reloads == 0)
    #expect(shownNames(controller) == ["d", "b", "c", "e", "0"])
    #expect(controller.tableView.selectedRowIndexes == [1])
}

/// A new folder's rows have nothing in common with the last one's.
@MainActor @Test func aNewFolderReloadsTheRows() async throws {
    let table = ReloadCountingTableView()
    let lister = StubLister(["/other": [file("x")]])
    let controller = await controller(showing: [file("a")], lister: lister, tableView: table)
    table.reloads = 0

    controller.pane.navigate(to: Location(path: "/other"))
    await settle { controller.pane.state.isLoaded }

    // Once for the loading state, with no rows, and once for the folder's.
    #expect(table.reloads == 2)
    #expect(try names(controller) == ["x"])
}

@MainActor @Test func selectionChangesMoveTheTableSelectionWithoutReloading() async throws {
    let table = ReloadCountingTableView()
    let controller = await controller(
        showing: [file("a", size: 1), file("b", size: 1)], tableView: table)
    table.reloads = 0

    controller.pane.moveSelection(by: 1)
    controller.pane.moveSelection(by: 1)

    #expect(table.selectedRowIndexes == [1])
    #expect(table.reloads == 0)
}

/// A folder change that shifts the selected rows, such as a growing download sorted by size,
/// leaves the view where the user scrolled it.
@MainActor @Test func aPatchThatShiftsTheSelectionDoesNotScrollBackToTheCursor() async throws {
    let entries = (0..<2_000).map { file(String(format: "e%04d", $0)) }
    let controller = await controller(showing: entries)
    let pane = controller.pane
    let table = controller.tableView
    controller.view.layoutSubtreeIfNeeded()
    pane.select(Selection([ExactName("e0000"), ExactName("e0001")], cursor: ExactName("e0001")))
    table.scrollRowToVisible(1_500)
    let scrolled = table.visibleRect

    // A new first row moves every row down one.
    pane.apply(.patches([.update(file("a-new"))]), at: pane.location)
    await settle { controller.listing?.count == 2_001 }
    // Past the pass a scroll after a reload waits for.
    await withCheckedContinuation { continuation in
        DispatchQueue.main.async { continuation.resume() }
    }

    #expect(table.selectedRowIndexes == [1, 2])
    #expect(table.visibleRect == scrolled)
    #expect(!table.visibleRect.intersects(table.rect(ofRow: 2)))
}

@MainActor @Test func aListOpenedLikeAnotherStillListingTakesItsScrollOnceTheRowsShow() async throws
{
    let entries = (0..<2_000).map { file(String(format: "e%04d", $0)) }
    let source = await controller(showing: entries)
    source.view.layoutSubtreeIfNeeded()
    source.pane.select(Selection([ExactName("e0010")], cursor: ExactName("e0010")))
    let sourceScroll = try #require(source.view as? NSScrollView)
    sourceScroll.contentView.scroll(to: NSPoint(x: 0, y: 5_000))
    sourceScroll.reflectScrolledClipView(sourceScroll.contentView)
    try #require(sourceScroll.contentView.bounds.origin.y == 5_000)
    let lister = GatedLister(["/folder": .batches([entries])])
    let pane = Pane(
        location: Location(path: "/folder"), service: ListingService(lister: lister),
        systemActions: StubSystemActions(), settings: untouchedSettings(),
        selecting: ExactName("e0010"))
    let copy = ListingViewController(pane: pane)
    pane.onChange = { [weak copy] in copy?.paneDidChange() }
    copy.view.frame = source.view.frame
    copy.view.layoutSubtreeIfNeeded()

    copy.scroll(like: source)
    lister.releaseAll()
    await settle { pane.state.isLoaded && copy.listing != nil }
    // Past the pass a scroll to the cursor after a reload waits for.
    await withCheckedContinuation { continuation in
        DispatchQueue.main.async { continuation.resume() }
    }

    let copyScroll = try #require(copy.view as? NSScrollView)
    #expect(copyScroll.contentView.bounds.origin.y == 5_000)
}

@MainActor @Test func aMovedCursorIsScrolledIntoViewInTheSamePass() async throws {
    let entries = (0..<2_000).map { file(String(format: "e%04d", $0)) }
    let controller = await controller(showing: entries)
    let table = controller.tableView
    controller.view.layoutSubtreeIfNeeded()

    controller.pane.selectLastRow()
    #expect(table.visibleRect.contains(table.rect(ofRow: 1_999)))

    // Extending up from the last row, the cursor moves and the anchor stays out of view.
    controller.pane.selectFirstRow()
    controller.pane.moveSelection(by: 100, extending: false)
    for _ in 0..<60 {
        controller.pane.moveSelection(by: -1, extending: true)
    }
    #expect(table.selectedRowIndexes == IndexSet(40...100))
    #expect(table.visibleRect.contains(table.rect(ofRow: 40)))
}

@MainActor @Test func theViewReportsHowManyRowsFitAsThePage() async throws {
    let entries = (0..<2_000).map { file(String(format: "e%04d", $0)) }
    let controller = await controller(showing: entries)
    let table = controller.tableView

    controller.view.frame = NSRect(x: 0, y: 0, width: 800, height: 400)
    controller.view.layoutSubtreeIfNeeded()
    let tall = controller.pane.visibleRowCount
    controller.view.frame = NSRect(x: 0, y: 0, width: 800, height: 200)
    controller.view.layoutSubtreeIfNeeded()
    let short = controller.pane.visibleRowCount

    #expect(short > 1)
    #expect(tall > short)
    // That many rows fit between the header and the bottom edge, and one more doesn't. At the
    // top of the list the header covers the part of the visible rect above y = 0.
    let below = table.visibleRect.maxY
    func span(_ rows: Int) -> CGFloat {
        table.rect(ofRow: rows - 1).maxY - table.rect(ofRow: 0).minY
    }
    #expect(span(short) <= below)
    #expect(span(short + 1) > below)
}

@MainActor @Test func aClickedSelectionReachesThePaneWithItsCursor() async throws {
    let controller = await controller(
        showing: [file("a"), file("b"), file("c"), file("d"), file("e")])
    let table = controller.tableView

    // A click selects through the table, as `selectRowIndexes` does; the table's last selected
    // row is the cursor.
    table.selectRowIndexes([1, 2], byExtendingSelection: false)
    await settle { controller.pane.selection.isSettled }

    #expect(
        controller.pane.selection
            == Selection([ExactName("b"), ExactName("c")], cursor: ExactName("c")))
    controller.pane.moveSelection(by: 1)
    #expect(table.selectedRowIndexes == [3])
}

/// A table that holds a press's rows as AppKit's mouse tracking does: a mouse down changes the
/// rows the table shows and posts that its selection is changing, and says it changed only on
/// mouse up. A real press can't be sent; see `aCmdClickOnARowStillTogglesItsSelection`. Rows set
/// from code replace the pressed ones, as they would during a real press.
private final class PressedTableView: ListingTableView {
    var row = -1
    private var pressed: IndexSet?

    override var clickedRow: Int { row }
    override var selectedRowIndexes: IndexSet { pressed ?? super.selectedRowIndexes }

    override func selectRowIndexes(_ indexes: IndexSet, byExtendingSelection extend: Bool) {
        pressed = nil
        super.selectRowIndexes(indexes, byExtendingSelection: extend)
    }

    /// Mouse down on `row`, leaving `rows` selected.
    func pressDown(on row: Int, selecting rows: IndexSet) {
        self.row = row
        pressed = rows
        NotificationCenter.default.post(
            name: NSTableView.selectionIsChangingNotification, object: self)
    }

    func pressUp() {
        NotificationCenter.default.post(
            name: NSTableView.selectionDidChangeNotification, object: self)
    }
}

/// A press in the pane without the keys focuses it, which lists its folder again. That listing
/// lands while the button is still down, and the pane's selection, shown again, must already be
/// the pressed row, or the table drops back to the old row until mouse up.
@MainActor @Test func aMouseDownSelectsThePressedRowInThePaneBeforeMouseUp() async throws {
    let table = PressedTableView()
    let controller = await controller(showing: [file("a"), file("b"), file("c")], tableView: table)
    let pane = controller.pane
    pane.select(Selection([ExactName("a")], cursor: ExactName("a")))

    table.pressDown(on: 1, selecting: [1])

    #expect(pane.selection.cursor == ExactName("b"))
    let version = pane.stateVersion
    pane.didGainFocus()
    await settle { pane.stateVersion != version }
    #expect(table.selectedRowIndexes == [1])
    await settle { pane.selection.isSettled }
    #expect(pane.selection == Selection([ExactName("b")], cursor: ExactName("b")))
}

/// Mouse up reports the rows mouse down already gave the pane, which changes nothing: Cmd-U
/// takes one step back to the row before the press.
@MainActor @Test func mouseUpAfterThePressChangesNothingMore() async throws {
    let table = PressedTableView()
    let controller = await controller(showing: [file("a"), file("b"), file("c")], tableView: table)
    let pane = controller.pane
    pane.select(Selection([ExactName("a")], cursor: ExactName("a")))
    table.pressDown(on: 1, selecting: [1])
    await settle { pane.selection.isSettled }
    let version = pane.selectionVersion

    table.pressUp()

    #expect(pane.selectionVersion == version)
    pane.undoSelection()
    await settle { pane.selection.isSettled }
    #expect(pane.selection == Selection([ExactName("a")], cursor: ExactName("a")))
    #expect(!pane.canUndoSelection)
}

/// The table reports by row the selection a key or command made by name; the same rows, cursor
/// and anchor are no change and no step.
@MainActor @Test func aReportOfTheSelectionANamedSelectionShowsChangesNothing() async throws {
    let table = PressedTableView()
    let controller = await controller(showing: [file("a"), file("b"), file("c")], tableView: table)
    let pane = controller.pane
    pane.select(Selection([ExactName("a")], cursor: ExactName("a")))
    pane.select(Selection([ExactName("b")], cursor: ExactName("b")))
    #expect(table.selectedRowIndexes == [1])
    let version = pane.selectionVersion

    table.pressUp()

    #expect(pane.selectionVersion == version)
    #expect(pane.selection == Selection([ExactName("b")], cursor: ExactName("b")))
    pane.undoSelection()
    #expect(pane.selection == Selection([ExactName("a")], cursor: ExactName("a")))
    #expect(!pane.canUndoSelection)
}

/// A press on a row of a multi-row selection leaves the selection to the table until mouse up,
/// so a drag takes every selected row; the mouse-down report changes nothing.
@MainActor @Test func aPressInsideTheSelectionKeepsItForADrag() async throws {
    let table = PressedTableView()
    let controller = await controller(showing: [file("a"), file("b"), file("c")], tableView: table)
    let pane = controller.pane
    pane.select(Selection([ExactName("a"), ExactName("b")], cursor: ExactName("b")))
    let version = pane.selectionVersion

    table.pressDown(on: 0, selecting: [0, 1])

    #expect(pane.selectionVersion == version)
    #expect(table.selectedRowIndexes == [0, 1])
}

#if DEBUG
    /// The table already has the rows, so the pane takes them as they are and names them off the
    /// main thread.
    @MainActor @Test func aClickSelectingHalfTheRowsNamesThemOffTheMainThread() async throws {
        let entries = (0..<4_000).map { file(String(format: "e%04d", $0)) }
        let controller = await controller(showing: entries)
        let pane = controller.pane
        let naming = DispatchQueue(label: "naming")
        naming.suspend()
        pane.settleQueue = naming
        let work = pane.mainSelectionWork

        controller.tableView.selectRowIndexes(IndexSet(0..<2_000), byExtendingSelection: false)

        #expect(pane.mainSelectionWork == work)
        #expect(!pane.selection.isSettled)
        #expect(pane.selection.rows(in: try #require(pane.state.listing)) == IndexSet(0..<2_000))
        #expect(pane.selection.contains(ExactName("e1999")))
        #expect(!pane.selection.contains(ExactName("e2000")))
        naming.resume()
        await settle { pane.selection.isSettled }
        #expect(
            pane.selection.members
                == .only(Set((0..<2_000).map { ExactName(String(format: "e%04d", $0)) })))
        #expect(pane.mainSelectionWork == work)
    }
#endif

/// The inset style's rounded selection updates each changed row's neighbors, 13–16 ms on the
/// main thread to select 100k rows; the full-width style draws the same selection in 0.2 ms.
@MainActor @Test func selectedRowsAreHighlightedFullWidth() async {
    let controller = await controller(showing: [])

    #expect(controller.tableView.style == .fullWidth)
}

@MainActor @Test func cutRowsDrawDimmedUntilTheCutEnds() async throws {
    let pasteboard = NSPasteboard(name: NSPasteboard.Name("searcher-test-\(UUID().uuidString)"))
    defer { pasteboard.releaseGlobally() }
    let clipboard = CutState(clipboard: PasteboardFileClipboard(pasteboard: pasteboard))
    let controller = await controller(showing: [file("a"), file("b")])
    controller.clipboard = clipboard
    func alphas() throws -> [CGFloat] {
        try (0..<2).map { try cell(controller, row: $0, column: 0).alphaValue }
    }
    #expect(try alphas() == [1, 1])

    clipboard.cut([URL(fileURLWithPath: "/folder/a", isDirectory: false)])
    #expect(try alphas() == [ListingViewController.cutAlpha, 1])

    pasteboard.clearContents()
    clipboard.clipboardMayHaveChanged()
    #expect(try alphas() == [1, 1])
}

@MainActor @Test func aClickThatSelectsMostRowsNamesTheRowsLeftOut() async throws {
    let controller = await controller(
        showing: [file("a"), file("b"), file("c"), file("d"), file("e")])
    let table = controller.tableView

    table.selectRowIndexes([0, 1, 2, 4], byExtendingSelection: false)
    await settle { controller.pane.selection.isSettled }

    #expect(controller.pane.selection.members == .allExcept([ExactName("d")]))
    #expect(controller.pane.selection.cursor == ExactName("e"))
    #expect(table.selectedRowIndexes == [0, 1, 2, 4])
}

@MainActor @Test func aShiftClickKeepsTheAnchorAndAPlainClickMovesIt() async throws {
    let controller = await controller(
        showing: [file("a"), file("b"), file("c"), file("d"), file("e")])
    let table = controller.tableView
    controller.pane.select(Selection([ExactName("d")], cursor: ExactName("d")))

    // The table's own Shift-click range, from its anchor; with no click, the last row it
    // selected, "c", is the cursor.
    controller.currentModifierFlags = { .shift }
    table.selectRowIndexes([1, 2], byExtendingSelection: false)
    await settle { controller.pane.selection.isSettled }
    #expect(
        controller.pane.selection
            == Selection(
                [ExactName("b"), ExactName("c")], cursor: ExactName("c"), anchor: ExactName("d")))
    // Shift-↓ moves the cursor onto the kept anchor, so the range from it shrinks to the anchor
    // and "c" leaves it.
    controller.pane.moveSelection(by: 1, extending: true)
    #expect(table.selectedRowIndexes == [1])

    controller.currentModifierFlags = { [] }
    table.selectRowIndexes([4], byExtendingSelection: false)
    await settle { controller.pane.selection.isSettled }
    #expect(controller.pane.selection == Selection([ExactName("e")], cursor: ExactName("e")))
}

/// A controller over a folder `docs` and files `a.txt` and `b.txt` in a table that reports a
/// double-click on a row, recording the commands and new tabs the table is asked for.
@MainActor
private final class DoubleClickFixture {
    let table = ClickedRowTableView()
    var ran: [CommandID] = []
    var opened: [Location] = []
    let controller: ListingViewController

    init() async {
        controller = await docsAndFiles(in: table)
        table.runCommand = { [unowned self] in ran.append($0) }
        table.openInNewTab = { [unowned self] in opened.append($0) }
    }

    func doubleClick(_ name: String) throws {
        table.row = try #require(rowNames(table).firstIndex(of: name))
        let action = try #require(table.doubleAction)
        #expect(NSApplication.shared.sendAction(action, to: table.target, from: table))
    }
}

@MainActor
private func docsAndFiles(in table: ListingTableView) async -> ListingViewController {
    await controller(showing: [folder("docs"), file("a.txt"), file("b.txt")], tableView: table)
}

@MainActor @Test func cmdDoubleClickOnAFolderRowOpensItInANewTab() async throws {
    let fixture = await DoubleClickFixture()
    fixture.controller.currentModifierFlags = { .command }

    try fixture.doubleClick("docs")

    #expect(fixture.opened == [Location(path: "/folder/docs")])
    #expect(fixture.ran.isEmpty)
    #expect(fixture.controller.pane.location == Location(path: "/folder"))
    #expect(fixture.controller.pane.selection.contains(ExactName("docs")))
}

@MainActor @Test func cmdDoubleClickOnAFileOpensItAsADoubleClickDoes() async throws {
    let fixture = await DoubleClickFixture()
    fixture.controller.currentModifierFlags = { .command }

    try fixture.doubleClick("a.txt")

    #expect(fixture.ran == [NavigationCommands.open.id])
    #expect(fixture.opened.isEmpty)
    #expect(fixture.controller.pane.selection.contains(ExactName("a.txt")))
}

/// A guard on how the table reports AppKit's own Cmd-click toggles, not a test of the click: a
/// real click can't be sent, since `NSTableView.mouseDown` tracks the press in a nested run loop
/// that stops the main run loop the test runner's async main runs on, and the test process exits.
/// It sets the rows a Cmd-click on `docs` and then a second one would leave selected, and checks
/// the pane takes them without running a command or opening a tab.
@MainActor @Test func aCmdClickOnARowStillTogglesItsSelection() async throws {
    let fixture = await DoubleClickFixture()
    let pane = fixture.controller.pane
    fixture.controller.currentModifierFlags = { .command }
    let docs = try #require(rowNames(fixture.table).firstIndex(of: "docs"))
    let file = try #require(rowNames(fixture.table).firstIndex(of: "a.txt"))
    pane.select(Selection([ExactName("a.txt")], cursor: ExactName("a.txt")))

    fixture.table.row = docs
    fixture.table.selectRowIndexes([file, docs], byExtendingSelection: false)
    await settle { pane.selection.isSettled }
    #expect(pane.selection.contains(ExactName("docs")))
    #expect(pane.selection.contains(ExactName("a.txt")))
    fixture.table.selectRowIndexes([file], byExtendingSelection: false)
    await settle { pane.selection.isSettled }

    #expect(pane.selection.contains(ExactName("a.txt")))
    #expect(!pane.selection.contains(ExactName("docs")))
    #expect(fixture.ran.isEmpty && fixture.opened.isEmpty)
}

@MainActor @Test func twoMp3FilesShareOneIconAndNoIconIsMadePerFile() async throws {
    let maker = IconMaker()
    let controller = await controller(
        showing: [
            file("a.mp3", size: 1), file("b.mp3", size: 2), file("c.MP3", size: 3), folder("d"),
        ],
        iconCache: TypeIconCache(makeIcon: maker.icon(for:)))

    let icons = try (0..<4).map {
        try #require(cell(controller, row: $0, column: 0).imageView?.image)
    }
    #expect(icons[0] === icons[1])
    #expect(icons[0] === icons[2])
    #expect(icons[0] !== icons[3])
    #expect(maker.calls == [.mp3: 1, .folder: 1])
}

@MainActor @Test func rowsAndCellsAreReachableByAccessibility() async throws {
    let controller = await controller(showing: [file("song.mp3", size: 1)])

    let name = try cell(controller, row: 0, column: 0)
    #expect(controller.tableView.isAccessibilityElement())
    #expect(name.textField?.accessibilityValue() as? String == "song.mp3")
    // The icon repeats the Kind column, so VoiceOver reads the name alone.
    #expect(name.imageView?.isAccessibilityElement() == false)
}

private func dataless(_ name: String, size: Int64) -> DirectoryEntry {
    DirectoryEntry(
        name: name, type: .regular, size: size, modified: testDate, isHidden: false,
        isDataless: true)
}

/// The not-downloaded badge in a name cell, or nil when the cell shows none.
@MainActor
private func shownBadge(_ cell: NSTableCellView) -> NSImageView? {
    let badge = cell.subviews.first {
        $0.identifier == ListingViewController.notDownloadedBadgeIdentifier
    }
    guard let badge = badge as? NSImageView, !badge.isHidden else { return nil }
    return badge
}

@MainActor @Test func aDatalessEntryShowsTheCloudBadgeOnItsRowOnly() async throws {
    let iconCache = TypeIconCache()
    let controller = await controller(
        showing: [file("a.mp3", size: 1), dataless("b.mp3", size: 4_000_000), folder("c")],
        iconCache: iconCache)

    let names = try (0..<3).map { try cell(controller, row: $0, column: 0) }
    #expect(shownBadge(names[0]) == nil)
    #expect(shownBadge(names[2]) == nil)
    let badge = try #require(shownBadge(names[1]))
    #expect(badge.image === iconCache.notDownloadedBadge)
    // The name ends before the badge starts.
    let text = try #require(names[1].textField)
    #expect(text.frame.maxX <= badge.frame.minX)
    // The row's label says it isn't downloaded (ListingAccessibilityTests), not the badge.
    #expect(!badge.isAccessibilityElement())
    // The size is the file's logical size, not the nothing it takes on disk.
    #expect(try cellText(controller)[1][1] == "4 MB")
}

/// A dataless file's icon comes from its type, as any file's does, so showing it reads nothing
/// from the file.
@MainActor @Test func aDatalessFileHasItsTypesIconAndNoIconIsMadeForIt() async throws {
    let maker = IconMaker()
    let controller = await controller(
        showing: [file("a.mp3", size: 1), dataless("b.mp3", size: 2)],
        iconCache: TypeIconCache(makeIcon: maker.icon(for:)))

    let icons = try (0..<2).map {
        try #require(cell(controller, row: $0, column: 0).imageView?.image)
    }
    #expect(icons[0] === icons[1])
    #expect(maker.calls == [.mp3: 1])
}

/// A row view refilled in place drops the badge when its new entry is downloaded, and shows it
/// when its new entry isn't.
@MainActor @Test func refreshedRowsShowTheBadgeOfTheirNewEntry() async throws {
    let lister = StubLister([:])
    let controller = await controller(
        showing: [dataless("a", size: 1), file("b", size: 2)], lister: lister)
    controller.view.layoutSubtreeIfNeeded()
    let table = controller.tableView
    func nameCells() throws -> [NSTableCellView] {
        try (0..<table.numberOfRows).map { row in
            try #require(
                table.view(atColumn: 0, row: row, makeIfNecessary: false) as? NSTableCellView)
        }
    }
    let before = try nameCells()
    #expect(before.map { shownBadge($0) != nil } == [true, false])

    lister.set("/folder", to: [file("a", size: 1), dataless("b", size: 2)])
    controller.pane.reload()
    await settle { controller.listing?[0].isDataless == false }
    controller.view.layoutSubtreeIfNeeded()

    let after = try nameCells()
    #expect(after[0] === before[0] && after[1] === before[1])
    #expect(after.map { shownBadge($0) != nil } == [false, true])
    // A name without a badge takes the badge's room back.
    let widths = try after.map { try #require($0.textField).frame.width }
    #expect(widths[0] > widths[1])
}

/// Narrowing the Name column below the name's width with the badge, then widening it, leaves the
/// name, the gap and the badge as they were, and a downloaded entry shown in the cell later ends
/// at the cell's padding.
@MainActor @Test func aBadgedNameKeepsItsGapThroughAColumnResizeAndReuse() async throws {
    let lister = StubLister([:])
    let controller = await controller(
        showing: [dataless("a", size: 1), file("b", size: 2)], lister: lister)
    let table = controller.tableView
    controller.view.layoutSubtreeIfNeeded()
    let nameColumn = table.tableColumns[0]
    let width = nameColumn.width
    nameColumn.width = nameColumn.minWidth
    controller.view.layoutSubtreeIfNeeded()
    nameColumn.width = width
    controller.view.layoutSubtreeIfNeeded()

    let name = try #require(
        table.view(atColumn: 0, row: 0, makeIfNecessary: false) as? NSTableCellView)
    let text = try #require(name.textField)
    let badge = try #require(shownBadge(name))
    #expect(badge.frame.minX - text.frame.maxX == 4)

    lister.set("/folder", to: [file("a", size: 1), file("b", size: 2)])
    controller.pane.reload()
    await settle { controller.listing?[0].isDataless == false }
    controller.view.layoutSubtreeIfNeeded()

    #expect(shownBadge(name) == nil)
    #expect(name.bounds.width - text.frame.maxX == 2)
}

@MainActor @Test func aFilterScrollsToTheCursor() async throws {
    let entries = (0..<2_000).map { file(String(format: "e%04d", $0)) }
    let controller = await controller(showing: entries)
    let table = controller.tableView
    table.scrollRowToVisible(1_900)
    #expect(!table.visibleRect.intersects(table.rect(ofRow: 0)))

    // Nothing was selected, so the filter selects its first row, "e1000".
    controller.pane.setFilter("e1")
    await settle {
        controller.listing?.count == 1_000 && table.selectedRowIndexes == [0]
            && table.visibleRect.intersects(table.rect(ofRow: 0))
    }
}

// MARK: - Folder sizes

/// A local volume for the held walks, so they run at once and each finishes when the test
/// releases it. On a share they would run one at a time in whatever order they were asked for,
/// and a walk the test hadn't released yet would hold up the rest. The fake folders can't be
/// watched for changes, so their sizes are delivered and not kept.
private let heldVolume = VolumeIdentity(
    device: "/dev/disk-held", mountPoint: "/fake-mount", kind: .local)

/// Folder walks that wait until the test releases their path with a total or fails it, and note
/// each volume read, start and cancellation.
private final class HeldWalks: @unchecked Sendable {
    private let condition = NSCondition()
    // Keyed by the path's bytes: `String` keys would take canonically equal paths as one.
    private var totals: [[UInt8]: TreeSizeWalker.Total] = [:]
    private var failures: Set<[UInt8]> = []
    private var volumeReadCount = 0
    private var startedPaths: [String] = []
    private var cancelledPaths: [String] = []

    var volumeReads: Int { condition.withLock { volumeReadCount } }
    var started: [String] { condition.withLock { startedPaths } }
    var cancelled: [String] { condition.withLock { cancelledPaths } }

    /// A service whose mount table holds `mounted` alone.
    func service(mounted: [VolumeIdentity] = []) -> FolderSizeService {
        FolderSizeService(
            cache: FolderSizeCache(store: nil), log: { _ in },
            walk: { try self.walk($0, isCancelled: $1) },
            volumeOf: { _ in
                self.condition.withLock { self.volumeReadCount += 1 }
                return heldVolume
            },
            mountedVolumes: { mounted })
    }

    func release(_ path: String, bytes: Int64, isPartial: Bool = false) {
        condition.withLock {
            failures.remove(Array(path.utf8))
            totals[Array(path.utf8)] = TreeSizeWalker.Total(
                bytes: bytes, files: 1, isPartial: isPartial)
            condition.broadcast()
        }
    }

    /// Makes walks of `path`, running or later, fail as a share that stopped answering does.
    func fail(_ path: String) {
        condition.withLock {
            failures.insert(Array(path.utf8))
            condition.broadcast()
        }
    }

    private func walk(_ path: String, isCancelled: () -> Bool) throws -> TreeSizeWalker.Total {
        condition.lock()
        defer { condition.unlock() }
        startedPaths.append(path)
        while true {
            if isCancelled() {
                cancelledPaths.append(path)
                throw CancellationError()
            }
            if failures.contains(Array(path.utf8)) { throw ListingError(path: path, code: EIO) }
            if let total = totals[Array(path.utf8)] { return total }
            condition.wait(until: Date(timeIntervalSinceNow: 0.001))
        }
    }
}

/// A lister whose calls wait while the test holds it, so a load can be kept in flight.
private final class HoldableLister: Lister, @unchecked Sendable {
    private let condition = NSCondition()
    private var folders: [String: [DirectoryEntry]]
    private var isHeld = false

    init(_ folders: [String: [DirectoryEntry]] = [:]) {
        self.folders = folders
    }

    func set(_ path: String, to entries: [DirectoryEntry]) {
        condition.withLock { folders[path] = entries }
    }

    func hold() {
        condition.withLock { isHeld = true }
    }

    func release() {
        condition.withLock {
            isHeld = false
            condition.broadcast()
        }
    }

    func list(_ path: String, onBatch: ([DirectoryEntry]) throws -> Void) throws {
        condition.lock()
        while isHeld { condition.wait() }
        let entries = folders[path]
        condition.unlock()
        guard let entries else { throw ListingError(path: path, code: ENOENT) }
        try onBatch(entries)
    }
}

/// A controller showing `path` as `controller(showing:)` does, whose pane walks folder sizes
/// with `walks` and waits out the time between size batches on `clock`. Tests that send volume
/// events give a path of their own, since every pane on the path gets them.
///
/// A batch's wait reads the clock when its task starts on the cooperative pool, which can be
/// after the batch lands. An advance before then doesn't end the wait, so a test that advances
/// once first settles until `clock.waitingSleeps` shows the wait.
@MainActor
private func sizedController(
    at path: String = "/folder", showing entries: [DirectoryEntry], walks: HeldWalks,
    clock: ManualClock = ManualClock(),
    settings: Settings = sizedSettings(), lister: HoldableLister = HoldableLister(),
    sortedBy column: SortColumn = .name, ascending: Bool = true,
    mounted: [VolumeIdentity] = []
) async -> ListingViewController {
    lister.set(path, to: entries)
    let pane = Pane(
        location: Location(path: path), service: ListingService(lister: lister),
        systemActions: StubSystemActions(), settings: settings, sortedBy: column,
        ascending: ascending)
    pane.sizeBatchClock = clock
    pane.folderSizes = walks.service(mounted: mounted)
    let formatter = EntryCellFormatter(
        locale: Locale(identifier: "en_US"), timeZone: TimeZone(identifier: "UTC")!)
    let controller = ListingViewController(
        pane: pane, iconCache: TypeIconCache(), formatter: formatter,
        tableView: ListingTableView())
    pane.onChange = { [weak controller] in controller?.paneDidChange() }
    controller.view.frame = NSRect(x: 0, y: 0, width: 800, height: 400)
    await settle { pane.state.isLoaded }
    return controller
}

/// Each row's Size text.
@MainActor
private func sizeText(_ controller: ListingViewController) throws -> [String] {
    try cellText(controller).map { $0[1] }
}

/// The walked size of the row named `name`.
@MainActor
private func folderSize(_ name: String, in pane: Pane) -> Listing.FolderSizeValue? {
    guard let listing = pane.state.listing, let row = listing.row(named: name) else { return nil }
    return listing.folderSize(atRow: row)
}

@MainActor @Test func aFolderShowsPendingTextUntilItsSizeArrivesAndGreaterOrEqualWhenPartial()
    async throws
{
    let walks = HeldWalks()
    let clock = ManualClock()
    let controller = await sizedController(
        showing: [folder("Music"), folder("Photos"), file("song", size: 500)], walks: walks,
        clock: clock)
    let pending = EntryCellFormatter.pendingSize
    #expect(try sizeText(controller) == [pending, pending, "500 bytes"])

    walks.release("/folder/Music", bytes: 4_000_000)
    await settle { (try? sizeText(controller)) == ["4 MB", pending, "500 bytes"] }

    walks.release("/folder/Photos", bytes: 2_000_000, isPartial: true)
    await settle { clock.waitingSleeps == 1 }
    clock.advance(by: Pane.sizeBatchInterval)
    await settle { (try? sizeText(controller)) == ["4 MB", "≥ 2 MB", "500 bytes"] }
}

/// Finder shows a package's size as it shows a folder's.
@MainActor @Test func aPackageShowsPendingTextThenItsWalkedSize() async throws {
    let walks = HeldWalks()
    let controller = await sizedController(showing: [package("Logic.logicx")], walks: walks)
    #expect(try sizeText(controller) == [EntryCellFormatter.pendingSize])

    walks.release("/folder/Logic.logicx", bytes: 4_000_000)

    await settle { (try? sizeText(controller)) == ["4 MB"] }
}

@MainActor @Test func aFailedWalkShowsNoSizeAndAReloadAsksAgain() async throws {
    let walks = HeldWalks()
    let clock = ManualClock()
    let controller = await sizedController(
        showing: [folder("Music")], walks: walks, clock: clock)
    let pane = controller.pane
    walks.fail("/folder/Music")
    await settle { (try? sizeText(controller)) == [EntryCellFormatter.noSize] }

    walks.release("/folder/Music", bytes: 4_000_000)
    pane.reload()
    await settle { clock.waitingSleeps == 1 }
    clock.advance(by: Pane.sizeBatchInterval)

    await settle { (try? sizeText(controller)) == ["4 MB"] }
    #expect(walks.started == ["/folder/Music", "/folder/Music"])
}

@MainActor @Test func sizesReachTheRowsAtMostOncePerBatchInterval() async throws {
    let walks = HeldWalks()
    let clock = ManualClock()
    let controller = await sizedController(
        showing: [folder("a"), folder("b")], walks: walks, clock: clock)
    let pane = controller.pane
    walks.release("/folder/a", bytes: 1_000)
    await settle { folderSize("a", in: pane) != nil }

    walks.release("/folder/b", bytes: 2_000)
    await settle { !pane.waitingSizes.isEmpty }
    await settle { clock.waitingSleeps == 1 }
    clock.advance(by: Pane.sizeBatchInterval - .milliseconds(1))
    try await Task.sleep(for: .milliseconds(50))
    #expect(folderSize("b", in: pane) == nil)

    clock.advance(by: .milliseconds(1))
    await settle { folderSize("b", in: pane) == .size(bytes: 2_000, isPartial: false) }
}

@MainActor @Test func sortedBySizeAFolderWhoseSizeArrivesMovesAndStaysSelected() async throws {
    let walks = HeldWalks()
    let controller = await sizedController(
        showing: [folder("a folder"), file("big", size: 3_000), file("small", size: 10)],
        walks: walks, sortedBy: .size, ascending: false)
    let pane = controller.pane
    #expect(try names(controller) == ["big", "small", "a folder"])
    pane.select(Selection([ExactName("a folder")], cursor: ExactName("a folder")))
    #expect(controller.tableView.selectedRowIndexes == [2])

    walks.release("/folder/a folder", bytes: 1_000_000)
    await settle { (try? names(controller)) == ["a folder", "big", "small"] }

    #expect(pane.selection.members == .only([ExactName("a folder")]))
    #expect(controller.tableView.selectedRowIndexes == [0])
}

@MainActor @Test func aFolderRowsLabelReadsItsWalkedSize() async throws {
    let walks = HeldWalks()
    let controller = await sizedController(showing: [folder("Music")], walks: walks)
    walks.release("/folder/Music", bytes: 4_000_000)
    await settle { (try? sizeText(controller)) == ["4 MB"] }
    controller.view.layoutSubtreeIfNeeded()

    let rowView = try #require(controller.tableView.rowView(atRow: 0, makeIfNecessary: false))
    let label = try #require(rowView.accessibilityLabel())
    #expect(label.contains(", 4 MB, "))
}

@MainActor @Test func byDefaultNoWalkIsRequestedAndFoldersShowNoSize() async throws {
    let walks = HeldWalks()
    let controller = await sizedController(
        showing: [folder("Music"), file("notes", size: 500)], walks: walks,
        settings: untouchedSettings())
    try await Task.sleep(for: .milliseconds(50))

    #expect(walks.volumeReads == 0)
    #expect(walks.started.isEmpty)
    #expect(try sizeText(controller) == ["--", "500 bytes"])
}

@MainActor @Test func calculateSizesWithSizesOffShowsPendingTextThenTheSize() async throws {
    let walks = HeldWalks()
    let clock = ManualClock()
    let controller = await sizedController(
        showing: [folder("Music"), file("notes", size: 500)], walks: walks, clock: clock,
        settings: untouchedSettings())
    let calculate = try #require(
        AppCommands.bindings.first { $0.command == SizeCommands.calculateSizes })

    calculate.run(CommandContext(pane: controller.pane))

    let pending = EntryCellFormatter.pendingSize
    await settle { (try? sizeText(controller)) == [pending, "500 bytes"] }
    walks.release("/folder/Music", bytes: 4_000_000)
    await settle {
        clock.advance(by: Pane.sizeBatchInterval)
        return (try? sizeText(controller)) == ["4 MB", "500 bytes"]
    }
    #expect(walks.started == ["/folder/Music"])
}

@MainActor @Test func turningSizesOffDuringALoadKeepsThemOffWhenItLands() async throws {
    let walks = HeldWalks()
    let settings = sizedSettings()
    let lister = HoldableLister()
    let clock = ManualClock()
    let controller = await sizedController(
        showing: [folder("Music")], walks: walks, clock: clock, settings: settings,
        lister: lister)
    let pane = controller.pane
    walks.release("/folder/Music", bytes: 4_000_000)
    await settle { (try? sizeText(controller)) == ["4 MB"] }

    lister.hold()
    let version = pane.stateVersion
    pane.reload()
    try await Task.sleep(for: .milliseconds(20))
    settings.folderSizes = false
    lister.release()
    await settle { pane.stateVersion != version && pane.state.isLoaded }
    await settle { clock.waitingSleeps == 1 }
    clock.advance(by: Pane.sizeBatchInterval)
    await settle { folderSize("Music", in: pane) == nil }

    #expect(folderSize("Music", in: pane) == nil)
    #expect(try sizeText(controller) == ["--"])
}

/// A running walk on a local volume finishes, so a return finds its size kept; one on a share
/// is still cancelled (FolderSizeServiceTests).
@MainActor @Test func navigatingAwayLetsTheRunningLocalWalkFinish() async throws {
    let walks = HeldWalks()
    let lister = HoldableLister(["/other": [file("x")]])
    let controller = await sizedController(
        showing: [folder("Music")], walks: walks, lister: lister)
    await settle { walks.started == ["/folder/Music"] }

    controller.pane.navigate(to: Location(path: "/other"))
    await settle { controller.pane.state.isLoaded }
    try await Task.sleep(for: .milliseconds(50))

    #expect(walks.cancelled.isEmpty)
    walks.release("/folder/Music", bytes: 1)
}

@MainActor @Test func columnViewCancelsTheListsWalksAndRequestsNone() async throws {
    let walks = HeldWalks()
    let controller = await sizedController(showing: [folder("Music")], walks: walks)
    let pane = controller.pane
    await settle { walks.started == ["/folder/Music"] }

    pane.setViewMode(.column)
    await settle { walks.cancelled == ["/folder/Music"] }
    let trail = try #require(pane.columnTrail)
    await settle { trail.focused.pane.state.isLoaded }
    try await Task.sleep(for: .milliseconds(50))

    #expect(walks.started == ["/folder/Music"])
}

@MainActor @Test func aReloadKeepsTheSizesShownWithoutWalkingAgain() async throws {
    let walks = HeldWalks()
    let controller = await sizedController(showing: [folder("Music")], walks: walks)
    let pane = controller.pane
    walks.release("/folder/Music", bytes: 4_000_000)
    await settle { (try? sizeText(controller)) == ["4 MB"] }

    let reads = walks.volumeReads

    for _ in 0..<5 {
        let version = pane.stateVersion
        pane.reload()
        await settle { pane.stateVersion != version && pane.state.isLoaded }
    }
    try await Task.sleep(for: .milliseconds(50))

    #expect(try sizeText(controller) == ["4 MB"])
    #expect(walks.started.count == 1)
    // A scan that finds nothing to ask for reads no volume: on a hung share each read would
    // hold a thread for good.
    #expect(walks.volumeReads == reads)
}

@MainActor @Test func patchesStillLandAfterSizesAreTurnedOffWhileTheRowsLoad() async throws {
    let walks = HeldWalks()
    let settings = sizedSettings()
    let lister = HoldableLister(["/other": [folder("Albums")]])
    let controller = await sizedController(
        showing: [folder("Music")], walks: walks, settings: settings, lister: lister)
    let pane = controller.pane

    lister.hold()
    pane.navigate(to: Location(path: "/other"))
    settings.folderSizes = false
    lister.release()
    await settle { pane.location.path == "/other" && pane.state.isLoaded }
    pane.apply(.patches([.update(file("new"))]), at: pane.location)

    await settle { pane.state.listing?.row(named: "new") != nil }
}

@MainActor @Test func canonicallyEqualFolderNamesEachGetTheirOwnWalkAndSize() async throws {
    let composed = "Caf\u{E9}"
    let decomposed = "Cafe\u{301}"
    let walks = HeldWalks()
    let clock = ManualClock()
    let controller = await sizedController(
        showing: [folder(composed), folder(decomposed)], walks: walks, clock: clock)
    let pane = controller.pane
    walks.release("/folder/" + composed, bytes: 1_000)
    walks.release("/folder/" + decomposed, bytes: 2_000)

    await settle {
        clock.advance(by: Pane.sizeBatchInterval)
        guard let listing = pane.state.listing, listing.count == 2 else { return false }
        return (0..<2).allSatisfy { listing.folderSize(atRow: $0) != nil }
    }
    let listing = try #require(pane.state.listing)
    let sizes = Dictionary(
        uniqueKeysWithValues: (0..<2).map {
            (Array(listing[$0].name.utf8), listing.folderSize(atRow: $0))
        })
    #expect(sizes[Array(composed.utf8)] == .size(bytes: 1_000, isPartial: false))
    #expect(sizes[Array(decomposed.utf8)] == .size(bytes: 2_000, isPartial: false))
    try await Task.sleep(for: .milliseconds(100))
    clock.advance(by: Pane.sizeBatchInterval)
    try await Task.sleep(for: .milliseconds(100))
    #expect(walks.started.count == 2)
}

// MARK: Volumes and visibility

@MainActor @Test func aVolumeAboutToUnmountStopsThePanesWalks() async throws {
    let walks = HeldWalks()
    let controller = await sizedController(
        at: "/volume-a", showing: [folder("Music")], walks: walks)
    await settle { walks.started == ["/volume-a/Music"] }

    VolumeEvents.willUnmount(at: "/volume-a")

    await settle { walks.cancelled == ["/volume-a/Music"] }
    _ = controller
}

@MainActor @Test func aGoneVolumeIsNotWalked() async throws {
    let walks = HeldWalks()
    let controller = await sizedController(
        at: "/volume-b", showing: [folder("Music")], walks: walks)
    let pane = controller.pane
    await settle { walks.started == ["/volume-b/Music"] }

    VolumeEvents.didUnmount(at: "/volume-b")
    await settle { walks.cancelled == ["/volume-b/Music"] }
    try await Task.sleep(for: .milliseconds(100))

    #expect(walks.started == ["/volume-b/Music"])
    if case .offline = pane.state {} else { Issue.record("the pane isn't offline: \(pane.state)") }
}

@MainActor @Test func aRemountedVolumeWalksTheFoldersWhoseWalksFailed() async throws {
    let walks = HeldWalks()
    let clock = ManualClock()
    let controller = await sizedController(
        at: "/volume-c",
        showing: [folder("Music")], walks: walks, clock: clock)
    walks.fail("/volume-c/Music")
    await settle { (try? sizeText(controller)) == [EntryCellFormatter.noSize] }

    walks.release("/volume-c/Music", bytes: 4_000_000)
    VolumeEvents.didMount(at: "/volume-c")
    await settle { clock.waitingSleeps == 1 }
    clock.advance(by: Pane.sizeBatchInterval)

    await settle { (try? sizeText(controller)) == ["4 MB"] }
}

@MainActor @Test func aHiddenTabsPanePausesItsWalksAndResumesWhenShown() async throws {
    let walks = HeldWalks()
    let controller = await sizedController(showing: [folder("Music")], walks: walks)
    let pane = controller.pane
    await settle { walks.started == ["/folder/Music"] }

    pane.isVisible = false
    await settle { walks.cancelled == ["/folder/Music"] }
    try await Task.sleep(for: .milliseconds(50))
    #expect(walks.started.count == 1)

    pane.isVisible = true
    await settle { walks.started.count == 2 }
    walks.release("/folder/Music", bytes: 4_000_000)
    await settle { (try? sizeText(controller)) == ["4 MB"] }
}

// MARK: Sizes and patches

@MainActor @Test func aSizeBatchWaitsForARunningPatch() async throws {
    let walks = HeldWalks()
    let controller = await sizedController(
        showing: [folder("Music"), file("a")], walks: walks)
    let pane = controller.pane
    let queue = DispatchQueue(label: "held rows")
    pane.rowWorkQueue = queue
    queue.suspend()
    pane.apply(.patches([.update(file("b"))]), at: pane.location)

    walks.release("/folder/Music", bytes: 4_000_000)
    await settle { !pane.waitingSizes.isEmpty }
    try await Task.sleep(for: .milliseconds(50))
    #expect(!pane.waitingSizes.isEmpty)

    queue.resume()
    await settle {
        folderSize("Music", in: pane) != nil && pane.state.listing?.row(named: "b") != nil
    }
}

@MainActor @Test func aSizeBatchThatWaitedGoesBeforeTheNextPatch() async throws {
    let walks = HeldWalks()
    let clock = ManualClock()
    let controller = await sizedController(
        showing: [folder("Music"), file("a")], walks: walks, clock: clock)
    let pane = controller.pane
    let queue = DispatchQueue(label: "held rows")
    pane.rowWorkQueue = queue
    queue.suspend()
    pane.apply(.patches([.update(file("b"))]), at: pane.location)
    walks.release("/folder/Music", bytes: 4_000_000)
    await settle { !pane.waitingSizes.isEmpty }
    clock.advance(by: Pane.sizeBatchInterval)
    pane.apply(.patches([.update(file("c"))]), at: pane.location)

    // Each state the rows go through: whether they have the size, and whether they have "c".
    var shown: [(size: Bool, c: Bool)] = []
    pane.onChange = { [weak controller] in
        shown.append(
            (folderSize("Music", in: pane) != nil, pane.state.listing?.row(named: "c") != nil))
        controller?.paneDidChange()
    }
    queue.resume()
    await settle {
        folderSize("Music", in: pane) != nil && pane.state.listing?.row(named: "c") != nil
    }

    #expect(shown.contains { $0.size && !$0.c }, "\(shown)")
}

@MainActor @Test func aVolumeUnmountingUnderThePanesFolderStopsThatFoldersWalk() async throws {
    let share = VolumeIdentity(
        device: "//dylan@nas.invalid/music", mountPoint: "/volume-d/music", kind: .network)
    let walks = HeldWalks()
    let controller = await sizedController(
        at: "/volume-d", showing: [folder("music"), folder("other")], walks: walks,
        mounted: [share])
    await settle { Set(walks.started) == ["/volume-d/music", "/volume-d/other"] }

    VolumeEvents.willUnmount(at: "/volume-d/music")

    await settle { walks.cancelled == ["/volume-d/music"] }
    try await Task.sleep(for: .milliseconds(50))
    #expect(walks.cancelled == ["/volume-d/music"])
    _ = controller
}
