import Base

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
    /// Opens the one selected folder, package or link in the other pane. A link opens there
    /// only once it lists as a folder; a link to a file opens nothing. Off for any other
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
                openInOtherPane, isEnabled: { selectedFolderOrLink(in: $0.pane) != nil },
                run: { context in
                    switch selectedFolderOrLink(in: context.pane) {
                    case .directory:
                        if let other = otherPane(in: context) {
                            context.pane.openSelection(in: other)
                        }
                    case .symbolicLink:
                        // The split waits for the link to list as a folder, so a link to a file
                        // leaves the tab as it was. A tab switched away from meanwhile is left.
                        let tab = context.tab
                        context.pane.openSelectedLink(asFolderIn: {
                            context.tab === tab ? otherPane(in: context) : nil
                        })
                    default:
                        return
                    }
                }),
        ]
    }

    /// The type of `pane`'s one selected entry when it is a folder, which a package is as the
    /// pane lists it, or a link; nil for any other selection.
    @MainActor
    private static func selectedFolderOrLink(in pane: Pane) -> DirectoryEntry.FileType? {
        let rows = pane.selectedRows
        guard rows.count == 1, let row = rows.first, let listing = pane.state.listing else {
            return nil
        }
        let type = listing[row].type
        return type == .directory || type == .symbolicLink ? type : nil
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
