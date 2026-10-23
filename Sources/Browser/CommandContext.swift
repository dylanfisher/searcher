/// What a command acts on: the focused pane, the window's workspace and the list of every
/// window's workspace when the view has them, and the views around them that Browser can't
/// reach.
@MainActor
public struct CommandContext {
    public let pane: Pane
    /// Gives the size the selected tab's panes fill, for the commands that split and resize. Only
    /// the window knows it; a context built without it traps when one of those runs.
    public let tabBounds: @MainActor () -> Rect
    /// Takes what Close Pane closed, so the window can drop the pane's view, the tab or itself.
    /// A context built without it traps when Close Pane runs.
    public let didClosePane: @MainActor (CloseResult) -> Void
    /// Opens the Quick Look panel on the pane's selection, or closes it. Interface supplies it,
    /// since the panel is AppKit's; a context made without one traps when the command runs.
    public let toggleQuickLook: @MainActor () -> Void
    /// Asks the user for a folder to show in `pane`, in the pane's window. Only the view that runs
    /// commands can show one; a context built without it traps when Go to folder runs.
    public let askForFolder: @MainActor () -> Void
    /// Shows the pane's filter field and puts the keyboard focus in it. Only the pane's view can;
    /// a context built without it traps when Filter runs.
    public let showFilter: @MainActor () -> Void
    /// The folder a click named, for Open in New Tab: a Cmd-double-clicked folder row or a
    /// Cmd-clicked path bar segment. Nil when a key or menu item runs a command.
    public let folder: Location?
    /// Runs the file commands' operations and asks their questions. Nil where nothing answers
    /// the queue's questions, as in a window without its sheets; the file commands are off then.
    public let fileOperations: FileOperationQueue?
    /// Starts editing the name of the pane's one selected entry in place, for Rename. Only the
    /// pane's view can; nil where it can't, and Rename is off then.
    public let editName: (@MainActor () -> Void)?
    private let givenWorkspace: Workspace?
    private let givenWorkspaces: WorkspaceList?

    /// With a `workspace`, `pane` must be the command pane of its selected tab's focused pane.
    public init(
        pane: Pane,
        workspace: Workspace? = nil,
        workspaces: WorkspaceList? = nil,
        tabBounds: @escaping @MainActor () -> Rect = {
            preconditionFailure("this command context has no tab bounds")
        },
        didClosePane: @escaping @MainActor (CloseResult) -> Void = { _ in
            preconditionFailure("this command context can't drop a closed pane")
        },
        toggleQuickLook: @escaping @MainActor () -> Void = {
            preconditionFailure("this command context has no Quick Look panel")
        },
        askForFolder: @escaping @MainActor () -> Void = {
            preconditionFailure("this command context can't ask for a folder")
        },
        showFilter: @escaping @MainActor () -> Void = {
            preconditionFailure("this command context has no filter field")
        },
        folder: Location? = nil,
        fileOperations: FileOperationQueue? = nil,
        editName: (@MainActor () -> Void)? = nil
    ) {
        if let workspace {
            precondition(
                workspace.selectedTab.focusedPane.commandPane === pane,
                "the context's pane isn't the selected tab's focused pane")
        }
        self.pane = pane
        givenWorkspace = workspace
        givenWorkspaces = workspaces
        self.tabBounds = tabBounds
        self.didClosePane = didClosePane
        self.toggleQuickLook = toggleQuickLook
        self.askForFolder = askForFolder
        self.showFilter = showFilter
        self.folder = folder
        self.fileOperations = fileOperations
        self.editName = editName
    }

    /// The window's tabs. A context built for one pane, as the benches and pane tests build it,
    /// traps when a tiling command asks for it.
    public var workspace: Workspace {
        guard let givenWorkspace else {
            preconditionFailure("this command context has no workspace")
        }
        return givenWorkspace
    }

    /// Every open window's workspace, for the commands that open, move or merge windows. A
    /// context built without it traps when one of those asks.
    public var workspaces: WorkspaceList {
        guard let givenWorkspaces else {
            preconditionFailure("this command context has no workspace list")
        }
        return givenWorkspaces
    }

    /// The tab the tiling commands act on: the workspace's selected one.
    public var tab: Tab { workspace.selectedTab }
}
