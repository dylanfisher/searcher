/// What the panes show and in what order: the hidden files, `.DS_Store`, columns from home and
/// folders first toggles, which are app-wide `Settings`, as are the toggles of the sidebar's
/// groups, the toolbar and the status bar, and the sort keys, which sort the focused pane by a
/// column. A sort key for the column already sorted by reverses it; Sort by Next Column moves
/// to the next column in the header's order, and Reverse Sort Direction reverses the column
/// sorted by. A column of column view shows names only, so it sorts by Name only: the other
/// sort keys and Sort by Next Column are off there. The item of the column sorted by is
/// checked. Space opens and closes Quick Look on the selection, Cmd-F opens the pane's filter
/// field, and Cmd-1 and Cmd-3 show the pane as a list or as columns. The appearance commands
/// make the app light, dark or follow the system.
public enum ViewCommands: CommandSet {
    public static let toggleHidden = Command(
        id: CommandID("view.toggleHidden"), title: "Show Hidden Files",
        chords: [KeyChord(".", modifiers: [.command, .shift])])
    public static let toggleHideDSStore = Command(
        id: CommandID("view.toggleHideDSStore"), title: "Always Hide .DS_Store", chords: [])
    public static let toggleColumnsStartAtHome = Command(
        id: CommandID("view.toggleColumnsStartAtHome"), title: "Columns Start at Home Folder",
        chords: [])
    public static let toggleSidebarFavorites = Command(
        id: CommandID("view.toggleSidebarFavorites"), title: "Show Favorites in Sidebar",
        chords: [])
    public static let toggleSidebarLocations = Command(
        id: CommandID("view.toggleSidebarLocations"), title: "Show Locations in Sidebar",
        chords: [])
    public static let toggleSidebarWorkspaces = Command(
        id: CommandID("view.toggleSidebarWorkspaces"), title: "Show Workspaces in Sidebar",
        chords: [])
    /// Shows or hides every window's toolbar, an app-wide setting; its menu item says which it
    /// would do, as Finder's does (docs/decisions/0128-finder-window-chrome.md).
    public static let toggleToolbar = Command(
        id: CommandID("view.toggleToolbar"), title: "Show Toolbar", chords: [])
    /// Shows or hides every window's status bar, an app-wide setting, on Finder's Cmd-/; its
    /// menu item says which it would do, as Finder's does (docs/decisions/0131-status-bar.md).
    public static let toggleStatusBar = Command(
        id: CommandID("view.toggleStatusBar"), title: "Show Status Bar",
        chords: [KeyChord("/", modifiers: .command)])
    public static let toggleFoldersFirst = Command(
        id: CommandID("view.toggleFoldersFirst"), title: "Folders First", chords: [])
    public static let sortByName = Command(
        id: CommandID("view.sortByName"), title: "Sort by Name",
        chords: [KeyChord("1", modifiers: [.control, .option])])
    public static let sortBySize = Command(
        id: CommandID("view.sortBySize"), title: "Sort by Size",
        chords: [KeyChord("2", modifiers: [.control, .option])])
    public static let sortByDateModified = Command(
        id: CommandID("view.sortByDateModified"), title: "Sort by Date Modified",
        chords: [KeyChord("3", modifiers: [.control, .option])])
    public static let sortByKind = Command(
        id: CommandID("view.sortByKind"), title: "Sort by Kind",
        chords: [KeyChord("4", modifiers: [.control, .option])])
    public static let sortByNextColumn = Command(
        id: CommandID("view.sortByNextColumn"), title: "Sort by Next Column",
        chords: [KeyChord("p", modifiers: [.option, .command])])
    public static let reverseSortDirection = Command(
        id: CommandID("view.reverseSortDirection"), title: "Reverse Sort Direction",
        chords: [KeyChord("p", modifiers: [.option, .command, .shift])])
    public static let toggleQuickLook = Command(
        id: CommandID("view.toggleQuickLook"), title: "Quick Look", chords: [KeyChord(.space)])
    public static let filter = Command(
        id: CommandID("view.filter"), title: "Filter",
        chords: [KeyChord("f", modifiers: .command)])
    public static let asList = Command(
        id: CommandID("view.asList"), title: "as List",
        chords: [KeyChord("1", modifiers: .command)])
    public static let asColumns = Command(
        id: CommandID("view.asColumns"), title: "as Columns",
        chords: [KeyChord("3", modifiers: .command)])

    public static let autoAppearance = Command(
        id: CommandID("view.autoAppearance"), title: "Auto Appearance", chords: [])
    public static let lightAppearance = Command(
        id: CommandID("view.lightAppearance"), title: "Light Appearance", chords: [])
    public static let darkAppearance = Command(
        id: CommandID("view.darkAppearance"), title: "Dark Appearance", chords: [])
    /// The title of the submenu that holds the appearance commands.
    public static let appearanceTitle = "Appearance"

    public static var bindings: [CommandBinding] {
        [
            CommandBinding(
                toggleHidden, isChecked: { $0.showHidden },
                run: { $0.pane.settings.showHidden.toggle() }),
            CommandBinding(
                toggleHideDSStore, isChecked: { $0.hideDSStore },
                run: { $0.pane.settings.hideDSStore.toggle() }),
            CommandBinding(
                toggleColumnsStartAtHome, isChecked: { $0.columnsStartAtHome },
                run: { $0.pane.settings.columnsStartAtHome.toggle() }),
            CommandBinding(
                toggleSidebarFavorites, isChecked: { $0.showsFavoritesInSidebar },
                run: { $0.pane.settings.showsFavoritesInSidebar.toggle() }),
            CommandBinding(
                toggleSidebarLocations, isChecked: { $0.showsLocationsInSidebar },
                run: { $0.pane.settings.showsLocationsInSidebar.toggle() }),
            CommandBinding(
                toggleSidebarWorkspaces, isChecked: { $0.showsWorkspacesInSidebar },
                run: { $0.pane.settings.showsWorkspacesInSidebar.toggle() }),
            CommandBinding(
                toggleToolbar,
                title: { $0.pane.settings.showsToolbar ? "Hide Toolbar" : toggleToolbar.title },
                run: { $0.pane.settings.showsToolbar.toggle() }),
            CommandBinding(
                toggleStatusBar,
                title: {
                    $0.pane.settings.showsStatusBar ? "Hide Status Bar" : toggleStatusBar.title
                },
                run: { $0.pane.settings.showsStatusBar.toggle() }),
            CommandBinding(
                toggleFoldersFirst, isChecked: { $0.foldersFirst },
                run: { $0.pane.settings.foldersFirst.toggle() }),
            sort(sortByName, by: .name),
            sort(sortBySize, by: .size),
            sort(sortByDateModified, by: .dateModified),
            sort(sortByKind, by: .kind),
            CommandBinding(
                sortByNextColumn, isEnabled: { sortsByEveryColumn($0.pane) },
                run: {
                    guard sortsByEveryColumn($0.pane) else { return }
                    let next = $0.pane.sortColumn.next
                    $0.pane.setSort(next, ascending: next.firstAscending)
                }),
            CommandBinding(reverseSortDirection) {
                $0.pane.setSort($0.pane.sortColumn, ascending: !$0.pane.sortAscending)
            },
            CommandBinding(toggleQuickLook) { $0.toggleQuickLook() },
            CommandBinding(filter) { $0.showFilter() },
            CommandBinding(
                asList, isCurrent: { tile(of: $0.pane).viewMode == .list },
                run: { tile(of: $0.pane).setViewMode(.list) }),
            CommandBinding(
                asColumns, isCurrent: { tile(of: $0.pane).viewMode == .column },
                run: { tile(of: $0.pane).setViewMode(.column) }),
            appearance(autoAppearance, .auto),
            appearance(lightAppearance, .light),
            appearance(darkAppearance, .dark),
        ]
    }

    /// The binding of `command`, which sets the app's appearance to `appearance` and shows a check
    /// mark while it is the one set.
    private static func appearance(_ command: Command, _ appearance: Settings.Appearance)
        -> CommandBinding
    {
        CommandBinding(
            command, isChecked: { $0.appearance == appearance },
            run: { $0.pane.settings.appearance = appearance })
    }

    /// The pane that has the view mode: the trail's owner when `pane` is a column's.
    @MainActor
    private static func tile(of pane: Pane) -> Pane {
        pane.containingTrail?.owner ?? pane
    }

    /// The binding of `command`, which sorts by `column` in its first direction, or reverses it
    /// if the pane already sorts by it, and is checked while the pane sorts by it. A column of
    /// column view sorts by Name only.
    private static func sort(_ command: Command, by column: SortColumn) -> CommandBinding {
        CommandBinding(
            command, isCurrent: { $0.pane.sortColumn == column },
            isEnabled: { column == .name || sortsByEveryColumn($0.pane) },
            run: {
                let pane = $0.pane
                guard column == .name || sortsByEveryColumn(pane) else { return }
                let ascending =
                    pane.sortColumn == column ? !pane.sortAscending : column.firstAscending
                pane.setSort(column, ascending: ascending)
            })
    }

    /// Whether `pane` shows every column it can sort by: a list does, and a column of column
    /// view shows names only.
    @MainActor
    private static func sortsByEveryColumn(_ pane: Pane) -> Bool {
        pane.containingTrail == nil
    }
}
