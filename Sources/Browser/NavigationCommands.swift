/// Moving between folders: Open and Go to parent.
public enum NavigationCommands: CommandSet {
    public static let open = Command(
        id: CommandID("navigation.open"), title: "Open",
        chords: [KeyChord(.down, modifiers: .command), KeyChord("o", modifiers: .command)])
    public static let goToParent = Command(
        id: CommandID("navigation.goToParent"), title: "Go to Parent",
        chords: [KeyChord(.up, modifiers: .command)])

    public static var bindings: [CommandBinding] {
        [
            CommandBinding(open) { $0.pane.openSelection() },
            CommandBinding(goToParent) { $0.pane.goToParent() },
        ]
    }
}
