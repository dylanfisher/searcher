import Base
import Foundation
import TestSupport
import Testing

@testable import Browser

private let frame = Rect(x: 0, y: 0, width: 900, height: 600)

/// A context on `workspace`'s focused pane whose name and delete questions, its saves and its
/// moves of the keys to the sidebar are counted.
@MainActor
private func context(
    _ workspace: Workspace, list: WorkspaceList, asked: EventLog<String>
) -> CommandContext {
    CommandContext(
        pane: workspace.selectedTab.focusedPane.commandPane, workspace: workspace,
        workspaces: list, askForWorkspaceName: { asked.append("name") },
        saveWorkspace: { asked.append("save") },
        askToDeleteWorkspace: { asked.append("delete") },
        focusSidebar: { asked.append("focusSidebar") })
}

@MainActor
private func binding(_ command: Command) throws -> CommandBinding {
    try #require(WorkspaceCommands.bindings.first { $0.command == command })
}

@MainActor @Test func saveAsksForANameFirstThenSavesWithoutAsking() async throws {
    let fixture = await PaneFixture.loaded()
    let workspace = Workspace(tab: Tab(pane: fixture.pane))
    let list = WorkspaceList()
    list.add(workspace)
    let asked = EventLog<String>()
    let save = try binding(WorkspaceCommands.save)

    #expect(save.title?(context(workspace, list: list, asked: asked)) == "Save Workspace…")
    save.run(context(workspace, list: list, asked: asked))
    #expect(asked.all == ["name"])

    try list.save(workspace, as: "Project 1", frame: frame)
    // It no longer asks anything, so its title loses the ellipsis.
    #expect(save.title?(context(workspace, list: list, asked: asked)) == "Save Workspace")
    save.run(context(workspace, list: list, asked: asked))
    #expect(asked.all == ["name", "save"])
}

@MainActor @Test func renameIsOnlyForANamedWorkspaceAndAsksForTheName() async throws {
    let fixture = await PaneFixture.loaded()
    let workspace = Workspace(tab: Tab(pane: fixture.pane))
    let list = WorkspaceList()
    list.add(workspace)
    let asked = EventLog<String>()
    let rename = try binding(WorkspaceCommands.rename)

    #expect(rename.isEnabled?(context(workspace, list: list, asked: asked)) == false)
    try list.save(workspace, as: "Project 1", frame: frame)
    #expect(rename.isEnabled?(context(workspace, list: list, asked: asked)) == true)

    rename.run(context(workspace, list: list, asked: asked))

    #expect(asked.all == ["name"])
}

@MainActor @Test func deleteIsOnlyForANamedWorkspaceAndAsksFirst() async throws {
    let fixture = await PaneFixture.loaded()
    let workspace = Workspace(tab: Tab(pane: fixture.pane))
    let list = WorkspaceList()
    list.add(workspace)
    let asked = EventLog<String>()
    let delete = try binding(WorkspaceCommands.delete)

    #expect(delete.isEnabled?(context(workspace, list: list, asked: asked)) == false)
    try list.save(workspace, as: "Project 1", frame: frame)
    #expect(delete.isEnabled?(context(workspace, list: list, asked: asked)) == true)

    delete.run(context(workspace, list: list, asked: asked))

    #expect(asked.all == ["delete"])
    // Nothing is deleted until the question is answered.
    #expect(list.saved.count == 1 && !workspace.isClosed)
}

@MainActor @Test func renameAndDeleteHaveNoChordsAndAreRegistered() throws {
    let registry = try AppCommands.registry()
    for command in [WorkspaceCommands.save, WorkspaceCommands.rename, WorkspaceCommands.delete] {
        #expect(registry.command(for: command.id) == command)
    }
    #expect(WorkspaceCommands.rename.chords.isEmpty && WorkspaceCommands.delete.chords.isEmpty)
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

/// Show Sidebar has Finder's chord, Control-Command-S; Calculate Sizes has Option-Command-S.
/// Save Workspace takes Command-S, which Finder leaves unused, and Focus Sidebar Command-0,
/// which Finder leaves unused too.
@MainActor @Test func theWorkspaceCommandsChords() throws {
    let registry = try AppCommands.registry()
    #expect(
        registry.command(for: KeyChord("s", modifiers: [.control, .command]))
            == WorkspaceCommands.toggleSidebar)
    #expect(
        registry.command(for: KeyChord("s", modifiers: [.option, .command]))
            == SizeCommands.calculateSizes)
    #expect(registry.command(for: KeyChord("s", modifiers: .command)) == WorkspaceCommands.save)
    #expect(
        registry.command(for: KeyChord("0", modifiers: .command))
            == WorkspaceCommands.focusSidebar)
}
