import Base
import BrowserTestSupport
import Darwin
import Foundation
import TestSupport
import Testing

@testable import Browser

private let bounds = Rect(x: 0, y: 0, width: 1200, height: 800)

/// A tab of one pane at `/r` whose load is held, so nothing finishes during a test.
@MainActor
private func heldTab() -> Tab {
    Tab(pane: PaneFixture(at: "/r", folders: ["/r": []], held: true).pane)
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
    "/r": [folder("docs")],
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
    await settle { trail.columns[0].pane.state.isLoaded }

    workspace.select(shown.id)
    #expect(trail.columns[0].pane.load?.priority == .hidden)

    // A folder selected in a hidden tab's column adds a column, which loads hidden too.
    let docs = ExactName("docs")
    trail.columns[0].pane.select(Selection([docs], cursor: docs))
    await settle { trail.columns.count == 2 }
    #expect(trail.columns[1].pane.load?.priority == .hidden)
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
