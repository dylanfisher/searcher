import AppKit
import Browser

/// What App ▸ Settings… sends up the responder chain. The responder that shows the Settings
/// window answers it; while none does, AppKit turns the item off.
@MainActor @objc public protocol SettingsShowing {
    func showSettings(_ sender: Any?)
}

/// Builds the menu bar, the only place main menus are built. An item either runs a registered
/// command or sends one of AppKit's own actions (Quit, Copy, Minimize) to the first responder
/// that implements it. Every key equivalent is spelled as a `KeyChord`. Every registered command
/// has an item (docs/decisions/0060-menu-items-for-every-command.md).
///
/// A command's item shows its first chord as its key equivalent, and a hidden item beside it
/// with the same action has the second, so the menu bar takes both chords, from text fields
/// too. A chord a text field types (`KeyChord.canBeKeyEquivalent`) is left off both; it reaches
/// the command from the table's `keyDown`
/// (docs/decisions/0106-primary-and-alternate-shortcuts.md).
@MainActor
public enum MainMenuBuilder {
    /// An action AppKit implements, sent up the responder chain with no target.
    struct StandardAction {
        let title: String
        let action: Selector
        /// The item's key equivalent, whatever chords the user gives `command`, so a text field
        /// always has Cmd-C and the others.
        let chord: KeyChord?
        /// A text-editing action. A command may share its chord: in a text field the field editor
        /// takes the key, and elsewhere the key runs the command.
        var isTextEditing = false
        /// The command the table runs for the action. Its chords other than `chord` go on a
        /// hidden item beside this one, which sends the same action.
        var command: CommandID?
    }

    enum Item {
        case command(CommandID)
        case standard(StandardAction)
        case submenu(Menu)
        /// The Open With submenu for the selection of the table with the keys.
        case openWith
        case separator
    }

    struct Menu {
        let title: String
        let items: [Item]
        /// The system adds this menu's items, so the bar keeps it with none of ours.
        var isFilledBySystem = false
        /// Whether the items show their commands' chords. The row keys' items don't, whatever
        /// the chords: text fields move by Opt- and Ctrl-Shift-arrows too.
        var showsChords = true
    }

    /// A command's item, or the hidden item beside an Edit item, whose key equivalent follows the
    /// registry: `showChords` sets it.
    final class CommandItem: NSMenuItem {
        /// The command whose chords the item shows.
        let command: CommandID
        /// Which of the command's `menuChords` the item shows: 0 for the first, 1 for the second.
        let position: Int
        let showsChords: Bool

        init(
            title: String, action: Selector, command: CommandID, position: Int, showsChords: Bool
        ) {
            self.command = command
            self.position = position
            self.showsChords = showsChords
            super.init(title: title, action: action, keyEquivalent: "")
        }

        @available(*, unavailable)
        required init(coder: NSCoder) {
            preconditionFailure("menu items aren't decoded")
        }
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
        chord: KeyChord("a", modifiers: .command), isTextEditing: true,
        command: SelectionCommands.selectAll.id)

    static let undo = StandardAction(
        title: "Undo", action: #selector(ListingTableView.undo(_:)),
        chord: KeyChord("z", modifiers: .command), isTextEditing: true,
        command: UndoCommands.undo.id)
    static let redo = StandardAction(
        title: "Redo", action: #selector(ListingTableView.redo(_:)),
        chord: KeyChord("z", modifiers: [.command, .shift]), isTextEditing: true,
        command: UndoCommands.redo.id)

    static let cut = StandardAction(
        title: "Cut", action: #selector(NSText.cut(_:)), chord: KeyChord("x", modifiers: .command),
        isTextEditing: true, command: ClipboardCommands.cut.id)
    static let copy = StandardAction(
        title: "Copy", action: #selector(NSText.copy(_:)),
        chord: KeyChord("c", modifiers: .command), isTextEditing: true,
        command: ClipboardCommands.copy.id)
    static let paste = StandardAction(
        title: "Paste", action: #selector(NSText.paste(_:)),
        chord: KeyChord("v", modifiers: .command), isTextEditing: true,
        command: ClipboardCommands.paste.id)

    /// The text-editing actions the table answers by running the action's command, so a text
    /// field with the keys still undoes, cuts, copies, pastes and selects its text
    /// (docs/decisions/0068-inline-rename.md).
    static let actionsRunningCommands = [undo, redo, cut, copy, paste, selectAll]

    /// The Edit items' own chords, each fixed as its command's primary: the Edit item takes the
    /// key first wherever the keys are, so `KeyBindings` gives it to no other command
    /// (docs/decisions/0106-primary-and-alternate-shortcuts.md).
    public static let fixedChords: [KeyChord: CommandID] = Dictionary(
        uniqueKeysWithValues: actionsRunningCommands.compactMap { action in
            guard let chord = action.chord, let id = action.command else { return nil }
            return (chord, id)
        })

    /// The row keys, which all reach the table from `keyDown`: a key equivalent would take
    /// ↑, ↓, Shift-, Opt- and Ctrl-Shift-arrows, the page keys, Home and End from text fields,
    /// and every row key repeat would go through the menu bar's key equivalents first.
    static let selectionMenu = Menu(
        title: "Selection",
        items: [
            .command(SelectionCommands.selectNext.id),
            .command(SelectionCommands.selectPrevious.id),
            .command(SelectionCommands.selectFirst.id),
            .command(SelectionCommands.selectLast.id),
            .separator,
            .command(SelectionCommands.tenRowsDown.id),
            .command(SelectionCommands.tenRowsUp.id),
            .command(SelectionCommands.pageDown.id),
            .command(SelectionCommands.pageUp.id),
            .separator,
            .command(SelectionCommands.extendDown.id),
            .command(SelectionCommands.extendUp.id),
        ],
        showsChords: false)

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
            .command(DualPaneCommands.focusOtherPane.id),
            directions(TilingCommands.focusTitle, TilingCommands.focus),
            directions(TilingCommands.moveTitle, TilingCommands.move),
            directions(TilingCommands.resizeTitle, TilingCommands.resize),
            .command(TilingCommands.zoom.id), .command(TilingCommands.unzoom.id),
            .command(TilingCommands.equalize.id),
            .separator,
            .command(WindowCommands.movePaneToNewWindow.id),
            .command(WindowCommands.mergeWindowIntoTab.id),
            .separator,
            .command(WorkspaceCommands.save.id), .command(WorkspaceCommands.rename.id),
            .command(WorkspaceCommands.delete.id),
            .separator,
            .command(WindowCommands.toggleOperations.id),
            .separator,
            // Cmd-W closes the pane, then the tab with its last pane, then the window with its
            // last tab.
            .command(TilingCommands.closePane.id),
        ])

    /// AppKit lists the services that take the selection here, once `install` makes it the app's
    /// services menu.
    static let servicesMenu = Menu(title: "Services", items: [], isFilledBySystem: true)

    /// AppKit puts its menu search field in the app's help menu and has no item of ours to add.
    /// There is no help book, so the menu has no items of its own.
    static let helpMenu = Menu(title: "Help", items: [], isFilledBySystem: true)

    /// The chords of the standard items that aren't text editing, such as Quit and Minimize. The
    /// item always takes its chord first, so no command may have one, and `KeyBindings` drops one
    /// that stored data gives a command (docs/decisions/0106-primary-and-alternate-shortcuts.md).
    public static let reservedChords: Set<KeyChord> = {
        func chords(in menu: Menu) -> [KeyChord] {
            menu.items.flatMap { item -> [KeyChord] in
                switch item {
                case .standard(let standard) where !standard.isTextEditing:
                    standard.chord.map { [$0] } ?? []
                case .submenu(let submenu): chords(in: submenu)
                default: []
                }
            }
        }
        // The app's name is only in titles.
        return Set(([appMenu("")] + menus).flatMap(chords))
    }()

    /// The commands each menu runs, in menu bar order, those of its submenus in their places and
    /// the Edit items' commands included; menus with none are left out. The Settings window
    /// lists the commands so.
    static let commandsByMenu: [(menu: String, commands: [CommandID])] = {
        func commands(in menu: Menu) -> [CommandID] {
            menu.items.flatMap { item -> [CommandID] in
                switch item {
                case .command(let id): [id]
                case .standard(let standard): standard.command.map { [$0] } ?? []
                case .submenu(let submenu): commands(in: submenu)
                case .openWith, .separator: []
                }
            }
        }
        // The app menu's section is named for the app, as the menu bar names its menu.
        return ([appMenu("Searcher")] + menus).compactMap { menu in
            let ids = commands(in: menu)
            return ids.isEmpty ? nil : (menu.title, ids)
        }
    }()

    /// The commands whose items show no chords (`Menu.showsChords`), such as the row keys: their
    /// chords reach them from the table's `keyDown` only.
    static let commandsWithoutMenuChords: Set<CommandID> = {
        func commands(in menu: Menu, showsChords: Bool) -> [CommandID] {
            let shows = showsChords && menu.showsChords
            return menu.items.flatMap { item -> [CommandID] in
                switch item {
                case .command(let id): shows ? [] : [id]
                case .submenu(let submenu): commands(in: submenu, showsChords: shows)
                case .standard, .openWith, .separator: []
                }
            }
        }
        return Set(menus.flatMap { commands(in: $0, showsChords: true) })
    }()

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
                .command(SystemCommands.getInfo.id),
                .command(FileCommands.rename.id),
                .command(FileCommands.duplicate.id),
                .command(FileCommands.copyToOtherPane.id),
                .command(FileCommands.moveToOtherPane.id),
                .separator,
                .openWith,
                .command(NavigationCommands.showPackageContents.id),
                .command(ViewCommands.toggleQuickLook.id),
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
                // Undo, Redo, Cut, Copy, Paste and Select All run their commands when the table
                // has the keys; Undo and Redo then name the change they would undo or redo.
                .standard(undo),
                .standard(redo),
                // Sublime Text's soft undo keys; they step through selections, not file changes.
                .command(SelectionCommands.undoSelection.id),
                .command(SelectionCommands.redoSelection.id),
                .separator,
                .standard(cut),
                .standard(copy),
                .command(SystemCommands.copyPath.id),
                .standard(paste),
                .command(ClipboardCommands.moveHere.id),
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
                .command(ColumnCommands.intoFolder.id),
                .command(ColumnCommands.toParent.id),
                .separator,
                .command(DualPaneCommands.sameFolderInOtherPane.id),
                .command(NavigationCommands.goToFolder.id),
                .command(WindowCommands.showPalette.id),
                .command(WindowCommands.goToItem.id),
            ]
        ),
        Menu(
            title: "View",
            items: [
                .command(ViewCommands.asList.id), .command(ViewCommands.asColumns.id),
                .command(ViewCommands.toggleColumnsStartAtHome.id),
                .separator,
                // Where Finder puts Hide Sidebar.
                .command(WorkspaceCommands.toggleSidebar.id),
                .command(WorkspaceCommands.focusSidebar.id),
                .command(ViewCommands.toggleSidebarFavorites.id),
                .command(ViewCommands.toggleSidebarLocations.id),
                .command(ViewCommands.toggleSidebarWorkspaces.id),
                .separator,
                .command(ViewCommands.toggleHidden.id),
                .command(ViewCommands.toggleHideDSStore.id),
                .command(ViewCommands.toggleFoldersFirst.id),
                .separator,
                .command(ViewCommands.sortByName.id), .command(ViewCommands.sortBySize.id),
                .command(ViewCommands.sortByDateModified.id), .command(ViewCommands.sortByKind.id),
                .command(ViewCommands.sortByNextColumn.id),
                .command(ViewCommands.reverseSortDirection.id),
                .separator,
                .command(SizeCommands.calculateAllSizes.id),
                .command(SizeCommands.calculateSizes.id),
                .separator,
                .submenu(
                    Menu(
                        title: ViewCommands.appearanceTitle,
                        items: [
                            .command(ViewCommands.autoAppearance.id),
                            .command(ViewCommands.lightAppearance.id),
                            .command(ViewCommands.darkAppearance.id),
                        ])),
            ]),
        windowMenu,
        helpMenu,
    ]

    /// Builds the menus and makes them `app`'s menu bar, with the Window menu as its windows menu,
    /// the Help menu as its help menu, and the app menu's Services as its services menu, which
    /// lists the services that take the list's selection
    /// (`ListingViewController.serviceSendTypes`).
    /// Items for commands that toggle a setting show its state from `settings`, and every
    /// command's items show the chords `settings` gives it (`PaneViewController.registry(for:)`),
    /// from the start and after each change.
    public static func install(in app: NSApplication, appName: String, settings: Settings)
        throws(BuildError)
    {
        let bar = try build(appName: appName, registry: PaneViewController.registry(for: settings))
        showChecks(in: bar, settings: settings)
        settings.observe(for: bar) { [weak bar, weak settings] in
            guard let bar, let settings else { return }
            showChords(in: bar, registry: PaneViewController.registry(for: settings))
        }
        app.mainMenu = bar
        app.windowsMenu = submenu(titled: windowMenu.title, in: bar)
        app.helpMenu = submenu(titled: helpMenu.title, in: bar)
        guard let appMenu = bar.items.first?.submenu else {
            preconditionFailure("the menu bar has no app menu")
        }
        app.servicesMenu = submenu(titled: servicesMenu.title, in: appMenu)
        app.registerServicesMenuSendTypes(ListingViewController.serviceSendTypes, returnTypes: [])
    }

    static func build(appName: String, registry: CommandRegistry) throws(BuildError) -> NSMenu {
        let bar = NSMenu()
        for menu in [appMenu(appName)] + menus {
            let barItem = try submenuItem(menu, registry: registry)
            guard menu.isFilledBySystem || barItem.submenu?.numberOfItems ?? 0 > 0 else { continue }
            bar.addItem(barItem)
        }
        showChords(in: bar, registry: registry)
        return bar
    }

    private static func submenu(titled title: String, in menu: NSMenu) -> NSMenu {
        guard let submenu = menu.items.first(where: { $0.title == title })?.submenu else {
            preconditionFailure("the menu \"\(menu.title)\" has no \(title) menu")
        }
        return submenu
    }

    /// An item titled `menu.title` whose submenu holds `menu`'s items.
    private static func submenuItem(_ menu: Menu, registry: CommandRegistry) throws(BuildError)
        -> NSMenuItem
    {
        let submenu = NSMenu(title: menu.title)
        for item in menu.items {
            for menuItem in try menuItems(item, in: menu, registry: registry) {
                submenu.addItem(menuItem)
            }
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
                // Fixed, so the user can always get back to the window that sets the keys.
                .standard(
                    StandardAction(
                        title: "Settings…", action: #selector(SettingsShowing.showSettings(_:)),
                        chord: KeyChord(",", modifiers: .command))),
                .command(SystemCommands.openConfigFile.id),
                .separator,
                .submenu(servicesMenu),
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

    /// The items for `item`: one, or for a command, its item and the hidden one beside it.
    private static func menuItems(_ item: Item, in menu: Menu, registry: CommandRegistry)
        throws(BuildError) -> [NSMenuItem]
    {
        switch item {
        case .separator:
            return [.separator()]
        case .submenu(let submenu):
            return [try submenuItem(submenu, registry: registry)]
        case .openWith:
            return [
                OpenWithMenu(target: {
                    (NSApplication.shared.keyWindow?.firstResponder as? ListingTableView)?
                        .openWith()
                }).item
            ]
        case .command(let id):
            guard let command = registry.command(for: id) else {
                throw .unregistered(id, menu: menu.title)
            }
            return (0..<2).map { position in
                let menuItem = CommandItem(
                    title: command.title, action: #selector(ListingTableView.runMenuCommand(_:)),
                    command: id, position: position, showsChords: menu.showsChords)
                menuItem.representedObject = id
                if position > 0 { hide(menuItem) }
                return menuItem
            }
        case .standard(let standard):
            let menuItem = NSMenuItem(
                title: standard.title, action: standard.action, keyEquivalent: "")
            if let chord = standard.chord {
                if !standard.isTextEditing, let command = registry.command(for: chord) {
                    throw .chordTaken(chord, item: standard.title, command: command)
                }
                set(chord, on: menuItem)
            }
            guard let id = standard.command else { return [menuItem] }
            guard registry.command(for: id) != nil else {
                throw .unregistered(id, menu: menu.title)
            }
            // The command's first chord is the Edit item's own, fixed by `fixedChords`.
            let alternate = CommandItem(
                title: standard.title, action: standard.action, command: id, position: 1,
                showsChords: menu.showsChords)
            hide(alternate)
            return [menuItem, alternate]
        }
    }

    /// Hides `item`, whose key equivalent still runs it, through the same validation and action
    /// as the item it sits beside.
    private static func hide(_ item: NSMenuItem) {
        item.isHidden = true
        item.allowsKeyEquivalentWhenHidden = true
    }

    /// The chords `command`'s menu items show, in order: those a key equivalent may have. The
    /// context menus show the first too.
    static func menuChords(of command: Command) -> [KeyChord] {
        command.chords.filter(\.canBeKeyEquivalent)
    }

    /// Gives each command's items in `bar` the key equivalents `registry` gives the command: its
    /// item the first chord, and the hidden item beside it the second. An Edit item keeps its
    /// own chord, its command's first, and its hidden item gets the second.
    static func showChords(in bar: NSMenu, registry: CommandRegistry) {
        for case let item as CommandItem in allItems(in: bar) {
            guard let command = registry.command(for: item.command) else {
                preconditionFailure(
                    "the menus run \(item.command), which the registry doesn't have")
            }
            let chords = item.showsChords ? menuChords(of: command) : []
            if chords.indices.contains(item.position) {
                set(chords[item.position], on: item)
            } else {
                item.keyEquivalent = ""
                item.keyEquivalentModifierMask = []
            }
        }
    }

    /// Shows `chord` as `item`'s key equivalent; the context menus use it too.
    static func set(_ chord: KeyChord, on item: NSMenuItem) {
        item.keyEquivalent = chord.keyEquivalent
        item.keyEquivalentModifierMask = chord.keyEquivalentModifierMask
    }
}
