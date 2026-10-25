import Base
import Foundation
import TestSupport
import Testing

@testable import Browser

/// Runs `command`'s binding on `workspace`'s selected tab, as the window would, with `folder` as
/// the clicked folder.
@MainActor
private func run(
    _ command: Command, in workspace: Workspace, of list: WorkspaceList? = nil,
    folder: Location? = nil
) throws {
    let binding = try #require(WindowCommands.bindings.first { $0.command == command })
    binding.run(
        CommandContext(
            pane: workspace.selectedTab.focusedPane.commandPane, workspace: workspace,
            workspaces: list, folder: folder))
}

@MainActor
private func isEnabled(
    _ command: Command, in workspace: Workspace, of list: WorkspaceList? = nil,
    folder: Location? = nil
) throws -> Bool {
    let binding = try #require(WindowCommands.bindings.first { $0.command == command })
    let context = CommandContext(
        pane: workspace.selectedTab.focusedPane.commandPane, workspace: workspace,
        workspaces: list, folder: folder)
    return binding.isEnabled?(context) ?? true
}

/// A list holding `workspaces`, the last one most recently active.
@MainActor
private func list(_ workspaces: Workspace...) -> WorkspaceList {
    let list = WorkspaceList()
    for workspace in workspaces {
        list.add(workspace)
    }
    return list
}

@MainActor @Test func openInNewTabAddsASelectedTabAtTheFolderLikeTheFocusedPane() async throws {
    let fixture = await PaneFixture.loaded()
    let sizes = FolderSizeService(cache: FolderSizeCache(store: nil), log: { _ in })
    fixture.pane.folderSizes = sizes
    fixture.pane.setSort(.size, ascending: false)
    fixture.pane.setViewMode(.column)
    let workspace = Workspace(tab: Tab(pane: fixture.pane))
    let first = workspace.selectedTab

    try run(WindowCommands.openInNewTab, in: workspace, folder: Location(path: "/root/docs"))

    #expect(workspace.tabs.count == 2)
    let added = workspace.selectedTab
    #expect(added !== first)
    let pane = added.focusedPane
    #expect(pane.location == Location(path: "/root/docs"))
    #expect(pane.viewMode == .column)
    #expect(pane.commandPane.sortColumn == .size && !pane.commandPane.sortAscending)
    #expect(pane.folderSizes === sizes)
    #expect(pane.isFocused && !fixture.pane.isFocused)
    #expect(first.focusedPane.location == Location(path: "/root"))
}

@MainActor @Test func openInNewTabIsOffWithoutAClickedFolderAndHasNoChord() async throws {
    let fixture = await PaneFixture.loaded()
    let workspace = Workspace(tab: Tab(pane: fixture.pane))

    #expect(try !isEnabled(WindowCommands.openInNewTab, in: workspace, folder: nil))
    #expect(
        try isEnabled(
            WindowCommands.openInNewTab, in: workspace, folder: Location(path: "/root/docs")))
    #expect(WindowCommands.openInNewTab.chords.isEmpty)
}

@MainActor @Test func newTabTakesTheFocusedPanesFolderSortAndSizes() async throws {
    let fixture = await PaneFixture.loaded()
    let sizes = FolderSizeService(cache: FolderSizeCache(store: nil), log: { _ in })
    fixture.pane.folderSizes = sizes
    fixture.pane.setSort(.size, ascending: false)
    let workspace = Workspace(tab: Tab(pane: fixture.pane))

    try run(WindowCommands.newTab, in: workspace)

    let pane = workspace.selectedTab.focusedPane
    #expect(workspace.tabs.count == 2)
    #expect(pane !== fixture.pane)
    #expect(pane.location == Location(path: "/root"))
    #expect(pane.viewMode == .list)
    #expect(pane.sortColumn == .size && !pane.sortAscending)
    #expect(pane.folderSizes === sizes)
}

@MainActor @Test func newWindowOpensAWorkspaceWithOneTabAtTheFocusedFolderAndViewMode() async throws
{
    let fixture = await PaneFixture.loaded()
    let sizes = FolderSizeService(cache: FolderSizeCache(store: nil), log: { _ in })
    fixture.pane.folderSizes = sizes
    fixture.pane.navigate(to: Location(path: "/root/docs"))
    fixture.pane.setViewMode(.column)
    let workspace = Workspace(tab: Tab(pane: fixture.pane))
    workspace.add(Tab(pane: fixture.pane.newPane(at: Location(path: "/root"))))
    workspace.select(workspace.tabs[0].id)
    let workspaces = list(workspace)

    try run(WindowCommands.newWindow, in: workspace, of: workspaces)

    #expect(workspaces.workspaces.count == 2)
    let opened = workspaces.workspaces[0]
    #expect(opened !== workspace)
    #expect(opened.tabs.count == 1)
    let pane = opened.selectedTab.focusedPane
    #expect(pane !== fixture.pane)
    #expect(pane.location == Location(path: "/root/docs"))
    #expect(pane.viewMode == .column)
    #expect(pane.folderSizes === sizes)
    #expect(opened.isActive && !workspace.isActive)
    #expect(workspace.tabs.count == 2)
    #expect(WindowCommands.newWindow.chords == [KeyChord("n", modifiers: .command)])
}

@MainActor @Test func movePaneToNewWindowKeepsThePaneItsRowsAndSelectionWithoutListing()
    async throws
{
    let fixture = await PaneFixture.loaded()
    let listed = fixture.pane.stateVersion
    let workspace = Workspace(tab: Tab(pane: fixture.pane))
    // Gaining the focus lists the folder again; the split copies the rows once that lands.
    await settle { fixture.pane.stateVersion > listed }
    let tab = workspace.selectedTab
    let kept = tab.layout.focused
    let moved = try #require(tab.split(.horizontal, in: Rect(x: 0, y: 0, width: 1200, height: 800)))
    let movedID = tab.layout.focused
    await settle { moved.state.isLoaded }
    moved.select(Selection([ExactName("a.txt")], cursor: ExactName("a.txt")))
    let selection = moved.selection
    let version = moved.stateVersion
    let calls = fixture.lister.calls.count
    let workspaces = list(workspace)

    try run(WindowCommands.movePaneToNewWindow, in: workspace, of: workspaces)

    #expect(workspaces.workspaces.count == 2)
    let opened = workspaces.workspaces[0]
    #expect(opened.tabs.count == 1)
    #expect(opened.selectedTab.layout.panes == [movedID])
    #expect(opened.selectedTab.panes[movedID] === moved)
    #expect(moved.stateVersion == version && moved.selection == selection)
    #expect(moved.isFocused && moved.isVisible)
    #expect(opened.isActive && !workspace.isActive)
    #expect(tab.layout.panes == [kept] && tab.panes[movedID] == nil)
    #expect(!fixture.pane.isFocused)
    try? await Task.sleep(for: .milliseconds(50))
    #expect(fixture.lister.calls.count == calls)
}

@MainActor @Test func movingATabsLastPaneToANewWindowClosesTheTab() async throws {
    let fixture = await PaneFixture.loaded()
    let workspace = Workspace(tab: Tab(pane: fixture.pane))
    let first = workspace.selectedTab
    try run(WindowCommands.newTab, in: workspace)
    let second = workspace.selectedTab
    let moved = second.focusedPane
    let workspaces = list(workspace)

    try run(WindowCommands.movePaneToNewWindow, in: workspace, of: workspaces)

    #expect(workspace.tabs.map(\.id) == [first.id])
    #expect(workspaces.workspaces[0].selectedTab.focusedPane === moved)
    #expect(workspaces.workspaces[0].selectedTab.layout.panes == second.layout.panes)
}

@MainActor @Test func movePaneToNewWindowIsOffWithOnePaneInTheWindow() async throws {
    let fixture = await PaneFixture.loaded()
    let workspace = Workspace(tab: Tab(pane: fixture.pane))
    let workspaces = list(workspace)

    #expect(try !isEnabled(WindowCommands.movePaneToNewWindow, in: workspace, of: workspaces))
    try run(WindowCommands.newTab, in: workspace)
    #expect(try isEnabled(WindowCommands.movePaneToNewWindow, in: workspace, of: workspaces))
}

@MainActor @Test func mergeWindowIntoTabIsOffWithOneWindow() async throws {
    let one = Workspace(tab: Tab(pane: await PaneFixture.loaded().pane))
    let two = Workspace(tab: Tab(pane: await PaneFixture.loaded().pane))
    let workspaces = list(one)

    #expect(try !isEnabled(WindowCommands.mergeWindowIntoTab, in: one, of: workspaces))
    workspaces.add(two)
    #expect(try isEnabled(WindowCommands.mergeWindowIntoTab, in: two, of: workspaces))
}

@MainActor @Test func mergeWindowIntoTabMovesTheTabsToTheLastActiveOtherWindow() async throws {
    let target = Workspace(tab: Tab(pane: await PaneFixture.loaded().pane))
    let source = Workspace(tab: Tab(pane: await PaneFixture.loaded().pane))
    let workspaces = list(target, source)
    let moved = source.selectedTab

    try run(WindowCommands.mergeWindowIntoTab, in: source, of: workspaces)

    #expect(workspaces.workspaces.count == 1 && workspaces.workspaces[0] === target)
    #expect(target.tabs.count == 2 && target.tabs[1] === moved)
}

@MainActor @Test func cmdKAndCmdShiftPResolveToShowPaletteWhichAsksTheWindowToShowIt() async throws
{
    let registry = try AppCommands.registry()
    for chord in [
        KeyChord("k", modifiers: .command), KeyChord("p", modifiers: [.command, .shift]),
    ] {
        #expect(registry.command(for: chord)?.id == WindowCommands.showPalette.id, "\(chord)")
    }
    let fixture = await PaneFixture.loaded()
    let shown = EventLog<Bool>()
    let binding = try #require(
        WindowCommands.bindings.first { $0.command == WindowCommands.showPalette })

    binding.run(CommandContext(pane: fixture.pane, showPalette: { shown.append(true) }))

    #expect(shown.all == [true])
    #expect(binding.isEnabled == nil)
}

@MainActor @Test func cmdPAndCmdShiftKResolveToGoToItemWhichAsksTheWindowToShowIt() async throws {
    let registry = try AppCommands.registry()
    for chord in [
        KeyChord("p", modifiers: .command), KeyChord("k", modifiers: [.command, .shift]),
    ] {
        #expect(registry.command(for: chord)?.id == WindowCommands.goToItem.id, "\(chord)")
    }
    let fixture = await PaneFixture.loaded()
    let shown = EventLog<Bool>()
    let binding = try #require(
        WindowCommands.bindings.first { $0.command == WindowCommands.goToItem })

    binding.run(CommandContext(pane: fixture.pane, showItemPalette: { shown.append(true) }))

    #expect(shown.all == [true])
    #expect(binding.isEnabled == nil)
}
