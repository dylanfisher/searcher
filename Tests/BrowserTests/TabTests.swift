import Base
import BrowserTestSupport
import Foundation
import TestSupport
import Testing

@testable import Browser

private let bounds = Rect(x: 0, y: 0, width: 1200, height: 800)

/// `/r` holds a folder `docs` and a file `a.txt`; `/r/docs` holds a folder `sub`.
private let tree: [String: [DirectoryEntry]] = [
    "/r": [folder("docs"), file("a.txt")],
    "/r/docs": [folder("sub")],
    "/r/docs/sub": [file("deep.txt")],
]

/// A tab of one pane at `path` over `tree`, every load released unless `held`.
@MainActor
private func makeTab(at path: String = "/r", held: Bool = false) -> (Tab, PaneFixture) {
    let fixture = PaneFixture(at: path, folders: tree, held: held)
    return (Tab(pane: fixture.pane), fixture)
}

@MainActor
private func expectLeavesMatchPanes(_ tab: Tab) {
    let leaves = tab.layout.panes
    #expect(leaves.count == tab.panes.count)
    #expect(Set(leaves) == Set(tab.panes.keys))
}

@MainActor @Test func newTabHoldsItsPaneAsTheOnlyLeaf() {
    let (tab, fixture) = makeTab()

    #expect(tab.layout.panes == [tab.layout.focused])
    #expect(tab.focusedPane === fixture.pane)
    expectLeavesMatchPanes(tab)
}

@MainActor @Test func splitAddsAPaneAtTheFocusedFolderAndViewModeAndFocusesIt() async throws {
    let (tab, fixture) = makeTab()
    let first = tab.layout.focused
    fixture.pane.navigate(to: Location(path: "/r/docs"))
    fixture.pane.setViewMode(.column)
    fixture.pane.commandPane.setSort(.size, ascending: false)

    let new = try #require(tab.split(.horizontal, in: bounds))

    #expect(tab.layout.panes == [first, tab.layout.focused])
    #expect(tab.focusedPane === new)
    #expect(new !== fixture.pane)
    #expect(new.location == Location(path: "/r/docs"))
    #expect(new.viewMode == .column)
    #expect(new.commandPane.location == Location(path: "/r/docs"))
    #expect(new.commandPane.sortColumn == .size)
    #expect(!new.commandPane.sortAscending)
    // The pane starts in column mode, with no list load of its own to cancel.
    #expect(new.load == nil)
    expectLeavesMatchPanes(tab)
}

@MainActor @Test func splitGivesTheNewPaneTheFocusedPanesFolderSizeService() throws {
    let (tab, fixture) = makeTab()
    let sizes = FolderSizeService(cache: FolderSizeCache(store: nil), log: { _ in })
    fixture.pane.folderSizes = sizes

    let new = try #require(tab.split(.horizontal, in: bounds))

    #expect(new.folderSizes === sizes)
}

@MainActor @Test func splitInListModeKeepsTheFocusedPanesSort() throws {
    let (tab, fixture) = makeTab()
    fixture.pane.setSort(.dateModified, ascending: false)

    let new = try #require(tab.split(.vertical, in: bounds))

    #expect(new.viewMode == .list)
    #expect(new.sortColumn == .dateModified)
    #expect(!new.sortAscending)
    #expect(new.load?.isCancelled == false)
}

@MainActor @Test func splitRefusedBelowTheMinimumSizeAddsNoPane() {
    let (tab, _) = makeTab()
    let narrow = Rect(x: 0, y: 0, width: 200, height: 800)

    #expect(tab.split(.horizontal, in: narrow) == nil)
    #expect(tab.panes.count == 1)
    expectLeavesMatchPanes(tab)
}

@MainActor @Test func closingAPaneCancelsItsLoadAndStopsItsWatch() throws {
    let (tab, fixture) = makeTab(held: true)
    let kept = fixture.pane
    let closing = try #require(tab.split(.vertical, in: bounds))
    let closingID = tab.layout.focused
    let monitor = StubMonitor()
    closing.monitor = monitor
    let load = try #require(closing.load)

    #expect(tab.closePane() == .pane)

    #expect(load.isCancelled)
    #expect(monitor.stopCount == 1)
    #expect(closing.monitor == nil)
    #expect(tab.panes[closingID] == nil)
    #expect(tab.focusedPane === kept)
    #expect(kept.load?.isCancelled == false)
    expectLeavesMatchPanes(tab)
}

@MainActor @Test func closingTheLastPaneReportsTheTabClosed() throws {
    let (tab, fixture) = makeTab(held: true)
    let monitor = StubMonitor()
    fixture.pane.monitor = monitor
    let load = try #require(fixture.pane.load)

    #expect(tab.closePane() == .tab)

    #expect(load.isCancelled)
    #expect(monitor.stopCount == 1)
    expectLeavesMatchPanes(tab)
}

@MainActor @Test func closingAColumnModePaneDropsItsTrail() {
    let (tab, fixture) = makeTab(held: true)
    fixture.pane.setViewMode(.column)

    #expect(tab.closePane() == .tab)

    #expect(fixture.pane.columnTrail == nil)
    #expect(fixture.pane.commandPane === fixture.pane)
}

@Test func splittingAClosedTabTraps() async {
    await #expect(processExitsWith: .failure) {
        await MainActor.run {
            let (tab, _) = makeTab(held: true)
            _ = tab.closePane()
            tab.split(.horizontal, in: bounds)
        }
    }
}

@Test func splittingAClosedColumnModeTabTraps() async {
    await #expect(processExitsWith: .failure) {
        await MainActor.run {
            let (tab, fixture) = makeTab(held: true)
            fixture.pane.setViewMode(.column)
            _ = tab.closePane()
            tab.split(.horizontal, in: bounds)
        }
    }
}

@Test func editingAClosedTabTraps() async {
    await #expect(processExitsWith: .failure) {
        await MainActor.run {
            let (tab, _) = makeTab(held: true)
            tab.close()
            tab.toggleZoom()
        }
    }
}

@Test func readingAClosedTabsFocusedPaneTraps() async {
    await #expect(processExitsWith: .failure) {
        await MainActor.run {
            let (tab, _) = makeTab(held: true)
            _ = tab.closePane()
            _ = tab.focusedPane.commandPane
        }
    }
}

@MainActor @Test func closingTheTabClosesEveryPane() throws {
    let (tab, _) = makeTab(held: true)
    _ = try #require(tab.split(.horizontal, in: bounds))
    _ = try #require(tab.split(.vertical, in: bounds))
    let panes = Array(tab.panes.values)
    let monitors = panes.map { pane in
        let monitor = StubMonitor()
        pane.monitor = monitor
        return monitor
    }
    let loads = try panes.map { try #require($0.load) }

    tab.close()

    #expect(loads.allSatisfy { $0.isCancelled })
    #expect(monitors.map(\.stopCount) == [1, 1, 1])
}

// MARK: Random edits

/// Random split, close, move and zoom edits, with focus moves between them, keep the layout's
/// leaves equal to the tab's pane keys. A close of the last pane ends the sequence.
@MainActor @Test(arguments: 0..<200) func randomEditsKeepLeavesEqualToPanes(seed: Int) {
    var random = SeededGenerator(seed: UInt64(seed))
    let (tab, _) = makeTab(held: true)
    for _ in 0..<(12 + seed % 30) {
        let direction = Direction.allCases.randomElement(using: &random)!
        switch Int.random(in: 0..<6, using: &random) {
        case 0, 1:
            tab.split(Bool.random(using: &random) ? .horizontal : .vertical, in: bounds)
        case 2:
            if tab.closePane() == .tab {
                expectLeavesMatchPanes(tab)
                return
            }
        case 3: tab.move(direction)
        case 4: tab.toggleZoom()
        default: tab.focus(direction)
        }
        expectLeavesMatchPanes(tab)
        #expect(tab.focusedPane === tab.panes[tab.layout.focused])
    }
    tab.close()
}

// MARK: Tab state

/// Four panes in a grid, with ratios moved off one half, histories both ways, one pane in column
/// mode, focus away from the last split and the focused pane zoomed.
@MainActor @Test func fourPaneTabSurvivesATabStateJSONRoundTrip() async throws {
    let (tab, fixture) = makeTab()
    let p0 = fixture.pane
    await settle { p0.state.isLoaded }
    fixture.select("docs")
    p0.navigate(to: Location(path: "/r/docs"))
    p0.navigate(to: Location(path: "/r/docs/sub"))
    p0.goBack()

    let p1 = try #require(tab.split(.horizontal, in: bounds))
    p1.setViewMode(.column)
    tab.focus(.left)
    _ = try #require(tab.split(.vertical, in: bounds))
    tab.resize(.down, by: 80, in: bounds)
    tab.focus(.right)
    _ = try #require(tab.split(.vertical, in: bounds))
    tab.resize(.left, by: 120, in: bounds)
    tab.focus(.left)
    tab.focus(.up)
    tab.toggleZoom()

    let state = tab.state
    let data = try JSONEncoder().encode(state)
    let decoded = try JSONDecoder().decode(TabState.self, from: data)

    #expect(decoded == state)
    #expect(decoded.layout == tab.layout)
    #expect(decoded.layout.panes.count == 4)
    #expect(decoded.layout.isZoomed)
    #expect(decoded.layout.focused == tab.layout.focused)
    #expect(decoded.layout.history == tab.layout.history)
    #expect(tab.focusedPane === p0)

    let first = try #require(decoded.panes[tab.layout.focused])
    #expect(first.location == Location(path: "/r/docs"))
    #expect(first.viewMode == .list)
    #expect(
        first.history.backEntries == [
            History.Entry(location: Location(path: "/r"), selected: ExactName("docs"))
        ])
    #expect(
        first.history.forwardEntries == [
            History.Entry(location: Location(path: "/r/docs/sub"), selected: nil)
        ])
    let p1ID = try #require(tab.panes.first { $0.value === p1 }?.key)
    let second = try #require(decoded.panes[p1ID])
    #expect(second.viewMode == .column)
    tab.close()
}

/// A split copies the pane's sort; Select All in the copy selects every row.
@MainActor @Test func tabStateKeepsEachPanesSelectionCursorAndSort() async throws {
    let (tab, fixture) = makeTab()
    await settle { fixture.pane.state.isLoaded }
    fixture.select("a.txt", "docs")
    fixture.pane.setSort(.size, ascending: false)
    let held = try #require(tab.split(.horizontal, in: bounds))
    held.selectAll()

    let state = tab.state
    let first = try #require(state.panes[tab.layout.history[1]])
    #expect(first.selection == [ExactName("a.txt"), ExactName("docs")])
    #expect(first.cursor == ExactName("docs"))
    #expect(first.sortColumn == .size)
    #expect(!first.sortAscending)
    // Select All's selection names no entry, so the state lists the rows it holds.
    let second = try #require(state.panes[tab.layout.focused])
    #expect(second.selection == [ExactName("a.txt"), ExactName("docs")])
    #expect(second.sortColumn == .size)
    let decoded = try JSONDecoder().decode(TabState.self, from: JSONEncoder().encode(state))
    #expect(decoded == state)
    tab.close()
}

@MainActor @Test func tabStateWhosePanesDontMatchTheLayoutFailsToDecode() throws {
    let (one, _) = makeTab(held: true)
    let (other, _) = makeTab(held: true)
    let encode = { (tab: Tab) throws -> [String: Any] in
        let data = try JSONEncoder().encode(tab.state)
        return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
    var mixed = try encode(one)
    mixed["panes"] = try encode(other)["panes"]
    one.close()
    other.close()
    let data = try JSONSerialization.data(withJSONObject: mixed)

    #expect(throws: DecodingError.self) { try JSONDecoder().decode(TabState.self, from: data) }
}

// MARK: Split and grid copies

/// A workspace whose one tab's pane at `/r` has listed `tree`, with `a.txt` and `docs` selected
/// and the cursor on `a.txt`.
@MainActor
private func loadedWorkspace() async -> (Workspace, PaneFixture) {
    let fixture = PaneFixture(at: "/r", folders: tree)
    let workspace = Workspace(tab: Tab(pane: fixture.pane))
    await settle { fixture.pane.state.isLoaded }
    fixture.select("docs", "a.txt")
    return (workspace, fixture)
}

@MainActor @Test func splitOpensOnTheSameRowsAndSelectionWithoutListingAgain() async throws {
    let (workspace, fixture) = await loadedWorkspace()
    let tab = workspace.selectedTab
    let calls = fixture.lister.calls.count

    let new = try #require(tab.split(.horizontal, in: bounds))

    #expect(new.state.isLoaded)
    #expect(new.state.names == fixture.pane.state.names)
    #expect(new.selection == fixture.pane.selection)
    #expect(new.selection.cursor == ExactName("a.txt"))
    // The new pane has the focus and its rows are as new as the old pane's, so nothing lists.
    #expect(new.isFocused && !fixture.pane.isFocused)
    #expect(new.load == nil)
    await drainMainQueue()
    #expect(fixture.lister.calls.count == calls)
}

@MainActor @Test func splitOfAPaneStillListingSelectsItsSelectionOnceTheRowsShow() async throws {
    let (tab, fixture) = makeTab(held: true)
    fixture.select("a.txt")

    let new = try #require(tab.split(.vertical, in: bounds))
    #expect(new.state.isLoading)
    fixture.lister.releaseAll()
    await settle { new.state.isLoaded }

    #expect(new.selection.cursor == ExactName("a.txt"))
    #expect(new.selection.rows(in: try #require(new.state.listing)) == [0])
}

@MainActor @Test func gridOpensNewPanesOnTheFocusedPanesRowsAndClosesTheRest() async throws {
    let (workspace, fixture) = await loadedWorkspace()
    let tab = workspace.selectedTab
    let first = tab.layout.focused
    let calls = fixture.lister.calls.count

    #expect(tab.makeGrid(columns: 2, rows: 2, in: bounds))

    #expect(tab.panes.count == 4)
    #expect(tab.layout.focused == first)
    #expect(tab.focusedPane === fixture.pane)
    for (id, pane) in tab.panes where id != first {
        #expect(pane.location == fixture.pane.location)
        #expect(pane.state.isLoaded && pane.state.names == fixture.pane.state.names)
        #expect(pane.selection == fixture.pane.selection)
        #expect(!pane.isFocused)
    }
    expectLeavesMatchPanes(tab)
    await drainMainQueue()
    #expect(fixture.lister.calls.count == calls)

    let others = tab.panes.filter { $0.key != first }
    let monitors = others.mapValues { pane in
        let monitor = StubMonitor()
        pane.monitor = monitor
        return monitor
    }

    #expect(tab.makeGrid(columns: 1, rows: 1, in: bounds))

    #expect(tab.layout.panes == [first])
    #expect(monitors.values.map(\.stopCount) == [1, 1, 1])
    #expect(others.values.allSatisfy { $0.monitor == nil })
    expectLeavesMatchPanes(tab)
}

@MainActor @Test func gridRefusedBelowTheMinimumSizeChangesNothing() {
    let (tab, _) = makeTab()
    let narrow = Rect(x: 0, y: 0, width: 200, height: 800)
    let before = tab.layout

    #expect(!tab.makeGrid(columns: 2, rows: 1, in: narrow))
    #expect(tab.layout == before)
    #expect(tab.panes.count == 1)
}
