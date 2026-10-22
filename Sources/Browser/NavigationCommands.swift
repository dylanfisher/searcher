/// Moving between folders: Open, Go to parent, Back and Forward through the pane's history, and
/// Go to folder.
public enum NavigationCommands: CommandSet {
    public static let open = Command(
        id: CommandID("navigation.open"), title: "Open",
        chords: [KeyChord(.down, modifiers: .command), KeyChord("o", modifiers: .command)])
    public static let goToParent = Command(
        id: CommandID("navigation.goToParent"), title: "Go to Parent",
        chords: [KeyChord(.up, modifiers: .command)])
    public static let back = Command(
        id: CommandID("navigation.back"), title: "Back",
        chords: [KeyChord("[", modifiers: .command)])
    public static let forward = Command(
        id: CommandID("navigation.forward"), title: "Forward",
        chords: [KeyChord("]", modifiers: .command)])
    public static let goToFolder = Command(
        id: CommandID("navigation.goToFolder"), title: "Go to Folder…",
        chords: [KeyChord("g", modifiers: [.command, .shift])])

    public static var bindings: [CommandBinding] {
        [
            CommandBinding(open) { $0.pane.openSelection() },
            CommandBinding(goToParent) { $0.pane.goToParent() },
            CommandBinding(back, isEnabled: { $0.pane.canGoBack }, run: { $0.pane.goBack() }),
            CommandBinding(
                forward, isEnabled: { $0.pane.canGoForward }, run: { $0.pane.goForward() }),
            CommandBinding(goToFolder) { $0.askForFolder() },
        ]
    }
}
