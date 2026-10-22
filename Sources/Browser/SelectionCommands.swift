/// Row movement and selection: the arrows, Opt-, Ctrl-Shift- and Fn-arrows move the cursor and
/// select its row alone, Shift-arrows extend the selection from the anchor, and Cmd-A selects
/// every row. Type-to-select, which no chord runs, selects by name.
public enum SelectionCommands: CommandSet {
    public static let selectNext = Command(
        id: CommandID("selection.next"), title: "Select Next Row", chords: [KeyChord(.down)])
    public static let selectPrevious = Command(
        id: CommandID("selection.previous"), title: "Select Previous Row",
        chords: [KeyChord(.up)])
    public static let extendDown = Command(
        id: CommandID("selection.extendDown"), title: "Extend Selection Down",
        chords: [KeyChord(.down, modifiers: .shift)])
    public static let extendUp = Command(
        id: CommandID("selection.extendUp"), title: "Extend Selection Up",
        chords: [KeyChord(.up, modifiers: .shift)])
    public static let selectFirst = Command(
        id: CommandID("selection.first"), title: "Select First Row",
        chords: [KeyChord(.up, modifiers: .option)])
    public static let selectLast = Command(
        id: CommandID("selection.last"), title: "Select Last Row",
        chords: [KeyChord(.down, modifiers: .option)])
    public static let tenRowsDown = Command(
        id: CommandID("selection.tenRowsDown"), title: "Move Down 10 Rows",
        chords: [KeyChord(.down, modifiers: [.control, .shift])])
    public static let tenRowsUp = Command(
        id: CommandID("selection.tenRowsUp"), title: "Move Up 10 Rows",
        chords: [KeyChord(.up, modifiers: [.control, .shift])])
    public static let pageDown = Command(
        id: CommandID("selection.pageDown"), title: "Page Down", chords: [KeyChord(.pageDown)])
    public static let pageUp = Command(
        id: CommandID("selection.pageUp"), title: "Page Up", chords: [KeyChord(.pageUp)])
    public static let selectAll = Command(
        id: CommandID("selection.all"), title: "Select All",
        chords: [KeyChord("a", modifiers: .command)])

    public static var bindings: [CommandBinding] {
        [
            CommandBinding(selectNext) { $0.pane.moveSelection(by: 1) },
            CommandBinding(selectPrevious) { $0.pane.moveSelection(by: -1) },
            CommandBinding(extendDown) { $0.pane.moveSelection(by: 1, extending: true) },
            CommandBinding(extendUp) { $0.pane.moveSelection(by: -1, extending: true) },
            CommandBinding(selectFirst) { $0.pane.selectFirstRow() },
            CommandBinding(selectLast) { $0.pane.selectLastRow() },
            CommandBinding(tenRowsDown) { $0.pane.moveSelection(by: 10) },
            CommandBinding(tenRowsUp) { $0.pane.moveSelection(by: -10) },
            CommandBinding(pageDown) { $0.pane.moveSelection(byPages: 1) },
            CommandBinding(pageUp) { $0.pane.moveSelection(byPages: -1) },
            CommandBinding(selectAll) { $0.pane.selectAll() },
        ]
    }

    /// Type-to-select: selects the first row in display order whose name starts with `query`,
    /// alone, with the cursor on it. Returns false and leaves the selection as it is when no
    /// row matches.
    @MainActor
    public static func selectFirstRow(startingWith query: String, in context: CommandContext)
        -> Bool
    {
        guard let listing = context.pane.state.listing,
            let row = TypeSelect.firstRow(startingWith: query, in: listing)
        else { return false }
        let name = ExactName(listing[row].name)
        context.pane.select(Selection([name], cursor: name))
        return true
    }
}
