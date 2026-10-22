import Base
import Foundation
import TestSupport
import Testing

@testable import Browser

/// Runs `command`'s binding on `workspace`'s selected tab, as the window would, with `folder` as
/// the clicked folder.
@MainActor
private func run(_ command: Command, in workspace: Workspace, folder: Location? = nil) throws {
    let binding = try #require(WindowCommands.bindings.first { $0.command == command })
    binding.run(
        CommandContext(
            pane: workspace.selectedTab.focusedPane.commandPane, workspace: workspace,
            folder: folder))
}

@MainActor
private func isEnabled(_ command: Command, in workspace: Workspace, folder: Location?) throws
    -> Bool
{
    let binding = try #require(WindowCommands.bindings.first { $0.command == command })
    let context = CommandContext(
        pane: workspace.selectedTab.focusedPane.commandPane, workspace: workspace, folder: folder)
    return binding.isEnabled?(context) ?? true
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
