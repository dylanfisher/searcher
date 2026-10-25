/// Row movement and selection: the arrows, Opt- and Ctrl-Shift-arrows (ten rows), Fn-arrows (a
/// page), Home and End, and Cmd-Opt-↑ and Cmd-Opt-↓, move the cursor and select its row alone, Shift-arrows extend the
/// selection from the anchor, and Cmd-A selects every row. Type-to-select, which no chord runs,
/// selects by name. Cmd-U and Shift-Cmd-U step back and forward through the pane's selections in
/// the folder.
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
        chords: [KeyChord(.home), KeyChord(.up, modifiers: [.command, .option])])
    public static let selectLast = Command(
        id: CommandID("selection.last"), title: "Select Last Row",
        chords: [KeyChord(.end), KeyChord(.down, modifiers: [.command, .option])])
    public static let tenRowsDown = Command(
        id: CommandID("selection.tenRowsDown"), title: "Move Down 10 Rows",
        chords: [
            KeyChord(.down, modifiers: .option), KeyChord(.down, modifiers: [.control, .shift]),
        ])
    public static let tenRowsUp = Command(
        id: CommandID("selection.tenRowsUp"), title: "Move Up 10 Rows",
        chords: [
            KeyChord(.up, modifiers: .option), KeyChord(.up, modifiers: [.control, .shift]),
        ])
    public static let pageDown = Command(
        id: CommandID("selection.pageDown"), title: "Page Down", chords: [KeyChord(.pageDown)])
    public static let pageUp = Command(
        id: CommandID("selection.pageUp"), title: "Page Up", chords: [KeyChord(.pageUp)])
    public static let selectAll = Command(
        id: CommandID("selection.all"), title: "Select All",
        chords: [KeyChord("a", modifiers: .command)])

    /// Sublime Text's soft undo: the selection before the last change in the folder, not a file
    /// change (docs/decisions/0077-selection-history.md).
    public static let undoSelection = Command(
        id: CommandID("selection.undo"), title: "Undo Selection",
        chords: [KeyChord("u", modifiers: .command)])
    public static let redoSelection = Command(
        id: CommandID("selection.redo"), title: "Redo Selection",
        chords: [KeyChord("u", modifiers: [.command, .shift])])

    public static var bindings: [CommandBinding] {
        [
            CommandBinding(
                undoSelection, isEnabled: { $0.pane.canUndoSelection },
                run: { $0.pane.undoSelection() }),
            CommandBinding(
                redoSelection, isEnabled: { $0.pane.canRedoSelection },
                run: { $0.pane.redoSelection() }),
            CommandBinding(selectNext) {
                $0.pane.moveSelection(by: 1, isKeyRepeat: $0.isKeyRepeat)
            },
            CommandBinding(selectPrevious) {
                $0.pane.moveSelection(by: -1, isKeyRepeat: $0.isKeyRepeat)
            },
            CommandBinding(extendDown) {
                $0.pane.moveSelection(by: 1, extending: true, isKeyRepeat: $0.isKeyRepeat)
            },
            CommandBinding(extendUp) {
                $0.pane.moveSelection(by: -1, extending: true, isKeyRepeat: $0.isKeyRepeat)
            },
            CommandBinding(selectFirst) { $0.pane.selectFirstRow(byKey: true) },
            CommandBinding(selectLast) { $0.pane.selectLastRow(byKey: true) },
            CommandBinding(tenRowsDown) {
                $0.pane.moveSelection(by: 10, isKeyRepeat: $0.isKeyRepeat)
            },
            CommandBinding(tenRowsUp) {
                $0.pane.moveSelection(by: -10, isKeyRepeat: $0.isKeyRepeat)
            },
            CommandBinding(pageDown) {
                $0.pane.moveSelection(byPages: 1, isKeyRepeat: $0.isKeyRepeat)
            },
            CommandBinding(pageUp) {
                $0.pane.moveSelection(byPages: -1, isKeyRepeat: $0.isKeyRepeat)
            },
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
        context.pane.select(Selection([name], cursor: name), as: .typing)
        return true
    }
}
