/// The saved workspace commands for the context's window: name or rename its workspace, which
/// makes it a saved one, and delete it, which closes its window and forgets it. Both ask the
/// user first, through the context. Opening a saved workspace takes its ID, so it is
/// `WorkspaceList.open`, not a command (docs/decisions/0082-saved-workspaces.md).
public enum WorkspaceCommands: CommandSet {
    /// Names the window's workspace, or renames it once named. Its menu item says which.
    public static let name = Command(
        id: CommandID("workspace.name"), title: "Name Workspace…", chords: [])
    /// Deletes the window's saved workspace and closes its window, once the user says yes. Off
    /// for an unnamed workspace, which closing its window forgets.
    public static let delete = Command(
        id: CommandID("workspace.delete"), title: "Delete Workspace…", chords: [])

    public static var bindings: [CommandBinding] {
        [
            CommandBinding(
                name,
                title: { $0.workspace.name == nil ? name.title : "Rename Workspace…" },
                run: { $0.askForWorkspaceName() }),
            CommandBinding(
                delete, isEnabled: { $0.workspace.name != nil },
                run: { $0.askToDeleteWorkspace() }),
        ]
    }
}
