/// Plain ↑ and ↓: move the selection one row.
public enum SelectionCommands: CommandSet {
    public static let selectNext = Command(
        id: CommandID("selection.next"), title: "Select Next Row", chords: [KeyChord(.down)])
    public static let selectPrevious = Command(
        id: CommandID("selection.previous"), title: "Select Previous Row",
        chords: [KeyChord(.up)])

    public static var bindings: [CommandBinding] {
        [
            CommandBinding(selectNext) { $0.pane.moveSelection(by: 1) },
            CommandBinding(selectPrevious) { $0.pane.moveSelection(by: -1) },
        ]
    }
}
