import Base
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

    // No preview column for a file: the folder's column goes, and nothing replaces it.
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
    #expect(paths(pane) == ["/r", "/r/docs", "/r/docs/sub"])
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
