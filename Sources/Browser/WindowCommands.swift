/// The tab keys: open a tab, close one, and show the next or previous one, on the context's
/// workspace. They change the model only; the window shows the result
/// (docs/decisions/0054-tabs-in-window.md).
public enum WindowCommands: CommandSet {
    /// Adds a tab after the selected one at the focused pane's folder, in its view mode and sort,
    /// and selects it.
    public static let newTab = Command(
        id: CommandID("window.newTab"), title: "New Tab",
        chords: [KeyChord("t", modifiers: .command)])
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

    public static var bindings: [CommandBinding] {
        [
            CommandBinding(newTab) { context in
                context.workspace.add(Tab(pane: paneLike(context.tab.focusedPane)))
            },
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

    /// A pane at `model`'s folder, in its view mode and sort, using the same services, settings
    /// and system actions, as `Tab.split` makes one.
    @MainActor
    private static func paneLike(_ model: Pane) -> Pane {
        let sorted = model.commandPane
        let pane = Pane(
            location: model.location, service: model.service, systemActions: model.systemActions,
            settings: model.settings, sortedBy: sorted.sortColumn, ascending: sorted.sortAscending,
            viewMode: model.viewMode)
        pane.folderSizes = model.folderSizes
        return pane
    }
}
