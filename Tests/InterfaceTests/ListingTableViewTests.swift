import AppKit
import Browser
import TestSupport
import Testing

@testable import Interface

/// Three rows of nothing, enough for the table's own arrow handling to move a selection.
@MainActor
private final class ThreeRows: NSObject, NSTableViewDataSource {
    func numberOfRows(in tableView: NSTableView) -> Int { 3 }
}

/// A table with the app's commands, whose runner and type-select only record what they are asked
/// to do. Row 1 is selected and several rows may be, so the table's own ↑, ↓ or select-all would
/// change the selection. Type-select finds a match unless `matches` is false, and its query
/// resets on `clock`. The table sits in a window that records the keys AppKit passes on to it,
/// where a real window beeps.
@MainActor
private struct RecordingTable {
    let window = KeyCatchingWindow()
    let table = ListingTableView()
    let rows = ThreeRows()
    let clock = ManualClock()
    private let log = Log()

    init(registry: CommandRegistry, matches: Bool = true) {
        table.addTableColumn(NSTableColumn(identifier: NSUserInterfaceItemIdentifier("name")))
        table.dataSource = rows
        table.allowsMultipleSelection = true
        table.registry = registry
        table.runCommand = { [log] in log.ids.append($0) }
        table.typeSelect = TypeSelect(clock: clock)
        table.selectTyped = { [log] in
            log.queries.append($0)
            return matches
        }
        table.beep = { [log] in log.beeps += 1 }
        table.frame = NSRect(x: 0, y: 0, width: 400, height: 300)
        window.contentView?.addSubview(table)
        table.reloadData()
        table.selectRowIndexes([1], byExtendingSelection: false)
    }

    var ran: [CommandID] { log.ids }
    var beeps: Int { log.beeps }
    /// The query type-select was asked to select, once per key it took.
    var queries: [String] { log.queries }

    @MainActor private final class Log {
        var ids: [CommandID] = []
        var beeps = 0
        var queries: [String] = []
    }
}

@MainActor @Test func downRunsSelectNextAndNeverReachesTheTable() throws {
    let recording = RecordingTable(registry: try AppCommands.registry())
    recording.table.keyDown(
        with: try keyEvent(functionKey(NSDownArrowFunctionKey), modifiers: arrowFlags))

    #expect(recording.ran == [SelectionCommands.selectNext.id])
    #expect(recording.table.selectedRowIndexes == [1])
}

@MainActor @Test func upRunsSelectPreviousAndNeverReachesTheTable() throws {
    let recording = RecordingTable(registry: try AppCommands.registry())
    recording.table.keyDown(
        with: try keyEvent(functionKey(NSUpArrowFunctionKey), modifiers: arrowFlags))

    #expect(recording.ran == [SelectionCommands.selectPrevious.id])
    #expect(recording.table.selectedRowIndexes == [1])
}

@MainActor @Test func cmdDownRunsOpen() throws {
    let recording = RecordingTable(registry: try AppCommands.registry())
    recording.table.keyDown(
        with: try keyEvent(
            functionKey(NSDownArrowFunctionKey), modifiers: arrowFlags.union(.command)))

    #expect(recording.ran == [NavigationCommands.open.id])
}

@MainActor @Test func cmdOAndCmdUpRunOpenAndGoToParent() throws {
    let recording = RecordingTable(registry: try AppCommands.registry())
    recording.table.keyDown(with: try keyEvent("o", modifiers: .command))
    recording.table.keyDown(
        with: try keyEvent(functionKey(NSUpArrowFunctionKey), modifiers: arrowFlags.union(.command))
    )

    #expect(recording.ran == [NavigationCommands.open.id, NavigationCommands.goToParent.id])
    #expect(recording.beeps == 0)
}

@MainActor @Test func anUnboundModifiedKeyBeepsAndNeverReachesTheTable() throws {
    let recording = RecordingTable(registry: try AppCommands.registry())
    let unbound = [
        try keyEvent("j", modifiers: .command), try keyEvent("n", modifiers: .control),
        try keyEvent(
            functionKey(NSDownArrowFunctionKey), modifiers: arrowFlags.union([.option, .shift])),
    ]
    for press in unbound {
        recording.table.keyDown(with: press)
    }

    #expect(recording.beeps == unbound.count)
    #expect(recording.ran.isEmpty)
    #expect(recording.table.selectedRowIndexes == [1])
}

/// Tab, Ctrl-Tab and Ctrl-Shift-Tab move the key view when no command takes them: their command
/// is off, as Focus Other Pane is with one pane, or none is bound.
@MainActor @Test func aTabKeyWhoseCommandIsOffOrUnboundGoesToTheTableWithoutABeep() throws {
    let presses = [
        try keyEvent("\t"), try keyEvent("\t", modifiers: .control),
        try keyEvent("\u{19}", modifiers: [.control, .shift]),
    ]
    let off = RecordingTable(registry: try AppCommands.registry())
    var asked: [CommandID] = []
    off.table.canRunCommand = {
        asked.append($0)
        return false
    }
    let unbound = RecordingTable(registry: CommandRegistry())
    for recording in [off, unbound] {
        for press in presses {
            recording.table.keyDown(with: press)
        }
        #expect(recording.ran.isEmpty)
        #expect(recording.beeps == 0)
    }
    #expect(
        asked == [
            DualPaneCommands.focusOtherPane.id, WindowCommands.nextTab.id,
            WindowCommands.previousTab.id,
        ])
}

@MainActor @Test func aTabKeyWhoseCommandIsOnRunsIt() throws {
    let recording = RecordingTable(registry: try AppCommands.registry())
    recording.table.canRunCommand = { _ in true }

    recording.table.keyDown(with: try keyEvent("\t"))
    recording.table.keyDown(with: try keyEvent("\t", modifiers: .control))

    #expect(recording.ran == [DualPaneCommands.focusOtherPane.id, WindowCommands.nextTab.id])
}

@MainActor @Test func anUnboundUnmodifiedKeyDoesNotBeep() throws {
    let recording = RecordingTable(registry: CommandRegistry())
    recording.table.keyDown(
        with: try keyEvent(functionKey(NSDownArrowFunctionKey), modifiers: arrowFlags))
    recording.table.keyDown(with: try keyEvent("G", modifiers: .shift))

    #expect(recording.beeps == 0)
}

/// Edit ▸ Select All runs Select All by its ID, though the user gave Cmd-A to another command,
/// and the table's own select-all never runs.
@MainActor @Test func selectAllRunsItsCommandWhicheverCommandHasCmdA() throws {
    let bindings = try KeyBindings(
        commands: AppCommands.commands,
        overrides: [
            WindowCommands.goToItem.id: ShortcutOverride(
                primary: .chord(KeyChord("a", modifiers: .command)))
        ])
    let recording = RecordingTable(registry: bindings.registry)
    recording.table.selectAll(nil)

    #expect(recording.beeps == 0)
    #expect(recording.ran == [SelectionCommands.selectAll.id])
    #expect(recording.table.selectedRowIndexes == [1])
}

@MainActor @Test func selectAllRunsTheSelectAllCommand() throws {
    let recording = RecordingTable(registry: try AppCommands.registry())
    recording.table.selectAll(nil)

    #expect(recording.ran == [SelectionCommands.selectAll.id])
    #expect(recording.table.selectedRowIndexes == [1])
}

/// `NSTableView` extends its own selection on Shift-↑ and Shift-↓; these keys and the other row
/// movement keys run the pane's commands instead.
@MainActor @Test func rowMovementKeysRunTheirCommandsAndNeverReachTheTable() throws {
    let recording = RecordingTable(registry: try AppCommands.registry())
    let down = functionKey(NSDownArrowFunctionKey)
    let up = functionKey(NSUpArrowFunctionKey)
    let presses: [(NSEvent, CommandID)] = [
        (try keyEvent(down, modifiers: arrowFlags.union(.shift)), SelectionCommands.extendDown.id),
        (try keyEvent(up, modifiers: arrowFlags.union(.shift)), SelectionCommands.extendUp.id),
        (
            try keyEvent(down, modifiers: arrowFlags.union(.option)),
            SelectionCommands.tenRowsDown.id
        ),
        (try keyEvent(up, modifiers: arrowFlags.union(.option)), SelectionCommands.tenRowsUp.id),
        (
            try keyEvent(functionKey(NSEndFunctionKey), modifiers: .function),
            SelectionCommands.selectLast.id
        ),
        (
            try keyEvent(functionKey(NSHomeFunctionKey), modifiers: .function),
            SelectionCommands.selectFirst.id
        ),
        (
            try keyEvent(down, modifiers: arrowFlags.union([.command, .option])),
            SelectionCommands.selectLast.id
        ),
        (
            try keyEvent(up, modifiers: arrowFlags.union([.command, .option])),
            SelectionCommands.selectFirst.id
        ),
        (
            try keyEvent(down, modifiers: arrowFlags.union([.control, .shift])),
            SelectionCommands.tenRowsDown.id
        ),
        (
            try keyEvent(up, modifiers: arrowFlags.union([.control, .shift])),
            SelectionCommands.tenRowsUp.id
        ),
        (
            try keyEvent(functionKey(NSPageDownFunctionKey), modifiers: .function),
            SelectionCommands.pageDown.id
        ),
        (
            try keyEvent(functionKey(NSPageUpFunctionKey), modifiers: .function),
            SelectionCommands.pageUp.id
        ),
    ]
    for (event, _) in presses {
        recording.table.keyDown(with: event)
    }

    #expect(recording.ran == presses.map(\.1))
    #expect(recording.beeps == 0)
    #expect(recording.table.selectedRowIndexes == [1])
}

/// Three rows named "a", "b" and "c" in one column, counting the views it makes.
@MainActor
private final class CountingRows: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    var viewsMade = 0

    func numberOfRows(in tableView: NSTableView) -> Int { 3 }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int)
        -> NSView?
    {
        viewsMade += 1
        return NSTextField(labelWithString: ["a", "b", "c"][row])
    }
}

@MainActor @Test func aLetterKeyMakesNoRowViewsForTypeSelect() throws {
    let table = ListingTableView()
    let rows = CountingRows()
    table.addTableColumn(NSTableColumn(identifier: NSUserInterfaceItemIdentifier("name")))
    table.dataSource = rows
    table.delegate = rows
    table.registry = try AppCommands.registry()
    table.selectTyped = { _ in true }
    table.reloadData()
    rows.viewsMade = 0

    table.keyDown(with: try keyEvent("c"))

    #expect(!table.allowsTypeSelect)
    #expect(rows.viewsMade == 0)
    #expect(table.selectedRowIndexes.isEmpty)
}

@MainActor @Test func keyWithoutACommandGoesToTheTable() throws {
    let recording = RecordingTable(registry: CommandRegistry())
    recording.table.keyDown(
        with: try keyEvent(functionKey(NSDownArrowFunctionKey), modifiers: arrowFlags))

    #expect(recording.ran.isEmpty)
    #expect(recording.table.selectedRowIndexes == [2])
}

/// Cmd-Shift-. on a US keyboard types ">" on the period key (47). On a French AZERTY one it
/// types "." on the key whose own character is ";", which is key code 41 on the test machine's
/// layout. Either runs Show Hidden Files.
@MainActor @Test(arguments: [(">", 47), (".", 41)] as [(String, UInt16)])
func commandShiftPeriodRunsShowHiddenFilesWhereverTheLayoutPutsThePeriod(
    typed: String, keyCode: UInt16
) throws {
    let recording = RecordingTable(registry: try AppCommands.registry())
    let event = try keyEvent(typed, modifiers: [.command, .shift], keyCode: keyCode)

    recording.table.keyDown(with: event)

    #expect(recording.ran == [ViewCommands.toggleHidden.id])
    #expect(recording.beeps == 0)
}

// MARK: - Type-select

/// The app's registry binds Space to Quick Look. The test table's runner only records the ID,
/// so no panel opens.
private let quickLook = ViewCommands.toggleQuickLook

@MainActor @Test func aPlainLetterWithNoCommandGoesToTypeSelect() throws {
    let recording = RecordingTable(registry: try AppCommands.registry())
    recording.table.keyDown(with: try keyEvent("r"))
    recording.table.keyDown(with: try keyEvent("E", modifiers: .shift))

    #expect(recording.queries == ["r", "re"])
    #expect(recording.ran.isEmpty)
    #expect(recording.beeps == 0)
    #expect(recording.table.selectedRowIndexes == [1])
}

@MainActor @Test func aLetterBoundToACommandRunsTheCommand() throws {
    var registry = try AppCommands.registry()
    let letter = Command(id: CommandID("test.letter"), title: "Letter", chords: [KeyChord("q")])
    try registry.register(letter)
    let recording = RecordingTable(registry: registry)
    recording.table.keyDown(with: try keyEvent("q"))

    #expect(recording.ran == [letter.id])
    #expect(recording.queries.isEmpty)
}

@MainActor @Test func aCommandLetterWithNoCommandBeepsAndTypesNothing() throws {
    let recording = RecordingTable(registry: try AppCommands.registry())
    recording.table.keyDown(with: try keyEvent("j", modifiers: .command))

    #expect(recording.queries.isEmpty)
    #expect(recording.beeps == 1)
}

@MainActor @Test func aQueryWithNoMatchBeepsAndKeepsTheSelection() throws {
    let recording = RecordingTable(registry: try AppCommands.registry(), matches: false)
    recording.table.keyDown(with: try keyEvent("x"))

    #expect(recording.queries == ["x"])
    #expect(recording.beeps == 1)
    #expect(recording.table.selectedRowIndexes == [1])
}

@MainActor @Test func spaceWithinTheResetIntervalJoinsTheQuery() throws {
    let recording = RecordingTable(registry: try AppCommands.registry())
    recording.table.keyDown(with: try keyEvent("m"))
    recording.clock.advance(by: .milliseconds(500))
    recording.table.keyDown(with: try keyEvent(" "))
    recording.table.keyDown(with: try keyEvent("f"))

    #expect(recording.queries == ["m", "m ", "m f"])
    #expect(recording.ran.isEmpty)
}

@MainActor @Test func spaceWithNoQueryRunsItsCommand() throws {
    let recording = RecordingTable(registry: try AppCommands.registry())
    recording.table.keyDown(with: try keyEvent(" "))

    #expect(recording.ran == [quickLook.id])
    #expect(recording.queries.isEmpty)
}

@MainActor @Test func spaceAfterTheResetIntervalRunsItsCommand() throws {
    let recording = RecordingTable(registry: try AppCommands.registry())
    recording.table.keyDown(with: try keyEvent("m"))
    recording.clock.advance(by: TypeSelect.resetInterval)
    recording.table.keyDown(with: try keyEvent(" "))

    #expect(recording.ran == [quickLook.id])
    #expect(recording.queries == ["m"])
}

@MainActor @Test func shiftSpaceWhileTypingIsNotTypeSelect() throws {
    let recording = RecordingTable(registry: try AppCommands.registry())
    recording.table.keyDown(with: try keyEvent("m"))
    let shiftSpace = try keyEvent(" ", modifiers: .shift)
    recording.table.keyDown(with: shiftSpace)

    #expect(recording.window.unhandledKeys == [shiftSpace])
    #expect(recording.queries == ["m"])
    #expect(recording.ran.isEmpty)
}

@MainActor @Test func aCommandBetweenKeysStartsANewQuery() throws {
    let recording = RecordingTable(registry: try AppCommands.registry())
    recording.table.keyDown(with: try keyEvent("b"))
    recording.table.keyDown(
        with: try keyEvent(functionKey(NSDownArrowFunctionKey), modifiers: arrowFlags))
    recording.table.keyDown(with: try keyEvent("c"))

    #expect(recording.queries == ["b", "c"])
    #expect(recording.ran == [SelectionCommands.selectNext.id])
}

@MainActor @Test func aMenuCommandBetweenKeysStartsANewQuery() throws {
    let recording = RecordingTable(registry: try AppCommands.registry())
    recording.table.keyDown(with: try keyEvent("b"))
    recording.table.selectAll(nil)
    recording.table.keyDown(with: try keyEvent("c"))

    #expect(recording.queries == ["b", "c"])
}

@MainActor @Test func aMissedKeyStaysInTheQuery() throws {
    let recording = RecordingTable(registry: try AppCommands.registry(), matches: false)
    recording.table.keyDown(with: try keyEvent("x"))
    recording.table.keyDown(with: try keyEvent("y"))

    #expect(recording.queries == ["x", "xy"])
    #expect(recording.beeps == 2)
}

// MARK: - The header and the cells' inset

/// A list's table, its columns laid out and its header in place, drawn in the light appearance
/// whatever the Mac's, so its titles are dark for `titleStart`.
@MainActor
private func laidOutList() async throws -> (table: ListingTableView, header: NSTableHeaderView) {
    let list = await controller(showing: [file("a")])
    list.view.appearance = NSAppearance(named: .aqua)
    list.view.layoutSubtreeIfNeeded()
    list.tableView.layoutSubtreeIfNeeded()
    return (list.tableView, try #require(list.tableView.headerView))
}

/// The index of the column titled `title` in `table`, in the order shown.
@MainActor
private func column(_ title: String, in table: NSTableView) throws -> Int {
    try #require(table.tableColumns.firstIndex { $0.title == title })
}

/// Where the first dark pixel of `header`'s drawing is, left to right, in `rect`: the start of
/// the title drawn there.
@MainActor
private func titleStart(in header: NSTableHeaderView, within rect: NSRect) throws -> Double {
    let bitmap = try #require(header.bitmapImageRepForCachingDisplay(in: header.bounds))
    header.cacheDisplay(in: header.bounds, to: bitmap)
    let scale = Double(bitmap.pixelsWide) / header.bounds.width
    let y = Int(header.bounds.midY * scale)
    for x in Int(rect.minX * scale)..<Int(rect.maxX * scale) {
        for dy in -4...4 {
            guard let color = bitmap.colorAt(x: x, y: y + dy)?.usingColorSpace(.sRGB),
                color.alphaComponent > 0.5,
                (color.redComponent + color.greenComponent + color.blueComponent) / 3 < 0.5
            else { continue }
            return Double(x) / scale
        }
    }
    Issue.record("no title drawn in \(rect)")
    return .nan
}

/// How far right of where AppKit's own header cell draws it the title of `index` starts.
@MainActor
private func titleShift(ofColumn index: Int, in header: NSTableHeaderView) throws -> Double {
    let column = try #require(header.tableView?.tableColumns[index])
    let rect = header.headerRect(ofColumn: index)
    let moved = try titleStart(in: header, within: rect)
    let cell = column.headerCell
    let plain = NSTableHeaderCell(textCell: cell.stringValue)
    plain.alignment = cell.alignment
    column.headerCell = plain
    defer { column.headerCell = cell }
    return moved - (try titleStart(in: header, within: rect))
}

/// The first column's title and cells move in by the one constant, `cellInset`; a column
/// between the ends keeps AppKit's. The last column's cells end that much sooner.
@MainActor @Test func theFirstHeadersTitleMovesInWithItsCells() async throws {
    let (table, header) = try await laidOutList()
    let last = table.numberOfColumns - 1
    let inset = ListingTableView.cellInset

    #expect(try column("Name", in: table) == 0)
    #expect(abs(try titleShift(ofColumn: 0, in: header) - inset) <= 0.5)
    #expect(abs(try titleShift(ofColumn: 1, in: header)) <= 0.5)
    // AppKit's cells, in a table of its own with the same columns.
    let plain = NSTableView(frame: table.frame)
    plain.style = table.style
    plain.intercellSpacing = table.intercellSpacing
    plain.rowHeight = table.rowHeight
    for column in table.tableColumns {
        let copy = NSTableColumn(identifier: column.identifier)
        copy.width = column.width
        plain.addTableColumn(copy)
    }
    let rows = ThreeRows()
    plain.dataSource = rows
    plain.reloadData()
    let first = table.frameOfCell(atColumn: 0, row: 0)
    let plainFirst = plain.frameOfCell(atColumn: 0, row: 0)
    #expect(first.minX - plainFirst.minX == inset)
    #expect(
        plain.frameOfCell(atColumn: last, row: 0).maxX
            - table.frameOfCell(atColumn: last, row: 0).maxX == inset)
    #expect(table.frameOfCell(atColumn: 1, row: 0) == plain.frameOfCell(atColumn: 1, row: 0))
}

/// A column the user moves to the front takes the moved title; the one it displaced loses it.
@MainActor @Test func aColumnMovedToTheFrontTakesTheMovedTitle() async throws {
    let (table, header) = try await laidOutList()

    table.moveColumn(try column("Kind", in: table), toColumn: 0)

    #expect(try column("Kind", in: table) == 0)
    #expect(abs(try titleShift(ofColumn: 0, in: header) - ListingTableView.cellInset) <= 0.5)
    #expect(abs(try titleShift(ofColumn: try column("Name", in: table), in: header)) <= 0.5)
}

/// Only the titles move: the header's rects stay AppKit's, from the header's left edge to the
/// last column's end, so a press in the first column's left 8 points or the last column's right
/// 8 points lands on that column, to sort it or drag it, and the last column's resize edge is
/// where it shows. A real press can't be sent (`clickHeader` in ListingViewControllerTests says
/// why), so the column the header finds at the point stands for it.
@MainActor @Test func theHeadersRectsAndPressesStayAppKits() async throws {
    let (table, header) = try await laidOutList()
    let last = table.numberOfColumns - 1
    let first = header.headerRect(ofColumn: 0)
    let end = header.headerRect(ofColumn: last)

    #expect(first.minX == 0)
    #expect(first.minX == table.rect(ofColumn: 0).minX)
    #expect(end.maxX == table.rect(ofColumn: last).maxX)
    let inset = ListingTableView.cellInset
    #expect(header.column(at: NSPoint(x: first.minX + inset / 2, y: first.midY)) == 0)
    #expect(header.column(at: NSPoint(x: end.maxX - inset / 2, y: end.midY)) == last)
}

/// Drawn outside a table's header, as AppKit may draw a header cell for a dragged column's
/// image, the cell draws its title where AppKit's own does.
@MainActor @Test func aHeaderCellDrawnOutsideAHeaderDrawsItsTitleUnmoved() throws {
    let view = NSView(frame: NSRect(x: 0, y: 0, width: 120, height: 28))
    view.appearance = NSAppearance(named: .aqua)
    /// The opacity of each pixel the cell draws.
    func drawn(_ cell: NSTableHeaderCell) throws -> [CGFloat] {
        let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        view.effectiveAppearance.performAsCurrentDrawingAppearance {
            cell.drawInterior(withFrame: view.bounds, in: view)
        }
        NSGraphicsContext.restoreGraphicsState()
        return (0..<bitmap.pixelsHigh).flatMap { y in
            (0..<bitmap.pixelsWide).map { x in bitmap.colorAt(x: x, y: y)?.alphaComponent ?? 0 }
        }
    }

    let ours = try drawn(ListingTableView.HeaderCell(textCell: "Name"))
    let appKits = try drawn(NSTableHeaderCell(textCell: "Name"))

    #expect(ours.contains { $0 > 0.5 })
    #expect(ours == appKits)
}
