import Base
import BrowserTestSupport
import Darwin
import Foundation
import TestSupport
import Testing

@testable import Browser

private let bounds = Rect(x: 0, y: 0, width: 1200, height: 800)

/// A tab of one pane at `/r` whose load is held, so nothing finishes during a test. It can
/// navigate to `other`, whose load is held too.
@MainActor
private func heldTab(leavingFor other: String? = nil) -> Tab {
    var folders: [String: [DirectoryEntry]] = ["/r": []]
    if let other { folders[other] = [] }
    return Tab(pane: PaneFixture(at: "/r", folders: folders, held: true).pane)
}

@MainActor @Test func newWorkspaceSelectsItsOnlyTab() {
    let tab = heldTab()
    let workspace = Workspace(tab: tab)

    #expect(workspace.tabs.map(\.id) == [tab.id])
    #expect(workspace.selectedTab === tab)
}

@MainActor @Test func addPutsTheTabAfterTheSelectedOneAndSelectsIt() {
    let a = heldTab()
    let b = heldTab()
    let c = heldTab()
    let workspace = Workspace(tab: a)
    workspace.add(b)
    workspace.select(a.id)

    workspace.add(c)

    #expect(workspace.tabs.map(\.id) == [a.id, c.id, b.id])
    #expect(workspace.selectedTab === c)
}

@MainActor @Test func moveReordersTabsAndKeepsTheSelection() {
    let a = heldTab()
    let b = heldTab()
    let c = heldTab()
    let workspace = Workspace(tab: a)
    workspace.add(b)
    workspace.add(c)
    workspace.select(b.id)

    workspace.move(a.id, to: 2)

    #expect(workspace.tabs.map(\.id) == [b.id, c.id, a.id])
    #expect(workspace.selectedTab === b)

    workspace.move(a.id, to: 0)

    #expect(workspace.tabs.map(\.id) == [a.id, b.id, c.id])
}

@MainActor @Test func closingTheSelectedTabSelectsTheNextOneOrThePreviousAtTheEnd() {
    let a = heldTab()
    let b = heldTab()
    let c = heldTab()
    let workspace = Workspace(tab: a)
    workspace.add(b)
    workspace.add(c)
    workspace.select(b.id)

    #expect(workspace.close(b.id) == .tab)
    #expect(workspace.tabs.map(\.id) == [a.id, c.id])
    #expect(workspace.selectedTab === c)

    #expect(workspace.close(c.id) == .tab)
    #expect(workspace.selectedTab === a)
}

@MainActor @Test func closingAnUnselectedTabKeepsTheSelection() {
    let a = heldTab()
    let b = heldTab()
    let workspace = Workspace(tab: a)
    workspace.add(b)

    #expect(workspace.close(a.id) == .tab)
    #expect(workspace.tabs.map(\.id) == [b.id])
    #expect(workspace.selectedTab === b)
}

@MainActor @Test func closingATabClosesItsPanes() throws {
    let a = heldTab()
    let b = heldTab()
    _ = try #require(b.split(.horizontal, in: bounds))
    let panes = Array(b.panes.values)
    let monitors = panes.map { pane in
        let monitor = StubMonitor()
        pane.monitor = monitor
        return monitor
    }
    let loads = try panes.map { try #require($0.load) }
    let workspace = Workspace(tab: a)
    workspace.add(b)

    workspace.close(b.id)

    #expect(loads.allSatisfy { $0.isCancelled })
    #expect(monitors.map(\.stopCount) == [1, 1])
}

@MainActor @Test func closePaneActsOnTheSelectedTabAndClosesItWithItsLastPane() throws {
    let a = heldTab()
    let b = heldTab()
    _ = try #require(b.split(.horizontal, in: bounds))
    let workspace = Workspace(tab: a)
    workspace.add(b)

    #expect(workspace.closePane() == .pane)
    #expect(b.panes.count == 1)
    #expect(workspace.tabs.count == 2)

    #expect(workspace.closePane() == .tab)
    #expect(workspace.tabs.map(\.id) == [a.id])
    #expect(workspace.selectedTab === a)
}

@MainActor @Test func closingTheLastTabReportsTheWorkspaceClosed() throws {
    let tab = heldTab()
    let monitor = StubMonitor()
    tab.focusedPane.monitor = monitor
    let load = try #require(tab.focusedPane.load)
    let workspace = Workspace(tab: tab)

    #expect(workspace.closePane() == .workspace)

    #expect(load.isCancelled)
    #expect(monitor.stopCount == 1)

    let other = Workspace(tab: heldTab())
    #expect(other.close(other.selectedTab.id) == .workspace)
}

// MARK: Load priority

/// Loads that hold every one of a service's slots, released one at a time by `startOrder`.
private let holdPaths = (0..<4).map { "/hold-\($0)" }

/// The folder a pending go-to-folder lists.
private let goPath = "/g"

/// Tab `/h` of two panes, unselected, and tab `/v` of three, selected, on one service whose slots
/// are all held: every pane's load waits, with its volume known. The order the loads are asked
/// in alone would start the hidden tab's first when `hiddenAskedFirst`, and last otherwise.
@MainActor
private struct QueuedTabs {
    let lister: GatedLister
    let workspace: Workspace
    let hidden: Tab
    let shown: Tab

    init(hiddenAskedFirst: Bool = true) async throws {
        lister = GatedLister(
            Dictionary(
                uniqueKeysWithValues: (holdPaths + ["/h", "/v", goPath]).map {
                    ($0, .batches([]))
                }))
        let service = ListingService(lister: lister)
        for path in holdPaths {
            service.load(Location(path: path)) { _ in }
        }
        #expect(await lister.waitForCalls(4))
        func tab(at path: String) -> Tab {
            Tab(
                pane: Pane(
                    location: Location(path: path), service: service,
                    systemActions: StubSystemActions(), settings: untouchedSettings()))
        }
        func split(_ tab: Tab, into count: Int) throws {
            for _ in 1..<count {
                _ = try #require(tab.split(.horizontal, in: bounds))
            }
        }
        if hiddenAskedFirst {
            hidden = tab(at: "/h")
            workspace = Workspace(tab: hidden)
            try split(hidden, into: 2)
            shown = tab(at: "/v")
            workspace.add(shown)
            try split(shown, into: 3)
        } else {
            shown = tab(at: "/v")
            workspace = Workspace(tab: shown)
            try split(shown, into: 3)
            hidden = tab(at: "/h")
            workspace.add(hidden)
            try split(hidden, into: 2)
            workspace.select(shown.id)
        }
        let loads = try (Array(hidden.panes.values) + Array(shown.panes.values)).map {
            try #require($0.load)
        }
        await settle { loads.allSatisfy { $0.volume != nil } }
    }

    /// The folders listed after the holds, in the order they started. One slot frees at a time,
    /// so each start is the queue's next pick.
    func startOrder() async -> [String] {
        for (index, path) in holdPaths.enumerated() {
            lister.release(path)
            #expect(await lister.waitForCalls(5 + index))
        }
        return Array(lister.calls.map(\.path).dropFirst(holdPaths.count))
    }

    func priorities(_ tab: Tab) -> [ListingLoad.Priority?] {
        tab.layout.panes.map { tab.panes[$0]?.load?.priority }
    }
}

@MainActor @Test func aHiddenTabsLoadsStartAfterEveryVisibleLoad() async throws {
    let tabs = try await QueuedTabs()
    defer { tabs.lister.releaseAll() }

    #expect(tabs.priorities(tabs.hidden) == [.hidden, .hidden])
    #expect(await tabs.startOrder() == ["/v", "/v", "/v", "/h"])
}

@MainActor @Test func selectingATabRaisesItsQueuedLoads() async throws {
    let tabs = try await QueuedTabs(hiddenAskedFirst: false)
    defer { tabs.lister.releaseAll() }
    #expect(tabs.priorities(tabs.hidden) == [.hidden, .hidden])

    tabs.workspace.select(tabs.hidden.id)

    // Its second pane was focused by the split that made it.
    #expect(tabs.priorities(tabs.hidden) == [.visible, .focused])
    #expect(tabs.priorities(tabs.shown).allSatisfy { $0 == .hidden })
    #expect(await tabs.startOrder() == ["/h", "/h", "/v", "/v"])
}

@MainActor @Test func closingTheFocusedPaneFocusesTheNextOnesLoad() async throws {
    let tabs = try await QueuedTabs()
    defer { tabs.lister.releaseAll() }
    let tab = tabs.workspace.selectedTab

    #expect(tabs.workspace.closePane() == .pane)

    #expect(tab.focusedPane.isFocused)
    #expect(tab.focusedPane.load?.priority == .focused)
    #expect(tabs.priorities(tab).filter { $0 == .focused }.count == 1)
}

@MainActor @Test func aPendingGoToFolderFollowsFocusAndTabChanges() async throws {
    let tabs = try await QueuedTabs()
    defer { tabs.lister.releaseAll() }
    let tab = tabs.shown
    let going = tab.focusedPane
    going.goToFolder(Location(path: goPath)) { _ in }
    let load = try #require(going.pendingGo?.load)
    #expect(load.priority == .focused)

    tab.focus(tab.layout.panes[0])
    #expect(load.priority == .visible)

    tabs.workspace.select(tabs.hidden.id)
    #expect(load.priority == .hidden)

    await settle { load.volume != nil }
    // Hidden, it starts after the two loads of the tab now shown and two of the other.
    #expect(await tabs.startOrder() == ["/h", "/h", "/v", "/v"])
}

/// A tree for column panes: `/r` holds a folder `docs`, which holds a folder `sub`.
private let columnTree: [String: [DirectoryEntry]] = [
    "/": [folder("r")], "/r": [folder("docs")],
    "/r/docs": [folder("sub")],
    "/r/docs/sub": [],
]

@MainActor @Test func aHiddenColumnPanesColumnsLoadHiddenNewOnesToo() async throws {
    let lister = GatedLister(columnTree.mapValues { .batches([$0]) })
    lister.releaseAll()
    let service = ListingService(lister: lister)
    func pane(_ viewMode: ViewMode) -> Pane {
        Pane(
            location: Location(path: "/r"), service: service, systemActions: StubSystemActions(),
            settings: untouchedSettings(), viewMode: viewMode)
    }
    let shown = Tab(pane: pane(.list))
    let workspace = Workspace(tab: shown)
    let columns = pane(.column)
    let hidden = Tab(pane: columns)
    workspace.add(hidden)
    let trail = try #require(columns.columnTrail)
    await settle { trail.columns.allSatisfy { $0.pane.state.isLoaded } }

    workspace.select(shown.id)
    #expect(trail.columns.map { $0.pane.load?.priority } == [.hidden, .hidden])

    // A folder selected in a hidden tab's column adds a column, which loads hidden too.
    let docs = ExactName("docs")
    trail.columns[1].pane.select(Selection([docs], cursor: docs))
    await settle { trail.columns.count == 3 }
    #expect(trail.columns[2].pane.load?.priority == .hidden)
}

@MainActor @Test func focusingAPaneMovesItsQueuedLoadFirst() async throws {
    let tabs = try await QueuedTabs()
    defer { tabs.lister.releaseAll() }
    let tab = tabs.workspace.selectedTab
    // The last split focused the third pane.
    #expect(tabs.priorities(tab) == [.visible, .visible, .focused])

    tab.focus(tab.layout.panes[0])

    #expect(tabs.priorities(tab) == [.focused, .visible, .visible])
}

/// The path an open descriptor refers to; nil once it's closed.
private func openPath(_ descriptor: Int32) -> String? {
    var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
    guard fcntl(descriptor, F_GETPATH, &buffer) != -1 else { return nil }
    return String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
}

@MainActor @Test func closingAPaneFreesItsListingAndClosesItsWatch() async throws {
    let folder = try TemporaryFolder("WorkspaceTests")
    let path = folder.url.path
    let lister = GatedLister([path: .batches([(0..<300).map { file("f\($0)") }])])
    lister.releaseAll()
    let tab = Tab(
        pane: Pane(
            location: Location(path: path), service: ListingService(lister: lister),
            systemActions: StubSystemActions(), settings: untouchedSettings()))
    let workspace = Workspace(tab: tab)
    _ = try #require(tab.split(.horizontal, in: bounds))
    weak let closed = tab.focusedPane
    await settle { closed?.state.listing?.count == 300 }
    // A vnode watch, which holds a descriptor open on the folder until it stops.
    let monitor = try await Task.detached {
        try FolderMonitor(location: Location(path: path), volume: .network) { _ in }
    }.value
    let descriptor = try #require(monitor.vnodeDescriptor)
    tab.focusedPane.monitor = monitor
    let watched = try #require(openPath(descriptor))

    #expect(workspace.closePane() == .pane)
    await drainMainQueue()

    // The pane held the only copy of its listing.
    #expect(closed == nil)
    #expect(openPath(descriptor) != watched)
}

// MARK: Changes

/// Loading a saved workspace's snapshot into its open window closes every tab the window had,
/// splits and all, and shows the snapshot's, whose changes it then reports.
@MainActor @Test func reloadClosesEveryTabAndShowsTheNewOnes() throws {
    let first = heldTab()
    let workspace = Workspace(tab: first)
    _ = try #require(first.split(.horizontal, in: bounds))
    let second = heldTab()
    workspace.add(second)
    var changes = 0
    workspace.onChange = { changes += 1 }
    let one = heldTab()
    let two = heldTab()

    workspace.reload(tabs: [one, two], selectedTab: 1, showsSidebar: true)

    #expect(first.isClosed && second.isClosed)
    #expect(workspace.tabs.map(\.id) == [one.id, two.id])
    #expect(workspace.selectedTab === two && workspace.showsSidebar)
    #expect(two.focusedPane.isFocused && two.focusedPane.isVisible)
    #expect(!one.focusedPane.isFocused && !one.focusedPane.isVisible)
    #expect(changes > 0)
    let before = changes
    _ = try #require(two.split(.horizontal, in: bounds))
    #expect(changes > before)
    workspace.closeAllTabs()
}

@MainActor @Test func stateKeepsTheTabsTheSelectedOneAndTheGivenFrame() {
    let first = heldTab()
    let workspace = Workspace(tab: first, showsSidebar: true)
    workspace.add(heldTab())
    workspace.select(first.id)
    let frame = Rect(x: 10, y: 20, width: 900, height: 600)

    let state = workspace.state(frame: frame)

    #expect(
        state
            == WorkspaceState(
                id: workspace.id, name: nil, frame: frame, tabs: workspace.tabs.map(\.state),
                selectedTab: 0, showsSidebar: true, history: WorkspaceHistory()))
    workspace.closeAllTabs()
}

/// Each edit to what `WorkspaceState` keeps reports a change: the tabs, a tab's layout, and a
/// pane's folder or selection, in a tab added later and in one moved in from another workspace.
@MainActor @Test func workspaceReportsEachChangeToWhatItKeeps() async throws {
    let fixture = PaneFixture(at: "/r", folders: ["/r": [file("a"), file("b")], "/s": []])
    let workspace = Workspace(tab: Tab(pane: fixture.pane))
    var changes = 0
    workspace.onChange = { changes += 1 }
    await settle { fixture.pane.state.isLoaded }
    func expectChange(_ edit: () throws -> Void, sourceLocation: SourceLocation = #_sourceLocation)
        rethrows
    {
        let before = changes
        try edit()
        #expect(changes > before, sourceLocation: sourceLocation)
    }

    expectChange { fixture.pane.select(Selection([ExactName("a")], cursor: ExactName("a"))) }
    try expectChange { _ = try #require(workspace.selectedTab.split(.horizontal, in: bounds)) }
    expectChange { workspace.selectedTab.setRatio(0.3, at: [], in: bounds) }
    expectChange { workspace.selectedTab.toggleZoom() }
    let added = heldTab(leavingFor: "/s")
    expectChange { workspace.add(added) }
    expectChange { added.focusedPane.navigate(to: Location(path: "/s")) }
    expectChange { workspace.select(workspace.tabs[0].id) }
    expectChange { workspace.move(added.id, to: 0) }
    let other = Workspace(tab: heldTab(leavingFor: "/s"))
    let moved = other.removeAllTabs()
    expectChange { workspace.append(moved, selecting: moved[0].id) }
    expectChange { moved[0].focusedPane.navigate(to: Location(path: "/s")) }
    expectChange { workspace.close(added.id) }
    workspace.closeAllTabs()
}

// MARK: The window's Back and Forward

/// A workspace of one tab at `/r`, whose tabs rebuild from their states on a released lister of
/// `/r`, `/r/a` and `/r/b`, as a window's owner rebuilds them.
@MainActor
private func steppingWorkspace() -> Workspace {
    let lister = GatedLister([
        "/r": .batches([[folder("a"), folder("b")]]), "/r/a": .batches([[file("x.txt")]]),
        "/r/b": .batches([[]]), "/": .batches([[folder("r")]]),
    ])
    lister.releaseAll()
    let service = ListingService(lister: lister, clock: ManualClock())
    func pane(_ state: TabState.PaneState) -> Pane {
        Pane(
            restoring: state, service: service, systemActions: StubSystemActions(),
            settings: untouchedSettings())
    }
    let workspace = Workspace(
        tab: Tab(
            pane: Pane(
                location: Location(path: "/r"), service: service,
                systemActions: StubSystemActions(), settings: untouchedSettings())))
    workspace.restoreTab = { state in Tab(restoring: state, panes: pane) }
    return workspace
}

/// A saved workspace's snapshot: one tab at `/r/b`, whose pane has a Back entry of its own.
private let snapshot: WorkspaceHistory.Step = {
    let layout = Layout()
    return WorkspaceHistory.Step(
        tabs: [
            TabState(
                layout: layout,
                panes: [
                    layout.focused: TabState.PaneState(
                        location: Location(path: "/r/b"), viewMode: .list,
                        history: History(
                            back: [History.Entry(location: Location(path: "/"), selected: nil)],
                            forward: []),
                        selection: [], cursor: nil, sortColumn: .name, sortAscending: true,
                        columnWidths: ColumnWidths())
                ])
        ], selectedTab: 0, showsSidebar: true)
}()

/// The context a window's focused pane gives its commands.
@MainActor
private func context(of workspace: Workspace) -> CommandContext {
    CommandContext(pane: workspace.selectedTab.focusedPane.commandPane, workspace: workspace)
}

@MainActor
private func run(_ command: Command, in workspace: Workspace) throws {
    try #require(AppCommands.bindings.first { $0.command == command }).run(context(of: workspace))
}

/// Whether `command`'s menu item is on in `workspace`'s window.
@MainActor
private func isEnabled(_ command: Command, in workspace: Workspace) throws -> Bool {
    let binding = try #require(AppCommands.bindings.first { $0.command == command })
    return binding.isEnabled?(context(of: workspace)) ?? true
}

/// Opening a snapshot into the window keeps what it showed, tabs, folders, selection and the
/// panes' own Back, as one step: Back shows it again and Forward the snapshot.
@MainActor @Test func openingASnapshotIsOneStepOfTheWindowsBackAndForward() async throws {
    let workspace = steppingWorkspace()
    let first = workspace.selectedTab.focusedPane
    first.navigate(to: Location(path: "/r/a"), selecting: "x.txt")
    await settle { first.state.isLoaded && first.selection.isSettled }
    workspace.add(Tab(pane: first.newPane(at: Location(path: "/r/b"))))
    workspace.select(workspace.tabs[0].id)
    let before = workspace.state(frame: bounds)

    workspace.open(snapshot)

    #expect(workspace.tabs.count == 1 && workspace.showsSidebar)
    let opened = workspace.selectedTab.focusedPane
    #expect(opened.location == Location(path: "/r/b"))
    // The snapshot's own Back is not the way back: the window's step is.
    #expect(!opened.canGoBack && !opened.canGoForward)
    #expect(workspace.canStepBack && !workspace.canStepForward)
    #expect(try isEnabled(NavigationCommands.back, in: workspace))
    #expect(try !isEnabled(NavigationCommands.forward, in: workspace))

    try run(NavigationCommands.back, in: workspace)

    #expect(workspace.tabs.count == 2 && !workspace.showsSidebar)
    let back = workspace.selectedTab.focusedPane
    await settle { back.state.isLoaded && back.selection.isSettled }
    #expect(workspace.state(frame: bounds) == before.withHistory(workspace.history))
    #expect(back.selection.cursor == ExactName("x.txt"))
    #expect(back.history.backEntries.map(\.location) == [Location(path: "/r")])
    #expect(!workspace.canStepBack && workspace.canStepForward)
    #expect(try isEnabled(NavigationCommands.forward, in: workspace))

    try run(NavigationCommands.forward, in: workspace)

    #expect(workspace.tabs.count == 1)
    #expect(workspace.selectedTab.focusedPane.location == Location(path: "/r/b"))
    #expect(workspace.canStepBack && !workspace.canStepForward)
    workspace.closeAllTabs()
}

/// Back walks the pane's own steps first, then the window's; a navigation ends the window's way
/// forward, as it ends a pane's.
@MainActor @Test func backTakesThePanesStepsBeforeTheWindowsAndANavigationEndsForward() throws {
    let workspace = steppingWorkspace()
    workspace.open(snapshot)
    let pane = workspace.selectedTab.focusedPane
    pane.navigate(to: Location(path: "/r/a"))

    try run(NavigationCommands.back, in: workspace)
    #expect(workspace.selectedTab.focusedPane === pane)
    #expect(pane.location == Location(path: "/r/b"))

    try run(NavigationCommands.back, in: workspace)
    #expect(workspace.selectedTab.focusedPane.location == Location(path: "/r"))
    #expect(workspace.canStepForward)

    workspace.selectedTab.focusedPane.navigate(to: Location(path: "/r/a"))

    #expect(!workspace.canStepForward)
    #expect(try !isEnabled(NavigationCommands.forward, in: workspace))
    workspace.closeAllTabs()
}

/// What the window showed loses its panes' way forward as it becomes a step, so Forward after
/// the window's Back goes to the snapshot, not to a folder a pane had stepped back from.
@MainActor @Test func openingEndsThePanesWayForward() throws {
    let workspace = steppingWorkspace()
    let pane = workspace.selectedTab.focusedPane
    pane.navigate(to: Location(path: "/r/a"))
    pane.goBack()
    #expect(pane.canGoForward)

    workspace.open(snapshot)
    workspace.stepBack()

    #expect(!workspace.selectedTab.focusedPane.canGoForward)
    try run(NavigationCommands.forward, in: workspace)
    #expect(workspace.selectedTab.focusedPane.location == Location(path: "/r/b"))
    workspace.closeAllTabs()
}

@MainActor @Test func theWindowKeepsItsNearestStepsUpToTheLimit() {
    let workspace = steppingWorkspace()
    for _ in 0...WorkspaceHistory.limit {
        workspace.open(snapshot)
    }

    #expect(workspace.history.back.count == WorkspaceHistory.limit)
    workspace.closeAllTabs()
}
