import AppKit
import Browser
import Testing

@testable import Interface

/// Three rows of nothing, enough for the table's own arrow handling to move a selection.
@MainActor
private final class ThreeRows: NSObject, NSTableViewDataSource {
    func numberOfRows(in tableView: NSTableView) -> Int { 3 }
}

/// A table with the app's commands, whose runner only records what it is asked to run. Row 1 is
/// selected and several rows may be, so the table's own ↑, ↓ or select-all would change
/// the selection.
@MainActor
private struct RecordingTable {
    let table = ListingTableView()
    let rows = ThreeRows()
    private let log = Log()

    init(registry: CommandRegistry) {
        table.addTableColumn(NSTableColumn(identifier: NSUserInterfaceItemIdentifier("name")))
        table.dataSource = rows
        table.allowsMultipleSelection = true
        table.registry = registry
        table.runCommand = { [log] in log.ids.append($0) }
        table.beep = { [log] in log.beeps += 1 }
        table.reloadData()
        table.selectRowIndexes([1], byExtendingSelection: false)
    }

    var ran: [CommandID] { log.ids }
    var beeps: Int { log.beeps }

    @MainActor private final class Log {
        var ids: [CommandID] = []
        var beeps = 0
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
        try keyEvent("k", modifiers: .command), try keyEvent("n", modifiers: .control),
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

@MainActor @Test func anUnboundUnmodifiedKeyDoesNotBeep() throws {
    let recording = RecordingTable(registry: CommandRegistry())
    recording.table.keyDown(
        with: try keyEvent(functionKey(NSDownArrowFunctionKey), modifiers: arrowFlags))
    recording.table.keyDown(with: try keyEvent("G", modifiers: .shift))

    #expect(recording.beeps == 0)
}

@MainActor @Test func selectAllWithNoCommandOnItsChordBeepsAndKeepsTheSelection() throws {
    let recording = RecordingTable(registry: CommandRegistry())
    recording.table.selectAll(nil)

    #expect(recording.beeps == 1)
    #expect(recording.ran.isEmpty)
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
        (try keyEvent(down, modifiers: arrowFlags.union(.option)), SelectionCommands.selectLast.id),
        (try keyEvent(up, modifiers: arrowFlags.union(.option)), SelectionCommands.selectFirst.id),
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
    let event = try #require(
        NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [.command, .shift], timestamp: 0,
            windowNumber: 0, context: nil, characters: typed, charactersIgnoringModifiers: typed,
            isARepeat: false, keyCode: keyCode))

    recording.table.keyDown(with: event)

    #expect(recording.ran == [ViewCommands.toggleHidden.id])
    #expect(recording.beeps == 0)
}
