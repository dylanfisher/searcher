/// What the panes show and in what order: the hidden files and folders first toggles, which are
/// app-wide `Settings`, and the sort keys, which sort the focused pane by a column. A sort key for
/// the column already sorted by reverses it.
public enum ViewCommands: CommandSet {
    public static let toggleHidden = Command(
        id: CommandID("view.toggleHidden"), title: "Show Hidden Files",
        chords: [KeyChord(".", modifiers: [.command, .shift])])
    public static let toggleFoldersFirst = Command(
        id: CommandID("view.toggleFoldersFirst"), title: "Folders First", chords: [])
    public static let sortByName = Command(
        id: CommandID("view.sortByName"), title: "Sort by Name",
        chords: [KeyChord("1", modifiers: [.control, .option, .command])])
    public static let sortByKind = Command(
        id: CommandID("view.sortByKind"), title: "Sort by Kind",
        chords: [KeyChord("2", modifiers: [.control, .option, .command])])
    public static let sortByDateModified = Command(
        id: CommandID("view.sortByDateModified"), title: "Sort by Date Modified",
        chords: [KeyChord("5", modifiers: [.control, .option, .command])])
    public static let sortBySize = Command(
        id: CommandID("view.sortBySize"), title: "Sort by Size",
        chords: [KeyChord("6", modifiers: [.control, .option, .command])])

    public static var bindings: [CommandBinding] {
        [
            CommandBinding(
                toggleHidden, isChecked: { $0.showHidden },
                run: { $0.pane.settings.showHidden.toggle() }),
            CommandBinding(
                toggleFoldersFirst, isChecked: { $0.foldersFirst },
                run: { $0.pane.settings.foldersFirst.toggle() }),
            CommandBinding(sortByName) { sort($0.pane, by: .name) },
            CommandBinding(sortByKind) { sort($0.pane, by: .kind) },
            CommandBinding(sortByDateModified) { sort($0.pane, by: .dateModified) },
            CommandBinding(sortBySize) { sort($0.pane, by: .size) },
        ]
    }

    /// Sorts by `column` in its first direction, or reverses it if the pane already sorts by it.
    @MainActor
    private static func sort(_ pane: Pane, by column: SortColumn) {
        let ascending = pane.sortColumn == column ? !pane.sortAscending : column.firstAscending
        pane.setSort(column, ascending: ascending)
    }
}
