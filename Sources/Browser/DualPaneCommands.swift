/// The dual-pane keys: focus the other pane, show the focused pane's folder there, and open the
/// selection there. The other pane is the selected tab's `Layout.otherPane`. With one pane, the
/// two that act on the other pane split right first and keep the focus where it was; focusing
/// the other pane is off (docs/decisions/0047-other-pane.md).
public enum DualPaneCommands: CommandSet {
    public static let focusOtherPane = Command(
        id: CommandID("dualPane.focusOtherPane"), title: "Focus Other Pane",
        chords: [KeyChord(.tab)])
    /// Shows the focused pane's folder in the other pane, as a step in that pane's history.
    public static let sameFolderInOtherPane = Command(
        id: CommandID("dualPane.sameFolderInOtherPane"), title: "Same Folder in Other Pane",
        chords: [KeyChord("=", modifiers: [.command, .option])])
    /// Opens the one selected folder, or package, in the other pane. Off for any other
    /// selection, as Open in New Tab is for a file, so a file never goes to its app from here.
    public static let openInOtherPane = Command(
        id: CommandID("dualPane.openInOtherPane"), title: "Open in Other Pane",
        chords: [KeyChord("o", modifiers: [.command, .option])])

    public static var bindings: [CommandBinding] {
        [
            // Off with one pane, so the table hands Tab on to move the key view.
            CommandBinding(
                focusOtherPane, isEnabled: { $0.tab.layout.otherPane != nil },
                run: { context in
                    if let other = context.tab.layout.otherPane {
                        context.tab.focus(other)
                    }
                }),
            CommandBinding(sameFolderInOtherPane) { context in
                otherPane(in: context)?.navigate(to: context.pane.location)
            },
            // The key runs the binding without asking `isEnabled`, so `run` checks too.
            CommandBinding(
                openInOtherPane, isEnabled: { selectsOneFolder($0.pane) },
                run: { context in
                    guard selectsOneFolder(context.pane), let other = otherPane(in: context)
                    else { return }
                    context.pane.openSelection(in: other)
                }),
        ]
    }

    /// Whether `pane`'s selection is one folder, which a package is as the pane lists it.
    @MainActor
    private static func selectsOneFolder(_ pane: Pane) -> Bool {
        let rows = pane.selectedRows
        guard rows.count == 1, let row = rows.first, let listing = pane.state.listing else {
            return false
        }
        return listing[row].type == .directory
    }

    /// The other pane, after ending a zoom so it shows. With one pane, splits right and focuses
    /// the pane that had the focus again; `nil` when that split is refused for size.
    @MainActor
    private static func otherPane(in context: CommandContext) -> Pane? {
        let tab = context.tab
        if tab.layout.isZoomed {
            tab.toggleZoom()
        }
        if tab.layout.otherPane == nil {
            let focused = tab.layout.focused
            guard tab.split(.horizontal, in: context.tabBounds()) != nil else { return nil }
            tab.focus(focused)
        }
        guard let id = tab.layout.otherPane, let pane = tab.panes[id] else {
            preconditionFailure("the tab has no other pane after a split")
        }
        return pane
    }
}
