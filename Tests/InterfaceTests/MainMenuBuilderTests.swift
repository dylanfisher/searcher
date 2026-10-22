import AppKit
import Browser
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

    let commandItems = allItems(menu).filter { $0.representedObject is CommandID }
    #expect(!commandItems.isEmpty)
    for item in commandItems {
        let id = try #require(item.representedObject as? CommandID)
        let command = try #require(registry.command(for: id))
        // A command with no chord, such as Folders First, has no key equivalent, and neither
        // has Focus Other Pane, whose Tab would take the key from text fields.
        guard let chord = command.chords.first, id != DualPaneCommands.focusOtherPane.id else {
            #expect(item.keyEquivalent.isEmpty, "\(id)")
            continue
        }
        #expect(item.keyEquivalent == chord.keyEquivalent, "\(id)")
        #expect(item.keyEquivalentModifierMask == chord.keyEquivalentModifierMask, "\(id)")
    }
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

/// An unshown window holding a pane's table, whose Cmd-A (Select All), Cmd-C and Cmd-V are bound
/// to commands that only record, and a text field.
@MainActor
private struct TextFieldWindow {
    let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled],
        backing: .buffered, defer: true)
    let table = ListingTableView()
    let field = NSTextField(string: "hello")
    let log = CommandLog()

    init() throws {
        window.isReleasedWhenClosed = false
        var registry = try AppCommands.registry()
        for key: Character in ["c", "v"] {
            try registry.register(
                Command(
                    id: CommandID("file.\(key)"), title: "File \(key)",
                    chords: [KeyChord(.character(key), modifiers: .command)]))
        }
        table.registry = registry
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

    for key in ["a", "c", "v"] {
        let press = try keyEvent(key, modifiers: .command)
        let item = try item(for: press, in: menu)
        #expect(try receiver(of: item, in: setup.window) === editor, "Cmd-\(key)")
    }
    let selectAll = try item(for: try keyEvent("a", modifiers: .command), in: menu)
    #expect(editor.tryToPerform(try #require(selectAll.action), with: selectAll))
    editor.keyDown(with: try keyEvent("a", modifiers: .command))

    #expect(editor.selectedRange() == NSRange(location: 0, length: 5))
    #expect(setup.log.ids.isEmpty)
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
/// directory. Nothing is written, so nothing is left. TestSupport can't build `Settings`, which
/// is in Browser, so each test target has this and `storedSettings`.
@MainActor
func untouchedSettings() -> Settings {
    Settings(defaults: temporarySuite(in: FileManager.default.temporaryDirectory.path))
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
        view.items.map(\.title) == [
            "as List", "as Columns", "", "Show Hidden Files", "Folders First", "", "Sort by Name",
            "Sort by Kind",
            "Sort by Date Modified", "Sort by Size", "", "Recalculate Sizes",
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
    ]
    for press in presses {
        let item = try item(for: press, in: menu)
        #expect(table.tryToPerform(try #require(item.action), with: item))
    }

    #expect(log.ids == [ViewCommands.toggleHidden.id, ViewCommands.sortBySize.id])
}

@MainActor @Test func viewMenuCheckMarksFollowTheSettings() throws {
    let folder = try TemporaryFolder("MainMenuBuilderTests")
    let settings = storedSettings(in: folder)
    let menu = try buildMenu(try AppCommands.registry())
    MainMenuBuilder.showChecks(in: menu, settings: settings)
    let hidden = try #require(allItems(menu).first { $0.title == "Show Hidden Files" })
    let foldersFirst = try #require(allItems(menu).first { $0.title == "Folders First" })
    let sortByName = try #require(allItems(menu).first { $0.title == "Sort by Name" })
    #expect(hidden.state == .off)
    #expect(foldersFirst.state == .off)

    settings.showHidden = true
    #expect(hidden.state == .on)
    #expect(foldersFirst.state == .off)

    settings.foldersFirst = true
    settings.showHidden = false
    #expect(hidden.state == .off)
    #expect(foldersFirst.state == .on)
    #expect(sortByName.state == .off)
}

@MainActor @Test func goMenuHasBackForwardAndGoToFolderWithTheirChords() throws {
    let menu = try buildMenu(try AppCommands.registry())
    let go = try #require(menu.items.first { $0.title == "Go" }?.submenu)
    #expect(
        go.items.map(\.title) == [
            "Back", "Forward", "", "Open", "Go to Parent", "", "Go to Folder…",
        ])
    let table = ListingTableView()
    let log = CommandLog()
    table.runCommand = { log.ids.append($0) }

    let presses = [
        try keyEvent("[", modifiers: .command), try keyEvent("]", modifiers: .command),
        try keyEvent("g", characters: "G", modifiers: [.command, .shift]),
    ]
    for press in presses {
        let item = try item(for: press, in: menu)
        #expect(table.tryToPerform(try #require(item.action), with: item))
    }

    #expect(
        log.ids == [
            NavigationCommands.back.id, NavigationCommands.forward.id,
            NavigationCommands.goToFolder.id,
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
        file.items.map(\.title) == [
            "New Window", "New Tab", "Close Tab", "", "Reveal in Finder", "Open Terminal Here",
            "", "Filter",
        ])
    let edit = try #require(menu.items.first { $0.title == "Edit" }?.submenu)
    #expect(edit.items.map(\.title).contains("Copy Path"))
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
        window.items.map(\.title) == [
            "Minimize", "Zoom", "", "Show Previous Tab", "Show Next Tab", "",
            "Move Pane to New Window", "Merge Window into Tab", "", "Focus Other Pane", "",
            "Close Pane",
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
