import Base
import BrowserTestSupport
import Foundation
import TestSupport
import Testing

@testable import Browser

/// `/r` holds folders `docs` and `other` and a file `a.txt`; `/r/docs` holds a folder `sub` and
/// a file `x.txt`.
private let tree: [String: [DirectoryEntry]] = [
    "/": [folder("r")],
    "/r": [folder("docs"), folder("other"), file("a.txt")],
    "/r/docs": [folder("sub"), file("x.txt"), file(".hidden")],
    "/r/docs/sub": [file("deep.txt")],
    "/r/other": [file("o.txt")],
]

/// A focused pane at `path` over `tree`, loaded, switched to column mode, with its first column
/// loaded.
@MainActor
private func columnPane(at path: String = "/r", selecting name: String? = nil) async
    -> PaneFixture
{
    let fixture = PaneFixture(at: path, folders: tree)
    await settle { fixture.pane.state.isLoaded }
    if let name { fixture.select(name) }
    fixture.pane.setViewMode(.column)
    await settle { trail(fixture.pane).focused.pane.state.isLoaded }
    return fixture
}

@MainActor
private func trail(_ pane: Pane) -> ColumnTrail {
    guard let trail = pane.columnTrail else {
        preconditionFailure("the pane isn't in column mode")
    }
    return trail
}

@MainActor
private func paths(_ pane: Pane) -> [String] {
    trail(pane).columns.map(\.pane.location.path)
}

/// Selects `name` alone in `column`, as a click or a key does.
@MainActor
private func select(_ name: String, in column: Column) {
    column.pane.select(Selection([ExactName(name)], cursor: ExactName(name)))
}

/// Runs the command bound to `chord` on the pane keys act on, as the view does.
@MainActor
private func press(_ chord: KeyChord, on pane: Pane) throws {
    let registry = try AppCommands.registry()
    let command = try #require(registry.command(for: chord), "nothing is bound to \(chord)")
    let binding = try #require(AppCommands.bindings.first { $0.command == command })
    binding.run(CommandContext(pane: pane.commandPane))
}

@MainActor @Test func switchingToColumnModeStartsTheTrailAtThePanesLocation() async {
    let fixture = await columnPane(selecting: "a.txt")
    let pane = fixture.pane

    #expect(pane.viewMode == .column)
    #expect(paths(pane) == ["/r"])
    #expect(trail(pane).focusedIndex == 0)
    #expect(trail(pane).focused.pane.selection.cursor == ExactName("a.txt"))
    #expect(pane.commandPane === trail(pane).focused.pane)
}

@MainActor @Test func switchingToColumnModeWithAFolderSelectedShowsItInTheNextColumn() async {
    let fixture = await columnPane(selecting: "docs")

    await settle { paths(fixture.pane) == ["/r", "/r/docs"] }
    #expect(trail(fixture.pane).focusedIndex == 0)
}

@MainActor @Test func selectingAFolderAddsAColumnAndAFileAddsNone() async {
    let fixture = await columnPane()
    let first = trail(fixture.pane).columns[0]

    select("docs", in: first)
    #expect(paths(fixture.pane) == ["/r", "/r/docs"])
    await settle { trail(fixture.pane).columns[1].pane.state.isLoaded }
    #expect(trail(fixture.pane).columns[1].pane.state.names == ["sub", "x.txt"])

    // A file opens no column: the folder's column goes, and the file's preview isn't one.
    select("a.txt", in: first)
    #expect(paths(fixture.pane) == ["/r"])
}

/// The lister answers for the file's path too, so a column wrongly made for it shows up in the
/// trail instead of trapping in the lister.
@MainActor @Test func selectingAFileWithNoColumnToItsRightAddsNone() async {
    var folders = tree
    folders["/r/a.txt"] = []
    let fixture = PaneFixture(at: "/r", folders: folders)
    await settle { fixture.pane.state.isLoaded }
    fixture.pane.setViewMode(.column)
    await settle { trail(fixture.pane).focused.pane.state.isLoaded }

    select("a.txt", in: trail(fixture.pane).columns[0])
    await drainMainQueue()

    #expect(paths(fixture.pane) == ["/r"])
}

/// A pane at `/p` in column mode over `/p`, holding a package `App.app` and a folder `docs`.
@MainActor
private func packageColumns() async -> PaneFixture {
    let fixture = PaneFixture(
        at: "/p",
        folders: [
            "/p": [package("App.app"), folder("docs")], "/p/App.app": [folder("Contents")],
            "/p/App.app/Contents": [file("Info.plist")], "/p/docs": [file("x.txt")],
        ])
    await settle { fixture.pane.state.isLoaded }
    fixture.pane.setViewMode(.column)
    await settle { trail(fixture.pane).focused.pane.state.isLoaded }
    return fixture
}

@MainActor @Test func selectingAPackageAddsNoColumnPreviewsItAndRightDoesNothing() async throws {
    let fixture = await packageColumns()
    let first = trail(fixture.pane).columns[0]
    select("docs", in: first)
    #expect(paths(fixture.pane) == ["/p", "/p/docs"])

    select("App.app", in: first)
    await drainMainQueue()
    #expect(paths(fixture.pane) == ["/p"])
    #expect(trail(fixture.pane).preview?.location == Location(path: "/p/App.app"))
    #expect(trail(fixture.pane).preview?.entry == package("App.app"))

    try press(KeyChord(.right), on: fixture.pane)
    #expect(paths(fixture.pane) == ["/p"])
    #expect(trail(fixture.pane).focusedIndex == 0)
    #expect(fixture.actions.openedFiles.isEmpty)
}

/// A package selected by keys waits for the pause, as a file does, then previews and still adds
/// no column; Show Package Contents opens its column at once, since it is a command.
@MainActor @Test func aPackageSelectedByKeysPreviewsAfterThePauseAndShowContentsOpensAtOnce()
    async throws
{
    let clock = ManualClock()
    let fixture = await packageColumns()
    fixture.pane.columnOpenClock = clock
    let pane = fixture.pane
    select("docs", in: trail(pane).columns[0])
    #expect(paths(pane) == ["/p", "/p/docs"])

    try press(KeyChord(.up), on: pane)

    #expect(trail(pane).columns[0].pane.selection.cursor == ExactName("App.app"))
    #expect(paths(pane) == ["/p"])
    #expect(trail(pane).preview == nil)
    await settle { clock.waitingSleeps == 1 }
    clock.advance(by: ColumnTrail.openDelay)
    await settle { trail(pane).preview?.location == Location(path: "/p/App.app") }
    #expect(paths(pane) == ["/p"])

    try press(KeyChord(.down), on: pane)
    try press(KeyChord(.up), on: pane)
    let binding = try #require(
        AppCommands.bindings.first { $0.command == NavigationCommands.showPackageContents })
    binding.run(CommandContext(pane: pane.commandPane))

    #expect(paths(pane) == ["/p", "/p/App.app"])
    #expect(trail(pane).focusedIndex == 1)
    clock.advance(by: ColumnTrail.openDelay)
    for _ in 0..<3 { await drainMainQueue() }
    #expect(paths(pane) == ["/p", "/p/App.app"])
}

@MainActor @Test func showPackageContentsAddsThePackagesColumnAndMovesIntoItUntilAnotherSelection()
    async throws
{
    let fixture = await packageColumns()
    let first = trail(fixture.pane).columns[0]
    select("App.app", in: first)
    let binding = try #require(
        AppCommands.bindings.first { $0.command == NavigationCommands.showPackageContents })

    binding.run(CommandContext(pane: fixture.pane.commandPane))

    #expect(paths(fixture.pane) == ["/p", "/p/App.app"])
    #expect(trail(fixture.pane).focusedIndex == 1)
    #expect(trail(fixture.pane).preview == nil)
    await settle { trail(fixture.pane).columns[1].pane.state.isLoaded }
    select("Contents", in: trail(fixture.pane).columns[1])
    #expect(paths(fixture.pane) == ["/p", "/p/App.app", "/p/App.app/Contents"])

    // A change in the package's own column keeps the package's column while it stays selected.
    first.pane.reload()
    await settle { first.pane.state.isLoaded }
    #expect(paths(fixture.pane).prefix(2) == ["/p", "/p/App.app"])

    select("docs", in: first)
    #expect(paths(fixture.pane) == ["/p", "/p/docs"])
    select("App.app", in: first)
    #expect(paths(fixture.pane) == ["/p"])
}

@MainActor @Test func selectingAFolderTruncatesTheColumnsToItsRight() async {
    let fixture = await columnPane()
    let first = trail(fixture.pane).columns[0]
    select("docs", in: first)
    await settle { trail(fixture.pane).columns[1].pane.state.isLoaded }
    select("sub", in: trail(fixture.pane).columns[1])
    #expect(paths(fixture.pane) == ["/r", "/r/docs", "/r/docs/sub"])

    select("other", in: first)

    #expect(paths(fixture.pane) == ["/r", "/r/other"])
    await settle { trail(fixture.pane).columns[1].pane.state.isLoaded }
    #expect(trail(fixture.pane).columns[1].pane.state.names == ["o.txt"])
}

@MainActor @Test func truncatedColumnsCancelTheirLoadsAndReleaseTheirWatches() async {
    let fixture = PaneFixture(at: "/r", folders: tree, held: true)
    fixture.lister.release("/r")
    fixture.lister.release("/r/docs")
    await settle { fixture.pane.state.isLoaded }
    fixture.pane.setViewMode(.column)
    await settle { trail(fixture.pane).focused.pane.state.isLoaded }
    let first = trail(fixture.pane).columns[0]
    select("docs", in: first)
    await settle { trail(fixture.pane).columns[1].pane.state.isLoaded }
    select("sub", in: trail(fixture.pane).columns[1])
    let docs = trail(fixture.pane).columns[1].pane
    let sub = trail(fixture.pane).columns[2].pane
    let docsMonitor = StubMonitor()
    let subMonitor = StubMonitor()
    docs.monitor = docsMonitor
    sub.monitor = subMonitor
    #expect(await fixture.lister.waitForCall("/r/docs/sub"))

    select("a.txt", in: first)
    fixture.lister.release("/r/docs/sub")
    #expect(await fixture.lister.waitForFinished(4))
    await drainMainQueue()

    #expect(paths(fixture.pane) == ["/r"])
    #expect(docsMonitor.stopCount == 1)
    #expect(subMonitor.stopCount == 1)
    #expect(docs.monitor == nil && sub.monitor == nil)
    // The held load was cancelled, so its listing never reached the column.
    #expect(sub.state.isLoading)

    // A monitor that finishes starting after its column went is stopped at once.
    let late = StubMonitor()
    sub.monitor = late
    #expect(late.stopCount == 1)
    #expect(sub.monitor == nil)
}

@MainActor @Test func rightMovesIntoTheSelectedFolderAndLeftBackToItsColumn() async throws {
    let fixture = await columnPane()
    let pane = fixture.pane
    select("docs", in: trail(pane).columns[0])
    await settle { trail(pane).columns[1].pane.state.isLoaded }

    try press(KeyChord(.right), on: pane)

    #expect(trail(pane).focusedIndex == 1)
    #expect(pane.location == Location(path: "/r/docs"))
    // Moving into a column with nothing selected selects its first row.
    #expect(trail(pane).focused.pane.selection.cursor == ExactName("sub"))
    #expect(paths(pane) == ["/r", "/r/docs", "/r/docs/sub"])

    try press(KeyChord(.left), on: pane)

    #expect(trail(pane).focusedIndex == 0)
    #expect(pane.location == Location(path: "/r"))
    #expect(paths(pane) == ["/r", "/r/docs", "/r/docs/sub"])
}

@MainActor @Test func rightOnAFileDoesNothing() async throws {
    let fixture = await columnPane(selecting: "a.txt")

    try press(KeyChord(.right), on: fixture.pane)

    #expect(trail(fixture.pane).focusedIndex == 0)
    #expect(paths(fixture.pane) == ["/r"])
    #expect(trail(fixture.pane).preview?.location == Location(path: "/r/a.txt"))
}

@MainActor
@Test(arguments: [KeyChord(.left), KeyChord(.up, modifiers: .command)])
func leftOrCommandUpPastTheFirstColumnAddsItsParentOnTheLeft(chord: KeyChord) async throws {
    let fixture = await columnPane(at: "/r/docs")
    let pane = fixture.pane

    try press(chord, on: pane)

    #expect(paths(pane) == ["/r", "/r/docs"])
    #expect(trail(pane).focusedIndex == 0)
    #expect(pane.location == Location(path: "/r"))
    #expect(trail(pane).focused.pane.selection.cursor == ExactName("docs"))
    // The column the parent selects is the one that was there, not a new one.
    await settle { trail(pane).focused.pane.state.isLoaded }
    #expect(paths(pane) == ["/r", "/r/docs"])

    try press(chord, on: pane)
    try press(chord, on: pane)

    // At `/` there is no parent to add.
    #expect(paths(pane) == ["/", "/r", "/r/docs"])
    #expect(trail(pane).focusedIndex == 0)
}

/// `ListingService` starts a `.focused` load before every waiting normal one whose volume is
/// known (its own tests check the order), so a column's load jumps the queue by asking for it.
@MainActor @Test func theFocusedColumnsLoadJumpsTheQueue() async throws {
    let lister = GatedLister(tree.mapValues { .batches([$0]) })
    lister.releaseAll()
    let pane = Pane(
        location: Location(path: "/r/docs"), service: ListingService(lister: lister),
        systemActions: StubSystemActions(), settings: untouchedSettings(), isFocused: true)
    await settle { pane.state.isLoaded }
    pane.setViewMode(.column)
    #expect(trail(pane).columns[0].pane.load?.priority == .focused)
    await settle { trail(pane).focused.pane.state.isLoaded }

    // A column for a selected folder isn't focused; the parent column ← adds is.
    select("sub", in: trail(pane).columns[0])
    try press(KeyChord(.left), on: pane)

    #expect(paths(pane) == ["/r", "/r/docs", "/r/docs/sub"])
    #expect(trail(pane).columns[2].pane.load?.priority == .visible)
    #expect(trail(pane).columns[0].pane.load?.priority == .focused)
}

@MainActor @Test func anUnfocusedPanesColumnsLoadAtNormalPriority() async {
    let fixture = await columnPane()

    #expect(trail(fixture.pane).focused.pane.load?.priority == .visible)
}

@MainActor @Test func switchingBackToListKeepsTheSelectedEntry() async throws {
    let fixture = await columnPane()
    let pane = fixture.pane
    select("docs", in: trail(pane).columns[0])
    await settle { trail(pane).columns[1].pane.state.isLoaded }
    try press(KeyChord(.right), on: pane)
    try press(KeyChord(.down), on: pane)
    #expect(trail(pane).focused.pane.selection.cursor == ExactName("x.txt"))

    try press(KeyChord("1", modifiers: .command), on: pane)

    #expect(pane.viewMode == .list)
    #expect(pane.columnTrail == nil)
    #expect(pane.commandPane === pane)
    #expect(pane.location == Location(path: "/r/docs"))
    await settle { pane.state.isLoaded }
    #expect(pane.selection.cursor == ExactName("x.txt"))
    #expect(pane.state.listing.map { pane.selection.rows(in: $0) } == [1])
}

@MainActor @Test func switchingBackToListClosesEveryColumn() async throws {
    let fixture = await columnPane(selecting: "docs")
    let pane = fixture.pane
    await settle { paths(pane).count == 2 }
    let monitors = trail(pane).columns.map { column in
        let monitor = StubMonitor()
        column.pane.monitor = monitor
        return monitor
    }

    pane.setViewMode(.list)

    #expect(monitors.map(\.stopCount) == [1, 1])
}

@MainActor @Test func rowKeysAndTypeToSelectActOnTheFocusedColumn() async throws {
    let fixture = await columnPane()
    let pane = fixture.pane
    select("docs", in: trail(pane).columns[0])
    await settle { trail(pane).columns[1].pane.state.isLoaded }
    try press(KeyChord(.right), on: pane)

    try press(KeyChord(.down), on: pane)
    #expect(trail(pane).columns[1].pane.selection.cursor == ExactName("x.txt"))
    #expect(trail(pane).columns[0].pane.selection.cursor == ExactName("docs"))

    let typed = SelectionCommands.selectFirstRow(
        startingWith: "su", in: CommandContext(pane: pane.commandPane))
    #expect(typed)
    #expect(trail(pane).columns[1].pane.selection.cursor == ExactName("sub"))
    // A key-made selection opens its column once the keys pause.
    await settle { paths(pane) == ["/r", "/r/docs", "/r/docs/sub"] }
}

@MainActor @Test func sortAndHiddenSettingsActOnTheFocusedColumn() async throws {
    let temp = try TemporaryFolder("ColumnTrailTests")
    let fixture = PaneFixture(at: "/r", folders: tree, settings: storedSettings(in: temp))
    await settle { fixture.pane.state.isLoaded }
    let pane = fixture.pane
    pane.setViewMode(.column)
    await settle { trail(pane).focused.pane.state.isLoaded }
    select("docs", in: trail(pane).columns[0])
    await settle { trail(pane).columns[1].pane.state.isLoaded }
    try press(KeyChord(.right), on: pane)

    // Sort by Name again reverses the focused column only.
    try press(KeyChord("1", modifiers: [.control, .option, .command]), on: pane)
    await settle { trail(pane).columns[1].pane.state.names == ["x.txt", "sub"] }
    #expect(trail(pane).columns[0].pane.sortAscending)

    try press(KeyChord(".", modifiers: [.command, .shift]), on: pane)
    await settle { trail(pane).columns[1].pane.state.names == ["x.txt", "sub", ".hidden"] }
}

@MainActor @Test func aColumnFilterNarrowsThatColumnOnly() async {
    let fixture = await columnPane()
    let pane = fixture.pane
    select("docs", in: trail(pane).columns[0])
    await settle { trail(pane).columns[1].pane.state.isLoaded }
    pane.columnTrail?.moveRight()

    pane.commandPane.setFilter("x")

    await settle { trail(pane).columns[1].pane.state.names == ["x.txt"] }
    #expect(trail(pane).columns[0].pane.state.names == ["a.txt", "docs", "other"])
}

@MainActor @Test func backInColumnModeStartsTheTrailAtTheFolderLeft() async throws {
    let fixture = await columnPane()
    let pane = fixture.pane
    select("docs", in: trail(pane).columns[0])
    await settle { trail(pane).columns[1].pane.state.isLoaded }
    try press(KeyChord(.right), on: pane)
    // Moving between columns isn't a step in the history.
    #expect(!pane.commandPane.canGoBack)

    pane.navigate(to: Location(path: "/r/other"))
    #expect(paths(pane) == ["/r/other"])
    #expect(pane.commandPane.canGoBack)

    try press(KeyChord("[", modifiers: .command), on: pane)

    #expect(paths(pane) == ["/r/docs"])
    #expect(pane.location == Location(path: "/r/docs"))
    #expect(trail(pane).focused.pane.selection.cursor == ExactName("sub"))
}

@MainActor @Test func openOnAFolderInAColumnMovesIntoItsColumn() async throws {
    let fixture = await columnPane(selecting: "docs")
    let pane = fixture.pane
    await settle { paths(pane).count == 2 && trail(pane).columns[1].pane.state.isLoaded }

    try press(KeyChord(.down, modifiers: .command), on: pane)

    #expect(trail(pane).focusedIndex == 1)
    #expect(paths(pane) == ["/r", "/r/docs", "/r/docs/sub"])
}

@MainActor @Test func aColumnWhoseLoadGoesSlowIsSlowAndKeepsTheTrail() async {
    var outcomes = tree.mapValues { GatedLister.Outcome.batches([$0]) }
    outcomes["/r/docs"] = .blockForever
    let lister = GatedLister(outcomes)
    lister.releaseAll()
    let clock = ManualClock()
    let pane = Pane(
        location: Location(path: "/r"), service: ListingService(lister: lister, clock: clock),
        systemActions: StubSystemActions(), settings: untouchedSettings())
    await settle { pane.state.isLoaded }
    pane.setViewMode(.column)
    await settle { trail(pane).focused.pane.state.isLoaded }
    select("docs", in: trail(pane).columns[0])
    #expect(await lister.waitForCall("/r/docs"))
    var changes = 0
    pane.onChange = { changes += 1 }

    clock.advance(by: LoadTimeouts.slow)
    // The slow update reaches the main queue from the load's timer task, with nothing to wait on.
    try? await Task.sleep(for: .milliseconds(200))
    await drainMainQueue()

    #expect(trail(pane).columns[1].pane.state.isSlow)
    #expect(trail(pane).columns[1].pane.state.listing == nil)
    #expect(paths(pane) == ["/r", "/r/docs"])
    #expect(trail(pane).focusedIndex == 0)
    #expect(changes == 1)
}

@MainActor @Test func backKeepsTheFocusedColumnsSort() async throws {
    let fixture = await columnPane()
    let pane = fixture.pane
    pane.navigate(to: Location(path: "/r/other"))
    await settle { trail(pane).focused.pane.state.isLoaded }
    try press(KeyChord("6", modifiers: [.control, .option, .command]), on: pane)
    #expect(trail(pane).focused.pane.sortColumn == .size)

    try press(KeyChord("[", modifiers: .command), on: pane)

    #expect(paths(pane) == ["/r"])
    #expect(trail(pane).focused.pane.sortColumn == .size)
    #expect(trail(pane).focused.pane.load?.column == .size)
}

@MainActor @Test func thePaneHoldsNoRowsInColumnModeAndSortsNothingOnAToggle() async throws {
    let temp = try TemporaryFolder("ColumnTrailTests")
    let fixture = PaneFixture(at: "/r/docs", folders: tree, settings: storedSettings(in: temp))
    await settle { fixture.pane.state.isLoaded }
    let pane = fixture.pane
    pane.setViewMode(.column)
    await settle { trail(pane).focused.pane.state.isLoaded }
    #expect(pane.state.listing == nil)
    let sorts = pane.sortCount

    pane.settings.showHidden = true
    await settle { trail(pane).focused.pane.state.names.count == 3 }

    #expect(pane.sortCount == sorts)
    #expect(pane.state.listing == nil)
}

@MainActor @Test func switchingToColumnsStopsThePanesOwnLoadAndMonitor() async {
    let fixture = PaneFixture(at: "/r", folders: tree, held: true)
    let pane = fixture.pane
    let monitor = StubMonitor()
    pane.monitor = monitor
    #expect(await fixture.lister.waitForCall("/r"))

    pane.setViewMode(.column)
    fixture.lister.releaseAll()
    await settle { trail(pane).focused.pane.state.isLoaded }
    #expect(await fixture.lister.waitForFinished(2))
    await drainMainQueue()

    #expect(monitor.stopCount == 1)
    #expect(pane.monitor == nil)
    #expect(pane.state.listing == nil)
}

@MainActor @Test func thePaneIgnoresFolderChangesInColumnMode() async {
    let fixture = await columnPane()
    let calls = fixture.lister.calls.count

    fixture.pane.apply(.relist, at: fixture.pane.location)

    #expect(await !fixture.lister.waitForCalls(calls + 1, timeout: 0.5))
    #expect(fixture.pane.state.listing == nil)
}

@MainActor @Test func aNavigationClosesEveryColumnItLeaves() async throws {
    let fixture = PaneFixture(at: "/r", folders: tree, held: true)
    for path in ["/r", "/r/docs", "/r/other"] { fixture.lister.release(path) }
    let pane = fixture.pane
    await settle { pane.state.isLoaded }
    pane.setViewMode(.column)
    await settle { trail(pane).focused.pane.state.isLoaded }
    select("docs", in: trail(pane).columns[0])
    await settle { trail(pane).columns[1].pane.state.isLoaded }
    select("sub", in: trail(pane).columns[1])
    #expect(await fixture.lister.waitForCall("/r/docs/sub"))
    let left = trail(pane).columns.map(\.pane)
    let monitors = left.map { column in
        let monitor = StubMonitor()
        column.monitor = monitor
        return monitor
    }

    // A path bar click.
    pane.navigate(to: Location(path: "/r/other"))
    fixture.lister.release("/r/docs/sub")
    await settle { trail(pane).focused.pane.state.isLoaded }
    #expect(await fixture.lister.waitForFinished(5))
    await drainMainQueue()

    #expect(paths(pane) == ["/r/other"])
    #expect(monitors.map(\.stopCount) == [1, 1, 1])
    // The held load was cancelled, so its listing never reached the closed column.
    #expect(left[2].state.isLoading)

    let other = StubMonitor()
    trail(pane).focused.pane.monitor = other
    try press(KeyChord("[", modifiers: .command), on: pane)

    #expect(other.stopCount == 1)
    #expect(paths(pane) == ["/r"])
}

@MainActor @Test func goToFolderInColumnModeStartsTheTrailAtTheFolder() async {
    let fixture = await columnPane()
    let pane = fixture.pane
    var finished = false

    pane.goToFolder(Location(path: "/r/docs")) { error in
        #expect(error == nil)
        finished = true
    }
    await settle { finished }

    #expect(paths(pane) == ["/r/docs"])
    #expect(pane.location == Location(path: "/r/docs"))
    #expect(pane.canGoBack)
    await settle { trail(pane).focused.pane.state.isLoaded }
}

@MainActor @Test func openOnALinkToAFolderInAColumnStartsTheTrailAtTheLink() async throws {
    let link = DirectoryEntry(
        name: "link", type: .symbolicLink, size: nil, modified: testDate, isHidden: false,
        isDataless: false)
    var folders = tree
    folders["/r"] = [folder("docs"), link]
    folders["/r/link"] = [file("l.txt")]
    let fixture = PaneFixture(at: "/r", folders: folders)
    let pane = fixture.pane
    await settle { pane.state.isLoaded }
    pane.setViewMode(.column)
    await settle { trail(pane).focused.pane.state.isLoaded }
    select("link", in: trail(pane).columns[0])

    try press(KeyChord(.down, modifiers: .command), on: pane)

    await settle { paths(pane) == ["/r/link"] }
    await settle { trail(pane).focused.pane.state.names == ["l.txt"] }
    #expect(fixture.actions.openedFiles.isEmpty)
}

@MainActor @Test func aColumnFocusedAgainAsksForFocusedLoads() async throws {
    let fixture = await columnPane()
    let pane = fixture.pane
    pane.didGainFocus()
    select("docs", in: trail(pane).columns[0])
    await settle { trail(pane).columns[1].pane.state.isLoaded }
    #expect(trail(pane).columns[1].pane.load?.priority == .visible)
    try press(KeyChord(.right), on: pane)
    try press(KeyChord(.left), on: pane)
    try press(KeyChord(.right), on: pane)
    await settle { trail(pane).columns.allSatisfy { $0.pane.state.isLoaded } }

    trail(pane).columns[1].pane.reload()
    trail(pane).columns[0].pane.reload()

    #expect(trail(pane).columns[1].pane.load?.priority == .focused)
    #expect(trail(pane).columns[0].pane.load?.priority == .visible)
}

@MainActor @Test func aColumnGoesCachedRefreshingThenOfflineLikeAListPane() async {
    let share = VolumeIdentity(device: "//me@nas.invalid/n", mountPoint: "/n", kind: .network)
    let listedAt = Date(timeIntervalSinceReferenceDate: 700_000_000)
    let cache = ListingCache(store: nil)
    for (path, entries) in ["/n": [folder("docs"), file("a.txt")], "/n/docs": [file("x.txt")]] {
        await cache.insert(
            ListingCache.Folder(entries: entries, listedAt: listedAt), at: path, on: share)
    }
    // The share stops answering: no read of it ever returns.
    let lister = GatedLister(["/n": .blockForever, "/n/docs": .blockForever])
    lister.releaseAll()
    let clock = ManualClock()
    let service = ListingService(
        lister: lister, clock: clock, volumeOf: { _ in share }, cache: cache)
    let pane = Pane(
        location: Location(path: "/n"), service: service, systemActions: StubSystemActions(),
        settings: untouchedSettings(), isFocused: true)
    await settle { pane.state.isCachedRefreshing }

    pane.setViewMode(.column)
    let first = trail(pane).columns[0]
    await settle { first.pane.state.isCachedRefreshing }
    #expect(first.pane.state.names == ["a.txt", "docs"])
    select("docs", in: first)
    await settle { paths(pane) == ["/n", "/n/docs"] }
    let second = trail(pane).columns[1]
    await settle { second.pane.state.isCachedRefreshing }
    #expect(second.pane.state.names == ["x.txt"])

    clock.advance(by: LoadTimeouts.giveUp)
    await settle { first.pane.state.isOffline && second.pane.state.isOffline }
    #expect(first.pane.state.names == ["a.txt", "docs"])
    #expect(first.pane.state.listedAt == listedAt)
    #expect(second.pane.state.names == ["x.txt"])
    #expect(paths(pane) == ["/n", "/n/docs"])
}

@MainActor @Test func cachedRowsThatLackTheSelectedFolderKeepTheColumnsToTheRight() async throws {
    let share = VolumeIdentity(device: "//me@nas.invalid/n", mountPoint: "/n", kind: .network)
    let cache = ListingCache(store: nil)
    // Cached before docs was made, so the parent's cached rows don't have it.
    await cache.insert(
        ListingCache.Folder(entries: [file("a.txt")], listedAt: testDate), at: "/n", on: share)
    let lister = GatedLister([
        "/n": .blockForever, "/n/docs": .batches([[file("x.txt")]]),
    ])
    lister.release("/n/docs")
    let clock = ManualClock()
    let service = ListingService(
        lister: lister, clock: clock, volumeOf: { _ in share }, cache: cache)
    let pane = Pane(
        location: Location(path: "/n/docs"), service: service,
        systemActions: StubSystemActions(), settings: untouchedSettings(), isFocused: true)
    await settle { pane.state.isLoaded }
    pane.setViewMode(.column)
    await settle { trail(pane).focused.pane.state.isLoaded }

    try press(KeyChord(.left), on: pane)
    let parent = trail(pane).columns[0].pane
    await settle { parent.state.isCachedRefreshing }
    #expect(paths(pane) == ["/n", "/n/docs"])

    clock.advance(by: LoadTimeouts.slow)
    await settle { parent.state.isSlow }
    #expect(paths(pane) == ["/n", "/n/docs"])

    clock.advance(by: LoadTimeouts.giveUp - LoadTimeouts.slow)
    await settle { parent.state.isOffline }
    #expect(paths(pane) == ["/n", "/n/docs"])
}

@MainActor @Test func focusingAColumnMovesTheKeysThereWithoutChangingTheColumns() async throws {
    let fixture = await columnPane()
    let pane = fixture.pane
    select("docs", in: trail(pane).columns[0])
    await settle { trail(pane).columns[1].pane.state.isLoaded }
    var changes = 0
    pane.onChange = { changes += 1 }

    trail(pane).focus(trail(pane).columns[1])

    #expect(trail(pane).focusedIndex == 1)
    #expect(pane.location == Location(path: "/r/docs"))
    #expect(pane.commandPane === trail(pane).columns[1].pane)
    #expect(paths(pane) == ["/r", "/r/docs"])
    #expect(trail(pane).columns[1].pane.selection.isEmpty)
    #expect(changes == 1)

    trail(pane).focus(trail(pane).columns[1])

    #expect(changes == 1)
}

@MainActor @Test func oneSelectedFileInTheLastColumnIsPreviewedFromItsListing() async throws {
    let fixture = await columnPane()
    let first = trail(fixture.pane).columns[0]
    let calls = fixture.lister.calls.count
    #expect(trail(fixture.pane).preview == nil)

    select("a.txt", in: first)

    let preview = try #require(trail(fixture.pane).preview)
    let listing = try #require(first.pane.state.listing)
    let row = try #require(listing.row(named: "a.txt"))
    #expect(preview.location == Location(path: "/r/a.txt"))
    #expect(preview.entry == file("a.txt"))
    #expect(preview.kind == listing.kind(atRow: row))
    // The preview is neither a column nor a pane, and reads nothing.
    #expect(paths(fixture.pane) == ["/r"])
    await drainMainQueue()
    #expect(fixture.lister.calls.count == calls)
}

@MainActor @Test func aFolderSeveralRowsOrNoneSelectedClearThePreview() async throws {
    let fixture = await columnPane()
    let first = trail(fixture.pane).columns[0]
    select("a.txt", in: first)
    #expect(trail(fixture.pane).preview != nil)

    select("docs", in: first)
    #expect(trail(fixture.pane).preview == nil)

    select("a.txt", in: first)
    #expect(trail(fixture.pane).preview != nil)
    first.pane.select(
        Selection([ExactName("a.txt"), ExactName("other")], cursor: ExactName("a.txt")))
    #expect(trail(fixture.pane).preview == nil)

    select("a.txt", in: first)
    #expect(trail(fixture.pane).preview != nil)
    first.pane.select(Selection())
    #expect(trail(fixture.pane).preview == nil)
}

@MainActor @Test func thePreviewFollowsTheLastColumnOnly() async throws {
    let fixture = await columnPane()
    let pane = fixture.pane
    select("docs", in: trail(pane).columns[0])
    await settle { trail(pane).columns[1].pane.state.isLoaded }

    select("x.txt", in: trail(pane).columns[1])

    #expect(trail(pane).preview?.location == Location(path: "/r/docs/x.txt"))
    #expect(paths(pane) == ["/r", "/r/docs"])

    // Choosing another folder on the left drops the column the file was in, and its preview.
    select("other", in: trail(pane).columns[0])

    #expect(trail(pane).preview == nil)
}

@MainActor @Test func aPatchedEntryUpdatesThePreviewAndARemovedOneClearsIt() async throws {
    let fixture = await columnPane()
    let first = trail(fixture.pane).columns[0].pane
    select("a.txt", in: trail(fixture.pane).columns[0])

    first.apply(.patches([.update(file("a.txt", size: 5))]), at: first.location)
    await settle { trail(fixture.pane).preview?.entry.size == 5 }

    first.apply(.patches([.remove(name: "a.txt")]), at: first.location)
    await settle { trail(fixture.pane).preview == nil }
    #expect(paths(fixture.pane) == ["/r"])
}

@MainActor @Test func closingTheTrailClearsThePreview() async throws {
    let fixture = await columnPane(selecting: "a.txt")
    let trail = trail(fixture.pane)
    #expect(trail.preview != nil)

    fixture.pane.setViewMode(.list)

    #expect(trail.preview == nil)
}

/// Telling a link to a folder from a link to a file takes a read, which the preview never makes,
/// and Open treats a link to a folder as its folder; so no link is previewed. A socket or another
/// special file is, as in Finder.
@MainActor @Test func aLinkShowsNoPreviewAndASpecialFileDoes() async throws {
    func entry(_ name: String, _ type: DirectoryEntry.FileType) -> DirectoryEntry {
        DirectoryEntry(
            name: name, type: type, size: nil, modified: testDate, isHidden: false,
            isDataless: false)
    }
    var folders = tree
    folders["/r"] = [folder("docs"), entry("link", .symbolicLink), entry("socket", .other)]
    let fixture = PaneFixture(at: "/r", folders: folders)
    await settle { fixture.pane.state.isLoaded }
    fixture.pane.setViewMode(.column)
    await settle { trail(fixture.pane).focused.pane.state.isLoaded }
    let first = trail(fixture.pane).columns[0]

    select("socket", in: first)
    #expect(trail(fixture.pane).preview?.location == Location(path: "/r/socket"))

    select("link", in: first)
    #expect(trail(fixture.pane).preview == nil)
    #expect(paths(fixture.pane) == ["/r"])
}

// MARK: - Opening a column once the keys pause

/// `/k` holds folders `f0` to `f10` and a file `z.txt`; each folder holds a folder `in` and files
/// `m.txt` and `n.txt`. `/k/z.txt` lists `y.txt` once a patch makes `z.txt` a folder.
private let keyTree: [String: [DirectoryEntry]] = {
    var folders: [String: [DirectoryEntry]] = ["/": [folder("k")], "/k/z.txt": [file("y.txt")]]
    folders["/k"] = (0...10).map { folder("f\($0)") } + [file("z.txt")]
    for index in 0...10 {
        folders["/k/f\(index)"] = [folder("in"), file("m.txt"), file("n.txt")]
        folders["/k/f\(index)/in"] = [file("deep.txt")]
    }
    return folders
}()

/// A focused pane at `/k` in column mode, waiting out its column-open pause on `clock`, with
/// `f0` selected as a click selects it and its column loaded.
@MainActor
private func keyedPane(clock: ManualClock) async -> PaneFixture {
    let fixture = PaneFixture(at: "/k", folders: keyTree)
    await settle { fixture.pane.state.isLoaded }
    fixture.pane.columnOpenClock = clock
    fixture.pane.setViewMode(.column)
    await settle { trail(fixture.pane).focused.pane.state.isLoaded }
    select("f0", in: trail(fixture.pane).columns[0])
    await settle { trail(fixture.pane).columns.last?.pane.state.isLoaded == true }
    return fixture
}

/// Lets cancelled waits finish, so the clock counts only the waits still running.
@MainActor
private func drainWaits() async {
    for _ in 0..<3 { await drainMainQueue() }
}

@MainActor @Test func tenFastDownPressesOpenOnlyTheLastFoldersColumnAfterThePause() async throws {
    let clock = ManualClock()
    let fixture = await keyedPane(clock: clock)
    let pane = fixture.pane
    #expect(paths(pane) == ["/k", "/k/f0"])

    for _ in 0..<10 {
        try press(KeyChord(.down), on: pane)
        clock.advance(by: ColumnTrail.openDelay - .milliseconds(1))
    }

    // The selection moves at once and the stale column goes; the new one waits.
    #expect(trail(pane).columns[0].pane.selection.cursor == ExactName("f10"))
    #expect(paths(pane) == ["/k"])
    await settle { clock.waitingSleeps == 1 }

    clock.advance(by: .milliseconds(1))

    await settle { paths(pane) == ["/k", "/k/f10"] }
    #expect(trail(pane).focusedIndex == 0)
    let skipped = (1...9).map { "/k/f\($0)" }
    #expect(!fixture.lister.calls.contains { skipped.contains($0.path) })
}

@MainActor @Test func aClickOpensTheFoldersColumnAtOnce() async throws {
    let clock = ManualClock()
    let fixture = await keyedPane(clock: clock)
    let first = trail(fixture.pane).columns[0].pane
    let listing = try #require(first.state.listing)
    let row = try #require(listing.row(named: "f3"))

    first.select(
        rows: IndexSet(integer: row), cursor: ExactName("f3"), anchor: ExactName("f3"),
        as: .press(1))

    #expect(paths(fixture.pane) == ["/k", "/k/f3"])
    await drainWaits()
    #expect(clock.waitingSleeps == 0)
}

@MainActor @Test func rightArrowOpensAWaitingFoldersColumnAtOnceAndMovesIntoIt() async throws {
    let clock = ManualClock()
    let fixture = await keyedPane(clock: clock)
    let pane = fixture.pane
    try press(KeyChord(.down), on: pane)
    #expect(paths(pane) == ["/k"])

    try press(KeyChord(.right), on: pane)

    #expect(paths(pane) == ["/k", "/k/f1"])
    #expect(trail(pane).focusedIndex == 1)
    await drainWaits()
    #expect(clock.waitingSleeps == 0)
}

@MainActor @Test func leftArrowCancelsAWaitingColumn() async throws {
    let clock = ManualClock()
    let fixture = await keyedPane(clock: clock)
    let pane = fixture.pane
    try press(KeyChord(.down), on: pane)
    await settle { clock.waitingSleeps == 1 }

    try press(KeyChord(.left), on: pane)
    clock.advance(by: ColumnTrail.openDelay)
    // A patch to the column it left reports a change, which doesn't start the wait again.
    let column = trail(pane).columns[1].pane
    column.apply(.patches([.update(folder("new"))]), at: column.location)
    await settle { column.state.names.contains("new") }
    clock.advance(by: ColumnTrail.openDelay)
    await drainWaits()

    #expect(paths(pane) == ["/", "/k"])
    #expect(column.selection.cursor == ExactName("f1"))
    #expect(clock.waitingSleeps == 0)
    #expect(!fixture.lister.calls.contains { $0.path == "/k/f1" })
}

@MainActor @Test func closingThePaneOrSwitchingToTheListCancelsAWaitingColumn() async throws {
    let leaves: [@MainActor (Pane) -> Void] = [{ $0.close() }, { $0.setViewMode(.list) }]
    for leave in leaves {
        let clock = ManualClock()
        let fixture = await keyedPane(clock: clock)
        let pane = fixture.pane
        try press(KeyChord(.down), on: pane)
        await settle { clock.waitingSleeps == 1 }

        leave(pane)
        clock.advance(by: ColumnTrail.openDelay)
        await drainWaits()

        #expect(clock.waitingSleeps == 0)
        #expect(!fixture.lister.calls.contains { $0.path == "/k/f1" })
    }
}

@MainActor @Test func thePreviewOfAFileReachedByKeysShowsAfterThePause() async throws {
    let clock = ManualClock()
    let fixture = await keyedPane(clock: clock)
    let pane = fixture.pane
    try press(KeyChord(.right), on: pane)
    // → selects the first row, the folder `in`, and opens its column at once.
    #expect(paths(pane) == ["/k", "/k/f0", "/k/f0/in"])

    try press(KeyChord(.down), on: pane)

    #expect(paths(pane) == ["/k", "/k/f0"])
    #expect(trail(pane).preview == nil)
    clock.advance(by: ColumnTrail.openDelay)
    await settle { trail(pane).preview?.location == Location(path: "/k/f0/m.txt") }

    try press(KeyChord(.down), on: pane)

    #expect(trail(pane).preview == nil)
    clock.advance(by: ColumnTrail.openDelay)
    await settle { trail(pane).preview?.location == Location(path: "/k/f0/n.txt") }
}

@MainActor @Test func typeToSelectAndSelectLastWaitForThePauseToo() async throws {
    let clock = ManualClock()
    let fixture = await keyedPane(clock: clock)
    let pane = fixture.pane

    let typed = SelectionCommands.selectFirstRow(
        startingWith: "f5", in: CommandContext(pane: pane.commandPane))
    #expect(typed)
    #expect(paths(pane) == ["/k"])
    clock.advance(by: ColumnTrail.openDelay)
    await settle { paths(pane) == ["/k", "/k/f5"] }

    try press(KeyChord(.down, modifiers: .option), on: pane)
    #expect(paths(pane) == ["/k"])
    clock.advance(by: ColumnTrail.openDelay)
    await settle { trail(pane).preview?.location == Location(path: "/k/z.txt") }
}

/// Selects `name`'s row alone in `pane` as a click does, keeping the anchor when the click lands
/// on the row already selected, as the table reports it.
@MainActor
private func click(_ name: String, in pane: Pane) throws {
    let listing = try #require(pane.state.listing)
    let row = try #require(listing.row(named: name))
    let isSelected = pane.selection.cursor == ExactName(name)
    pane.select(
        rows: IndexSet(integer: row), cursor: ExactName(name),
        anchor: isSelected ? pane.selection.anchor : ExactName(name), as: .press(1))
}

@MainActor @Test func aClickOnTheRowTheKeysLeftOpensItsColumnAtOnce() async throws {
    let clock = ManualClock()
    let fixture = await keyedPane(clock: clock)
    let pane = fixture.pane
    try press(KeyChord(.down), on: pane)
    await settle { clock.waitingSleeps == 1 }
    try press(KeyChord(.left), on: pane)
    let column = trail(pane).columns[1].pane

    try click("f1", in: column)

    #expect(paths(pane) == ["/", "/k", "/k/f1"])
}

@MainActor @Test func aClickOnAnotherRowDuringTheWaitOpensOnlyItsColumn() async throws {
    let clock = ManualClock()
    let fixture = await keyedPane(clock: clock)
    let pane = fixture.pane
    try press(KeyChord(.down), on: pane)
    await settle { clock.waitingSleeps == 1 }

    try click("f3", in: trail(pane).columns[0].pane)
    #expect(paths(pane) == ["/k", "/k/f3"])
    clock.advance(by: ColumnTrail.openDelay)
    await drainWaits()

    #expect(paths(pane) == ["/k", "/k/f3"])
    #expect(clock.waitingSleeps == 0)
    #expect(!fixture.lister.calls.contains { $0.path == "/k/f1" })
}

@MainActor @Test func removingTheWaitingFolderOpensWhatTheSelectionHoldsOnceTheKeysPause()
    async throws
{
    let clock = ManualClock()
    let fixture = await keyedPane(clock: clock)
    let pane = fixture.pane
    let first = trail(pane).columns[0].pane
    try press(KeyChord(.down), on: pane)
    await settle { clock.waitingSleeps == 1 }

    // A rename arrives as the old name's removal and the new name's update.
    first.apply(.patches([.remove(name: "f1"), .update(folder("g1"))]), at: first.location)
    await settle { !first.state.names.contains("f1") }
    #expect(paths(pane) == ["/k"])
    clock.advance(by: ColumnTrail.openDelay)
    await drainWaits()

    // The columns follow whatever the selection holds now, and the removed folder never lists.
    let listing = try #require(first.state.listing)
    if let row = first.selection.cursorRow(in: listing), listing[row].type == .directory,
        first.selection.rows(in: listing) == IndexSet(integer: row)
    {
        await settle { paths(pane) == ["/k", "/k/\(listing[row].name)"] }
    } else {
        #expect(paths(pane) == ["/k"])
    }
    #expect(!fixture.lister.calls.contains { $0.path == "/k/f1" })
}

@MainActor @Test func rightArrowOnAFileShowsItsWaitingPreviewAtOnce() async throws {
    let clock = ManualClock()
    let fixture = await keyedPane(clock: clock)
    let pane = fixture.pane
    try press(KeyChord(.right), on: pane)
    try press(KeyChord(.down), on: pane)
    #expect(trail(pane).preview == nil)

    try press(KeyChord(.right), on: pane)

    #expect(trail(pane).preview?.location == Location(path: "/k/f0/m.txt"))
    #expect(trail(pane).focusedIndex == 1)
    await drainWaits()
    #expect(clock.waitingSleeps == 0)
}

/// Once the columns follow a key-made selection, a patch that changes what it asks for is
/// followed at once: only a new selection by keys waits.
@MainActor @Test func aPatchAfterTheWaitIsFollowedAtOnce() async throws {
    let clock = ManualClock()
    let fixture = await keyedPane(clock: clock)
    let pane = fixture.pane
    let first = trail(pane).columns[0].pane
    try press(KeyChord(.down, modifiers: .option), on: pane)
    clock.advance(by: ColumnTrail.openDelay)
    await settle { trail(pane).preview?.location == Location(path: "/k/z.txt") }

    first.apply(.patches([.update(folder("z.txt"))]), at: first.location)

    await settle { paths(pane) == ["/k", "/k/z.txt"] }
    #expect(clock.waitingSleeps == 0)
}

// MARK: - Reading the preview's info

/// An `ItemInfo` whose dates are `seconds` and twice that after `testDate`, tagged `tags`.
private func info(_ seconds: Double, tags: [String] = []) -> ItemInfo {
    ItemInfo(
        created: testDate.addingTimeInterval(seconds),
        lastOpened: testDate.addingTimeInterval(2 * seconds), tags: tags)
}

@MainActor @Test func aPreviewReadsItsFilesInfoOffTheMainThread() async throws {
    let fixture = await columnPane()
    let reader = GatedItemInfoReader(["/r/a.txt": info(1, tags: ["Red"])])
    fixture.pane.itemInfoReader = reader

    select("a.txt", in: trail(fixture.pane).columns[0])

    #expect(trail(fixture.pane).preview?.info == .reading)
    #expect(await reader.waitForCall("/r/a.txt"))
    #expect(reader.calls.map(\.onMainThread) == [false])
    #expect(reader.calls.map(\.onBlockingCallThread) == [true])
    reader.releaseAll()
    await settle { trail(fixture.pane).preview?.info == .read(info(1, tags: ["Red"])) }
}

/// A file replaced under its name, as a save by rename replaces it, is read again; it shows
/// what was read of it until then.
@MainActor @Test func aChangedFileIsReadAgain() async throws {
    let fixture = await columnPane()
    let reader = GatedItemInfoReader(["/r/a.txt": info(1)])
    reader.releaseAll()
    fixture.pane.itemInfoReader = reader
    let first = trail(fixture.pane).columns[0].pane
    select("a.txt", in: trail(fixture.pane).columns[0])
    await settle { trail(fixture.pane).preview?.info == .read(info(1)) }

    first.apply(.patches([.update(file("a.txt", size: 5))]), at: first.location)

    await settle { reader.calls.count == 2 }
    #expect(trail(fixture.pane).preview?.entry.size == 5)
    #expect(trail(fixture.pane).preview?.info == .read(info(1)))
    #expect(await reader.waitForFinished(2))
    for _ in 0..<3 { await drainMainQueue() }
    #expect(trail(fixture.pane).preview?.info == .read(info(1)))
}

/// A failed read is tried again only once the file's entry changes, not on a patch to another.
@MainActor @Test func aFailedReadIsReadAgainOnlyOnceItsEntryChanges() async throws {
    let fixture = await columnPane()
    let reader = GatedItemInfoReader(["/r/a.txt": nil])
    reader.releaseAll()
    fixture.pane.itemInfoReader = reader
    let first = trail(fixture.pane).columns[0].pane
    select("a.txt", in: trail(fixture.pane).columns[0])
    await settle { trail(fixture.pane).preview?.info == .failed }

    first.apply(.patches([.update(file("b.txt"))]), at: first.location)
    await settle { first.state.names.contains("b.txt") }
    for _ in 0..<3 { await drainMainQueue() }
    #expect(reader.calls.count == 1)

    first.apply(.patches([.update(file("a.txt", size: 5))]), at: first.location)

    await settle { reader.calls.count == 2 }
    #expect(await reader.waitForFinished(2))
    await settle { trail(fixture.pane).preview?.entry.size == 5 }
    for _ in 0..<3 { await drainMainQueue() }
    #expect(trail(fixture.pane).preview?.info == .failed)
}

@MainActor @Test func aPatchToAnotherEntryKeepsThePreviewsRead() async throws {
    let fixture = await columnPane()
    let reader = GatedItemInfoReader(["/r/a.txt": info(1)])
    reader.releaseAll()
    fixture.pane.itemInfoReader = reader
    let first = trail(fixture.pane).columns[0].pane
    select("a.txt", in: trail(fixture.pane).columns[0])
    await settle { trail(fixture.pane).preview?.info == .read(info(1)) }

    first.apply(.patches([.update(file("b.txt"))]), at: first.location)

    await settle { first.state.names.contains("b.txt") }
    for _ in 0..<3 { await drainMainQueue() }
    #expect(trail(fixture.pane).preview?.info == .read(info(1)))
    #expect(reader.calls.count == 1)
}

@MainActor @Test func aPackagesPreviewReadsItsInfoToo() async throws {
    var folders = tree
    folders["/r"] = [package("App.app")]
    let fixture = PaneFixture(at: "/r", folders: folders)
    await settle { fixture.pane.state.isLoaded }
    fixture.pane.setViewMode(.column)
    await settle { trail(fixture.pane).focused.pane.state.isLoaded }
    let reader = GatedItemInfoReader(["/r/App.app": info(3)])
    reader.releaseAll()
    fixture.pane.itemInfoReader = reader

    select("App.app", in: trail(fixture.pane).columns[0])

    await settle { trail(fixture.pane).preview?.info == .read(info(3)) }
}

@MainActor @Test func aFailedReadShowsAsFailed() async throws {
    let fixture = await columnPane()
    let reader = GatedItemInfoReader(["/r/a.txt": nil])
    reader.releaseAll()
    fixture.pane.itemInfoReader = reader

    select("a.txt", in: trail(fixture.pane).columns[0])

    await settle { trail(fixture.pane).preview?.info == .failed }
}

@MainActor @Test func aPreviewReachedByKeysReadsOnlyOnceTheKeysPause() async throws {
    let clock = ManualClock()
    let fixture = await keyedPane(clock: clock)
    let pane = fixture.pane
    let reader = GatedItemInfoReader(["/k/f0/m.txt": info(1), "/k/f0/n.txt": info(2)])
    reader.releaseAll()
    pane.itemInfoReader = reader
    try press(KeyChord(.right), on: pane)
    try press(KeyChord(.down), on: pane)
    try press(KeyChord(.down), on: pane)

    await drainMainQueue()
    #expect(reader.calls.isEmpty)
    clock.advance(by: ColumnTrail.openDelay)

    await settle { trail(pane).preview?.info == .read(info(2)) }
    #expect(reader.calls.map(\.path) == ["/k/f0/n.txt"])
}

@MainActor @Test func aReadForAFileNoLongerPreviewedIsDropped() async throws {
    let fixture = await keyedPane(clock: ManualClock())
    let pane = fixture.pane
    let reader = GatedItemInfoReader(["/k/f0/m.txt": info(1), "/k/f0/n.txt": info(2)])
    pane.itemInfoReader = reader
    let column = trail(pane).columns[1]
    try click("m.txt", in: column.pane)
    #expect(await reader.waitForCall("/k/f0/m.txt"))

    try click("n.txt", in: column.pane)
    reader.release("/k/f0/m.txt")
    #expect(await reader.waitForFinished(1))
    for _ in 0..<3 { await drainMainQueue() }

    #expect(trail(pane).preview?.location == Location(path: "/k/f0/n.txt"))
    #expect(trail(pane).preview?.info == .reading)
    reader.release("/k/f0/n.txt")
    await settle { trail(pane).preview?.info == .read(info(2)) }
}

@MainActor @Test func aReadLandingAfterTheTrailClosesIsDropped() async throws {
    for closing in ["list mode", "navigation", "pane close"] {
        let fixture = await columnPane()
        let pane = fixture.pane
        let reader = GatedItemInfoReader(["/r/a.txt": info(1)])
        pane.itemInfoReader = reader
        let trail = trail(pane)
        select("a.txt", in: trail.columns[0])
        #expect(await reader.waitForCall("/r/a.txt"), "\(closing)")

        switch closing {
        case "list mode": pane.setViewMode(.list)
        case "navigation": pane.navigate(to: Location(path: "/r/other"))
        default: pane.close()
        }
        reader.releaseAll()
        #expect(await reader.waitForFinished(1), "\(closing)")
        for _ in 0..<3 { await drainMainQueue() }

        #expect(trail.preview == nil, "\(closing)")
    }
}

@MainActor @Test func aDatalessFileGetsNoRead() async throws {
    var folders = tree
    folders["/r"] = [
        DirectoryEntry(
            name: "cloud.txt", type: .regular, size: 9, modified: testDate, isHidden: false,
            isDataless: true)
    ]
    let fixture = PaneFixture(at: "/r", folders: folders)
    await settle { fixture.pane.state.isLoaded }
    fixture.pane.setViewMode(.column)
    await settle { trail(fixture.pane).focused.pane.state.isLoaded }
    let reader = GatedItemInfoReader([:])
    fixture.pane.itemInfoReader = reader

    select("cloud.txt", in: trail(fixture.pane).columns[0])
    for _ in 0..<3 { await drainMainQueue() }

    #expect(trail(fixture.pane).preview?.location == Location(path: "/r/cloud.txt"))
    #expect(trail(fixture.pane).preview?.info == .unread)
    #expect(reader.calls.isEmpty)
}

/// A focused pane on a share at `/n` in column mode, showing cached rows that list `a.txt`
/// while `lister` lists it again on `clock`.
@MainActor
private func cachedSharePane(lister: GatedLister, clock: ManualClock) async -> Pane {
    let share = VolumeIdentity(device: "//me@nas.invalid/n", mountPoint: "/n", kind: .network)
    let cache = ListingCache(store: nil)
    await cache.insert(
        ListingCache.Folder(entries: [file("a.txt")], listedAt: testDate), at: "/n", on: share)
    let service = ListingService(
        lister: lister, clock: clock, volumeOf: { _ in share }, cache: cache)
    let pane = Pane(
        location: Location(path: "/n"), service: service, systemActions: StubSystemActions(),
        settings: untouchedSettings(), isFocused: true)
    await settle { pane.state.isCachedRefreshing }
    pane.setViewMode(.column)
    await settle { trail(pane).columns[0].pane.state.isCachedRefreshing }
    return pane
}

/// A share that hasn't answered might not: no read waits on it while its rows are cached, slow
/// or offline.
@MainActor @Test func aFileOnAShareThatDoesntAnswerGetsNoRead() async throws {
    let clock = ManualClock()
    let pane = await cachedSharePane(lister: GatedLister(["/n": .blockForever]), clock: clock)
    let reader = GatedItemInfoReader([:])
    pane.itemInfoReader = reader
    let first = trail(pane).columns[0]

    select("a.txt", in: first)
    #expect(trail(pane).preview?.info == .unread)

    clock.advance(by: LoadTimeouts.giveUp)
    await settle { first.pane.state.isOffline }
    for _ in 0..<3 { await drainMainQueue() }

    #expect(trail(pane).preview?.location == Location(path: "/n/a.txt"))
    #expect(trail(pane).preview?.info == .unread)
    #expect(reader.calls.isEmpty)
}

@MainActor @Test func aFileIsReadOnceItsShareAnswers() async throws {
    let lister = GatedLister(["/n": .batches([[file("a.txt")]])])
    let pane = await cachedSharePane(lister: lister, clock: ManualClock())
    let reader = GatedItemInfoReader(["/n/a.txt": info(4)])
    reader.releaseAll()
    pane.itemInfoReader = reader
    select("a.txt", in: trail(pane).columns[0])
    #expect(trail(pane).preview?.info == .unread)

    lister.release("/n")

    await settle { trail(pane).preview?.info == .read(info(4)) }
}
