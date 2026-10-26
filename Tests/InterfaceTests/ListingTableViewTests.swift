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
    let event = try #require(
        NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [.command, .shift], timestamp: 0,
            windowNumber: 0, context: nil, characters: typed, charactersIgnoringModifiers: typed,
            isARepeat: false, keyCode: keyCode))

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
