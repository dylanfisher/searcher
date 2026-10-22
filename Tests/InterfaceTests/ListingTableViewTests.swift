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
        try keyEvent(functionKey(NSDownArrowFunctionKey), modifiers: arrowFlags.union(.option)),
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
    let recording = RecordingTable(registry: try AppCommands.registry())
    recording.table.selectAll(nil)

    #expect(recording.beeps == 1)
    #expect(recording.ran.isEmpty)
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
