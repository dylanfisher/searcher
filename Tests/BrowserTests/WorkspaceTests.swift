import Base
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
