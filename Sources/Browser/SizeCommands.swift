/// Folder sizes: Recalculate Sizes drops the kept sizes of the pane's folder and every folder
/// under it, so the list walks its subfolders again (docs/decisions/0043-folder-sizes.md). It has
/// no chord; the View menu runs it. It is off where the pane shows no folder sizes, such as in
/// column view.
public enum SizeCommands: CommandSet {
    public static let recalculateSizes = Command(
        id: CommandID("size.recalculate"), title: "Recalculate Sizes", chords: [])

    public static var bindings: [CommandBinding] {
        [
            CommandBinding(
                recalculateSizes, isEnabled: { $0.pane.showsFolderSizes },
                run: { $0.pane.recalculateSizes() })
        ]
    }
}
