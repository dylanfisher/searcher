import Base
import BrowserTestSupport
import Foundation
import TestSupport
import Testing

@testable import Browser

/// A pane at `/rows` with files "r00" to "r24", sized so that by size, largest first, the order
/// reverses; loaded, with 7 rows on screen.
@MainActor
private func rows25() async -> PaneFixture {
    let fixture = PaneFixture(
        at: "/rows",
        folders: ["/rows": (0..<25).map { file(String(format: "r%02d", $0), size: Int64($0)) }])
    await settle { fixture.pane.state.isLoaded }
    fixture.pane.visibleRowCount = 7
    return fixture
}

private func name(_ row: Int) -> ExactName {
    ExactName(String(format: "r%02d", row))
}

private func names(_ rows: ClosedRange<Int>) -> Set<ExactName> {
    Set(rows.map(name))
}

@MainActor
private func run(_ chord: KeyChord, in fixture: PaneFixture, isKeyRepeat: Bool = false) throws {
    let registry = try AppCommands.registry()
    let command = try #require(registry.command(for: chord), "nothing is bound to \(chord)")
    let binding = try #require(AppCommands.bindings.first { $0.command == command })
    binding.run(CommandContext(pane: fixture.pane, isKeyRepeat: isKeyRepeat))
}

@MainActor
private func put(_ fixture: PaneFixture, at row: Int) {
    fixture.pane.select(Selection([name(row)], cursor: name(row)))
}

private let down = KeyChord(.down)
private let up = KeyChord(.up)
private let optionDown = KeyChord(.down, modifiers: .option)
private let optionUp = KeyChord(.up, modifiers: .option)
private let home = KeyChord(.home)
private let end = KeyChord(.end)
private let commandOptionUp = KeyChord(.up, modifiers: [.command, .option])
private let commandOptionDown = KeyChord(.down, modifiers: [.command, .option])
private let tenDown = KeyChord(.down, modifiers: [.control, .shift])
private let tenUp = KeyChord(.up, modifiers: [.control, .shift])
private let pageDown = KeyChord(.pageDown)
private let pageUp = KeyChord(.pageUp)
private let shiftDown = KeyChord(.down, modifiers: .shift)
private let shiftUp = KeyChord(.up, modifiers: .shift)
private let commandA = KeyChord("a", modifiers: .command)

@MainActor
@Test(
    arguments: [
        // (chord, start row, row after one press, row after many presses)
        (down, 12, 13, 24), (up, 12, 11, 0),
        (optionDown, 12, 22, 24), (optionUp, 12, 2, 0),
        (home, 12, 0, 0), (end, 12, 24, 24),
        (commandOptionUp, 12, 0, 0), (commandOptionDown, 12, 24, 24),
        (tenDown, 12, 22, 24), (tenUp, 12, 2, 0),
        (pageDown, 12, 19, 24), (pageUp, 12, 5, 0),
    ])
func eachRowCommandMovesTheCursorAndClampsAtTheEnd(
    chord: KeyChord, start: Int, once: Int, clamped: Int
) async throws {
    let fixture = await rows25()
    put(fixture, at: start)

    try run(chord, in: fixture)
    #expect(fixture.pane.selection == Selection([name(once)], cursor: name(once)), "\(chord)")

    for _ in 0..<30 {
        try run(chord, in: fixture)
    }
    #expect(fixture.pane.selection == Selection([name(clamped)], cursor: name(clamped)), "\(chord)")
}

@MainActor @Test func thePageFollowsTheRowsOnScreen() async throws {
    let fixture = await rows25()
    put(fixture, at: 0)
    fixture.pane.visibleRowCount = 3

    try run(pageDown, in: fixture)

    #expect(fixture.pane.selection.cursor == name(3))
}

@MainActor @Test func shiftDownAfterShiftUpShrinksTowardTheAnchor() async throws {
    let fixture = await rows25()
    put(fixture, at: 10)

    try run(shiftUp, in: fixture)
    try run(shiftUp, in: fixture)
    #expect(fixture.pane.selection == Selection(names(8...10), cursor: name(8), anchor: name(10)))

    try run(shiftDown, in: fixture)
    #expect(fixture.pane.selection == Selection(names(9...10), cursor: name(9), anchor: name(10)))
    try run(shiftDown, in: fixture)
    try run(shiftDown, in: fixture)
    #expect(fixture.pane.selection == Selection(names(10...11), cursor: name(11), anchor: name(10)))
}

/// As in Finder and `NSTableView`, Shift-↑ and Shift-↓ change the range from the anchor and keep
/// the rows selected outside it, such as Cmd-clicked ones.
@MainActor @Test func shiftKeepsRowsSelectedOutsideTheRange() async throws {
    let fixture = await rows25()
    // Rows 2 and 10 Cmd-clicked, the cursor and anchor on 10.
    fixture.pane.select(Selection([name(2), name(10)], cursor: name(10)))

    try run(shiftDown, in: fixture)
    #expect(
        fixture.pane.selection
            == Selection([name(2), name(10), name(11)], cursor: name(11), anchor: name(10)))

    for _ in 0..<3 {
        try run(shiftUp, in: fixture)
    }
    #expect(
        fixture.pane.selection
            == Selection(names(8...10).union([name(2)]), cursor: name(8), anchor: name(10)))
}

@MainActor @Test func aPlainMoveCollapsesAMultiRowSelection() async throws {
    let fixture = await rows25()
    put(fixture, at: 4)
    try run(shiftDown, in: fixture)
    try run(shiftDown, in: fixture)

    try run(down, in: fixture)

    #expect(fixture.pane.selection == Selection([name(7)], cursor: name(7)))
}

@MainActor @Test func commandASelectsEveryRowAndKeepsTheCursor() async throws {
    let fixture = await rows25()
    put(fixture, at: 4)

    try run(commandA, in: fixture)

    #expect(fixture.pane.selection == Selection(.allExcept([]), cursor: name(4), anchor: name(4)))
    #expect(
        fixture.pane.selection.rows(in: try #require(fixture.pane.state.listing))
            == IndexSet(0...24))
    try run(down, in: fixture)
    #expect(fixture.pane.selection == Selection([name(5)], cursor: name(5)))
}

/// A file that appears after Cmd-A was never seen, so a command on the selection must not take
/// it in.
@MainActor @Test func aFileAddedAfterCommandAIsNotSelected() async throws {
    let fixture = await rows25()
    put(fixture, at: 4)
    try run(commandA, in: fixture)
    let version = fixture.pane.stateVersion

    fixture.pane.apply(
        .patches([.update(file("a-new")), .remove(name: "r03")]), at: fixture.pane.location)
    await settle { fixture.pane.stateVersion != version }

    let listing = try #require(fixture.pane.state.listing)
    #expect(!fixture.pane.selection.contains(ExactName("a-new")))
    #expect(fixture.pane.selection.rows(in: listing) == IndexSet(1...24))
    #expect(fixture.pane.selection.members == .allExcept([ExactName("a-new")]))
}

@MainActor @Test func theSelectionSurvivesAReSortByName() async throws {
    let fixture = await rows25()
    put(fixture, at: 2)
    try run(shiftDown, in: fixture)

    fixture.pane.setSort(.size, ascending: false)
    await settle { fixture.pane.state.listing?.column == .size }

    // By size, largest first, "r03" is row 21 and "r02" row 22.
    #expect(fixture.pane.selection == Selection(names(2...3), cursor: name(3), anchor: name(2)))
    let sorted = try #require(fixture.pane.state.listing)
    #expect(fixture.pane.selection.rows(in: sorted) == IndexSet(21...22))
    try run(shiftDown, in: fixture)
    #expect(fixture.pane.selection == Selection([name(2)], cursor: name(2), anchor: name(2)))
    #expect(fixture.pane.selection.rows(in: sorted) == [22])
}

/// A pane at `/wide` over a `StubLister` with files "w0000" up to `count`, loaded. Change the
/// lister's entries before a reload to change the folder.
@MainActor
private func widePane(_ count: Int) async -> (Pane, StubLister) {
    let lister = StubLister(["/wide": wideEntries(count)])
    let pane = Pane(
        location: Location(path: "/wide"), service: ListingService(lister: lister),
        systemActions: StubSystemActions(), settings: untouchedSettings())
    await settle { pane.state.isLoaded }
    return (pane, lister)
}

private func wideEntries(_ count: Int) -> [DirectoryEntry] {
    (0..<count).map { file(String(format: "w%04d", $0)) }
}

private func wide(_ row: Int) -> ExactName {
    ExactName(String(format: "w%04d", row))
}

#if DEBUG
    @MainActor @Test func aReloadAfterCommandALandsWithNoSelectionWorkOnTheMainThread() async throws
    {
        let (pane, lister) = await widePane(4_000)
        pane.selectAll()
        // "a-new" sorts first.
        lister.set("/wide", to: wideEntries(4_000) + [file("a-new")])
        let work = pane.mainSelectionWork

        pane.reload()
        await settle { pane.state.isLoaded && pane.state.listing?.count == 4_001 }

        #expect(pane.mainSelectionWork == work)
        #expect(!pane.selection.contains(ExactName("a-new")))
        #expect(pane.selection.members == .allExcept([ExactName("a-new")]))
        #expect(pane.selection.rows(in: try #require(pane.state.listing)) == IndexSet(1...4_000))
    }

    @MainActor @Test
    func aPatchWithHalfTheRowsSelectedByNameLandsWithNoSelectionWorkOnTheMainThread()
        async throws
    {
        let (pane, _) = await widePane(4_000)
        pane.select(rows: IndexSet(0..<2_000), cursor: wide(1_999), anchor: wide(1_999))
        let work = pane.mainSelectionWork
        let version = pane.stateVersion

        // "a-new" sorts first and moves every row down one.
        pane.apply(
            .patches([.update(file("w0001", size: 9)), .update(file("a-new"))]), at: pane.location)
        await settle { pane.stateVersion != version }

        #expect(pane.mainSelectionWork == work)
        #expect(pane.selection.rows(in: try #require(pane.state.listing)) == IndexSet(1...2_000))
    }
#endif

/// The load resolved the selection it started with; the user's ↓ during the load replaced it,
/// so the pane resolves the new one when the load lands.
@MainActor @Test func aSelectionChangedDuringALoadIsResolvedWhenItLands() async throws {
    let (pane, lister) = await widePane(25)
    pane.select(Selection([wide(4)], cursor: wide(4)))
    pane.selectAll()
    lister.set("/wide", to: wideEntries(25) + [file("a-new")])

    pane.reload()
    // The load hands its listing over on the main queue, so this runs before it lands.
    pane.moveSelection(by: 1)
    await settle {
        pane.state.isLoaded && pane.state.listing?.count == 26 && pane.selection.isSettled
    }

    #expect(pane.selection == Selection([wide(5)], cursor: wide(5)))
    #expect(pane.selection.rows(in: try #require(pane.state.listing)) == [6])
}

/// The same file name, removed and written again in one batch, stays selected whether it was
/// selected by name or by Select All.
@MainActor @Test(arguments: [false, true])
func aNameRemovedAndWrittenAgainInOneBatchStaysSelected(afterSelectAll: Bool) async throws {
    let fixture = await rows25()
    put(fixture, at: 3)
    if afterSelectAll {
        try run(commandA, in: fixture)
    }
    let version = fixture.pane.stateVersion

    fixture.pane.apply(
        .patches([.remove(name: "r03"), .update(file("r03", size: 3))]),
        at: fixture.pane.location)
    await settle { fixture.pane.stateVersion != version }

    #expect(fixture.pane.selection.contains(name(3)))
    #expect(fixture.pane.selection.rows(in: try #require(fixture.pane.state.listing)).contains(3))
}

@MainActor @Test func theSelectionSurvivesAChangeWatchingPatchByName() async throws {
    let fixture = await rows25()
    put(fixture, at: 2)
    try run(shiftDown, in: fixture)
    let version = fixture.pane.stateVersion

    // A new first row moves every selected entry down one.
    fixture.pane.apply(.patches([.update(file("a-new"))]), at: fixture.pane.location)
    await settle { fixture.pane.stateVersion != version }

    #expect(fixture.pane.selection == Selection(names(2...3), cursor: name(3), anchor: name(2)))
    try run(down, in: fixture)
    #expect(fixture.pane.selection == Selection([name(4)], cursor: name(4)))
}

@MainActor
@Test(
    arguments: [
        down, up, optionDown, optionUp, home, end, commandOptionUp, commandOptionDown, tenDown,
        tenUp, pageDown, pageUp, shiftDown,
        shiftUp, commandA,
    ])
func movingOnAnEmptyListingDoesNothing(chord: KeyChord) async throws {
    let fixture = PaneFixture(at: "/empty", folders: ["/empty": []])
    await settle { fixture.pane.state.isLoaded }
    var changes = 0
    fixture.pane.onChange = { changes += 1 }

    try run(chord, in: fixture)

    #expect(fixture.pane.selection == Selection())
    #expect(changes == 0)
}

// MARK: Selection undo

private let commandU = KeyChord("u", modifiers: .command)
private let shiftCommandU = KeyChord("u", modifiers: [.command, .shift])

@MainActor
private func isEnabled(_ chord: KeyChord, in fixture: PaneFixture) throws -> Bool {
    let registry = try AppCommands.registry()
    let command = try #require(registry.command(for: chord), "nothing is bound to \(chord)")
    let binding = try #require(AppCommands.bindings.first { $0.command == command })
    return binding.isEnabled?(CommandContext(pane: fixture.pane)) ?? true
}

@MainActor @Test func commandURestoresTheSelectionAndCursorAndShiftCommandURedoes() async throws {
    let fixture = await rows25()
    put(fixture, at: 3)
    fixture.pane.select(Selection(names(5...6), cursor: name(6), anchor: name(5)))
    #expect(try !isEnabled(shiftCommandU, in: fixture))

    try run(commandU, in: fixture)
    await settle { fixture.pane.selection.isSettled }
    #expect(fixture.pane.selection == Selection([name(3)], cursor: name(3)))
    #expect(fixture.pane.selection.rows(in: try #require(fixture.pane.state.listing)) == [3])

    try run(shiftCommandU, in: fixture)
    await settle { fixture.pane.selection.isSettled }
    #expect(fixture.pane.selection == Selection(names(5...6), cursor: name(6), anchor: name(5)))
    #expect(fixture.pane.selection.rows(in: try #require(fixture.pane.state.listing)) == [5, 6])
}

@MainActor @Test func selectionUndoIsOffWithNothingToUndoAndOnAfterAChange() async throws {
    let fixture = await rows25()
    #expect(try !isEnabled(commandU, in: fixture))
    #expect(try !isEnabled(shiftCommandU, in: fixture))

    put(fixture, at: 3)
    put(fixture, at: 4)

    #expect(try isEnabled(commandU, in: fixture))
    try run(commandU, in: fixture)
    #expect(try isEnabled(shiftCommandU, in: fixture))
}

@MainActor @Test func aChangeAfterCommandUEndsTheWayForward() async throws {
    let fixture = await rows25()
    put(fixture, at: 3)
    put(fixture, at: 4)
    try run(commandU, in: fixture)

    try run(down, in: fixture)

    #expect(try !isEnabled(shiftCommandU, in: fixture))
}

@MainActor @Test func threeTapsOfDownAreThreeSteps() async throws {
    let fixture = await rows25()
    put(fixture, at: 2)

    for _ in 0..<3 {
        try run(down, in: fixture)
    }

    for row in [4, 3, 2] {
        try run(commandU, in: fixture)
        await settle { fixture.pane.selection.isSettled }
        #expect(fixture.pane.selection == Selection([name(row)], cursor: name(row)))
    }
    #expect(try !isEnabled(commandU, in: fixture))
}

@MainActor @Test func aHeldDownArrowIsOneStepHoweverLongItRepeats() async throws {
    let fixture = await rows25()
    let clock = ManualClock()
    fixture.tab.selectionHistory = SelectionHistory(clock: clock)
    put(fixture, at: 2)

    try run(down, in: fixture)
    for _ in 0..<4 {
        clock.advance(by: .seconds(2))
        try run(down, in: fixture, isKeyRepeat: true)
    }
    #expect(fixture.pane.selection.cursor == name(7))

    try run(commandU, in: fixture)
    await settle { fixture.pane.selection.isSettled }
    #expect(fixture.pane.selection == Selection([name(2)], cursor: name(2)))
    #expect(try !isEnabled(commandU, in: fixture))
}

@MainActor @Test func aTypeToSelectBurstIsOneStep() async throws {
    let fixture = await rows25()
    put(fixture, at: 0)
    let context = CommandContext(pane: fixture.pane)

    for query in ["r", "r1", "r12"] {
        #expect(SelectionCommands.selectFirstRow(startingWith: query, in: context))
    }
    #expect(fixture.pane.selection.cursor == name(12))

    try run(commandU, in: fixture)
    await settle { fixture.pane.selection.isSettled }
    #expect(fixture.pane.selection == Selection([name(0)], cursor: name(0)))
    #expect(try !isEnabled(commandU, in: fixture))
}

@MainActor @Test func commandURestoresOnlyTheEntriesStillListed() async throws {
    let fixture = await rows25()
    fixture.pane.select(Selection(names(3...4), cursor: name(4), anchor: name(3)))
    put(fixture, at: 10)
    let version = fixture.pane.stateVersion
    fixture.pane.apply(.patches([.remove(name: "r04")]), at: fixture.pane.location)
    await settle { fixture.pane.stateVersion != version }

    try run(commandU, in: fixture)
    await settle { fixture.pane.selection.isSettled }

    #expect(fixture.pane.selection.members == .only([name(3)]))
    #expect(fixture.pane.selection.rows(in: try #require(fixture.pane.state.listing)) == [3])
}

@MainActor @Test func commandUSkipsAStepWhoseEntriesAreAllGone() async throws {
    let fixture = await rows25()
    put(fixture, at: 3)
    put(fixture, at: 10)
    put(fixture, at: 12)
    let version = fixture.pane.stateVersion
    fixture.pane.apply(.patches([.remove(name: "r10")]), at: fixture.pane.location)
    await settle { fixture.pane.stateVersion != version }

    try run(commandU, in: fixture)
    await settle { fixture.pane.selection.isSettled }
    #expect(fixture.pane.selection == Selection([name(3)], cursor: name(3)))
    #expect(try !isEnabled(commandU, in: fixture))

    try run(shiftCommandU, in: fixture)
    await settle { fixture.pane.selection.isSettled }
    #expect(fixture.pane.selection == Selection([name(12)], cursor: name(12)))
}

/// A step that would select what is selected now, here because its other entry left the
/// folder, is no step: with nothing else, Cmd-U is off and does nothing.
@MainActor @Test func commandUSkipsAStepThatWouldRestoreTheCurrentSelection() async throws {
    let fixture = await rows25()
    fixture.pane.select(Selection(names(3...4), cursor: name(3), anchor: name(3)))
    put(fixture, at: 3)
    let version = fixture.pane.stateVersion
    fixture.pane.apply(.patches([.remove(name: "r04")]), at: fixture.pane.location)
    await settle { fixture.pane.stateVersion != version }
    let selectionVersion = fixture.pane.selectionVersion

    #expect(try !isEnabled(commandU, in: fixture))
    try run(commandU, in: fixture)
    #expect(fixture.pane.selectionVersion == selectionVersion)
}

/// A click's rows settle off the main thread into the selection a step already holds, which
/// changes no version; Cmd-U, asked before, is off once they settle.
@MainActor @Test func commandUIsOffOnceAClickSettlesIntoItsOnlyStep() async throws {
    let fixture = await rows25()
    let pane = fixture.pane
    put(fixture, at: 5)
    put(fixture, at: 3)
    let version = pane.stateVersion
    pane.apply(.patches([.remove(name: "r05")]), at: pane.location)
    await settle { pane.stateVersion != version }
    pane.select(Selection())
    let naming = heldQueue("naming")
    pane.settleQueue = naming

    pane.select(rows: [3], cursor: name(3), anchor: name(3))
    #expect(try isEnabled(commandU, in: fixture))
    naming.resume()
    await settle { pane.selection.isSettled }

    #expect(try !isEnabled(commandU, in: fixture))
}

/// `/rows` with files "r00" to "r24", and `/other` with "o1" and "o2", both in `/`; loaded at
/// `/rows`.
@MainActor
private func rowsAndOther() async -> PaneFixture {
    let fixture = PaneFixture(
        at: "/rows",
        folders: [
            "/rows": (0..<25).map { file(String(format: "r%02d", $0)) },
            "/other": [file("o1"), file("o2")],
            "/": [folder("other"), folder("rows")],
        ])
    await settle { fixture.pane.state.isLoaded }
    return fixture
}

/// Going to another folder drops the pane's steps, so Cmd-U never navigates: in the new folder
/// it does nothing, and back in the first folder its steps are gone too
/// (docs/decisions/0112-position-history.md).
@MainActor @Test func goingToAnotherFolderDropsThePanesSteps() async throws {
    let fixture = await rowsAndOther()
    put(fixture, at: 3)
    put(fixture, at: 5)
    put(fixture, at: 7)
    try run(commandU, in: fixture)
    #expect(try isEnabled(shiftCommandU, in: fixture))

    fixture.pane.navigate(to: Location(path: "/other"))
    await settle { fixture.pane.state.isLoaded && fixture.pane.location.path == "/other" }
    #expect(try !isEnabled(commandU, in: fixture))
    #expect(try !isEnabled(shiftCommandU, in: fixture))
    try run(commandU, in: fixture)
    #expect(fixture.pane.location.path == "/other")
    #expect(fixture.pane.selection == Selection())

    fixture.pane.goBack()
    await settle { fixture.pane.state.isLoaded && fixture.pane.location.path == "/rows" }
    #expect(fixture.pane.selection.cursor == name(5))
    #expect(try !isEnabled(commandU, in: fixture))
    #expect(try !isEnabled(shiftCommandU, in: fixture))
}

/// Listing the folder the pane is in again is no navigation: its steps stay.
@MainActor @Test func goingToTheFolderThePaneIsInKeepsItsSteps() async throws {
    let fixture = await rowsAndOther()
    put(fixture, at: 3)
    put(fixture, at: 5)

    fixture.pane.navigate(to: Location(path: "/rows"))
    await settle { fixture.pane.state.isLoaded }

    try run(commandU, in: fixture)
    await settle { fixture.pane.selection.isSettled }
    #expect(fixture.pane.selection == Selection([name(3)], cursor: name(3)))
}

@MainActor @Test(arguments: [ViewMode.column, .list])
func switchingTheViewModeDropsThePanesSteps(_ mode: ViewMode) async throws {
    let fixture = await rowsAndOther()
    if mode == .list {
        fixture.pane.setViewMode(.column)
        await settle { fixture.pane.commandPane.state.isLoaded }
    }
    let shown = fixture.pane.commandPane
    shown.select(Selection([name(3)], cursor: name(3)))
    shown.select(Selection([name(5)], cursor: name(5)))
    #expect(fixture.tab.canUndoSelection)

    fixture.pane.setViewMode(mode)
    await settle { fixture.pane.commandPane.state.isLoaded }

    #expect(fixture.pane.commandPane.selection.cursor == name(5))
    #expect(!fixture.tab.canUndoSelection)
}

@MainActor @Test func eachTabHasItsOwnSelectionHistory() async throws {
    let first = await rows25()
    let second = await rows25()
    put(first, at: 3)
    put(first, at: 4)

    #expect(try isEnabled(commandU, in: first))
    #expect(try !isEnabled(commandU, in: second))
}

/// Runs the command bound to `chord` with `pane` the one keys act on.
@MainActor
private func run(_ chord: KeyChord, on pane: Pane) throws {
    let registry = try AppCommands.registry()
    let command = try #require(registry.command(for: chord), "nothing is bound to \(chord)")
    let binding = try #require(AppCommands.bindings.first { $0.command == command })
    binding.run(CommandContext(pane: pane))
}

/// A split of `rowsAndOther()`'s pane: the pane on the left, unfocused, and its copy on the right,
/// focused, both at `/rows` with nothing selected.
@MainActor
private func splitRows() async throws -> (PaneFixture, left: Pane, right: Pane) {
    let fixture = await rowsAndOther()
    let tab = fixture.tab
    let right = try #require(tab.split(.horizontal, in: Rect(x: 0, y: 0, width: 1200, height: 800)))
    await settle { right.state.isLoaded }
    return (fixture, fixture.pane, right)
}

/// Steps of both panes of a split are one history: Cmd-U steps back through the focused pane's,
/// then to the other pane, which takes the focus with the selection it had when the keys left
/// it, then through its steps, and Shift-Cmd-U forward again, each pane getting back what it had
/// (docs/decisions/0112-position-history.md).
@MainActor @Test func commandUStepsThroughBothPanesOfASplitAndFocusesThePaneItRestores()
    async throws
{
    let (fixture, left, right) = try await splitRows()
    let tab = fixture.tab
    let leftID = try #require(tab.panes.first { $0.value === left }?.key)
    let rightID = tab.layout.focused
    tab.focus(leftID, recordingAs: nil)
    tab.selectionHistory = SelectionHistory()
    left.select(Selection([name(1)], cursor: name(1)))
    left.select(Selection([name(2)], cursor: name(2)))
    tab.focus(rightID)
    right.select(Selection([name(10)], cursor: name(10)))
    right.select(Selection([name(11)], cursor: name(11)))

    try run(commandU, on: right)
    #expect(tab.layout.focused == rightID)
    #expect(right.selection.cursor == name(10))
    try run(commandU, on: right)
    #expect(tab.layout.focused == leftID)
    #expect(left.selection.cursor == name(2))
    #expect(right.selection.cursor == name(10))
    try run(commandU, on: left)
    #expect(tab.layout.focused == leftID)
    #expect(left.selection.cursor == name(1))
    #expect(!tab.canUndoSelection)

    try run(shiftCommandU, on: left)
    #expect(tab.layout.focused == leftID)
    #expect(left.selection.cursor == name(2))
    try run(shiftCommandU, on: left)
    #expect(tab.layout.focused == rightID)
    #expect(right.selection.cursor == name(10))
    try run(shiftCommandU, on: right)
    #expect(tab.layout.focused == rightID)
    #expect(right.selection.cursor == name(11))
    #expect(left.selection.cursor == name(2))
    #expect(!tab.canRedoSelection)
}

/// A move of the keys to another pane of a split is a step: Cmd-U gives the pane they left the
/// keys back, with its selection, and Shift-Cmd-U the other pane again. A held focus key is one
/// step however many panes its repeats cross (docs/decisions/0112-position-history.md).
@MainActor @Test func commandUAfterMovingToAnotherPaneGivesThePaneTheKeysLeftThemBack()
    async throws
{
    let (fixture, left, _) = try await splitRows()
    let tab = fixture.tab
    let leftID = try #require(tab.panes.first { $0.value === left }?.key)
    let rightID = tab.layout.focused
    let third = try #require(tab.split(.horizontal, in: Rect(x: 0, y: 0, width: 1800, height: 800)))
    let thirdID = tab.layout.focused
    await settle { third.state.isLoaded }
    tab.selectionHistory = SelectionHistory()
    third.select(Selection([name(20)], cursor: name(20)))
    left.select(Selection([name(3)], cursor: name(3)))

    tab.focus(.left)
    #expect(tab.layout.focused == rightID)
    tab.focus(.left, isKeyRepeat: true)
    #expect(tab.layout.focused == leftID)

    tab.undoSelection()
    #expect(tab.layout.focused == thirdID)
    #expect(third.selection.cursor == name(20))
    #expect(left.selection.cursor == name(3))
    #expect(!tab.canUndoSelection)

    tab.redoSelection()
    #expect(tab.layout.focused == leftID)
    #expect(!tab.canRedoSelection)

    tab.focus(thirdID)
    tab.focus(.left)
    #expect(tab.layout.focused == rightID)
    tab.undoSelection()
    #expect(tab.layout.focused == thirdID)
    tab.undoSelection()
    #expect(tab.layout.focused == leftID)
}

/// A pane that closes takes its steps with it; the other pane's stay.
@MainActor @Test func closingAPaneDropsItsStepsAndKeepsTheOthers() async throws {
    let (fixture, left, right) = try await splitRows()
    let tab = fixture.tab
    let leftID = try #require(tab.panes.first { $0.value === left }?.key)
    let rightID = tab.layout.focused
    tab.focus(leftID)
    left.select(Selection([name(1)], cursor: name(1)))
    left.select(Selection([name(2)], cursor: name(2)))
    tab.focus(rightID)
    right.select(Selection([name(10)], cursor: name(10)))
    right.select(Selection([name(11)], cursor: name(11)))

    #expect(tab.closePane() == .pane)

    #expect(!tab.selectionHistory.canUndo { $0.pane == rightID })
    #expect(tab.layout.focused == leftID)
    tab.undoSelection()
    #expect(left.selection.cursor == name(1))
    #expect(!tab.canUndoSelection)
}

/// A pane that goes to another folder drops its own steps, which aren't there when it comes
/// back; the other pane's stay.
@MainActor @Test func aPaneGoingToAnotherFolderKeepsTheOtherPanesSteps() async throws {
    let (fixture, left, right) = try await splitRows()
    let tab = fixture.tab
    let leftID = try #require(tab.panes.first { $0.value === left }?.key)
    tab.focus(leftID)
    left.select(Selection([name(1)], cursor: name(1)))
    left.select(Selection([name(2)], cursor: name(2)))
    right.select(Selection([name(10)], cursor: name(10)))
    right.select(Selection([name(11)], cursor: name(11)))

    right.navigate(to: Location(path: "/other"))
    right.goBack()
    await settle { right.location.path == "/rows" && right.state.isLoaded }
    #expect(right.selection.cursor == name(11))

    tab.undoSelection()
    #expect(left.selection.cursor == name(1))
    #expect(!tab.canUndoSelection)
}

/// A pane moved out to another window leaves its steps behind, dropped, and its changes from
/// then on are steps of its new tab.
@MainActor @Test func aPaneMovedToAnotherWindowTakesNoStepsAndLeavesNone() async throws {
    let (fixture, _, right) = try await splitRows()
    let tab = fixture.tab
    let rightID = tab.layout.focused
    right.select(Selection([name(10)], cursor: name(10)))
    right.select(Selection([name(11)], cursor: name(11)))

    #expect(tab.removeFocusedPane() == .pane)
    let moved = Tab(pane: right, id: rightID)

    #expect(!tab.selectionHistory.canUndo { $0.pane == rightID })
    #expect(!moved.canUndoSelection)
    right.select(Selection([name(12)], cursor: name(12)))
    #expect(moved.canUndoSelection)
    #expect(!tab.selectionHistory.canUndo { $0.pane == rightID })
}

@MainActor @Test func optionAndControlShiftArrowsMoveTenRowsAndHomeAndEndSelectTheEnds() throws {
    let registry = try AppCommands.registry()

    #expect(registry.command(for: optionDown) == SelectionCommands.tenRowsDown)
    #expect(registry.command(for: optionUp) == SelectionCommands.tenRowsUp)
    #expect(registry.command(for: tenDown) == SelectionCommands.tenRowsDown)
    #expect(registry.command(for: tenUp) == SelectionCommands.tenRowsUp)
    #expect(registry.command(for: home) == SelectionCommands.selectFirst)
    #expect(registry.command(for: end) == SelectionCommands.selectLast)
}

@MainActor @Test func commandOptionArrowsSelectTheEndsAndHomeAndEndStayBound() throws {
    let registry = try AppCommands.registry()

    #expect(registry.command(for: commandOptionUp) == SelectionCommands.selectFirst)
    #expect(registry.command(for: commandOptionDown) == SelectionCommands.selectLast)
    #expect(SelectionCommands.selectFirst.chords == [home, commandOptionUp])
    #expect(SelectionCommands.selectLast.chords == [end, commandOptionDown])
}
