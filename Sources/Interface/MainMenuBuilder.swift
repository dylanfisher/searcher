import AppKit
import Browser

/// Builds the menu bar, the only place main menus are built. An item either runs a registered
/// command, with the command's first chord as its key equivalent unless a text field needs that
/// key, or sends one of AppKit's own actions (Quit, Copy, Minimize) to the first responder that
/// implements it. Every key equivalent is spelled as a `KeyChord`. Every registered command has
/// an item (docs/decisions/0060-menu-items-for-every-command.md).
@MainActor
public enum MainMenuBuilder {
    /// An action AppKit implements, sent up the responder chain with no target.
    struct StandardAction {
        let title: String
        let action: Selector
        let chord: KeyChord?
        /// A text-editing action. A command may share its chord: in a text field the field editor
        /// takes the key, and elsewhere the key runs the command.
        var isTextEditing = false
    }

    enum Item {
        case command(CommandID)
        /// A command's item with no key equivalent, for a key a text field must still get: the
        /// menu would take it before the field did. The key reaches the command from the table.
        case commandWithoutKey(CommandID)
        case standard(StandardAction)
        case submenu(Menu)
        case separator
    }

    struct Menu {
        let title: String
        let items: [Item]
        /// The system adds this menu's items, so the bar keeps it with none of ours.
        var isFilledBySystem = false
    }

    /// Why the menus couldn't be built from the registry.
    public enum BuildError: Error, CustomStringConvertible {
        case unregistered(CommandID, menu: String)
        /// A command bound to the chord of an always-enabled standard item, such as Cmd-Q, which
        /// the menu would take before the pane saw the key.
        case chordTaken(KeyChord, item: String, command: Command)

        public var description: String {
            switch self {
            case .unregistered(let id, let menu):
                "the \(menu) menu lists \(id), which isn't registered"
            case .chordTaken(let chord, let item, let command):
                "\(command.id) (\"\(command.title)\") is bound to \(chord), which \"\(item)\" uses"
            }
        }
    }

    static let selectAll = StandardAction(
        title: "Select All", action: #selector(NSResponder.selectAll(_:)),
        chord: KeyChord("a", modifiers: .command), isTextEditing: true)

    /// The row keys, which all reach the table from `keyDown`: a key equivalent would take
    /// ↑, ↓, Shift-, Opt- and Ctrl-Shift-arrows and the page keys from text fields.
    static let selectionMenu = Menu(
        title: "Selection",
        items: [
            .commandWithoutKey(SelectionCommands.selectNext.id),
            .commandWithoutKey(SelectionCommands.selectPrevious.id),
            .commandWithoutKey(SelectionCommands.selectFirst.id),
            .commandWithoutKey(SelectionCommands.selectLast.id),
            .separator,
            .commandWithoutKey(SelectionCommands.tenRowsDown.id),
            .commandWithoutKey(SelectionCommands.tenRowsUp.id),
            .commandWithoutKey(SelectionCommands.pageDown.id),
            .commandWithoutKey(SelectionCommands.pageUp.id),
            .separator,
            .commandWithoutKey(SelectionCommands.extendDown.id),
            .commandWithoutKey(SelectionCommands.extendUp.id),
        ])

    static let windowMenu = Menu(
        title: "Window",
        items: [
            .standard(
                StandardAction(
                    title: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)),
                    chord: KeyChord("m", modifiers: .command))),
            .standard(
                StandardAction(
                    title: "Zoom", action: #selector(NSWindow.performZoom(_:)), chord: nil)),
            .separator,
            .command(WindowCommands.previousTab.id), .command(WindowCommands.nextTab.id),
            .separator,
            .command(TilingCommands.splitRight.id), .command(TilingCommands.splitDown.id),
            counts(TilingCommands.columnsTitle, TilingCommands.columns),
            counts(TilingCommands.rowsTitle, TilingCommands.rows),
            .separator,
            // Tab is its key.
            .commandWithoutKey(DualPaneCommands.focusOtherPane.id),
            directions(TilingCommands.focusTitle, TilingCommands.focus),
            directions(TilingCommands.moveTitle, TilingCommands.move),
            directions(TilingCommands.resizeTitle, TilingCommands.resize),
            .command(TilingCommands.zoom.id), .command(TilingCommands.unzoom.id),
            .command(TilingCommands.equalize.id),
            .separator,
            .command(WindowCommands.movePaneToNewWindow.id),
            .command(WindowCommands.mergeWindowIntoTab.id),
            .separator,
            .command(WindowCommands.toggleOperations.id),
            .separator,
            // Cmd-W closes the pane, then the tab with its last pane, then the window with its
            // last tab.
            .command(TilingCommands.closePane.id),
        ])

    /// AppKit puts its menu search field in the app's help menu and has no item of ours to add.
    /// There is no help book, so the menu has no items of its own.
    static let helpMenu = Menu(title: "Help", items: [], isFilledBySystem: true)

    /// The menus after the app menu, in menu bar order. A menu with no items is left out of the
    /// bar until a step gives it some, unless the system fills it.
    static let menus = [
        Menu(
            title: "File",
            items: [
                .command(WindowCommands.newWindow.id), .command(FileCommands.newFolder.id),
                .command(WindowCommands.newTab.id),
                .command(WindowCommands.closeTab.id),
                .separator,
                // Return is its key.
                .commandWithoutKey(FileCommands.rename.id),
                .command(FileCommands.duplicate.id),
                .command(FileCommands.copyToOtherPane.id),
                .command(FileCommands.moveToOtherPane.id),
                .separator,
                // Space is its key.
                .commandWithoutKey(ViewCommands.toggleQuickLook.id),
                .command(SystemCommands.revealInFinder.id),
                .command(SystemCommands.openTerminal.id),
                .separator,
                .command(FileCommands.moveToTrash.id),
                .separator,
                // Where Finder puts Find.
                .command(ViewCommands.filter.id),
            ]),
        Menu(
            title: "Edit",
            items: [
                .standard(
                    StandardAction(
                        title: "Undo", action: Selector(("undo:")),
                        chord: KeyChord("z", modifiers: .command), isTextEditing: true)),
                .standard(
                    StandardAction(
                        title: "Redo", action: Selector(("redo:")),
                        chord: KeyChord("z", modifiers: [.command, .shift]), isTextEditing: true)),
                .separator,
                .standard(
                    StandardAction(
                        title: "Cut", action: #selector(NSText.cut(_:)),
                        chord: KeyChord("x", modifiers: .command), isTextEditing: true)),
                .standard(
                    StandardAction(
                        title: "Copy", action: #selector(NSText.copy(_:)),
                        chord: KeyChord("c", modifiers: .command), isTextEditing: true)),
                .command(SystemCommands.copyPath.id),
                .standard(
                    StandardAction(
                        title: "Paste", action: #selector(NSText.paste(_:)),
                        chord: KeyChord("v", modifiers: .command), isTextEditing: true)),
                // Runs Select All's command when the table has the keys.
                .standard(selectAll),
                .separator,
                .submenu(selectionMenu),
            ]),
        Menu(
            title: "Go",
            items: [
                .command(NavigationCommands.back.id), .command(NavigationCommands.forward.id),
                .separator,
                .command(NavigationCommands.open.id), .command(WindowCommands.openInNewTab.id),
                .command(DualPaneCommands.openInOtherPane.id),
                .command(NavigationCommands.goToParent.id),
                .separator,
                // → and ← are their keys, in column view.
                .commandWithoutKey(ColumnCommands.intoFolder.id),
                .commandWithoutKey(ColumnCommands.toParent.id),
                .separator,
                .command(DualPaneCommands.sameFolderInOtherPane.id),
                .command(NavigationCommands.goToFolder.id),
            ]
        ),
        Menu(
            title: "View",
            items: [
                .command(ViewCommands.asList.id), .command(ViewCommands.asColumns.id),
                .separator,
                .command(ViewCommands.toggleHidden.id),
                .command(ViewCommands.toggleFoldersFirst.id),
                .separator,
                .command(ViewCommands.sortByName.id), .command(ViewCommands.sortByKind.id),
                .command(ViewCommands.sortByDateModified.id), .command(ViewCommands.sortBySize.id),
                .separator,
                .command(SizeCommands.recalculateSizes.id),
            ]),
        windowMenu,
        helpMenu,
    ]

    /// Builds the menus and makes them `app`'s menu bar, with the Window menu as its windows menu
    /// and the Help menu as its help menu.
    /// Items for commands that toggle a setting show its state from `settings`.
    public static func install(
        in app: NSApplication, appName: String, registry: CommandRegistry, settings: Settings
    ) throws(BuildError) {
        let bar = try build(appName: appName, registry: registry)
        showChecks(in: bar, settings: settings)
        app.mainMenu = bar
        app.windowsMenu = submenu(titled: windowMenu.title, in: bar)
        app.helpMenu = submenu(titled: helpMenu.title, in: bar)
    }

    static func build(appName: String, registry: CommandRegistry) throws(BuildError) -> NSMenu {
        let bar = NSMenu()
        for menu in [appMenu(appName)] + menus {
            let barItem = try submenuItem(menu, registry: registry)
            guard menu.isFilledBySystem || barItem.submenu?.numberOfItems ?? 0 > 0 else { continue }
            bar.addItem(barItem)
        }
        return bar
    }

    private static func submenu(titled title: String, in bar: NSMenu) -> NSMenu {
        guard let submenu = bar.items.first(where: { $0.title == title })?.submenu else {
            preconditionFailure("the menu bar has no \(title) menu")
        }
        return submenu
    }

    /// An item titled `menu.title` whose submenu holds `menu`'s items.
    private static func submenuItem(_ menu: Menu, registry: CommandRegistry) throws(BuildError)
        -> NSMenuItem
    {
        let submenu = NSMenu(title: menu.title)
        for item in menu.items {
            submenu.addItem(try menuItem(item, in: menu, registry: registry))
        }
        let item = NSMenuItem(title: menu.title, action: nil, keyEquivalent: "")
        item.submenu = submenu
        return item
    }

    /// A submenu titled `title` with one item per direction, in `Direction.allCases` order.
    private static func directions(_ title: String, _ commands: [Direction: Command]) -> Item {
        .submenu(
            Menu(
                title: title,
                items: Direction.allCases.map { direction in
                    guard let command = commands[direction] else {
                        preconditionFailure("\(title) has no command for \(direction)")
                    }
                    return .command(command.id)
                }))
    }

    /// A submenu titled `title` with one item per count, smallest first. A Shift-digit key
    /// equivalent doesn't match the "!" a US keyboard types for it, so Cmd-Opt-Shift-1 reaches
    /// its command through the table's `keyDown`, as Cmd-Shift-. does.
    private static func counts(_ title: String, _ commands: [Int: Command]) -> Item {
        .submenu(
            Menu(
                title: title,
                items: commands.sorted { $0.key < $1.key }.map { .command($0.value.id) }))
    }

    /// Gives each item of a command that turns a setting on and off (`CommandBinding.isChecked`)
    /// a check mark while the setting is on, now and after each change, for as long as `bar`
    /// exists.
    static func showChecks(in bar: NSMenu, settings: Settings) {
        let isChecked = Dictionary(
            uniqueKeysWithValues: AppCommands.bindings.compactMap { binding in
                binding.isChecked.map { (binding.command.id, $0) }
            })
        let items: [(NSMenuItem, @MainActor @Sendable (Settings) -> Bool)] =
            allItems(in: bar).compactMap { item in
                guard let id = item.representedObject as? CommandID, let check = isChecked[id]
                else { return nil }
                return (item, check)
            }
        showChecks(items, settings: settings)
        settings.observe(for: bar) { [weak settings] in
            guard let settings else { return }
            showChecks(items, settings: settings)
        }
    }

    private static func showChecks(
        _ items: [(NSMenuItem, @MainActor @Sendable (Settings) -> Bool)], settings: Settings
    ) {
        for (item, isChecked) in items {
            item.state = isChecked(settings) ? .on : .off
        }
    }

    private static func allItems(in menu: NSMenu) -> [NSMenuItem] {
        menu.items.flatMap { [$0] + ($0.submenu.map(allItems) ?? []) }
    }

    private static func appMenu(_ appName: String) -> Menu {
        Menu(
            title: appName,
            items: [
                .standard(
                    StandardAction(
                        title: "About \(appName)",
                        action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
                        chord: nil)),
                .separator,
                .standard(
                    StandardAction(
                        title: "Hide \(appName)", action: #selector(NSApplication.hide(_:)),
                        chord: KeyChord("h", modifiers: .command))),
                .standard(
                    StandardAction(
                        title: "Hide Others",
                        action: #selector(NSApplication.hideOtherApplications(_:)),
                        chord: KeyChord("h", modifiers: [.option, .command]))),
                .separator,
                .standard(
                    StandardAction(
                        title: "Quit \(appName)", action: #selector(NSApplication.terminate(_:)),
                        chord: KeyChord("q", modifiers: .command))),
            ])
    }

    private static func menuItem(_ item: Item, in menu: Menu, registry: CommandRegistry)
        throws(BuildError) -> NSMenuItem
    {
        switch item {
        case .separator:
            return .separator()
        case .submenu(let submenu):
            return try submenuItem(submenu, registry: registry)
        case .command(let id), .commandWithoutKey(let id):
            guard let command = registry.command(for: id) else {
                throw .unregistered(id, menu: menu.title)
            }
            // The menu shows one chord. The others reach the command through the pane's keys.
            let menuItem = NSMenuItem(
                title: command.title, action: #selector(ListingTableView.runMenuCommand(_:)),
                keyEquivalent: "")
            menuItem.representedObject = id
            if case .command = item {
                command.chords.first.map { set($0, on: menuItem) }
            }
            return menuItem
        case .standard(let standard):
            let menuItem = NSMenuItem(
                title: standard.title, action: standard.action, keyEquivalent: "")
            if let chord = standard.chord {
                if !standard.isTextEditing, let command = registry.command(for: chord) {
                    throw .chordTaken(chord, item: standard.title, command: command)
                }
                set(chord, on: menuItem)
            }
            return menuItem
        }
    }

    private static func set(_ chord: KeyChord, on item: NSMenuItem) {
        item.keyEquivalent = chord.keyEquivalent
        item.keyEquivalentModifierMask = chord.keyEquivalentModifierMask
    }
}
