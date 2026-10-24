import Base
import Foundation
import TestSupport
import Testing

@testable import Browser

/// A context on `workspace`'s focused pane whose name and delete questions, and its moves of
/// the keys to the sidebar, are counted.
@MainActor
private func context(
    _ workspace: Workspace, list: WorkspaceList, asked: EventLog<String>
) -> CommandContext {
    CommandContext(
        pane: workspace.selectedTab.focusedPane.commandPane, workspace: workspace,
        workspaces: list, askForWorkspaceName: { asked.append("name") },
        askToDeleteWorkspace: { asked.append("delete") },
        focusSidebar: { asked.append("focusSidebar") })
}

@MainActor
private func binding(_ command: Command) throws -> CommandBinding {
    try #require(WorkspaceCommands.bindings.first { $0.command == command })
}

@MainActor @Test func nameAsksForANameAndSaysRenameOnceNamed() async throws {
    let fixture = await PaneFixture.loaded()
    let workspace = Workspace(tab: Tab(pane: fixture.pane))
    let list = WorkspaceList()
    list.add(workspace)
    let asked = EventLog<String>()
    let name = try binding(WorkspaceCommands.name)

    #expect(name.title?(context(workspace, list: list, asked: asked)) == "Name Workspace…")
    name.run(context(workspace, list: list, asked: asked))
    #expect(asked.all == ["name"])

    try list.name(workspace, as: "Project 1")
    #expect(name.title?(context(workspace, list: list, asked: asked)) == "Rename Workspace…")
}

@MainActor @Test func deleteIsOnlyForANamedWorkspaceAndAsksFirst() async throws {
    let fixture = await PaneFixture.loaded()
    let workspace = Workspace(tab: Tab(pane: fixture.pane))
    let list = WorkspaceList()
    list.add(workspace)
    let asked = EventLog<String>()
    let delete = try binding(WorkspaceCommands.delete)

    #expect(delete.isEnabled?(context(workspace, list: list, asked: asked)) == false)
    try list.name(workspace, as: "Project 1")
    #expect(delete.isEnabled?(context(workspace, list: list, asked: asked)) == true)

    delete.run(context(workspace, list: list, asked: asked))

    #expect(asked.all == ["delete"])
    // Nothing is deleted until the question is answered.
    #expect(list.saved.count == 1 && !workspace.isClosed)
}

@MainActor @Test func workspaceCommandsHaveNoChordsAndAreRegistered() throws {
    let registry = try AppCommands.registry()
    for command in [WorkspaceCommands.name, WorkspaceCommands.delete] {
        #expect(command.chords.isEmpty)
        #expect(registry.command(for: command.id) == command)
    }
}

@MainActor @Test func toggleSidebarShowsAndHidesItInTheWorkspaceAndSaysWhich() async throws {
    let fixture = await PaneFixture.loaded()
    let workspace = Workspace(tab: Tab(pane: fixture.pane))
    let list = WorkspaceList()
    list.add(workspace)
    let asked = EventLog<String>()
    var changes = 0
    workspace.onChange = { changes += 1 }
    let toggle = try binding(WorkspaceCommands.toggleSidebar)
    #expect(!workspace.showsSidebar)
    #expect(toggle.title?(context(workspace, list: list, asked: asked)) == "Show Sidebar")

    toggle.run(context(workspace, list: list, asked: asked))

    #expect(workspace.showsSidebar && changes == 1)
    #expect(toggle.title?(context(workspace, list: list, asked: asked)) == "Hide Sidebar")

    toggle.run(context(workspace, list: list, asked: asked))

    #expect(!workspace.showsSidebar && changes == 2)
    #expect(asked.all.isEmpty)
}

@MainActor @Test func focusSidebarShowsItAndAsksTheWindowForTheKeys() async throws {
    let fixture = await PaneFixture.loaded()
    let workspace = Workspace(tab: Tab(pane: fixture.pane))
    let list = WorkspaceList()
    list.add(workspace)
    let asked = EventLog<String>()

    try binding(WorkspaceCommands.focusSidebar).run(context(workspace, list: list, asked: asked))

    #expect(workspace.showsSidebar)
    #expect(asked.all == ["focusSidebar"])
}

/// Finder's Show Sidebar chord, Control-Command-S, is Calculate Sizes' here, so the sidebar
/// takes Option-Command-S, the key Finder used for it before.
@MainActor @Test func toggleSidebarHasOptionCommandSAndCalculateSizesKeepsItsChord() throws {
    let registry = try AppCommands.registry()
    #expect(
        registry.command(for: KeyChord("s", modifiers: [.option, .command]))
            == WorkspaceCommands.toggleSidebar)
    #expect(
        registry.command(for: KeyChord("s", modifiers: [.control, .command]))
            == SizeCommands.calculateSizes)
    #expect(WorkspaceCommands.focusSidebar.chords.isEmpty)
}
