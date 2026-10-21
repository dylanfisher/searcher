import AppKit
import Base
import Browser
import Foundation
import Testing

@testable import Interface

private let modified = Date(timeIntervalSince1970: 1_600_000_000)

private func file(_ name: String, size: Int64) -> DirectoryEntry {
    DirectoryEntry(name: name, type: .regular, size: size, modified: modified)
}

private func folder(_ name: String) -> DirectoryEntry {
    DirectoryEntry(name: name, type: .directory, size: nil, modified: modified)
}

private func link(_ name: String) -> DirectoryEntry {
    DirectoryEntry(name: name, type: .symbolicLink, size: nil, modified: modified)
}

/// Builds the listing off the main thread, where `Listing` must be built.
private func listing(_ entries: [DirectoryEntry]) async -> Listing {
    await Task.detached { Listing(entries) }.value
}

private func kindText(_ type: DirectoryEntry.FileType, _ pathExtension: Substring) async -> String {
    await Task.detached { EntryKind(type, pathExtension: pathExtension).text }.value
}

/// Dates in UTC and English, so the expected text doesn't depend on the machine. Sizes follow the
/// system locale, which `ByteCountFormatter` gives no way to change: the tests use sizes without a
/// decimal part, so the region doesn't change them, but the unit words assume an English language.
@MainActor
private func controller(
    iconCache: TypeIconCache = TypeIconCache(), tableView: NSTableView = NSTableView()
) -> ListingViewController {
    let formatter = EntryCellFormatter(
        locale: Locale(identifier: "en_US"), timeZone: TimeZone(identifier: "UTC")!)
    let controller = ListingViewController(
        iconCache: iconCache, formatter: formatter, tableView: tableView)
    controller.view.frame = NSRect(x: 0, y: 0, width: 800, height: 400)
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
    let controller = controller()
    controller.show(
        await listing([
            file("song.mp3", size: 4_000_000), folder("Documents"), file("empty", size: 0),
            link("shortcut"), file("notes.txt", size: 500),
        ]))

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

@MainActor @Test func sizeHeaderClickSortsBySizeAndASecondClickReverses() async throws {
    let controller = controller()
    controller.show(
        await listing([
            file("big", size: 3_000), folder("b folder"), file("small", size: 10),
            folder("a folder"), file("mid", size: 200),
        ]))
    #expect(try names(controller) == ["a folder", "b folder", "big", "mid", "small"])

    // The first click puts the largest first, as in Finder. Ties stay in ascending name order.
    try clickHeader(controller, titled: "Size")
    #expect(try names(controller) == ["big", "mid", "small", "a folder", "b folder"])

    try clickHeader(controller, titled: "Size")
    #expect(try names(controller) == ["a folder", "b folder", "small", "mid", "big"])
}

@MainActor @Test func columnsResizeAndReorder() {
    let controller = controller()
    let table = controller.tableView
    #expect(table.allowsColumnReordering)
    #expect(table.allowsColumnResizing)
    #expect(table.tableColumns.count == 4)
    for column in table.tableColumns {
        #expect(column.resizingMask.contains(.userResizingMask), "\(column.title)")
    }
}

/// Counts the calls that change a table's rows.
private final class RowChangeCountingTableView: NSTableView {
    var reloads = 0
    var rowChanges = 0

    override func reloadData() {
        reloads += 1
        super.reloadData()
    }

    override func reloadData(forRowIndexes rows: IndexSet, columnIndexes columns: IndexSet) {
        rowChanges += 1
        super.reloadData(forRowIndexes: rows, columnIndexes: columns)
    }

    override func insertRows(at indexes: IndexSet, withAnimation options: AnimationOptions) {
        rowChanges += 1
        super.insertRows(at: indexes, withAnimation: options)
    }

    override func removeRows(at indexes: IndexSet, withAnimation options: AnimationOptions) {
        rowChanges += 1
        super.removeRows(at: indexes, withAnimation: options)
    }

    override func moveRow(at oldIndex: Int, to newIndex: Int) {
        rowChanges += 1
        super.moveRow(at: oldIndex, to: newIndex)
    }
}

@MainActor @Test func newBatchReplacesRowsInOneSwapAndKeepsTheSelectionByName() async throws {
    let table = RowChangeCountingTableView()
    let controller = controller(tableView: table)
    controller.show(
        await listing([file("a", size: 1), file("b", size: 3), file("c", size: 2)]))
    try clickHeader(controller, titled: "Size")
    controller.tableView.selectRowIndexes([0], byExtendingSelection: false)
    #expect(try names(controller)[0] == "b")

    // Built in name order; the table keeps its size order.
    let batch = await listing([
        file("d", size: 4), file("b", size: 3), file("0", size: 0), file("c", size: 2),
        file("e", size: 1),
    ])
    table.reloads = 0
    table.rowChanges = 0
    controller.show(batch)

    #expect(table.reloads == 1)
    #expect(table.rowChanges == 0)
    #expect(controller.tableView.numberOfRows == 5)
    #expect(try names(controller) == ["d", "b", "c", "e", "0"])
    #expect(controller.tableView.selectedRowIndexes == [1])
}

@MainActor @Test func twoMp3FilesShareOneIconAndNoIconIsMadePerFile() async throws {
    let maker = IconMaker()
    let controller = controller(iconCache: TypeIconCache(makeIcon: maker.icon(for:)))
    controller.show(
        await listing([
            file("a.mp3", size: 1), file("b.mp3", size: 2), file("c.MP3", size: 3),
            folder("d"),
        ]))

    let icons = try (0..<4).map {
        try #require(cell(controller, row: $0, column: 0).imageView?.image)
    }
    #expect(icons[0] === icons[1])
    #expect(icons[0] === icons[2])
    #expect(icons[0] !== icons[3])
    #expect(maker.calls == [.mp3: 1, .folder: 1])
}

@MainActor @Test func rowsAndCellsAreReachableByAccessibility() async throws {
    let controller = controller()
    controller.show(await listing([file("song.mp3", size: 1)]))

    let name = try cell(controller, row: 0, column: 0)
    #expect(controller.tableView.isAccessibilityElement())
    #expect(name.textField?.accessibilityValue() as? String == "song.mp3")
    // The icon repeats the Kind column, so VoiceOver reads the name alone.
    #expect(name.imageView?.isAccessibilityElement() == false)
}
