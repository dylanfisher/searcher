import AppKit
import Base
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
private func controller(
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
    // VoiceOver reads the badge after the name.
    #expect(badge.isAccessibilityElement())
    #expect(badge.accessibilityLabel() == ListingViewController.notDownloadedLabel)
    #expect(ListingViewController.notDownloadedLabel == "Not downloaded")
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
