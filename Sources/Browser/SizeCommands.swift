/// Folder sizes (docs/decisions/0043-folder-sizes.md). Calculate All Sizes, Finder's name for it,
/// turns `Settings.folderSizes` on and off: on, every list pane walks its subfolders. Calculate
/// Sizes walks the subfolders of the pane's folder now: with the setting off it walks them once
/// and the folder shows their sizes from then on, and with it on it drops the kept sizes of the
/// folder and every folder under it and walks again. It is off where the pane shows no folder
/// sizes, such as in column view.
public enum SizeCommands: CommandSet {
    public static let calculateAllSizes = Command(
        id: CommandID("size.calculateAll"), title: "Calculate All Sizes", chords: [])
    public static let calculateSizes = Command(
        id: CommandID("size.calculate"), title: "Calculate Sizes",
        chords: [KeyChord("s", modifiers: [.option, .command])])

    public static var bindings: [CommandBinding] {
        [
            CommandBinding(
                calculateAllSizes, isChecked: { $0.folderSizes },
                run: { $0.pane.settings.folderSizes.toggle() }),
            CommandBinding(
                calculateSizes, isEnabled: { $0.pane.canCalculateSizes },
                run: { $0.pane.calculateSizes() }),
        ]
    }
}
