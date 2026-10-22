import AppKit
import Browser
import Testing

@testable import Interface

/// Every item in `menu` and its submenus, depth first.
@MainActor
private func allItems(_ menu: NSMenu) -> [NSMenuItem] {
    menu.items.flatMap { [$0] + ($0.submenu.map(allItems) ?? []) }
}

/// The item a key press would trigger: the one whose key equivalent spells the event's chord.
@MainActor
private func item(for event: NSEvent, in menu: NSMenu) throws -> NSMenuItem {
    let chord = try #require(KeyChord(event: event))
    return try #require(
        allItems(menu).first {
            $0.keyEquivalent == chord.keyEquivalent
                && $0.keyEquivalentModifierMask == chord.keyEquivalentModifierMask
        }, "no menu item for \(chord)")
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
        let chord = try #require(registry.command(for: id)?.chords.first)
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
    #expect(error?.description.contains(NavigationCommands.open.id.rawValue) == true)
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
        (KeyChord("w", modifiers: .command), #selector(NSWindow.performClose(_:))),
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
