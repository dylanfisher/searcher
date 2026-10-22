/// The dual-pane keys: focus the other pane, show the focused pane's folder there, and open the
/// selection there. The other pane is the selected tab's `Layout.otherPane`. With one pane, the
/// two that act on the other pane split right first and keep the focus where it was; focusing
/// the other pane does nothing.
///
/// Not in `AppCommands.sets` yet: the panes' views build their contexts without a workspace
/// (docs/decisions/0047-other-pane.md).
public enum DualPaneCommands: CommandSet {
    public static let focusOtherPane = Command(
        id: CommandID("dualPane.focusOtherPane"), title: "Focus Other Pane",
        chords: [KeyChord(.tab)])
    /// Shows the focused pane's folder in the other pane, as a step in that pane's history.
    public static let sameFolderInOtherPane = Command(
        id: CommandID("dualPane.sameFolderInOtherPane"), title: "Same Folder in Other Pane",
        chords: [KeyChord("=", modifiers: [.command, .option])])
    /// Opens a selected folder in the other pane; any other selection opens as Open does.
    public static let openInOtherPane = Command(
        id: CommandID("dualPane.openInOtherPane"), title: "Open in Other Pane",
        chords: [KeyChord("o", modifiers: [.command, .option])])

    public static var bindings: [CommandBinding] {
        [
            CommandBinding(focusOtherPane) { context in
                if let other = context.tab.layout.otherPane {
                    context.tab.focus(other)
                }
            },
            CommandBinding(sameFolderInOtherPane) { context in
                otherPane(in: context)?.navigate(to: context.pane.location)
            },
            CommandBinding(openInOtherPane) { context in
                if let other = otherPane(in: context) {
                    context.pane.openSelection(in: other)
                }
            },
        ]
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
