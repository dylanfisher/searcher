/// The tab keys: open a tab, close one, and show the next or previous one, on the context's
/// workspace, and Open in New Tab for a clicked folder; and the window commands: open a window,
/// move a pane to a new one, and merge one into another. They change the model only; the windows
/// show the result (docs/decisions/0054-tabs-in-window.md,
/// docs/decisions/0057-windows-and-tear-out.md). Operations shows or hides the window's
/// operations panel through the context, and Open Quickly shows the command palette
/// (docs/decisions/0087-palette-window.md).
public enum WindowCommands: CommandSet {
    /// Adds a tab after the selected one at the focused pane's folder, in its view mode and sort,
    /// and selects it.
    public static let newTab = Command(
        id: CommandID("window.newTab"), title: "New Tab",
        chords: [KeyChord("t", modifiers: .command)])
    /// Adds a tab after the selected one at the context's `folder`, in the focused pane's view
    /// mode and sort, and selects it. Cmd-double-click on a folder row and Cmd-click on a path bar
    /// segment run it; it has no chord, and is off without a folder.
    public static let openInNewTab = Command(
        id: CommandID("window.openInNewTab"), title: "Open in New Tab", chords: [])
    /// Closes the selected tab, and the window with its last tab. The context's `didClosePane`
    /// gets what closed, as it does for Close Pane.
    public static let closeTab = Command(
        id: CommandID("window.closeTab"), title: "Close Tab",
        chords: [KeyChord("w", modifiers: [.command, .shift])])
    /// The tab right of the selected one, or the first after the last. The menu shows the first
    /// chord.
    public static let nextTab = Command(
        id: CommandID("window.nextTab"), title: "Show Next Tab",
        chords: [
            KeyChord("]", modifiers: [.command, .shift]), KeyChord(.tab, modifiers: .control),
        ])
    public static let previousTab = Command(
        id: CommandID("window.previousTab"), title: "Show Previous Tab",
        chords: [
            KeyChord("[", modifiers: [.command, .shift]),
            KeyChord(.tab, modifiers: [.control, .shift]),
        ])

    /// Opens a window with one tab at the focused pane's folder, in its view mode and sort.
    public static let newWindow = Command(
        id: CommandID("window.newWindow"), title: "New Window",
        chords: [KeyChord("n", modifiers: .command)])
    /// Moves the focused pane, with its rows, selection and watch, to a new window of one tab.
    /// Its tab closes with its last pane. Off with one pane in the window.
    public static let movePaneToNewWindow = Command(
        id: CommandID("window.movePaneToNewWindow"), title: "Move Pane to New Window", chords: [])
    /// Moves every tab of the window, in order, to the end of the most recently active other
    /// window's strip and closes this one. Off with one window.
    public static let mergeWindowIntoTab = Command(
        id: CommandID("window.mergeWindowIntoTab"), title: "Merge Window into Tab", chords: [])
    /// Shows the window's operations panel, which lists the running and queued file operations,
    /// or hides it.
    public static let toggleOperations = Command(
        id: CommandID("window.toggleOperations"), title: "Operations",
        chords: [KeyChord("l", modifiers: [.command, .option])])

    /// Shows the command palette over the window: commands, saved workspaces, visited folders,
    /// the folders open panes show and a typed path, to jump to or run.
    public static let showPalette = Command(
        id: CommandID("window.showPalette"), title: "Open Quickly…",
        chords: [KeyChord("k", modifiers: .command)])

    public static var bindings: [CommandBinding] {
        [
            CommandBinding(showPalette) { $0.showPalette() },
            CommandBinding(toggleOperations) { $0.toggleOperations() },
            CommandBinding(newWindow) { context in
                let focused = context.tab.focusedPane
                context.workspaces.add(
                    Workspace(
                        tab: Tab(pane: focused.newPane(at: focused.location)),
                        showsSidebar: context.workspace.showsSidebar))
            },
            CommandBinding(
                movePaneToNewWindow, isEnabled: { $0.workspace.paneCount > 1 },
                run: { context in
                    let showsSidebar = context.workspace.showsSidebar
                    context.workspaces.add(
                        Workspace(
                            tab: context.workspace.removeFocusedPane(),
                            showsSidebar: showsSidebar))
                }),
            CommandBinding(
                mergeWindowIntoTab, isEnabled: { $0.workspaces.workspaces.count > 1 },
                run: { context in context.workspaces.merge(context.workspace) }),
            CommandBinding(newTab) { context in
                let focused = context.tab.focusedPane
                context.workspace.add(Tab(pane: focused.newPane(at: focused.location)))
            },
            CommandBinding(
                openInNewTab, isEnabled: { $0.folder != nil },
                run: { context in
                    guard let folder = context.folder else {
                        preconditionFailure("Open in New Tab ran with no folder")
                    }
                    context.workspace.add(Tab(pane: context.tab.focusedPane.newPane(at: folder)))
                }),
            CommandBinding(closeTab) { context in
                context.didClosePane(context.workspace.close(context.tab.id))
            },
            CommandBinding(nextTab, isEnabled: hasOtherTabs) { select(1, in: $0) },
            CommandBinding(previousTab, isEnabled: hasOtherTabs) { select(-1, in: $0) },
        ]
    }

    @MainActor
    private static func hasOtherTabs(_ context: CommandContext) -> Bool {
        context.workspace.tabs.count > 1
    }

    /// Selects the tab `offset` places from the selected one, wrapping at either end.
    @MainActor
    private static func select(_ offset: Int, in context: CommandContext) {
        let tabs = context.workspace.tabs
        guard let index = tabs.firstIndex(where: { $0 === context.tab }) else {
            preconditionFailure("the selected tab is not in the workspace")
        }
        let count = tabs.count
        context.workspace.select(tabs[((index + offset) % count + count) % count].id)
    }
}
