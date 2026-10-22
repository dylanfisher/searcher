import AppKit
import Browser

/// Builds the menu bar, the only place main menus are built. An item either runs a registered
/// command, with the command's first chord as its key equivalent, or sends one of AppKit's own
/// actions (Quit, Copy, Minimize) to the first responder that implements it. Every key
/// equivalent is spelled as a `KeyChord`.
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
        case standard(StandardAction)
        case separator
    }

    struct Menu {
        let title: String
        let items: [Item]
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
            .standard(
                StandardAction(
                    title: "Close Window", action: #selector(NSWindow.performClose(_:)),
                    chord: KeyChord("w", modifiers: .command))),
        ])

    /// The menus after the app menu, in menu bar order. A menu with no items is left out of the
    /// bar until a step gives it some.
    static let menus = [
        Menu(
            title: "File",
            items: [
                .command(SystemCommands.revealInFinder.id),
                .command(SystemCommands.openTerminal.id),
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
                .standard(selectAll),
            ]),
        Menu(
            title: "Go",
            items: [
                .command(NavigationCommands.back.id), .command(NavigationCommands.forward.id),
                .separator,
                .command(NavigationCommands.open.id), .command(NavigationCommands.goToParent.id),
                .separator,
                .command(NavigationCommands.goToFolder.id),
            ]
        ),
        Menu(
            title: "View",
            items: [
                .command(ViewCommands.toggleHidden.id),
                .command(ViewCommands.toggleFoldersFirst.id),
                .separator,
                .command(ViewCommands.sortByName.id), .command(ViewCommands.sortByKind.id),
                .command(ViewCommands.sortByDateModified.id), .command(ViewCommands.sortBySize.id),
            ]),
        windowMenu,
    ]

    /// Builds the menus and makes them `app`'s menu bar, with the Window menu as its windows menu.
    /// Items for commands that toggle a setting show its state from `settings`.
    public static func install(
        in app: NSApplication, appName: String, registry: CommandRegistry, settings: Settings
    ) throws(BuildError) {
        let bar = try build(appName: appName, registry: registry)
        showChecks(in: bar, settings: settings)
        guard let windows = bar.items.first(where: { $0.title == windowMenu.title })?.submenu else {
            preconditionFailure("the menu bar has no \(windowMenu.title) menu")
        }
        app.mainMenu = bar
        app.windowsMenu = windows
    }

    static func build(appName: String, registry: CommandRegistry) throws(BuildError) -> NSMenu {
        let bar = NSMenu()
        for menu in [appMenu(appName)] + menus {
            let submenu = NSMenu(title: menu.title)
            for item in menu.items {
                submenu.addItem(try menuItem(item, in: menu, registry: registry))
            }
            guard submenu.numberOfItems > 0 else { continue }
            let barItem = NSMenuItem(title: menu.title, action: nil, keyEquivalent: "")
            barItem.submenu = submenu
            bar.addItem(barItem)
        }
        return bar
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
        case .command(let id):
            guard let command = registry.command(for: id) else {
                throw .unregistered(id, menu: menu.title)
            }
            // The menu shows one chord. The others reach the command through the pane's keys.
            let menuItem = NSMenuItem(
                title: command.title, action: #selector(ListingTableView.runMenuCommand(_:)),
                keyEquivalent: "")
            menuItem.representedObject = id
            command.chords.first.map { set($0, on: menuItem) }
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
