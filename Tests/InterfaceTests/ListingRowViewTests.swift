import AppKit
import TestSupport
import Testing

@testable import Interface

/// A selected row 300 points wide, as a list's or a column's, in the light appearance whatever
/// the Mac's, so what it draws doesn't follow the machine.
@MainActor
private func selectedRow(emphasized: Bool = true) -> ListingRowView {
    let row = ListingRowView(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
    row.appearance = NSAppearance(named: .aqua)
    row.isSelected = true
    row.isEmphasized = emphasized
    return row
}

/// The opacity `row` draws at `point`, in its coordinates.
@MainActor
private func alpha(of row: NSView, at point: NSPoint) throws -> Double {
    let bitmap = try #require(row.bitmapImageRepForCachingDisplay(in: row.bounds))
    row.cacheDisplay(in: row.bounds, to: bitmap)
    let scale = Double(bitmap.pixelsWide) / row.bounds.width
    // The bitmap's rows run down from the top, as the flipped row's do.
    #expect(row.isFlipped)
    let color = bitmap.colorAt(x: Int(point.x * scale), y: Int(point.y * scale))
    return try #require(color).alphaComponent
}

/// Finder's selected row is a rounded band inset from the row's sides, not the full width.
@MainActor @Test func aSelectedRowDrawsARoundedBandInsetFromItsSides() throws {
    let row = selectedRow()
    let inset = ListingRowView.selectionInset

    // The arcs leave the path's bounds a hair off whole points.
    let band = row.selectionPath.bounds
    let expected = row.bounds.insetBy(dx: inset, dy: 0)
    for (edge, wanted) in zip(
        [band.minX, band.minY, band.maxX, band.maxY],
        [expected.minX, expected.minY, expected.maxX, expected.maxY])
    {
        #expect(abs(edge - wanted) < 0.001)
    }
    // Clear outside the band and in its rounded corners, filled inside it.
    #expect(try alpha(of: row, at: NSPoint(x: inset / 2, y: 12)) == 0)
    #expect(try alpha(of: row, at: NSPoint(x: inset + 0.5, y: 0.5)) == 0)
    #expect(try alpha(of: row, at: NSPoint(x: 300 - inset - 0.5, y: 23.5)) == 0)
    #expect(try alpha(of: row, at: NSPoint(x: inset + 1, y: 12)) == 1)
    #expect(try alpha(of: row, at: NSPoint(x: 150, y: 0.5)) == 1)
}

/// Adjacent selected rows make one block: a row's corners are square where the row beside it
/// is selected too.
@MainActor @Test func aSelectedRowIsSquareWhereItsNeighborIsSelected() throws {
    let row = selectedRow()
    let inset = ListingRowView.selectionInset
    let topCorner = NSPoint(x: inset + 0.5, y: 0.5)
    let bottomCorner = NSPoint(x: inset + 0.5, y: 23.5)

    row.isPreviousRowSelected = true
    #expect(row.selectionPath.contains(topCorner))
    #expect(!row.selectionPath.contains(bottomCorner))

    row.isPreviousRowSelected = false
    row.isNextRowSelected = true
    #expect(!row.selectionPath.contains(topCorner))
    #expect(row.selectionPath.contains(bottomCorner))
}

/// The table, in its full-width style, tells each row whether its neighbors are selected.
@MainActor @Test func aListsSelectedRowsTakeTheirNeighborsSelection() async throws {
    let list = await controller(showing: [file("a"), file("b"), file("c")])
    let table = list.tableView
    list.view.layoutSubtreeIfNeeded()

    table.selectRowIndexes([0, 1], byExtendingSelection: false)

    let rows = try (0..<3).map {
        try #require(table.rowView(atRow: $0, makeIfNecessary: true) as? ListingRowView)
    }
    #expect(rows[0].isNextRowSelected && !rows[0].isPreviousRowSelected)
    #expect(rows[1].isPreviousRowSelected && !rows[1].isNextRowSelected)
}

/// Accent while emphasized, Finder's grey otherwise.
@MainActor @Test func theSelectionIsAccentWhenEmphasizedAndGreyOtherwise() {
    #expect(selectedRow().selectionColor == .selectedContentBackgroundColor)
    #expect(
        selectedRow(emphasized: false).selectionColor
            == .unemphasizedSelectedContentBackgroundColor)
}

/// The content sits inside the band, the icon as far in from its edge as Finder's, 7 points,
/// and the last column's cells end inside it too.
@MainActor @Test func aRowsContentSitsInsideItsSelection() async throws {
    let list = await controller(showing: [file("a")])
    let table = list.tableView
    list.view.layoutSubtreeIfNeeded()
    let row = try #require(table.rowView(atRow: 0, makeIfNecessary: true))
    let name = try #require(row.view(atColumn: 0) as? NSTableCellView)
    let icon = try #require(name.imageView)
    let last = try #require(row.view(atColumn: table.numberOfColumns - 1) as? NSView)

    let band = try #require(row as? ListingRowView).selectionPath.bounds
    let iconInside = row.convert(icon.frame, from: name).minX - band.minX
    // Where AppKit's full-width style starts the first cell, in a table of its own.
    let rows = OneRow()
    let plain = NSTableView(frame: table.frame)
    plain.style = table.style
    plain.intercellSpacing = table.intercellSpacing
    let column = NSTableColumn(identifier: table.tableColumns[0].identifier)
    column.width = table.tableColumns[0].width
    plain.addTableColumn(column)
    plain.dataSource = rows
    plain.reloadData()
    let appKitCellX = plain.frameOfCell(atColumn: 0, row: 0).minX

    #expect(
        iconInside
            == appKitCellX + ListingTableView.cellInset + icon.frame.minX
            - ListingRowView.selectionInset)
    // Finder's icon sits 7 points inside its selection (chevron-finder.jpg).
    #expect(iconInside == 7)
    #expect(row.convert(last.bounds, from: last).maxX <= band.maxX - 5)
}

/// List view's rows are 20 points and their icons 16, as Finder's list view draws them in macOS
/// 26, smaller than its column view's, and the name starts 3 points after the icon, as Finder's
/// does (fb-1029-1.jpg; docs/decisions/0135-list-rows-as-finder.md).
@MainActor @Test func aListRowsIconIsFindersSizeAndTheNameStartsWhereFindersDoes() async throws {
    let list = await controller(showing: [folder("audio")])
    list.view.layoutSubtreeIfNeeded()
    let row = try #require(list.tableView.rowView(atRow: 0, makeIfNecessary: true))
    let name = try #require(row.view(atColumn: 0) as? NSTableCellView)
    let icon = try #require(name.imageView)
    let text = try #require(name.textField)

    #expect(list.tableView.rowHeight == 20)
    #expect(list.tableView.rect(ofRow: 0).height == 20)
    #expect(icon.frame == NSRect(x: 2, y: 2, width: 16, height: 16))
    #expect(text.frame.minX == icon.frame.maxX + 3)
    #expect(text.frame.midY == 10)
}

/// The name is the label color and the Size, Date Modified and Kind text the secondary label
/// color, as Finder's list view draws them; on the emphasized selection the muted text is drawn
/// near white, as Finder's is (fb-1029-2.jpg; docs/decisions/0135-list-rows-as-finder.md).
@MainActor @Test func aListRowsMetadataIsMutedBesideItsName() async throws {
    let list = await controller(showing: [file("a.txt", size: 500)])
    list.view.appearance = NSAppearance(named: .aqua)
    list.view.layoutSubtreeIfNeeded()
    let row = try #require(list.tableView.rowView(atRow: 0, makeIfNecessary: true))
    let cells = try (0..<list.tableView.numberOfColumns).map {
        try #require(row.view(atColumn: $0) as? NSTableCellView)
    }
    let fields = try cells.map { try #require($0.textField) }

    #expect(fields[0].textColor == .labelColor)
    #expect(fields.dropFirst().allSatisfy { $0.textColor == .secondaryLabelColor })

    let size = cells[1]
    size.backgroundStyle = .emphasized
    let bitmap = try #require(size.bitmapImageRepForCachingDisplay(in: size.bounds))
    size.cacheDisplay(in: size.bounds, to: bitmap)
    let brightest = (0..<bitmap.pixelsWide).flatMap { x in
        (0..<bitmap.pixelsHigh).compactMap { y in
            bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB).flatMap {
                $0.alphaComponent > 0.5 ? min($0.redComponent, $0.blueComponent) : nil
            }
        }
    }.max()
    #expect(try #require(brightest) > 0.85)
}

/// One row of nothing, for a table of AppKit's own.
@MainActor
private final class OneRow: NSObject, NSTableViewDataSource {
    func numberOfRows(in tableView: NSTableView) -> Int { 1 }
}
