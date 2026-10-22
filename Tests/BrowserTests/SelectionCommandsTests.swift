import Base
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
private func run(_ chord: KeyChord, in fixture: PaneFixture) throws {
    let registry = try AppCommands.registry()
    let command = try #require(registry.command(for: chord), "nothing is bound to \(chord)")
    let binding = try #require(AppCommands.bindings.first { $0.command == command })
    binding.run(CommandContext(pane: fixture.pane))
}

@MainActor
private func put(_ fixture: PaneFixture, at row: Int) {
    fixture.pane.select(Selection([name(row)], cursor: name(row)))
}

private let down = KeyChord(.down)
private let up = KeyChord(.up)
private let optionDown = KeyChord(.down, modifiers: .option)
private let optionUp = KeyChord(.up, modifiers: .option)
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
        (optionDown, 12, 24, 24), (optionUp, 12, 0, 0),
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
        down, up, optionDown, optionUp, tenDown, tenUp, pageDown, pageUp, shiftDown,
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
