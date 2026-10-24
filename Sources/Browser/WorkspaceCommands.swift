/// The saved workspace commands for the context's window: name or rename its workspace, which
/// makes it a saved one, and delete it, which closes its window and forgets it. Both ask the
/// user first, through the context. Opening a saved workspace takes its ID, so it is
/// `WorkspaceList.open`, not a command (docs/decisions/0082-saved-workspaces.md). The sidebar
/// commands show or hide the window's list of saved workspaces, and move the keys into it
/// (docs/decisions/0086-workspace-sidebar.md).
public enum WorkspaceCommands: CommandSet {
    /// Names the window's workspace, or renames it once named. Its menu item says which.
    public static let name = Command(
        id: CommandID("workspace.name"), title: "Name Workspace…", chords: [])
    /// Deletes the window's saved workspace and closes its window, once the user says yes. Off
    /// for an unnamed workspace, which closing its window forgets.
    public static let delete = Command(
        id: CommandID("workspace.delete"), title: "Delete Workspace…", chords: [])
    /// Shows the window's workspace sidebar, or hides it; the workspace keeps which. Its menu
    /// item says which it would do, as Finder's does. Finder's chord, Control-Command-S, is
    /// Calculate Sizes' here, so it has Option-Command-S, Finder's chord for it before.
    public static let toggleSidebar = Command(
        id: CommandID("workspace.toggleSidebar"), title: "Show Sidebar",
        chords: [KeyChord("s", modifiers: [.option, .command])])
    /// Shows the sidebar and moves the keys into it. Esc there gives them back to the pane.
    public static let focusSidebar = Command(
        id: CommandID("workspace.focusSidebar"), title: "Focus Sidebar", chords: [])

    public static var bindings: [CommandBinding] {
        [
            CommandBinding(
                name,
                title: { $0.workspace.name == nil ? name.title : "Rename Workspace…" },
                run: { $0.askForWorkspaceName() }),
            CommandBinding(
                delete, isEnabled: { $0.workspace.name != nil },
                run: { $0.askToDeleteWorkspace() }),
            CommandBinding(
                toggleSidebar,
                title: { $0.workspace.showsSidebar ? "Hide Sidebar" : toggleSidebar.title },
                run: { $0.workspace.showsSidebar.toggle() }),
            CommandBinding(focusSidebar) { context in
                context.workspace.showsSidebar = true
                context.focusSidebar()
            },
        ]
    }
}
