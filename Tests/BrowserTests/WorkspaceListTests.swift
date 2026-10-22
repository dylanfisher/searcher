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

@MainActor @Test func removeDropsAWorkspaceAndKeepsTheOrder() async {
    let (one, _) = await loadedWorkspace()
    let (two, _) = await loadedWorkspace()
    let (three, _) = await loadedWorkspace()
    let list = WorkspaceList()
    for workspace in [one, two, three] {
        list.add(workspace)
    }

    list.remove(two)

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
