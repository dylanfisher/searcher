import AppKit
import TestSupport
import Testing

@testable import Interface

/// A selected row 300 points wide, as a list's or a column's.
@MainActor
private func selectedRow(emphasized: Bool = true) -> ListingRowView {
    let row = ListingRowView(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
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

    let band = (row as? ListingRowView)?.selectionPath.bounds ?? .zero
    #expect(row.convert(icon.frame, from: name).minX - band.minX == 7)
    #expect(row.convert(last.bounds, from: last).maxX <= band.maxX - 5)
}
