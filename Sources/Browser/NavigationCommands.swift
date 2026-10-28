/// Moving between folders: Open, Go to parent, Back and Forward through the pane's history and
/// then the window's, and Go to folder.
public enum NavigationCommands: CommandSet {
    public static let open = Command(
        id: CommandID("navigation.open"), title: "Open",
        chords: [KeyChord(.down, modifiers: .command), KeyChord("o", modifiers: .command)])
    /// Browses into the one selected package as a folder, which Open never does: Open hands a
    /// package to its app, as Finder does.
    public static let showPackageContents = Command(
        id: CommandID("navigation.showPackageContents"), title: "Show Package Contents",
        chords: [])
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
            // A share that isn't mounted opens by mounting it, selected alone; a selection with
            // one among others has nothing to open (docs/decisions/0115-server-shares.md). A key
            // runs the binding whether or not it is enabled, so `run` checks too.
            CommandBinding(
                open, isEnabled: { canOpen($0.pane) },
                run: { context in
                    guard canOpen(context.pane) else { return }
                    context.pane.openSelection()
                }),
            CommandBinding(
                showPackageContents, isEnabled: { $0.pane.selectedPackage != nil },
                run: { $0.pane.showPackageContents() }),
            CommandBinding(goToParent) { $0.pane.goToParent() },
            // The pane's own steps first, then the window's
            // (docs/decisions/0125-workspace-open-is-a-back-step.md).
            CommandBinding(
                back,
                isEnabled: { $0.pane.canGoBack || $0.windowWorkspace?.canStepBack == true },
                run: { context in
                    if context.pane.canGoBack { return context.pane.goBack() }
                    context.windowWorkspace?.stepBack()
                }),
            CommandBinding(
                forward,
                isEnabled: { $0.pane.canGoForward || $0.windowWorkspace?.canStepForward == true },
                run: { context in
                    if context.pane.canGoForward { return context.pane.goForward() }
                    context.windowWorkspace?.stepForward()
                }),
            CommandBinding(goToFolder) { $0.askForFolder() },
        ]
    }

    /// Whether Open acts on `pane`'s selection: each selected row has a location, or the one
    /// selected is a share that can be mounted.
    @MainActor private static func canOpen(_ pane: Pane) -> Bool {
        !pane.selectsUnmountedShare || pane.selectedUnmountedShare != nil
    }
}
