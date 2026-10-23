import AppKit
import Browser

/// Builds the context menus of the list and of each column, the only place context menus are
/// built. Each item runs a registered command on the table that was clicked, with the command's
/// title and first chord from the registry, except Open With, whose apps `OpenWithMenu` lists.
/// As in the main menu, a chord without Command, Control or Option shows no key equivalent.
/// AppKit adds the services that take the selection when it shows the menu, through
/// `ListingViewController`'s `NSServicesMenuRequestor`
/// (docs/decisions/0070-context-menus-and-services.md).
@MainActor
enum ContextMenuBuilder {
    enum Item {
        case command(CommandID)
        /// The Open With submenu for the clicked table's selection.
        case openWith
        case separator
    }

    /// Why a context menu couldn't be built from the registry.
    enum BuildError: Error, CustomStringConvertible {
        case unregistered(CommandID)

        var description: String {
            switch self {
            case .unregistered(let id): "a context menu lists \(id), which isn't registered"
            }
        }
    }

    /// For a right-click on a row, which is selected first if it wasn't: what acts on the
    /// selection.
    static let rowItems: [Item] = [
        .command(NavigationCommands.open.id), .openWith,
        .command(WindowCommands.openInNewTab.id), .command(DualPaneCommands.openInOtherPane.id),
        .separator,
        .command(ViewCommands.toggleQuickLook.id),
        .separator,
        .command(FileCommands.rename.id), .command(FileCommands.duplicate.id),
        .command(FileCommands.copyToOtherPane.id), .command(FileCommands.moveToOtherPane.id),
        .separator,
        .command(ClipboardCommands.cut.id), .command(ClipboardCommands.copy.id),
        .command(SystemCommands.copyPath.id),
        .separator,
        .command(SystemCommands.revealInFinder.id),
        .separator,
        .command(FileCommands.moveToTrash.id),
    ]

    /// For a right-click below the rows: what acts on the folder shown.
    static let folderItems: [Item] = [
        .command(FileCommands.newFolder.id),
        .separator,
        .command(ClipboardCommands.paste.id), .command(ClipboardCommands.moveHere.id),
        .separator,
        .command(SystemCommands.openTerminal.id),
    ]

    /// A menu of `items` whose commands run on `target`, which also turns each item off while its
    /// command would do nothing.
    static func build(_ items: [Item], registry: CommandRegistry, target: ListingTableView)
        throws(BuildError) -> NSMenu
    {
        let menu = NSMenu()
        for item in items {
            switch item {
            case .separator:
                menu.addItem(.separator())
            case .openWith:
                menu.addItem(OpenWithMenu(target: { [weak target] in target?.openWith() }).item)
            case .command(let id):
                guard let command = registry.command(for: id) else { throw .unregistered(id) }
                let menuItem = NSMenuItem(
                    title: command.title, action: #selector(ListingTableView.runMenuCommand(_:)),
                    keyEquivalent: "")
                menuItem.representedObject = id
                menuItem.target = target
                if let chord = command.chords.first,
                    !chord.modifiers.isDisjoint(with: [.command, .control, .option])
                {
                    MainMenuBuilder.set(chord, on: menuItem)
                }
                menu.addItem(menuItem)
            }
        }
        return menu
    }
}
