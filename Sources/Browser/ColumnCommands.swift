/// Moving between columns in column view: → into the column of the selected folder, ← to the
/// column on the left, adding the parent folder's column past the first. Both do nothing in list
/// view.
public enum ColumnCommands: CommandSet {
    public static let intoFolder = Command(
        id: CommandID("column.intoFolder"), title: "Into Selected Folder",
        chords: [KeyChord(.right)])
    public static let toParent = Command(
        id: CommandID("column.toParent"), title: "To Parent Column", chords: [KeyChord(.left)])

    public static var bindings: [CommandBinding] {
        [
            CommandBinding(intoFolder) {
                $0.pane.containingTrail?.moveRight(isKeyRepeat: $0.isKeyRepeat)
            },
            CommandBinding(toParent) {
                $0.pane.containingTrail?.moveLeft(isKeyRepeat: $0.isKeyRepeat)
            },
        ]
    }
}
