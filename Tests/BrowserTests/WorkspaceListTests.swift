import Base
import Foundation
import TestSupport
import Testing

@testable import Browser

/// A workspace of one tab of one loaded pane at `/root`, with its lister.
@MainActor
private func loadedWorkspace() async -> (Workspace, GatedLister) {
    let fixture = await PaneFixture.loaded()
    return (Workspace(tab: Tab(pane: fixture.pane)), fixture.lister)
}

@MainActor @Test func addPutsAWorkspaceFirstAndMakesItTheOnlyActiveOne() async {
    let (one, _) = await loadedWorkspace()
    let (two, _) = await loadedWorkspace()
    let list = WorkspaceList()

    list.add(one)
    list.add(two)

    #expect(list.workspaces.map(ObjectIdentifier.init) == [two, one].map(ObjectIdentifier.init))
    #expect(two.isActive && !one.isActive)
    #expect(two.selectedTab.focusedPane.isFocused && !one.selectedTab.focusedPane.isFocused)
}

@MainActor @Test func activatingAWorkspaceMovesItFirst() async {
    let (one, _) = await loadedWorkspace()
    let (two, _) = await loadedWorkspace()
    let (three, _) = await loadedWorkspace()
    let list = WorkspaceList()
    for workspace in [one, two, three] {
        list.add(workspace)
    }

    list.activate(one)

    #expect(
        list.workspaces.map(ObjectIdentifier.init)
            == [one, three, two].map(ObjectIdentifier.init))
    #expect(one.isActive && !two.isActive && !three.isActive)
}

@MainActor @Test func aClosedWindowDropsItsWorkspaceAndKeepsTheOrder() async {
    let (one, _) = await loadedWorkspace()
    let (two, _) = await loadedWorkspace()
    let (three, _) = await loadedWorkspace()
    let list = WorkspaceList()
    for workspace in [one, two, three] {
        list.add(workspace)
    }

    list.windowClosed(two)

    #expect(list.workspaces.map(ObjectIdentifier.init) == [three, one].map(ObjectIdentifier.init))
}

@MainActor @Test func mergeAppendsEveryTabInOrderToTheMostRecentlyActiveOtherWorkspace() async {
    let (target, targetLister) = await loadedWorkspace()
    let (other, _) = await loadedWorkspace()
    let (source, sourceLister) = await loadedWorkspace()
    let list = WorkspaceList()
    for workspace in [other, target, source] {
        list.add(workspace)
    }
    let targetTabs = target.tabs.map(\.id)
    let sourceFirst = source.selectedTab
    source.add(Tab(pane: sourceFirst.focusedPane.newPane(at: Location(path: "/root/docs"))))
    let sourceSecond = source.selectedTab
    source.select(sourceFirst.id)
    let focused = sourceFirst.focusedPane
    // The second tab's pane finishes its first load before the merge.
    await settle { sourceSecond.focusedPane.state.isLoaded }
    let version = focused.stateVersion
    let callsBefore = targetLister.calls.count + sourceLister.calls.count

    list.merge(source)

    #expect(target.tabs.map(\.id) == targetTabs + [sourceFirst.id, sourceSecond.id])
    #expect(target.selectedTab === sourceFirst)
    #expect(
        list.workspaces.map(ObjectIdentifier.init) == [target, other].map(ObjectIdentifier.init))
    #expect(target.isActive)
    // The pane that had the focus keeps it, and its rows, without being listed again.
    #expect(focused.isFocused && focused.stateVersion == version)
    #expect(!sourceSecond.focusedPane.isFocused && !sourceSecond.focusedPane.isVisible)
    #expect(!target.tabs[0].focusedPane.isFocused && !target.tabs[0].focusedPane.isVisible)
    try? await Task.sleep(for: .milliseconds(50))
    #expect(targetLister.calls.count + sourceLister.calls.count == callsBefore)
}

@MainActor @Test func aMergedWorkspaceLeavesThePanesItGaveAwayAlone() async {
    let (target, _) = await loadedWorkspace()
    let (source, _) = await loadedWorkspace()
    let list = WorkspaceList()
    list.add(target)
    list.add(source)
    let targetTab = target.selectedTab
    let moved = source.selectedTab.focusedPane
    list.merge(source)
    target.select(targetTab.id)
    #expect(!moved.isVisible && !moved.isFocused)

    source.isActive = false
    source.isActive = true

    #expect(!moved.isVisible && !moved.isFocused)
    #expect(targetTab.focusedPane.isFocused && targetTab.focusedPane.isVisible)
}

// MARK: Saved workspaces

private let frame = Rect(x: 40, y: 60, width: 900, height: 600)

/// A list of `count` loaded workspaces, the last most recently active, the IDs it forgets and
/// the snapshots it saves.
@MainActor
private func savingList(_ count: Int) async -> (
    WorkspaceList, [Workspace], EventLog<UUID>, EventLog<WorkspaceState>
) {
    let list = WorkspaceList()
    var workspaces: [Workspace] = []
    for _ in 0..<count {
        let (workspace, _) = await loadedWorkspace()
        list.add(workspace)
        workspaces.append(workspace)
    }
    let forgotten = EventLog<UUID>()
    let snapshots = EventLog<WorkspaceState>()
    list.onForget = { forgotten.append($0) }
    list.onSnapshot = { snapshots.append($0) }
    return (list, workspaces, forgotten, snapshots)
}

@MainActor @Test func savingAnUnnamedWorkspaceNamesItAndKeepsItsStateAsTheSnapshot() async throws {
    let (list, workspaces, _, snapshots) = await savingList(2)
    let named = workspaces[0]
    var changes = 0
    named.onChange = { changes += 1 }

    try list.save(named, as: "  Project 1 ", frame: frame)

    #expect(named.name == "Project 1")
    #expect(list.saved == [WorkspaceList.Saved(id: named.id, name: "Project 1", isOpen: true)])
    #expect(list.snapshots == [named.id: named.state(frame: frame)])
    #expect(snapshots.all == [named.state(frame: frame)])
    #expect(changes == 1)
}

@MainActor @Test func savingANamedWorkspaceAgainReplacesItsSnapshot() async throws {
    let (list, workspaces, _, snapshots) = await savingList(1)
    let named = workspaces[0]
    try list.save(named, as: "Project 1", frame: frame)
    named.selectedTab.focusedPane.navigate(to: Location(path: "/root/docs"))
    let moved = Rect(x: 300, y: 200, width: 1000, height: 700)

    try list.save(named, frame: moved)

    #expect(list.snapshots[named.id] == named.state(frame: moved))
    #expect(
        list.snapshots[named.id]?.tabs[0].panes.values.first?.location
            == Location(path: "/root/docs"))
    #expect(snapshots.all.count == 2)
}

@MainActor @Test func changesAfterASaveLeaveTheSnapshotAlone() async throws {
    let (list, workspaces, _, snapshots) = await savingList(1)
    let named = workspaces[0]
    try list.save(named, as: "Project 1", frame: frame)
    let saved = named.state(frame: frame)

    named.selectedTab.focusedPane.navigate(to: Location(path: "/root/docs"))
    _ = try #require(named.selectedTab.split(.horizontal, in: frame))

    #expect(list.snapshots[named.id] == saved)
    #expect(snapshots.all == [saved])
}

@MainActor @Test func savedWorkspacesAreListedByNameAsFinderSortsThem() async throws {
    let (list, workspaces, _, _) = await savingList(3)

    try list.save(workspaces[0], as: "Project 10", frame: frame)
    try list.save(workspaces[1], as: "project 9", frame: frame)
    try list.save(workspaces[2], as: "Archive", frame: frame)

    #expect(list.saved.map(\.name) == ["Archive", "project 9", "Project 10"])
}

@MainActor @Test func aDuplicateNameIsRefusedNamingTheExistingOne() async throws {
    let (list, workspaces, _, _) = await savingList(3)
    try list.save(workspaces[0], as: "Project 1", frame: frame)
    try list.save(workspaces[1], as: "Closed", frame: frame)
    list.windowClosed(workspaces[1])

    #expect(throws: WorkspaceList.NameRefusal.taken("Project 1")) {
        try list.save(workspaces[2], as: "project 1", frame: frame)
    }
    #expect(throws: WorkspaceList.NameRefusal.taken("Closed")) {
        try list.save(workspaces[2], as: "CLOSED", frame: frame)
    }
    #expect(throws: WorkspaceList.NameRefusal.empty) {
        try list.save(workspaces[2], as: "   ", frame: frame)
    }
    #expect(workspaces[2].name == nil && list.snapshots[workspaces[2].id] == nil)
    // A workspace may take its own name in another case.
    try list.rename(workspaces[0], as: "PROJECT 1")
    #expect(workspaces[0].name == "PROJECT 1")
}

@MainActor @Test func renamingRenamesTheSnapshotAndKeepsTheRestOfIt() async throws {
    let (list, workspaces, _, snapshots) = await savingList(2)
    let named = workspaces[0]
    try list.save(named, as: "Project 1", frame: frame)
    let saved = named.state(frame: frame)
    named.selectedTab.focusedPane.navigate(to: Location(path: "/root/docs"))

    try list.rename(named, as: " Project 2 ")

    #expect(named.name == "Project 2")
    let renamed = try #require(list.snapshots[named.id])
    #expect(renamed.name == "Project 2")
    #expect(renamed.tabs == saved.tabs && renamed.frame == saved.frame)
    #expect(snapshots.all.last == renamed)
    #expect(throws: WorkspaceList.NameRefusal.empty) {
        try list.rename(named, as: "")
    }
}

@MainActor @Test func theRefusalSaysWhichNameIsTaken() {
    #expect(
        WorkspaceList.NameRefusal.taken("Project 1").description
            == "The name “Project 1” is already taken. Please choose a different name.")
}

@MainActor @Test func closingANamedWorkspacesWindowKeepsItsSnapshot() async throws {
    let (list, workspaces, forgotten, snapshots) = await savingList(2)
    let named = workspaces[0]
    try list.save(named, as: "Project 1", frame: frame)
    let saved = named.state(frame: frame)
    named.selectedTab.focusedPane.navigate(to: Location(path: "/root/docs"))

    list.windowClosed(named)

    #expect(list.workspaces.map(\.id) == [workspaces[1].id])
    #expect(list.closed == [saved])
    #expect(list.saved == [WorkspaceList.Saved(id: named.id, name: "Project 1", isOpen: false)])
    #expect(forgotten.all.isEmpty && snapshots.all == [saved])
}

@MainActor @Test func closingAnUnnamedWorkspacesWindowKeepsNothing() async {
    let (list, workspaces, forgotten, _) = await savingList(2)

    list.windowClosed(workspaces[0])

    #expect(list.closed.isEmpty && list.saved.isEmpty)
    #expect(forgotten.all.isEmpty)
}

@MainActor @Test func openingAClosedWorkspaceRebuildsItsSnapshot() async throws {
    let (list, workspaces, _, _) = await savingList(2)
    let named = workspaces[0]
    try list.save(named, as: "Project 1", frame: frame)
    let saved = named.state(frame: frame)
    named.selectedTab.focusedPane.navigate(to: Location(path: "/root/docs"))
    list.windowClosed(named)
    let rebuilt = Workspace(
        id: named.id, name: "Project 1", tabs: [Tab(pane: await PaneFixture.loaded().pane)],
        selectedTab: 0, showsSidebar: false)
    var given: [WorkspaceState] = []

    let opened = list.open(named.id) { state in
        given.append(state)
        return rebuilt
    }

    #expect(given == [saved])
    #expect(opened === rebuilt)
    #expect(list.workspaces.first === rebuilt && rebuilt.isActive)
    #expect(list.closed.isEmpty)
    #expect(list.snapshots[named.id] == saved)
}

@MainActor @Test func openingAnOpenWorkspaceActivatesItAndBuildsNothing() async throws {
    let (list, workspaces, _, _) = await savingList(2)
    let named = workspaces[0]
    try list.save(named, as: "Project 1", frame: frame)

    let opened = list.open(named.id) { _ in
        Issue.record("an open workspace was rebuilt")
        return named
    }

    #expect(opened === named)
    #expect(list.workspaces.map(\.id) == [named.id, workspaces[1].id])
    #expect(named.isActive && !workspaces[1].isActive)
}

@MainActor @Test func deletingAnOpenWorkspaceClosesItAndForgetsItOnce() async throws {
    let (list, workspaces, forgotten, _) = await savingList(2)
    let named = workspaces[0]
    try list.save(named, as: "Project 1", frame: frame)

    list.delete(named.id)

    #expect(list.workspaces.map(\.id) == [workspaces[1].id])
    #expect(named.isClosed)
    #expect(forgotten.all == [named.id])
    #expect(list.saved.isEmpty && list.snapshots.isEmpty)
    // Its window then closes, which keeps nothing and forgets nothing more.
    list.windowClosed(named)
    #expect(list.closed.isEmpty)
    #expect(forgotten.all == [named.id])
}

@MainActor @Test func deletingAClosedWorkspaceForgetsIt() async throws {
    let (list, workspaces, forgotten, _) = await savingList(1)
    let named = workspaces[0]
    try list.save(named, as: "Project 1", frame: frame)
    list.windowClosed(named)

    list.delete(named.id)

    #expect(list.closed.isEmpty && list.saved.isEmpty && list.snapshots.isEmpty)
    #expect(forgotten.all == [named.id])
}

@MainActor @Test func aMergedWorkspaceKeepsItsSnapshotAsItsWindowCloses() async throws {
    let (list, workspaces, forgotten, _) = await savingList(3)
    let named = workspaces[1]
    let unnamed = workspaces[2]
    try list.save(named, as: "Project 1", frame: frame)
    let saved = named.state(frame: frame)

    list.merge(named)
    list.windowClosed(named)
    list.merge(unnamed)
    list.windowClosed(unnamed)

    #expect(list.closed == [saved])
    #expect(forgotten.all.isEmpty)
}

@MainActor @Test func aRestoredClosedWorkspaceIsListedAsSaved() async throws {
    let (list, workspaces, _, snapshots) = await savingList(1)
    let closed = WorkspaceState(
        id: UUID(), name: "Project 1", frame: Rect(x: 0, y: 0, width: 800, height: 500),
        tabs: workspaces[0].tabs.map(\.state), selectedTab: 0, showsSidebar: false)

    try list.addSaved(closed)

    #expect(list.closed == [closed])
    #expect(list.saved == [WorkspaceList.Saved(id: closed.id, name: "Project 1", isOpen: false)])
    // The launch read it; nothing new to write.
    #expect(snapshots.all.isEmpty)
    #expect(throws: WorkspaceList.NameRefusal.taken("Project 1")) {
        try list.save(workspaces[0], as: "Project 1", frame: frame)
    }
}

/// A window the launch restores linked to a saved workspace is listed open, not closed.
@MainActor @Test func aRestoredSnapshotOfAnOpenWindowIsListedOpen() async throws {
    let (list, _, _, _) = await savingList(0)
    let (open, _) = await loadedWorkspace()
    let linked = Workspace(
        id: open.id, name: "Project 1", tabs: open.removeAllTabs(), selectedTab: 0,
        showsSidebar: false)
    list.add(linked)

    try list.addSaved(linked.state(frame: frame))

    #expect(list.closed.isEmpty)
    #expect(list.saved == [WorkspaceList.Saved(id: linked.id, name: "Project 1", isOpen: true)])
}

@MainActor @Test func savingIsRefusedUntilTheSavedWorkspacesAreListed() async throws {
    let (list, workspaces, _, _) = await savingList(1)
    list.awaitsRestore = true

    #expect(throws: WorkspaceList.NameRefusal.loading) {
        try list.save(workspaces[0], as: "Project 1", frame: frame)
    }
    #expect(workspaces[0].name == nil)
    list.awaitsRestore = false
    try list.save(workspaces[0], as: "Project 1", frame: frame)
    #expect(workspaces[0].name == "Project 1")
}

@MainActor @Test func aRestoredClosedWorkspaceWhoseNameIsTakenIsRefused() async throws {
    let (list, workspaces, _, _) = await savingList(1)
    try list.save(workspaces[0], as: "Project 1", frame: frame)
    let closed = WorkspaceState(
        id: UUID(), name: "project 1", frame: Rect(x: 0, y: 0, width: 800, height: 500),
        tabs: workspaces[0].tabs.map(\.state), selectedTab: 0, showsSidebar: false)

    #expect(throws: WorkspaceList.NameRefusal.taken("Project 1")) {
        try list.addSaved(closed)
    }
    #expect(list.closed.isEmpty)
}

@MainActor @Test func aFreeNameTakesTheNextNumberAsFinderNamesADuplicate() async throws {
    let (list, workspaces, _, _) = await savingList(3)
    try list.save(workspaces[0], as: "Project 1", frame: frame)
    try list.save(workspaces[1], as: "project 1 2", frame: frame)

    #expect(list.freeName("PROJECT 1", for: workspaces[2].id) == "PROJECT 1 3")
    #expect(list.freeName("Project 1", for: workspaces[0].id) == "Project 1")
    #expect(list.freeName("Archive", for: workspaces[2].id) == "Archive")
    #expect(WorkspaceList.freeName("Notes", among: ["notes", "Notes 2"]) == "Notes 3")
}
