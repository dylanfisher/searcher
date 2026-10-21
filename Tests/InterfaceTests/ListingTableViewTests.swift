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
/// selected, so the table's own ↑ or ↓ handling would move the selection.
@MainActor
private struct RecordingTable {
    let table = ListingTableView()
    let rows = ThreeRows()
    private let log = Log()

    init(registry: CommandRegistry) {
        table.addTableColumn(NSTableColumn(identifier: NSUserInterfaceItemIdentifier("name")))
        table.dataSource = rows
        table.registry = registry
        table.runCommand = { [log] in log.ids.append($0) }
        table.reloadData()
        table.selectRowIndexes([1], byExtendingSelection: false)
    }

    var ran: [CommandID] { log.ids }

    @MainActor private final class Log {
        var ids: [CommandID] = []
    }
}

private let arrowFlags: NSEvent.ModifierFlags = [.numericPad, .function]

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

@MainActor @Test func keyWithoutACommandGoesToTheTable() throws {
    let recording = RecordingTable(registry: CommandRegistry())
    recording.table.keyDown(
        with: try keyEvent(functionKey(NSDownArrowFunctionKey), modifiers: arrowFlags))

    #expect(recording.ran.isEmpty)
    #expect(recording.table.selectedRowIndexes == [2])
}
