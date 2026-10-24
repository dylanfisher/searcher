import Base
import BrowserTestSupport
import Darwin
import Foundation
import TestSupport
import Testing

@testable import Browser

private let bounds = Rect(x: 0, y: 0, width: 1200, height: 800)

/// A pane state at `path` with `selection` selected, the cursor on `cursor`.
private func saved(
    _ path: String, selection: [String] = [], cursor: String? = nil,
    viewMode: ViewMode = .list, sortedBy column: SortColumn = .name, ascending: Bool = true,
    back: [String] = []
) -> TabState.PaneState {
    TabState.PaneState(
        location: Location(path: path), viewMode: viewMode,
        history: History(
            back: back.map { History.Entry(location: Location(path: $0), selected: nil) },
            forward: []),
        selection: Set(selection.map(ExactName.init)), cursor: cursor.map(ExactName.init),
        sortColumn: column, sortAscending: ascending)
}

@MainActor
private func restored(
    _ state: TabState.PaneState, lister: GatedLister
) -> Pane {
    Pane(
        restoring: state, service: ListingService(lister: lister),
        systemActions: StubSystemActions(), settings: untouchedSettings())
}

@MainActor @Test func restoredPaneSelectsItsSavedNamesAndDropsTheMissingOnes() async {
    let lister = GatedLister([
        "/r": .batches([[folder("docs"), file("a.txt"), file("b.txt")]])
    ])
    lister.releaseAll()
    let pane = restored(
        saved(
            "/r", selection: ["a.txt", "gone.txt", "docs"], cursor: "a.txt", sortedBy: .size,
            ascending: false, back: ["/"]),
        lister: lister)

    await settle { pane.state.isLoaded && pane.selection.isSettled }

    #expect(pane.location == Location(path: "/r"))
    #expect(pane.selection.members == .only([ExactName("a.txt"), ExactName("docs")]))
    #expect(pane.selection.cursor == ExactName("a.txt"))
    #expect(pane.sortColumn == .size)
    #expect(!pane.sortAscending)
    #expect(pane.canGoBack)
    #expect(pane.history.backEntries.map(\.location) == [Location(path: "/")])
}

@MainActor @Test func restoredPaneWhoseFolderWasDeletedShowsTheMissingStateWithItsPath() async {
    let lister = GatedLister([
        "/r/gone": .failure(ListingError(path: "/r/gone", code: ENOENT))
    ])
    lister.releaseAll()
    let pane = restored(saved("/r/gone", selection: ["a.txt"], cursor: "a.txt"), lister: lister)

    await settle { pane.state.missingFolder != nil }

    #expect(pane.state.missingFolder == "/r/gone")
    // The pane stays at the saved folder rather than moving to another one.
    #expect(pane.location == Location(path: "/r/gone"))
}

@MainActor @Test func aFolderThatIsAFileNowIsMissingToo() async {
    let lister = GatedLister(["/r/x": .failure(ListingError(path: "/r/x", code: ENOTDIR))])
    lister.releaseAll()
    let pane = restored(saved("/r/x"), lister: lister)

    await settle { pane.state.missingFolder != nil }

    #expect(pane.state.missingFolder == "/r/x")
}

@MainActor @Test func aFolderTheAppCantReadIsNotMissing() async {
    let lister = GatedLister(["/r/x": .failure(ListingError(path: "/r/x", code: EACCES))])
    lister.releaseAll()
    let pane = restored(saved("/r/x"), lister: lister)

    await settle { pane.state.isFailed }

    #expect(pane.state.missingFolder == nil)
}

@MainActor @Test func restoredColumnPaneOpensOneColumnOnItsFolderWithTheCursorSelected()
    async throws
{
    let lister = GatedLister([
        "/r": .batches([[folder("docs"), file("a.txt")]]),
        "/r/docs": .batches([[file("inside.txt")]]),
    ])
    lister.releaseAll()
    let pane = restored(saved("/r", cursor: "docs", viewMode: .column), lister: lister)

    let trail = try #require(pane.columnTrail)
    await settle { trail.columns.count == 2 }

    #expect(pane.viewMode == .column)
    #expect(trail.columns[0].pane.location == Location(path: "/r"))
    #expect(trail.columns[0].pane.selection.cursor == ExactName("docs"))
    pane.close()
}

@MainActor @Test func restoredTabHasTheSavedLayoutAndAPaneForEachLeaf() throws {
    var layout = Layout()
    let first = layout.focused
    let split = layout.split(.horizontal, in: bounds)
    let second = try #require(split)
    layout.focus(first)
    let state = TabState(
        layout: layout, panes: [first: saved("/a"), second: saved("/b", viewMode: .column)])
    let lister = GatedLister(["/a": .batches([[]]), "/b": .batches([[]])])

    let tab = Tab(restoring: state) { restored($0, lister: lister) }

    #expect(tab.layout == layout)
    #expect(tab.focusedPane.location == Location(path: "/a"))
    #expect(tab.panes[second]?.location == Location(path: "/b"))
    #expect(tab.panes[second]?.viewMode == .column)
    #expect(tab.state.layout == layout)
    tab.close()
}

@MainActor @Test func restoredWorkspaceKeepsItsIDNameAndSelectedTab() {
    let lister = GatedLister(["/a": .batches([[]]), "/b": .batches([[]])])
    let one = Tab(pane: restored(saved("/a"), lister: lister))
    let two = Tab(pane: restored(saved("/b"), lister: lister))
    let id = UUID()

    let workspace = Workspace(
        id: id, name: "Project 1", tabs: [one, two], selectedTab: 1, showsSidebar: true)

    #expect(workspace.id == id)
    #expect(workspace.name == "Project 1")
    #expect(workspace.showsSidebar)
    #expect(workspace.tabs.map(\.id) == [one.id, two.id])
    #expect(workspace.selectedTab === two)
    #expect(one.focusedPane.isVisible == false)
    workspace.closeAllTabs()
}
