import AppKit
import Base
import BrowserTestSupport
import Foundation
import TestSupport
import Testing

@testable import Browser
@testable import Interface

// The row menu's tag dots, driven through a real window (`TaggingWindow`): its pane and list
// over a real temporary folder, its table's commands, the app's queue and the undo history that
// follows it. Nothing is faked (docs/decisions/0121-tag-commands.md).

@MainActor @Test func aRowMenuDotTagsTheSelectionThroughTheQueueAndUndoTakesItOff() async throws {
    let window = try await TaggingWindow([("a.txt", ["Red", "Work"]), ("b.txt", [])])
    window.pane.select(
        Selection([ExactName("a.txt"), ExactName("b.txt")], cursor: ExactName("b.txt")))

    let dots = try await window.dots(onRowOf: "b.txt")
    let red = try window.dot("Red", in: dots)
    // One of the two has Red: the dot shows a dash, and a click adds it to the other.
    #expect(red.coverage == .someItems)
    #expect(red.mark == .dash)
    #expect(red.isEnabled)
    #expect(red.accessibilityLabel() == "Add Tag “Red”")
    #expect(try window.dot("Blue", in: dots).coverage == .noItems)

    // What a mouse-up on the dot sends.
    #expect(red.sendAction(red.action, to: red.target))
    await settle { window.history.undoTitle == "Undo Add Tag “Red”" }

    #expect(try await tags(window.path("a.txt")) == ["Red", "Work"])
    #expect(try await tags(window.path("b.txt")) == ["Red\n6"])
    let after = try window.dot("Red", in: try await window.dots(onRowOf: "b.txt"))
    #expect(after.coverage == .allItems)
    #expect(after.mark == .check)
    #expect(after.accessibilityLabel() == "Remove Tag “Red”")

    try window.list.tableView.run(UndoCommands.undo.id)
    await settle { window.history.redoTitle == "Redo Add Tag “Red”" }

    #expect(try await tags(window.path("a.txt")) == ["Red", "Work"])
    #expect(try await tags(window.path("b.txt")) == [])
}

@MainActor @Test func theFileMenusTagItemsShowTheirColorsAndRunOnTheSelection() async throws {
    let window = try await TaggingWindow([("a.txt", [])])
    window.pane.select(Selection([ExactName("a.txt")], cursor: ExactName("a.txt")))
    let bar = try MainMenuBuilder.build(appName: "Searcher", registry: AppCommands.registry())
    let file = try #require(bar.items.first { $0.title == "File" }?.submenu)
    let tagsMenu = try #require(file.items.first { $0.title == TagCommands.menuTitle }?.submenu)
    let shown = tagsMenu.items.filter { !$0.isHidden }

    #expect(shown.map(\.title) == FinderTag.all.map { "\($0.name) Tag" })
    #expect(shown.allSatisfy { $0.image != nil })

    let green = try #require(shown.first { $0.title == "Green Tag" })
    let table = try window.list.tableView
    #expect(table.validateMenuItem(green))
    table.runMenuCommand(green)
    await settle { window.history.undoTitle == "Undo Add Tag “Green”" }
    #expect(try await tags(window.path("a.txt")) == ["Green\n2"])
}

/// Where on a row a test presses: the name's label, the icon, the first tag dot, the cell's
/// empty end, and a folder's chevron in a column.
enum RowSpot: String, CaseIterable, Sendable {
    case name, icon, dot, emptyEnd, chevron
}

/// The presses that open a context menu.
enum MenuPress: String, CaseIterable, Sendable {
    case rightClick, controlClick
}

/// The window point of `spot` on `name`'s row.
@MainActor
private func windowPoint(of spot: RowSpot, onRowOf name: String, in window: TaggingWindow)
    throws -> NSPoint
{
    let list = try window.list
    let table = list.tableView
    let row = try window.row(of: name)
    let cell = try window.nameCell(of: name)
    let cellFrame = table.frameOfCell(
        atColumn: table.column(withIdentifier: SortColumn.name.identifier), row: row)
    let point: NSPoint
    switch spot {
    case .name:
        let name = list.nameFrame(atRow: row)
        point = NSPoint(x: name.minX + 4, y: name.midY)
    case .icon:
        let icon = try #require(cell.imageView)
        point = table.convert(NSPoint(x: icon.frame.midX, y: icon.frame.midY), from: cell)
    case .dot:
        let dots = try #require(try window.rowDots(of: name))
        let dot = dots.dotRect(at: 0)
        point = table.convert(NSPoint(x: dot.midX, y: dot.midY), from: dots)
    case .emptyEnd:
        point = NSPoint(x: cellFrame.maxX - 2, y: cellFrame.midY)
    case .chevron:
        let chevron = try #require(ListingCellLayout.chevron(in: cell))
        try #require(!chevron.isHidden)
        point = table.convert(NSPoint(x: chevron.frame.midX, y: chevron.frame.midY), from: cell)
    }
    return table.convert(point, to: nil)
}

/// What the table did with a press: the rows it built a menu for, and the menu it built last.
@MainActor
private final class TablePresses {
    var menuRows: [Int] = []
    var menu: NSMenu?
}

/// Sends a `type` press with `modifiers` at `spot` on `name`'s row through the app's queue
/// (`sendThroughTheQueue`), a left press released at once, and records the menus the table
/// builds, keeping each rather than showing it, so the test tracks no menu and takes no input
/// from the user. The window is on the second display for the press, then ordered out
/// (docs/decisions/0091-test-windows-on-second-display.md).
@MainActor
private func press(
    _ type: NSEvent.EventType, modifiers: NSEvent.ModifierFlags = [], at spot: RowSpot,
    onRowOf name: String, in window: TaggingWindow
) throws -> TablePresses {
    let shown = try #require(window.controller.window)
    shown.setFrame(NSRect(x: 0, y: 0, width: 900, height: 600), display: false)
    SecondDisplay.orderFront(shown)
    defer { shown.orderOut(nil) }
    shown.contentView?.layoutSubtreeIfNeeded()
    let point = try windowPoint(of: spot, onRowOf: name, in: window)
    let now = ProcessInfo.processInfo.systemUptime
    let down = try mouseEvent(type, at: point, in: shown, modifiers: modifiers, timestamp: now)
    let up =
        type == .leftMouseDown
        ? try mouseEvent(
            .leftMouseUp, at: point, in: shown, modifiers: modifiers, timestamp: now + 0.05)
        : nil
    let table = try window.list.tableView
    let build = table.contextMenu
    defer { table.contextMenu = build }
    let presses = TablePresses()
    table.contextMenu = { row in
        presses.menuRows.append(row)
        presses.menu = build(row)
        return nil
    }
    try sendThroughTheQueue(down, releasedBy: up)
    return presses
}

/// A press that opens a context menu, at a spot of a row, in a view.
struct MenuPressCase: Sendable, CustomTestStringConvertible {
    let viewMode: ViewMode
    let spot: RowSpot
    let press: MenuPress

    var testDescription: String { "\(viewMode) \(spot.rawValue) \(press.rawValue)" }

    /// Every spot in both views with both presses; the chevron in a column only.
    static let all: [MenuPressCase] = [ViewMode.list, .column].flatMap { viewMode in
        RowSpot.allCases.filter { viewMode == .column || $0 != .chevron }.flatMap { spot in
            MenuPress.allCases.map { MenuPressCase(viewMode: viewMode, spot: spot, press: $0) }
        }
    }
}

/// The names of the tags whose dot `dots` draws in its tag's color: drawn as the open menu draws
/// it, and sampled inside each circle, clear of its mark.
@MainActor
private func coloredDots(_ dots: TagDotsView) throws -> [String] {
    let bitmap = try #require(dots.bitmapImageRepForCachingDisplay(in: dots.bounds))
    dots.cacheDisplay(in: dots.bounds, to: bitmap)
    let scale = CGFloat(bitmap.pixelsWide) / dots.bounds.width
    return dots.dots.filter { dot in
        let frame = dot.convert(dot.bounds, to: dots)
        let sample = NSPoint(x: frame.midX, y: frame.midY + TagDotButton.restDiameter / 2 - 1.5)
        let pixel = bitmap.colorAt(
            x: Int(sample.x * scale), y: bitmap.pixelsHigh - Int(sample.y * scale) - 1)
        guard let pixel = pixel?.usingColorSpace(.sRGB),
            let fill = dot.fill.usingColorSpace(.sRGB)
        else { return false }
        return abs(pixel.redComponent - fill.redComponent) < 0.1
            && abs(pixel.greenComponent - fill.greenComponent) < 0.1
            && abs(pixel.blueComponent - fill.blueComponent) < 0.1
    }
    .map(\.finderTag.name)
}

/// Dylan: "what do you mean by the dots? the colors? these aren't displaying". A right-click
/// or a Control-click anywhere on a row's name cell, on its name, icon, tag dot or empty end or
/// a folder's chevron, builds the menu for that row, in a list and in a column, and its dots
/// show: an item that isn't hidden, at a size, each dot drawn in its tag's color, with the
/// selection's tags on them. The press goes through the app's queue, as a click does: sent
/// without being the app's current event, a right-click on the label or the icon reached no
/// menu, which an earlier version of this test took for a bug in the app
/// (docs/decisions/0124-tags-in-rows-and-preview.md).
@MainActor @Test(arguments: MenuPressCase.all)
func aMenuPressOnARowsNameCellBuildsTheMenuWithItsTagDotsShown(_ test: MenuPressCase)
    async throws
{
    let window = try await TaggingWindow(
        [("a.txt", ["Orange\n7"]), ("b.txt", [])], folders: ["f"], viewMode: test.viewMode)
    let name = test.spot == .chevron ? "f" : "a.txt"

    let presses =
        switch test.press {
        case .rightClick: try press(.rightMouseDown, at: test.spot, onRowOf: name, in: window)
        case .controlClick:
            try press(
                .leftMouseDown, modifiers: .control, at: test.spot, onRowOf: name, in: window)
        }

    #expect(presses.menuRows == [try window.row(of: name)])
    let menu = try #require(presses.menu)
    let item = try #require(menu.items.first { $0.view is TagDotsView })
    let dots = try #require(item.view as? TagDotsView)
    #expect(!item.isHidden && !dots.isHidden)
    #expect(dots.frame.width > 0 && dots.frame.height > 0)
    #expect(
        dots.dots.allSatisfy {
            !$0.isHidden && $0.frame.width == TagDotButton.side
                && dots.bounds.contains($0.frame)
        })
    #expect(dots.dots.count == FinderTag.all.count)
    await settle { dots.hasTags }
    dots.validate()
    let orange: FinderTag.Coverage = name == "a.txt" ? .allItems : .noItems
    #expect(try window.dot("Orange", in: dots).coverage == orange)
    #expect(try window.dot("Red", in: dots).coverage == .noItems)
    #expect(try coloredDots(dots) == FinderTag.all.map(\.name))
}

/// A plain press on a name builds no menu and reaches the table, which selects the row, in a
/// list and in a column.
@MainActor @Test(arguments: [ViewMode.list, .column])
func aPlainPressOnANameSelectsTheRowAndBuildsNoMenu(_ viewMode: ViewMode) async throws {
    let window = try await TaggingWindow(
        [("a.txt", ["Orange\n7"]), ("b.txt", [])], viewMode: viewMode)
    let list = try window.list
    list.pane.select(Selection([ExactName("b.txt")], cursor: ExactName("b.txt")))

    let presses = try press(.leftMouseDown, at: .name, onRowOf: "a.txt", in: window)

    #expect(presses.menuRows.isEmpty)
    #expect(list.pane.selection.cursor == ExactName("a.txt"))
    #expect(list.tableView.selectedRowIndexes == [try window.row(of: "a.txt")])
}
