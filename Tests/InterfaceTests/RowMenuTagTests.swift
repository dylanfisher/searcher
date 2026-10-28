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

/// The menu a right-click on the name of `name`'s row builds, the press sent through the app as
/// one the user makes: the window hit-tests it and the view it hits passes it on until the
/// table builds its menu (`ListingTableView.menu(for:)`). Nil when the press built none. The
/// menu is kept, not shown, so the test tracks no menu and takes no input from the user. The
/// window is on the second display for the press, then ordered out
/// (docs/decisions/0091-test-windows-on-second-display.md).
@MainActor
private func menuARightClickBuilds(onNameOf name: String, in window: TaggingWindow) throws
    -> NSMenu?
{
    let shown = try #require(window.controller.window)
    shown.setFrame(NSRect(x: 0, y: 0, width: 900, height: 600), display: false)
    SecondDisplay.orderFront(shown)
    defer { shown.orderOut(nil) }
    shown.contentView?.layoutSubtreeIfNeeded()
    let list = try window.list
    let nameFrame = list.nameFrame(atRow: try window.row(of: name))
    let point = list.tableView.convert(
        NSPoint(x: nameFrame.minX + 4, y: nameFrame.midY), to: nil)
    let press = try mouseEvent(
        .rightMouseDown, at: point, in: shown, timestamp: ProcessInfo.processInfo.systemUptime)
    let table = list.tableView
    let build = table.contextMenu
    defer { table.contextMenu = build }
    var built: NSMenu?
    table.contextMenu = { row in
        built = build(row)
        return nil
    }
    // Taken from the queue, as the app's event loop takes a press, so it is the app's current
    // event while the window hit-tests it. After `nextEvent`, HIToolbox may stop the outermost
    // main run loop, which would end the test process (`performRealPress`).
    dropStrayMainRunLoopStops()
    while NSApp.nextEvent(matching: .any, until: .distantPast, inMode: .default, dequeue: true)
        != nil
    {}
    NSApp.postEvent(press, atStart: true)
    let taken = try #require(
        NSApp.nextEvent(
            matching: .rightMouseDown, until: .distantPast, inMode: .default, dequeue: true))
    #expect(NSApp.currentEvent === taken)
    NSApp.sendEvent(taken)
    // The press stays the app's current event until another is taken, and the views of later
    // tests, pressed without the queue, would see a right-click. An event of no kind replaces it.
    let blank = try #require(
        NSEvent.otherEvent(
            with: .applicationDefined, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: 0, context: nil, subtype: 0, data1: 0, data2: 0))
    NSApp.postEvent(blank, atStart: true)
    _ = NSApp.nextEvent(
        matching: .applicationDefined, until: .distantPast, inMode: .default, dequeue: true)
    #expect(NSApp.currentEvent?.type == .applicationDefined)
    return built
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

/// Dylan: "what do you mean by the dots? the colors? these aren't displaying". A right-click on
/// a row's name builds the row menu, in a list and in a column, and its dots show: an item that
/// isn't hidden, at a size, each dot drawn in its tag's color, with the selection's tags on
/// them. In a column the name's label and the icon took the right-click and no menu opened
/// (docs/decisions/0124-tags-in-rows-and-preview.md).
@MainActor @Test(arguments: [ViewMode.list, .column])
func aRightClickOnARowsNameBuildsTheMenuWithItsTagDotsShown(_ viewMode: ViewMode) async throws {
    let window = try await TaggingWindow(
        [("a.txt", ["Orange\n7"]), ("b.txt", [])], viewMode: viewMode)

    let menu = try #require(try menuARightClickBuilds(onNameOf: "a.txt", in: window))

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
    #expect(try window.dot("Orange", in: dots).coverage == .allItems)
    #expect(try window.dot("Red", in: dots).coverage == .noItems)
    #expect(try coloredDots(dots) == FinderTag.all.map(\.name))
}
