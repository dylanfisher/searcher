/// The saved workspace commands for the context's window: save its workspace's state as a
/// snapshot, asking for a name the first time; rename it; and delete it, which closes its window
/// and forgets it. Opening a saved workspace takes its ID, so it is `WorkspaceList.open`, not a
/// command (docs/decisions/0082-saved-workspaces.md, docs/decisions/0088-workspace-snapshots.md).
/// The sidebar commands show or hide the window's list of saved workspaces, and move the keys
/// into it and back (docs/decisions/0086-workspace-sidebar.md).
public enum WorkspaceCommands: CommandSet {
    /// Saves the window's workspace as it is now, asking for a name first when it has none. Finder
    /// leaves Command-S unused.
    public static let save = Command(
        id: CommandID("workspace.save"), title: "Save Workspace…",
        chords: [KeyChord("s", modifiers: .command)])
    /// Renames the window's saved workspace. Off for one that isn't saved.
    public static let rename = Command(
        id: CommandID("workspace.rename"), title: "Rename Workspace…", chords: [])
    /// Deletes the window's saved workspace and closes its window, once the user says yes. Off
    /// for an unnamed workspace, which closing its window forgets.
    public static let delete = Command(
        id: CommandID("workspace.delete"), title: "Delete Workspace…", chords: [])
    /// Shows the window's workspace sidebar, or hides it; the workspace keeps which. Its menu
    /// item says which it would do, as Finder's does, and has Finder's chord, Control-Command-S.
    public static let toggleSidebar = Command(
        id: CommandID("workspace.toggleSidebar"), title: "Show Sidebar",
        chords: [KeyChord("s", modifiers: [.control, .command])])
    /// Shows the sidebar and moves the keys into it; with the keys in the sidebar it gives them
    /// back to the pane, as Esc there does. Finder leaves Command-0 unused.
    public static let focusSidebar = Command(
        id: CommandID("workspace.focusSidebar"), title: "Focus Sidebar",
        chords: [KeyChord("0", modifiers: .command)])

    public static var bindings: [CommandBinding] {
        [
            CommandBinding(
                save,
                // A save that asks nothing has no ellipsis, as the HIG has it.
                title: { $0.workspace.name == nil ? save.title : "Save Workspace" },
                run: { context in
                    if context.workspace.name == nil {
                        context.askForWorkspaceName()
                    } else {
                        context.saveWorkspace()
                    }
                }),
            CommandBinding(
                rename, isEnabled: { $0.workspace.name != nil },
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
