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

    list.windowClosed(two, as: state(of: two))

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

/// `workspace` as the store keeps it, with a fixed frame.
@MainActor
private func state(of workspace: Workspace) -> WorkspaceState {
    WorkspaceState(
        id: workspace.id, name: workspace.name, frame: Rect(x: 40, y: 60, width: 900, height: 600),
        tabs: workspace.tabs.map(\.state), selectedTab: 0, showsSidebar: false)
}

/// A list of `count` loaded workspaces, the last most recently active, and the IDs it forgets.
@MainActor
private func savingList(_ count: Int) async -> (WorkspaceList, [Workspace], EventLog<UUID>) {
    let list = WorkspaceList()
    var workspaces: [Workspace] = []
    for _ in 0..<count {
        let (workspace, _) = await loadedWorkspace()
        list.add(workspace)
        workspaces.append(workspace)
    }
    let forgotten = EventLog<UUID>()
    list.onForget = { forgotten.append($0) }
    return (list, workspaces, forgotten)
}

@MainActor @Test func namingTheOpenWorkspaceListsItAsSaved() async throws {
    let (list, workspaces, _) = await savingList(2)
    let named = workspaces[0]
    var changes = 0
    named.onChange = { changes += 1 }

    try list.name(named, as: "  Project 1 ")

    #expect(named.name == "Project 1")
    #expect(list.saved == [WorkspaceList.Saved(id: named.id, name: "Project 1", isOpen: true)])
    #expect(changes == 1)
}

@MainActor @Test func savedWorkspacesAreListedByNameAsFinderSortsThem() async throws {
    let (list, workspaces, _) = await savingList(3)

    try list.name(workspaces[0], as: "Project 10")
    try list.name(workspaces[1], as: "project 9")
    try list.name(workspaces[2], as: "Archive")

    #expect(list.saved.map(\.name) == ["Archive", "project 9", "Project 10"])
}

@MainActor @Test func aDuplicateNameIsRefusedNamingTheExistingOne() async throws {
    let (list, workspaces, _) = await savingList(3)
    try list.name(workspaces[0], as: "Project 1")
    try list.name(workspaces[1], as: "Closed")
    list.windowClosed(workspaces[1], as: state(of: workspaces[1]))

    #expect(throws: WorkspaceList.NameRefusal.taken("Project 1")) {
        try list.name(workspaces[2], as: "project 1")
    }
    #expect(throws: WorkspaceList.NameRefusal.taken("Closed")) {
        try list.name(workspaces[2], as: "CLOSED")
    }
    #expect(throws: WorkspaceList.NameRefusal.empty) {
        try list.name(workspaces[2], as: "   ")
    }
    #expect(workspaces[2].name == nil)
    // A workspace may take its own name in another case.
    try list.name(workspaces[0], as: "PROJECT 1")
    #expect(workspaces[0].name == "PROJECT 1")
}

@MainActor @Test func theRefusalSaysWhichNameIsTaken() {
    #expect(
        WorkspaceList.NameRefusal.taken("Project 1").description
            == "The name “Project 1” is already taken. Please choose a different name.")
}

@MainActor @Test func closingANamedWorkspacesWindowKeepsItsEntryAsItWasAtClose() async throws {
    let (list, workspaces, forgotten) = await savingList(2)
    let named = workspaces[0]
    try list.name(named, as: "Project 1")
    let atClose = state(of: named)

    list.windowClosed(named, as: atClose)

    #expect(list.workspaces.map(\.id) == [workspaces[1].id])
    #expect(list.closed == [atClose])
    #expect(list.saved == [WorkspaceList.Saved(id: named.id, name: "Project 1", isOpen: false)])
    #expect(forgotten.all.isEmpty)
}

@MainActor @Test func closingAnUnnamedWorkspacesWindowForgetsIt() async {
    let (list, workspaces, forgotten) = await savingList(2)

    list.windowClosed(workspaces[0], as: state(of: workspaces[0]))

    #expect(forgotten.all == [workspaces[0].id])
    #expect(list.closed.isEmpty && list.saved.isEmpty)
}

@MainActor @Test func openingAClosedWorkspaceRebuildsTheStateItHadAtClose() async throws {
    let (list, workspaces, _) = await savingList(2)
    let named = workspaces[0]
    try list.name(named, as: "Project 1")
    let atClose = state(of: named)
    list.windowClosed(named, as: atClose)
    let rebuilt = Workspace(
        id: named.id, name: "Project 1", tabs: [Tab(pane: await PaneFixture.loaded().pane)],
        selectedTab: 0, showsSidebar: false)
    var given: [WorkspaceState] = []

    let opened = list.open(named.id) { state in
        given.append(state)
        return rebuilt
    }

    #expect(given == [atClose])
    #expect(opened === rebuilt)
    #expect(list.workspaces.first === rebuilt && rebuilt.isActive)
    #expect(list.closed.isEmpty)
}

@MainActor @Test func openingAnOpenWorkspaceActivatesItAndBuildsNothing() async throws {
    let (list, workspaces, _) = await savingList(2)
    let named = workspaces[0]
    try list.name(named, as: "Project 1")

    let opened = list.open(named.id) { _ in
        Issue.record("an open workspace was rebuilt")
        return named
    }

    #expect(opened === named)
    #expect(list.workspaces.map(\.id) == [named.id, workspaces[1].id])
    #expect(named.isActive && !workspaces[1].isActive)
}

@MainActor @Test func deletingAnOpenWorkspaceClosesItAndForgetsItOnce() async throws {
    let (list, workspaces, forgotten) = await savingList(2)
    let named = workspaces[0]
    try list.name(named, as: "Project 1")

    list.delete(named.id)

    #expect(list.workspaces.map(\.id) == [workspaces[1].id])
    #expect(named.isClosed)
    #expect(forgotten.all == [named.id])
    #expect(list.saved.isEmpty)
    // Its window then closes, which keeps nothing and forgets nothing more.
    list.windowClosed(named, as: state(of: workspaces[1]))
    #expect(list.closed.isEmpty)
    #expect(forgotten.all == [named.id])
}

@MainActor @Test func deletingAClosedWorkspaceForgetsIt() async throws {
    let (list, workspaces, forgotten) = await savingList(1)
    let named = workspaces[0]
    try list.name(named, as: "Project 1")
    list.windowClosed(named, as: state(of: named))

    list.delete(named.id)

    #expect(list.closed.isEmpty && list.saved.isEmpty)
    #expect(forgotten.all == [named.id])
}

@MainActor @Test func aMergedWorkspaceIsKeptIfNamedAndForgottenIfNotAsItsWindowCloses() async throws
{
    let (list, workspaces, forgotten) = await savingList(3)
    let named = workspaces[1]
    let unnamed = workspaces[2]
    try list.name(named, as: "Project 1")
    let atMerge = state(of: named)

    list.merge(named)
    list.windowClosed(named, as: atMerge)
    list.merge(unnamed)
    list.windowClosed(unnamed, as: state(of: workspaces[0]))

    #expect(list.closed == [atMerge])
    #expect(forgotten.all == [unnamed.id])
}

@MainActor @Test func aRestoredClosedWorkspaceIsListedAsSaved() async throws {
    let (list, workspaces, _) = await savingList(1)
    let closed = WorkspaceState(
        id: UUID(), name: "Project 1", frame: Rect(x: 0, y: 0, width: 800, height: 500),
        tabs: workspaces[0].tabs.map(\.state), selectedTab: 0, showsSidebar: false)

    try list.addSaved(closed)

    #expect(list.closed == [closed])
    #expect(list.saved == [WorkspaceList.Saved(id: closed.id, name: "Project 1", isOpen: false)])
    #expect(throws: WorkspaceList.NameRefusal.taken("Project 1")) {
        try list.name(workspaces[0], as: "Project 1")
    }
}

@MainActor @Test func namingIsRefusedUntilTheSavedWorkspacesAreListed() async throws {
    let (list, workspaces, _) = await savingList(1)
    list.awaitsRestore = true

    #expect(throws: WorkspaceList.NameRefusal.loading) {
        try list.name(workspaces[0], as: "Project 1")
    }
    #expect(workspaces[0].name == nil)
    list.awaitsRestore = false
    try list.name(workspaces[0], as: "Project 1")
    #expect(workspaces[0].name == "Project 1")
}

@MainActor @Test func aRestoredClosedWorkspaceWhoseNameIsTakenIsRefused() async throws {
    let (list, workspaces, _) = await savingList(1)
    try list.name(workspaces[0], as: "Project 1")
    let closed = WorkspaceState(
        id: UUID(), name: "project 1", frame: Rect(x: 0, y: 0, width: 800, height: 500),
        tabs: workspaces[0].tabs.map(\.state), selectedTab: 0, showsSidebar: false)

    #expect(throws: WorkspaceList.NameRefusal.taken("Project 1")) {
        try list.addSaved(closed)
    }
    #expect(list.closed.isEmpty)
}
