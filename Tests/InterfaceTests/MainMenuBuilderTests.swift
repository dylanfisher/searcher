import AppKit
import Browser
import BrowserTestSupport
import Foundation
import TestSupport
import Testing

@testable import Interface

/// Every item in `menu` and its submenus, depth first.
@MainActor
private func allItems(_ menu: NSMenu) -> [NSMenuItem] {
    menu.items.flatMap { [$0] + ($0.submenu.map(allItems) ?? []) }
}

/// The item a key press would trigger: the one whose key equivalent spells one of the event's
/// chords, tried in order.
@MainActor
private func item(for event: NSEvent, in menu: NSMenu) throws -> NSMenuItem {
    let chords = KeyChord.candidates(for: event)
    let found = chords.lazy.compactMap { chord in
        allItems(menu).first {
            $0.keyEquivalent == chord.keyEquivalent
                && $0.keyEquivalentModifierMask == chord.keyEquivalentModifierMask
        }
    }.first
    return try #require(found, "no menu item for \(chords)")
}

/// The responder AppKit would send `item`'s action to: the first one up the chain from the
/// window's first responder that implements it.
@MainActor
private func receiver(of item: NSMenuItem, in window: NSWindow) throws -> NSResponder? {
    let action = try #require(item.action)
    var responder = window.firstResponder
    while let current = responder {
        if current.responds(to: action) { return current }
        responder = current.nextResponder
    }
    return nil
}

/// A runner that records the commands it is asked to run.
@MainActor
private final class CommandLog {
    var ids: [CommandID] = []
}

/// The menus built from `registry`, with the key equivalents the builder set. Shortcuts the user
/// set in System Settings' App Shortcuts would otherwise replace them when an item joins a menu.
@MainActor
private func buildMenu(_ registry: CommandRegistry) throws -> NSMenu {
    NSMenuItem.usesUserKeyEquivalents = false
    return try MainMenuBuilder.build(appName: "Searcher", registry: registry)
}

@MainActor @Test func eachCommandItemsKeyEquivalentIsItsCommandsFirstChord() throws {
    let registry = try AppCommands.registry()
    let menu = try buildMenu(registry)

    let commandItems = allItems(menu).filter { $0.representedObject is CommandID && !$0.isHidden }
    #expect(!commandItems.isEmpty)
    for item in commandItems {
        let id = try #require(item.representedObject as? CommandID)
        let command = try #require(registry.command(for: id))
        // A command with no chord, such as Folders First, has no key equivalent.
        guard let chord = command.chords.first else {
            #expect(item.keyEquivalent.isEmpty, "\(id)")
            continue
        }
        if item.keyEquivalent.isEmpty {
            // Only a key without Command may be left off, such as Tab or Opt-↑, which text
            // fields also use.
            #expect(!chord.modifiers.contains(.command), "\(id)")
            continue
        }
        #expect(item.keyEquivalent == chord.keyEquivalent, "\(id)")
        #expect(item.keyEquivalentModifierMask == chord.keyEquivalentModifierMask, "\(id)")
        // The menu would take a plain or Shift-only key from text fields and type-to-select.
        #expect(!chord.modifiers.isDisjoint(with: [.command, .control, .option]), "\(id)")
    }
}

@MainActor @Test func everyRegisteredCommandHasAMenuItem() throws {
    let registry = try AppCommands.registry()
    let menu = try buildMenu(registry)
    // A hidden item runs its command on a second chord; it doesn't list it.
    var listed = Set(
        allItems(menu).filter { !$0.isHidden }.compactMap { $0.representedObject as? CommandID })
    // Edit's Undo, Redo, Cut, Copy, Paste and Select All run their commands when the table has
    // the keys.
    listed.formUnion(MainMenuBuilder.actionsRunningCommands.compactMap(\.command))

    let missing = AppCommands.bindings.map(\.command).filter { !listed.contains($0.id) }

    #expect(
        missing.isEmpty,
        "no menu item for \(missing.map { "\($0.id) (\"\($0.title)\")" }.joined(separator: ", "))")
}

@MainActor @Test func goMenuRunsOpenAndGoToParentWithTheirChords() throws {
    let menu = try buildMenu(try AppCommands.registry())
    let table = ListingTableView()
    let log = CommandLog()
    table.runCommand = { log.ids.append($0) }

    let presses = [
        try keyEvent(functionKey(NSDownArrowFunctionKey), modifiers: arrowFlags.union(.command)),
        try keyEvent(functionKey(NSUpArrowFunctionKey), modifiers: arrowFlags.union(.command)),
    ]
    for press in presses {
        let item = try item(for: press, in: menu)
        #expect(table.tryToPerform(try #require(item.action), with: item))
    }

    #expect(log.ids == [NavigationCommands.open.id, NavigationCommands.goToParent.id])
}

@MainActor @Test func aMenuListingAnUnregisteredCommandFailsNamingIt() throws {
    let error = #expect(throws: MainMenuBuilder.BuildError.self) {
        try buildMenu(CommandRegistry())
    }
    #expect(error?.description.contains(WindowCommands.newWindow.id.rawValue) == true)
}

@MainActor @Test func aCommandOnAnAppOrWindowChordFailsNamingBoth() throws {
    var registry = try AppCommands.registry()
    let quitClash = Command(
        id: CommandID("test.quitClash"), title: "Clash",
        chords: [KeyChord("q", modifiers: .command)])
    try registry.register(quitClash)

    let error = #expect(throws: MainMenuBuilder.BuildError.self) {
        try buildMenu(registry)
    }
    #expect(error?.description.contains("test.quitClash") == true)
    #expect(error?.description.contains("Quit Searcher") == true)
}

@MainActor @Test func appAndWindowItemsSendTheStandardActions() throws {
    let menu = try buildMenu(try AppCommands.registry())
    let expected: [(KeyChord, Selector)] = [
        (KeyChord("q", modifiers: .command), #selector(NSApplication.terminate(_:))),
        (KeyChord("h", modifiers: .command), #selector(NSApplication.hide(_:))),
        (
            KeyChord("h", modifiers: [.option, .command]),
            #selector(NSApplication.hideOtherApplications(_:))
        ),
        (KeyChord("m", modifiers: .command), #selector(NSWindow.performMiniaturize(_:))),
    ]
    for (chord, action) in expected {
        let item = try #require(allItems(menu).first { $0.action == action }, "\(action)")
        #expect(item.target == nil, "\(action)")
        #expect(item.keyEquivalent == chord.keyEquivalent, "\(action)")
        #expect(item.keyEquivalentModifierMask == chord.keyEquivalentModifierMask, "\(action)")
    }
    let titles = allItems(menu).map(\.title)
    #expect(titles.contains("About Searcher"))
    #expect(titles.contains("Zoom"))
}

/// An unshown window holding a pane's table, whose commands only record, and a text field.
@MainActor
private struct TextFieldWindow {
    let window = KeyCatchingWindow()
    let table = ListingTableView()
    let field = NSTextField(string: "hello")
    let log = CommandLog()

    init() throws {
        table.registry = try AppCommands.registry()
        table.runCommand = { [log] in log.ids.append($0) }
        table.addTableColumn(NSTableColumn(identifier: NSUserInterfaceItemIdentifier("name")))
        table.frame = NSRect(x: 0, y: 100, width: 400, height: 200)
        field.frame = NSRect(x: 0, y: 0, width: 400, height: 24)
        window.contentView?.addSubview(table)
        window.contentView?.addSubview(field)
    }
}

@MainActor @Test func aTextFieldsEditingKeysReachItsFieldEditorAndRunNoCommand() throws {
    let setup = try TextFieldWindow()
    let menu = try buildMenu(setup.table.registry)
    #expect(setup.window.makeFirstResponder(setup.field))
    let editor = try #require(setup.window.firstResponder as? NSTextView)
    #expect(editor.isFieldEditor)

    for key in ["a", "x", "c", "v"] {
        let press = try keyEvent(key, modifiers: .command)
        let item = try item(for: press, in: menu)
        #expect(try receiver(of: item, in: setup.window) === editor, "Cmd-\(key)")
    }
    let selectAll = try item(for: try keyEvent("a", modifiers: .command), in: menu)
    #expect(editor.tryToPerform(try #require(selectAll.action), with: selectAll))
    // With no main menu to take Cmd-A first, the key reaches the editor and ends at the window.
    editor.keyDown(with: try keyEvent("a", modifiers: .command))

    #expect(setup.window.unhandledCommands.count == 1)
    #expect(editor.selectedRange() == NSRange(location: 0, length: 5))
    #expect(setup.log.ids.isEmpty)
}

/// Cmd-Delete deletes to the start of the line in a text field, so Move to Trash has no receiver
/// there and its item is off.
@MainActor @Test func moveToTrashHasNoReceiverWhileATextFieldHasTheKeys() throws {
    let setup = try TextFieldWindow()
    let menu = try buildMenu(setup.table.registry)
    #expect(setup.window.makeFirstResponder(setup.field))

    let trash = try item(for: try keyEvent("\u{7F}", modifiers: .command), in: menu)

    #expect(trash.representedObject as? CommandID == FileCommands.moveToTrash.id)
    #expect(try receiver(of: trash, in: setup.window) == nil)
    #expect(setup.window.makeFirstResponder(setup.table))
    #expect(try receiver(of: trash, in: setup.window) === setup.table)
}

/// Move Items Here has no text-editing meaning, so its item is off while a text field has the
/// keys and the field gets Cmd-Opt-V.
@MainActor @Test func moveItemsHereHasNoReceiverWhileATextFieldHasTheKeys() throws {
    let setup = try TextFieldWindow()
    let menu = try buildMenu(setup.table.registry)
    #expect(setup.window.makeFirstResponder(setup.field))

    let moveHere = try item(for: try keyEvent("v", modifiers: [.command, .option]), in: menu)

    #expect(moveHere.representedObject as? CommandID == ClipboardCommands.moveHere.id)
    #expect(try receiver(of: moveHere, in: setup.window) == nil)
    #expect(setup.window.makeFirstResponder(setup.table))
    #expect(try receiver(of: moveHere, in: setup.window) === setup.table)
}

@MainActor @Test func cutCopyAndPasteInTheTableRunTheCommandsOnTheirChords() throws {
    let setup = try TextFieldWindow()
    let menu = try buildMenu(setup.table.registry)
    #expect(setup.window.makeFirstResponder(setup.table))

    for key in ["x", "c", "v"] {
        let item = try item(for: try keyEvent(key, modifiers: .command), in: menu)
        #expect(try receiver(of: item, in: setup.window) === setup.table, "Cmd-\(key)")
        #expect(setup.table.tryToPerform(try #require(item.action), with: item), "Cmd-\(key)")
    }

    #expect(
        setup.log.ids == [
            ClipboardCommands.cut.id, ClipboardCommands.copy.id, ClipboardCommands.paste.id,
        ])
}

@MainActor @Test func cutCopyAndPasteAreOffWhileTheirCommandsWouldDoNothing() throws {
    let setup = try TextFieldWindow()
    let menu = try buildMenu(setup.table.registry)
    let on: Set<CommandID> = [ClipboardCommands.copy.id]
    setup.table.canRunCommand = { on.contains($0) }

    let enabled = try ["x", "c", "v"].map { key in
        setup.table.validateMenuItem(
            try item(for: try keyEvent(key, modifiers: .command), in: menu))
    }

    #expect(enabled == [false, true, false])
}

@MainActor @Test func selectAllInTheTableRunsTheCommandOnItsChord() throws {
    let setup = try TextFieldWindow()
    let menu = try buildMenu(setup.table.registry)
    #expect(setup.window.makeFirstResponder(setup.table))

    let selectAll = try item(for: try keyEvent("a", modifiers: .command), in: menu)
    #expect(try receiver(of: selectAll, in: setup.window) === setup.table)
    #expect(setup.table.tryToPerform(try #require(selectAll.action), with: selectAll))

    #expect(setup.log.ids == [SelectionCommands.selectAll.id])
}

/// Settings for a test that never changes one, over a `temporarySuite` under the temporary
/// directory, which removes its file with the settings. TestSupport can't build `Settings`, which
/// is in Browser, so each test target has this and `storedSettings`.
@MainActor
func untouchedSettings() -> Settings {
    Settings(defaults: temporarySuite(in: FileManager.default.temporaryDirectory.path))
}

/// `untouchedSettings` with folder sizes on, for a test of the walks that setting starts.
@MainActor
func sizedSettings() -> Settings {
    let settings = untouchedSettings()
    settings.folderSizes = true
    return settings
}

/// Settings stored in `folder`, which takes the suite's file with it when the test removes it.
@MainActor
func storedSettings(in folder: TemporaryFolder) -> Settings {
    Settings(defaults: temporarySuite(in: folder.url.path))
}

@MainActor @Test func viewMenuRunsTheTogglesAndSortKeysWithTheirChords() throws {
    let menu = try buildMenu(try AppCommands.registry())
    let view = try #require(menu.items.first { $0.title == "View" }?.submenu)
    #expect(
        view.items.filter { !$0.isHidden }.map(\.title) == [
            "as List", "as Columns", "Columns Start at Home Folder", "", "Show Sidebar",
            "Focus Sidebar", "Show Favorites in Sidebar", "Show Locations in Sidebar",
            "Show Workspaces in Sidebar", "",
            "Show Hidden Files",
            "Always Hide .DS_Store", "Folders First", "", "Sort by Name",
            "Sort by Kind",
            "Sort by Date Modified", "Sort by Size", "", "Calculate All Sizes", "Calculate Sizes",
            "", "Appearance",
        ])
    let appearance = try #require(view.items.last?.submenu)
    #expect(
        appearance.items.filter { !$0.isHidden }.map(\.title) == [
            "Auto Appearance", "Light Appearance", "Dark Appearance",
        ])
    let table = ListingTableView()
    let log = CommandLog()
    table.runCommand = { log.ids.append($0) }

    // Cmd-Shift-. types ">" on a US keyboard; the chord names the unshifted key.
    let presses = [
        try #require(
            NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: [.command, .shift], timestamp: 0,
                windowNumber: 0, context: nil, characters: ">", charactersIgnoringModifiers: ">",
                isARepeat: false, keyCode: 47)),
        try keyEvent("6", modifiers: [.control, .option, .command]),
        try keyEvent("s", modifiers: [.option, .command]),
        try keyEvent("s", modifiers: [.control, .command]),
    ]
    for press in presses {
        let item = try item(for: press, in: menu)
        #expect(table.tryToPerform(try #require(item.action), with: item))
    }

    #expect(
        log.ids == [
            ViewCommands.toggleHidden.id, ViewCommands.sortBySize.id,
            SizeCommands.calculateSizes.id, WorkspaceCommands.toggleSidebar.id,
        ])
}

@MainActor @Test func viewMenuCheckMarksFollowTheSettings() throws {
    let folder = try TemporaryFolder("MainMenuBuilderTests")
    let settings = storedSettings(in: folder)
    let menu = try buildMenu(try AppCommands.registry())
    MainMenuBuilder.showChecks(in: menu, settings: settings)
    let hidden = try #require(allItems(menu).first { $0.title == "Show Hidden Files" })
    let foldersFirst = try #require(allItems(menu).first { $0.title == "Folders First" })
    let sortByName = try #require(allItems(menu).first { $0.title == "Sort by Name" })
    let allSizes = try #require(allItems(menu).first { $0.title == "Calculate All Sizes" })
    #expect(hidden.state == .off)
    #expect(foldersFirst.state == .off)
    #expect(allSizes.state == .off)

    settings.folderSizes = true
    #expect(allSizes.state == .on)
    #expect(hidden.state == .off)

    settings.showHidden = true
    #expect(hidden.state == .on)
    #expect(foldersFirst.state == .off)

    settings.foldersFirst = true
    settings.showHidden = false
    #expect(hidden.state == .off)
    #expect(foldersFirst.state == .on)
    #expect(sortByName.state == .off)
}

@MainActor @Test func theDSStoreHomeAndAppearanceItemsAreCheckedFromTheSettings() throws {
    let folder = try TemporaryFolder("MainMenuBuilderTests")
    let settings = storedSettings(in: folder)
    let menu = try buildMenu(try AppCommands.registry())
    MainMenuBuilder.showChecks(in: menu, settings: settings)
    let dsStore = try #require(allItems(menu).first { $0.title == "Always Hide .DS_Store" })
    let home = try #require(allItems(menu).first { $0.title == "Columns Start at Home Folder" })
    let appearances = try ["Auto", "Light", "Dark"].map { name in
        try #require(allItems(menu).first { $0.title == "\(name) Appearance" })
    }
    #expect(dsStore.state == .on)
    #expect(home.state == .on)
    #expect(appearances.map(\.state) == [.on, .off, .off])

    settings.hideDSStore = false
    #expect(dsStore.state == .off)
    settings.columnsStartAtHome = false
    #expect(home.state == .off)

    let favorites = try #require(allItems(menu).first { $0.title == "Show Favorites in Sidebar" })
    #expect(favorites.state == .on)
    settings.showsFavoritesInSidebar = false
    #expect(favorites.state == .off)
    let locations = try #require(allItems(menu).first { $0.title == "Show Locations in Sidebar" })
    #expect(locations.state == .on)
    settings.showsLocationsInSidebar = false
    #expect(locations.state == .off)

    settings.appearance = .dark
    #expect(appearances.map(\.state) == [.off, .off, .on])
    settings.appearance = .light
    #expect(appearances.map(\.state) == [.off, .on, .off])
    #expect(dsStore.state == .off)
}

@MainActor @Test func goMenuHasBackForwardAndGoToFolderWithTheirChords() throws {
    let menu = try buildMenu(try AppCommands.registry())
    let go = try #require(menu.items.first { $0.title == "Go" }?.submenu)
    #expect(
        go.items.filter { !$0.isHidden }.map(\.title) == [
            "Back", "Forward", "", "Open", "Open in New Tab", "Open in Other Pane",
            "Go to Parent", "", "Into Selected Folder", "To Parent Column", "",
            "Same Folder in Other Pane", "Go to Folder…", "Open Quickly…", "Go to Item…",
        ])
    let table = ListingTableView()
    let log = CommandLog()
    table.runCommand = { log.ids.append($0) }

    let presses = [
        try keyEvent("[", modifiers: .command), try keyEvent("]", modifiers: .command),
        try keyEvent("g", characters: "G", modifiers: [.command, .shift]),
        try keyEvent("p", modifiers: .command),
    ]
    for press in presses {
        let item = try item(for: press, in: menu)
        #expect(table.tryToPerform(try #require(item.action), with: item))
    }

    #expect(
        log.ids == [
            NavigationCommands.back.id, NavigationCommands.forward.id,
            NavigationCommands.goToFolder.id, WindowCommands.goToItem.id,
        ])
}

@MainActor @Test func backAndForwardItemsDisableAtTheEndsOfHistory() async throws {
    let pane = Pane(
        location: Location(path: "/a"),
        service: ListingService(
            lister: StubLister(["/a": [file("x")], "/b": [file("y")]]),
            rootVolumeName: { "Test Disk" }),
        systemActions: StubSystemActions(), settings: untouchedSettings(), isFocused: true)
    let table = ListingTableView()
    let controller = PaneViewController(
        pane: pane, iconCache: TypeIconCache { _ in NSImage() }, formatter: .init(),
        tableView: table, monitorsFolders: false)
    let menu = try buildMenu(try AppCommands.registry())
    let back = try #require(allItems(menu).first { $0.title == "Back" })
    let forward = try #require(allItems(menu).first { $0.title == "Forward" })
    let goToFolder = try #require(allItems(menu).first { $0.title == "Go to Folder…" })
    await settle { pane.state.isLoaded }
    #expect(!table.validateMenuItem(back))
    #expect(!table.validateMenuItem(forward))
    #expect(table.validateMenuItem(goToFolder))

    pane.navigate(to: Location(path: "/b"))
    await settle { pane.state.isLoaded }
    #expect(table.validateMenuItem(back))
    #expect(!table.validateMenuItem(forward))

    pane.goBack()
    await settle { pane.state.isLoaded }
    #expect(!table.validateMenuItem(back))
    #expect(table.validateMenuItem(forward))
    withExtendedLifetime(controller) {}
}

@MainActor @Test func copyPathRevealAndOpenTerminalHaveItemsWithTheirChords() throws {
    let menu = try buildMenu(try AppCommands.registry())
    let file = try #require(menu.items.first { $0.title == "File" }?.submenu)
    #expect(
        file.items.filter { !$0.isHidden }.map(\.title) == [
            "New Window", "New Folder", "New Tab", "Close Tab", "", "Get Info", "Rename",
            "Duplicate",
            "Copy to Other Pane", "Move to Other Pane", "", "Open With",
            "Show Package Contents", "Quick Look",
            "Reveal in Finder",
            "Open Terminal Here", "", "Move to Trash", "", "Filter",
        ])
    let edit = try #require(menu.items.first { $0.title == "Edit" }?.submenu)
    #expect(edit.items.filter { !$0.isHidden }.map(\.title).contains("Copy Path"))
    let quickLook = try #require(file.items.first { $0.title == "Quick Look" })
    #expect(quickLook.keyEquivalent.isEmpty)
    let table = ListingTableView()
    let log = CommandLog()
    table.runCommand = { log.ids.append($0) }

    for key in ["c", "r", "t"] {
        let item = try item(for: try keyEvent(key, modifiers: [.option, .command]), in: menu)
        #expect(table.tryToPerform(try #require(item.action), with: item))
    }

    #expect(
        log.ids == [
            SystemCommands.copyPath.id, SystemCommands.revealInFinder.id,
            SystemCommands.openTerminal.id,
        ])
}

/// Finder's Get Info: in the File menu before Rename, on Cmd-I, and on with nothing selected.
@MainActor @Test func getInfoHasAFileMenuItemOnCmdIThatIsOnWithNothingSelected() async throws {
    let registry = try AppCommands.registry()
    let menu = try buildMenu(registry)
    let pane = Pane(
        location: Location(path: "/folder"),
        service: ListingService(lister: StubLister(["/folder": [file("a")]])),
        systemActions: StubSystemActions(), settings: untouchedSettings())
    let controller = PaneViewController(
        pane: pane, iconCache: TypeIconCache { _ in NSImage() }, formatter: .init(),
        tableView: ListingTableView(), monitorsFolders: false)
    await settle { pane.state.isLoaded }
    let table = controller.listingViewController.tableView

    let item = try item(for: try keyEvent("i", modifiers: [.command]), in: menu)

    #expect(item.title == "Get Info")
    #expect(table.validateMenuItem(item))
    #expect(table.tryToPerform(try #require(item.action), with: item))
    let actions = try #require(pane.systemActions as? StubSystemActions)
    #expect(actions.shownInfo == [[URL(fileURLWithPath: "/folder", isDirectory: true)]])
}

@MainActor @Test func fileMenuRunsFilterWithCmdF() throws {
    let menu = try buildMenu(try AppCommands.registry())
    let item = try item(for: try keyEvent("f", modifiers: .command), in: menu)
    #expect(item.title == "Filter")
    #expect(menu.items.first { $0.title == "File" }?.submenu?.items.contains(item) == true)
    let table = ListingTableView()
    let log = CommandLog()
    table.runCommand = { log.ids.append($0) }

    #expect(table.tryToPerform(try #require(item.action), with: item))

    #expect(log.ids == [ViewCommands.filter.id])
}

@MainActor @Test func windowMenuHasTheTabAndPaneItemsAndCmdWClosesThePane() throws {
    let menu = try buildMenu(try AppCommands.registry())
    let window = try #require(menu.items.first { $0.title == "Window" }?.submenu)
    #expect(
        window.items.filter { !$0.isHidden }.map(\.title) == [
            "Minimize", "Zoom", "", "Show Previous Tab", "Show Next Tab", "", "Split Right",
            "Split Down", "Columns", "Rows", "", "Focus Other Pane", "Focus Pane", "Move Pane",
            "Resize Pane",
            "Zoom Pane", "Unzoom Pane", "Equalize Panes", "", "Move Pane to New Window",
            "Merge Window into Tab", "", "Save Workspace…", "Rename Workspace…",
            "Delete Workspace…",
            "", "Operations", "", "Close Pane",
        ])
    #expect(!allItems(menu).contains { $0.action == #selector(NSWindow.performClose(_:)) })
    let focusOtherPane = try #require(window.items.first { $0.title == "Focus Other Pane" })
    #expect(focusOtherPane.keyEquivalent.isEmpty)
    let table = ListingTableView()
    let log = CommandLog()
    table.runCommand = { log.ids.append($0) }

    let presses = [
        try keyEvent("w", modifiers: .command),
        try keyEvent("w", characters: "W", modifiers: [.command, .shift]),
        try keyEvent("t", modifiers: .command),
    ]
    for press in presses {
        let item = try item(for: press, in: menu)
        #expect(table.tryToPerform(try #require(item.action), with: item))
    }

    #expect(
        log.ids == [
            TilingCommands.closePane.id, WindowCommands.closeTab.id, WindowCommands.newTab.id,
        ])
}

@MainActor @Test func editMenuHasTheRowKeysInASelectionSubmenuWithNoKeyEquivalents() throws {
    let menu = try buildMenu(try AppCommands.registry())
    let edit = try #require(menu.items.first { $0.title == "Edit" }?.submenu)
    let selection = try #require(edit.items.first { $0.title == "Selection" }?.submenu)

    #expect(
        selection.items.filter { !$0.isHidden }.map(\.title) == [
            "Select Next Row", "Select Previous Row", "Select First Row", "Select Last Row", "",
            "Move Down 10 Rows", "Move Up 10 Rows", "Page Down", "Page Up", "",
            "Extend Selection Down", "Extend Selection Up",
        ])
    #expect(selection.items.allSatisfy { $0.keyEquivalent.isEmpty })
}

@MainActor @Test func windowMenuRunsTheDirectionalPaneKeysFromItsSubmenus() throws {
    let menu = try buildMenu(try AppCommands.registry())
    let window = try #require(menu.items.first { $0.title == "Window" }?.submenu)
    for family in ["Focus Pane", "Move Pane", "Resize Pane"] {
        let submenu = try #require(window.items.first { $0.title == family }?.submenu, "\(family)")
        #expect(
            submenu.items.filter { !$0.isHidden }.map(\.title)
                == ["Left", "Right", "Up", "Down"].map { "\(family) \($0)" })
    }
    let table = ListingTableView()
    let log = CommandLog()
    table.runCommand = { log.ids.append($0) }

    let presses = [
        try keyEvent(
            functionKey(NSLeftArrowFunctionKey),
            modifiers: arrowFlags.union([.command, .option, .shift])),
        try keyEvent(
            functionKey(NSLeftArrowFunctionKey),
            modifiers: arrowFlags.union([.control, .option, .shift])),
        try keyEvent(
            functionKey(NSLeftArrowFunctionKey), modifiers: arrowFlags.union([.control, .command])),
    ]
    for press in presses {
        let item = try item(for: press, in: menu)
        #expect(table.tryToPerform(try #require(item.action), with: item))
    }

    #expect(
        log.ids == [
            try #require(TilingCommands.focus[.left]).id,
            try #require(TilingCommands.move[.left]).id,
            try #require(TilingCommands.resize[.left]).id,
        ])
}

/// A key event as a US keyboard sends it: Shift applies to `ignoringModifiers`, and `keyCode`
/// reads the key's own character.
@MainActor
private func usKey(
    _ ignoringModifiers: String, characters: String, keyCode: UInt16,
    _ modifiers: NSEvent.ModifierFlags
) throws -> NSEvent {
    try #require(
        NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0,
            windowNumber: 0, context: nil, characters: characters,
            charactersIgnoringModifiers: ignoringModifiers, isARepeat: false, keyCode: keyCode))
}

@MainActor @Test func windowMenuRunsTheSplitAndGridKeysFromItsItems() throws {
    let menu = try buildMenu(try AppCommands.registry())
    let window = try #require(menu.items.first { $0.title == "Window" }?.submenu)
    let columns = try #require(window.items.first { $0.title == "Columns" }?.submenu)
    let rows = try #require(window.items.first { $0.title == "Rows" }?.submenu)
    #expect(
        columns.items.filter { !$0.isHidden }.map(\.title) == [
            "1 Column", "2 Columns", "3 Columns", "4 Columns",
        ])
    #expect(
        rows.items.filter { !$0.isHidden }.map(\.title) == ["1 Row", "2 Rows", "3 Rows", "4 Rows"])
    let table = ListingTableView()
    let log = CommandLog()
    table.runCommand = { log.ids.append($0) }

    // Option and Shift-Option type other characters; Shift-4 types "$".
    let presses = [
        try usKey("T", characters: "T", keyCode: 17, [.command, .shift]),
        try usKey("T", characters: "ˇ", keyCode: 17, [.option, .shift]),
        try usKey("1", characters: "¡", keyCode: 18, [.command, .option]),
        try usKey("$", characters: "›", keyCode: 21, [.command, .option, .shift]),
    ]
    for press in presses {
        let item = try item(for: press, in: menu)
        #expect(table.tryToPerform(try #require(item.action), with: item))
    }

    #expect(
        log.ids == [
            TilingCommands.splitRight.id, TilingCommands.splitDown.id,
            try #require(TilingCommands.columns[1]).id, try #require(TilingCommands.rows[4]).id,
        ])
}

@MainActor @Test func theTableRunsCmdOptShiftDigitsAsAUSKeyboardTypesThem() throws {
    let table = ListingTableView()
    table.registry = try AppCommands.registry()
    let log = CommandLog()
    table.runCommand = { log.ids.append($0) }
    table.beep = { Issue.record("beeped") }

    for (typed, keyCode) in [("!", 18), ("@", 19), ("#", 20), ("$", 21)] as [(String, UInt16)] {
        table.keyDown(
            with: try usKey(
                typed, characters: typed, keyCode: keyCode, [.command, .option, .shift]))
    }

    #expect(log.ids == (1...4).compactMap { TilingCommands.rows[$0]?.id })
}

@MainActor @Test func theTableRunsOptShiftTWhateverTheKeyTypesAndTypeSelectDoesNotTakeIt() throws {
    let table = ListingTableView()
    table.registry = try AppCommands.registry()
    let log = CommandLog()
    table.runCommand = { log.ids.append($0) }
    table.beep = { Issue.record("beeped") }

    // Option-Shift-T types "ˇ" on a US keyboard; the key is read without Option, so "T".
    table.keyDown(with: try usKey("T", characters: "ˇ", keyCode: 17, [.option, .shift]))
    table.keyDown(with: try usKey("t", characters: "ˇ", keyCode: 17, [.option, .shift]))

    #expect(log.ids == [TilingCommands.splitDown.id, TilingCommands.splitDown.id])
    #expect(!table.typeSelect.isTyping)
}

@MainActor @Test func theLastMenuIsHelpWithNoItemsForTheSystemToFill() throws {
    let menu = try buildMenu(try AppCommands.registry())
    let help = try #require(menu.items.last)
    #expect(help.title == "Help")
    #expect(try #require(help.submenu).numberOfItems == 0)
}

@MainActor @Test func installMakesTheHelpMenuTheAppsHelpMenu() throws {
    let app = NSApplication.shared
    let (mainMenu, windowsMenu, helpMenu) = (app.mainMenu, app.windowsMenu, app.helpMenu)
    defer { (app.mainMenu, app.windowsMenu, app.helpMenu) = (mainMenu, windowsMenu, helpMenu) }

    try MainMenuBuilder.install(in: app, appName: "Searcher", settings: untouchedSettings())

    let help = try #require(app.mainMenu?.items.last?.submenu)
    #expect(help.title == "Help")
    #expect(app.helpMenu === help)
}

/// Each file and clipboard command has one item in File or Edit: its own, or for Cut, Copy and
/// Paste the text-editing item on its chord, which the table answers by running it.
@MainActor @Test func everyFileAndClipboardCommandIsInFileOrEditOnceWithItsTitleAndChord()
    throws
{
    let registry = try AppCommands.registry()
    let menu = try buildMenu(registry)
    let items = try ["File", "Edit"].flatMap { title in
        try #require(menu.items.first { $0.title == title }?.submenu).items
    }.filter { !$0.isHidden }

    for command in (FileCommands.bindings + ClipboardCommands.bindings).map(\.command) {
        let matching = items.filter { item in
            if let id = item.representedObject as? CommandID { return id == command.id }
            return MainMenuBuilder.actionsRunningCommands.contains {
                $0.action == item.action && $0.command == command.id
            }
        }
        #expect(matching.count == 1, "\(command.id)")
        let item = try #require(matching.first)
        #expect(item.title == command.title, "\(command.id)")
        let chord = try #require(command.chords.first)
        if chord.modifiers.isDisjoint(with: [.command, .control, .option]) {
            // Return, Rename's key, is a text field's key too.
            #expect(item.keyEquivalent.isEmpty, "\(command.id)")
        } else {
            #expect(item.keyEquivalent == chord.keyEquivalent, "\(command.id)")
            #expect(item.keyEquivalentModifierMask == chord.keyEquivalentModifierMask)
        }
    }
}

@MainActor @Test func fileAndClipboardItemsDisableWithTheirCommands() throws {
    let registry = try AppCommands.registry()
    let menu = try buildMenu(registry)
    let table = ListingTableView()
    table.registry = registry
    table.canRunCommand = { _ in false }
    let ids = Set((FileCommands.bindings + ClipboardCommands.bindings).map(\.command.id))
    let clipboardActions = [MainMenuBuilder.cut, MainMenuBuilder.copy, MainMenuBuilder.paste]
    let items = allItems(menu).filter { !$0.isHidden }.filter { item in
        if let id = item.representedObject as? CommandID { return ids.contains(id) }
        return clipboardActions.contains { $0.action == item.action }
    }

    #expect(items.count == ids.count)
    for item in items {
        #expect(!table.validateMenuItem(item), "\(item.title)")
    }
}

@MainActor @Test func theAppMenuHasAnEmptyServicesMenuForTheSystemToFill() throws {
    let menu = try buildMenu(try AppCommands.registry())

    let appMenu = try #require(menu.items.first?.submenu)
    let services = try #require(appMenu.items.first { $0.title == "Services" }?.submenu)
    #expect(services.numberOfItems == 0)
}

/// AppKit keeps the first services menu a process is given and ignores later ones, so this checks
/// that the app's is an installed app menu's Services, whichever test installed first.
@MainActor @Test func installGivesTheAppTheAppMenusServicesMenu() throws {
    let app = NSApplication.shared
    let (mainMenu, windowsMenu, helpMenu) = (app.mainMenu, app.windowsMenu, app.helpMenu)
    defer { (app.mainMenu, app.windowsMenu, app.helpMenu) = (mainMenu, windowsMenu, helpMenu) }

    try MainMenuBuilder.install(in: app, appName: "Searcher", settings: untouchedSettings())

    let services = try #require(app.servicesMenu)
    #expect(services.title == "Services")
    #expect(services.supermenu?.title == "Searcher")
}

/// Undo and Redo send AppKit's text actions, so the rename and filter fields' field editors keep
/// their own undo; the table answers them by running the undo commands, with the commands' titles.
@MainActor @Test func undoAndRedoSendTheTextActionsAndTheTableRunsAndNamesTheCommands() throws {
    let registry = try AppCommands.registry()
    let menu = try buildMenu(registry)
    let edit = try #require(menu.items.first { $0.title == "Edit" }?.submenu)
    let undo = try #require(edit.items.first { $0.action == MainMenuBuilder.undo.action })
    let redo = try #require(edit.items.first { $0.action == MainMenuBuilder.redo.action })
    #expect(NSStringFromSelector(MainMenuBuilder.undo.action) == "undo:")
    #expect(NSStringFromSelector(MainMenuBuilder.redo.action) == "redo:")
    #expect(undo.keyEquivalent == "z" && undo.keyEquivalentModifierMask == .command)
    #expect(redo.keyEquivalent == "z" && redo.keyEquivalentModifierMask == [.command, .shift])
    let table = ListingTableView()
    table.registry = registry
    let log = CommandLog()
    table.runCommand = { log.ids.append($0) }
    table.canRunCommand = { $0 == UndoCommands.undo.id }
    table.commandTitle = { $0 == UndoCommands.undo.id ? "Undo Move 3 Items" : nil }

    #expect(table.validateMenuItem(undo))
    #expect(undo.title == "Undo Move 3 Items")
    #expect(!table.validateMenuItem(redo))
    #expect(redo.title == "Redo")
    table.undo(undo)
    table.redo(redo)

    #expect(log.ids == [UndoCommands.undo.id, UndoCommands.redo.id])
}

/// Selection undo has its own items under Redo, on Sublime Text's soft undo keys, separate from
/// the file Undo and Redo; they grey out while their commands would do nothing.
@MainActor @Test func editMenuHasUndoAndRedoSelectionOnCmdUAndShiftCmdU() throws {
    let registry = try AppCommands.registry()
    let menu = try buildMenu(registry)
    let edit = try #require(menu.items.first { $0.title == "Edit" }?.submenu)
    let titles = edit.items.filter { !$0.isHidden }.map(\.title)
    let undo = try #require(edit.items.first { $0.title == "Undo Selection" })
    let redo = try #require(edit.items.first { $0.title == "Redo Selection" })

    #expect(Array(titles.prefix(4)) == ["Undo", "Redo", "Undo Selection", "Redo Selection"])
    #expect(undo.keyEquivalent == "u" && undo.keyEquivalentModifierMask == .command)
    #expect(redo.keyEquivalent == "u" && redo.keyEquivalentModifierMask == [.command, .shift])
    #expect(undo.representedObject as? CommandID == SelectionCommands.undoSelection.id)
    #expect(redo.representedObject as? CommandID == SelectionCommands.redoSelection.id)
    let table = ListingTableView()
    table.registry = registry
    table.canRunCommand = { $0 == SelectionCommands.undoSelection.id }
    #expect(table.validateMenuItem(undo))
    #expect(!table.validateMenuItem(redo))
}

/// The always-on standard items' chords are reserved; the text-editing ones a command may share.
@MainActor @Test func theReservedChordsAreTheNonTextEditingStandardItems() {
    #expect(
        MainMenuBuilder.reservedChords == [
            KeyChord("q", modifiers: .command), KeyChord("h", modifiers: .command),
            KeyChord("h", modifiers: [.option, .command]), KeyChord("m", modifiers: .command),
            KeyChord(",", modifiers: .command),
        ])
}

// MARK: Primary and alternate chords

/// The bindings the app makes from `overrides`.
@MainActor
private func bindings(_ overrides: [CommandID: ShortcutOverride]) throws -> KeyBindings {
    try KeyBindings(
        commands: AppCommands.commands, overrides: overrides,
        reserved: MainMenuBuilder.reservedChords, fixed: MainMenuBuilder.fixedChords)
}

/// The registry the app makes from `overrides`.
@MainActor
private func registry(_ overrides: [CommandID: ShortcutOverride]) throws -> CommandRegistry {
    try bindings(overrides).registry
}

/// The visible item and the hidden one that run command `id`.
@MainActor
private func items(for id: CommandID, in menu: NSMenu) throws -> (
    shown: NSMenuItem, hidden: NSMenuItem
) {
    let running = allItems(menu).filter { $0.representedObject as? CommandID == id }
    let shown = running.filter { !$0.isHidden }
    let hidden = running.filter(\.isHidden)
    #expect(shown.count == 1 && hidden.count == 1, "\(id)")
    return (try #require(shown.first), try #require(hidden.first))
}

@MainActor
private func expectKey(_ chord: KeyChord?, on item: NSMenuItem, _ comment: Comment? = nil) {
    #expect(item.keyEquivalent == (chord?.keyEquivalent ?? ""), comment)
    #expect(item.keyEquivalentModifierMask == (chord?.keyEquivalentModifierMask ?? []), comment)
}

/// Open Quickly shows Cmd-K; Cmd-Shift-P is a hidden item beside it that sends the same action
/// with the same command, so the menu bar takes it from a text field too.
@MainActor @Test func theItemShowsThePrimaryAndAHiddenItemBesideItHasTheAlternate() throws {
    let menu = try buildMenu(try AppCommands.registry())
    let (shown, hidden) = try items(for: WindowCommands.showPalette.id, in: menu)

    expectKey(KeyChord("k", modifiers: .command), on: shown)
    expectKey(KeyChord("p", modifiers: [.command, .shift]), on: hidden)
    #expect(hidden.action == shown.action)
    #expect(hidden.allowsKeyEquivalentWhenHidden)
    #expect(!shown.isHidden)
    #expect(hidden.menu === shown.menu)
    #expect(hidden.menu?.index(of: hidden) == (shown.menu?.index(of: shown)).map { $0 + 1 })
}

/// A chord with no Command, Control or Option is typed in text fields, so the user's plain key
/// never becomes a key equivalent, and the item shows the command's other chord.
@MainActor @Test func aPlainChordTheUserGaveACommandIsNoKeyEquivalent() throws {
    let menu = try buildMenu(
        try registry([
            WindowCommands.showPalette.id: ShortcutOverride(primary: .chord(KeyChord("j"))),
            WindowCommands.newTab.id: ShortcutOverride(alternate: .chord(KeyChord(.escape))),
        ]))

    let palette = try items(for: WindowCommands.showPalette.id, in: menu)
    expectKey(KeyChord("p", modifiers: [.command, .shift]), on: palette.shown)
    expectKey(nil, on: palette.hidden)
    let newTab = try items(for: WindowCommands.newTab.id, in: menu)
    expectKey(KeyChord("t", modifiers: .command), on: newTab.shown)
    expectKey(nil, on: newTab.hidden)
    #expect(!allItems(menu).contains { $0.keyEquivalent == "j" || $0.keyEquivalent == "\u{1B}" })
}

/// An F-key has no meaning in a text field, so the preset's F5 is a key equivalent.
@MainActor @Test func anFKeyAlternateIsAKeyEquivalent() throws {
    let menu = try buildMenu(
        try KeyBindings(commands: AppCommands.commands, preset: FileCommands.commanderFKeys)
            .registry)

    let (_, hidden) = try items(for: FileCommands.copyToOtherPane.id, in: menu)
    expectKey(KeyChord(.function(5)), on: hidden)
}

@MainActor @Test func changingTheShortcutsSettingUpdatesTheInstalledItems() throws {
    let app = NSApplication.shared
    let (mainMenu, windowsMenu, helpMenu) = (app.mainMenu, app.windowsMenu, app.helpMenu)
    defer { (app.mainMenu, app.windowsMenu, app.helpMenu) = (mainMenu, windowsMenu, helpMenu) }
    let folder = try TemporaryFolder("MainMenuBuilderTests")
    let settings = storedSettings(in: folder)
    NSMenuItem.usesUserKeyEquivalents = false
    try MainMenuBuilder.install(in: app, appName: "Searcher", settings: settings)
    let menu = try #require(app.mainMenu)
    let custom = KeyChord("o", modifiers: [.command, .shift])

    settings.shortcuts = [
        WindowCommands.showPalette.id: ShortcutOverride(
            primary: .removed, alternate: .chord(custom))
    ]

    let (shown, hidden) = try items(for: WindowCommands.showPalette.id, in: menu)
    expectKey(custom, on: shown)
    expectKey(nil, on: hidden)

    settings.shortcuts = [:]

    expectKey(KeyChord("k", modifiers: .command), on: shown)
    expectKey(KeyChord("p", modifiers: [.command, .shift]), on: hidden)
}

/// Copy's alternate is a hidden Edit item sending `copy:`, so a text field copies on it too.
@MainActor @Test func anEditCommandsAlternateIsAHiddenItemSendingTheEditAction() throws {
    let alternate = KeyChord("c", modifiers: [.control, .command])
    let menu = try buildMenu(
        try registry([ClipboardCommands.copy.id: ShortcutOverride(alternate: .chord(alternate))]))
    let edit = try #require(menu.items.first { $0.title == "Edit" }?.submenu)

    let copies = edit.items.filter { $0.action == MainMenuBuilder.copy.action }

    #expect(copies.map(\.isHidden) == [false, true])
    expectKey(KeyChord("c", modifiers: .command), on: copies[0])
    expectKey(alternate, on: copies[1])
    #expect(copies[1].allowsKeyEquivalentWhenHidden)
}

/// Edit ▸ Copy runs Copy by its ID on its fixed Cmd-C. Stored data that removes or moves Copy's
/// Cmd-C, or gives Cmd-C to another command, is dropped, so Cmd-C has one meaning in the menus
/// and in the table's keys.
@MainActor @Test func cmdCStaysCopysWhateverTheStoredShortcutsSay() throws {
    let cmdC = KeyChord("c", modifiers: .command)
    let cmdY = KeyChord("y", modifiers: .command)
    // Each case's overrides, and the command and reason of each chord they lose.
    let cases: [([CommandID: ShortcutOverride], [CommandID], [KeyBindings.Dropped.Reason])] = [
        ([ClipboardCommands.copy.id: ShortcutOverride(primary: .removed)], [], []),
        (
            [ClipboardCommands.copy.id: ShortcutOverride(primary: .chord(cmdY))],
            [ClipboardCommands.copy.id], [.fixed]
        ),
        (
            [WindowCommands.goToItem.id: ShortcutOverride(primary: .chord(cmdC))],
            [WindowCommands.goToItem.id], [.reserved]
        ),
    ]
    for (overrides, losers, reasons) in cases {
        let bindings = try bindings(overrides)
        #expect(bindings.dropped.map(\.command) == losers, "\(overrides)")
        #expect(bindings.dropped.map(\.reason) == reasons, "\(overrides)")
        let registry = bindings.registry
        #expect(registry.command(for: cmdC)?.id == ClipboardCommands.copy.id, "\(overrides)")
        #expect(registry.command(for: cmdY) == nil, "\(overrides)")
        let menu = try buildMenu(registry)
        let edit = try #require(menu.items.first { $0.title == "Edit" }?.submenu)
        let copy = try #require(
            edit.items.first { $0.action == MainMenuBuilder.copy.action && !$0.isHidden })
        let table = ListingTableView()
        table.registry = registry
        let log = CommandLog()
        table.runCommand = { log.ids.append($0) }
        table.canRunCommand = { $0 == ClipboardCommands.copy.id }

        expectKey(cmdC, on: copy, "\(overrides)")
        let onCmdC = allItems(menu).filter {
            $0.keyEquivalent == cmdC.keyEquivalent
                && $0.keyEquivalentModifierMask == cmdC.keyEquivalentModifierMask
        }
        #expect(onCmdC == [copy], "\(overrides)")
        #expect(table.validateMenuItem(copy), "\(overrides)")
        table.copy(copy)
        // With Copy's item off, the key falls to the table, which runs Copy too, not another
        // command.
        table.canRunCommand = { _ in false }
        table.keyDown(with: try keyEvent("c", modifiers: .command))

        #expect(log.ids == [ClipboardCommands.copy.id, ClipboardCommands.copy.id], "\(overrides)")
    }
}

/// Settings… is fixed on Cmd-, so the user can always get back to the window that sets keys.
@MainActor @Test func theAppMenuHasSettingsOnCmdCommaWhichNoCommandMayTake() throws {
    let menu = try buildMenu(try AppCommands.registry())
    let appMenu = try #require(menu.items.first?.submenu)

    let settings = try #require(appMenu.items.first { $0.title == "Settings…" })

    #expect(settings.action == #selector(SettingsShowing.showSettings(_:)))
    // Nothing in AppKit answers it, so the item is off until a responder of the app does.
    #expect(!NSApplication.shared.responds(to: settings.action))
    expectKey(KeyChord(",", modifiers: .command), on: settings)
    #expect(MainMenuBuilder.reservedChords.contains(KeyChord(",", modifiers: .command)))
}
