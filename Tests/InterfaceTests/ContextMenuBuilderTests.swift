import AppKit
import Base
import Browser
import TestSupport
import Testing

@testable import Interface

/// The commands a context menu runs, in order, separators left out.
@MainActor
private func commandIDs(_ menu: NSMenu) -> [CommandID] {
    menu.items.compactMap { $0.representedObject as? CommandID }
}

@MainActor
private func ids(_ items: [ContextMenuBuilder.Item]) -> [CommandID] {
    items.compactMap { item in
        guard case .command(let id) = item else { return nil }
        return id
    }
}

/// A list at `/folder` in an unshown window, its rows laid out, so a right-click can be sent at a
/// row. The window is never ordered in.
@MainActor
private struct ListWindow {
    let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 800, height: 400), styleMask: [.titled],
        backing: .buffered, defer: true)
    let list: ListingViewController

    init(showing entries: [DirectoryEntry]) async throws {
        window.isReleasedWhenClosed = false
        list = await controller(showing: entries)
        list.tableView.registry = try AppCommands.registry()
        list.tableView.canRunCommand = { _ in true }
        window.contentView = list.view
        window.contentView?.layoutSubtreeIfNeeded()
    }

    /// The menu a right-click at the middle of `row` gets, without showing it.
    func rightClick(row: Int) throws -> NSMenu? {
        let rect = list.tableView.rect(ofRow: row)
        return try rightClick(at: NSPoint(x: rect.midX, y: rect.midY))
    }

    /// The menu a right-click 50 points below the last row gets.
    func rightClickBelowTheRows() throws -> NSMenu? {
        let table = list.tableView
        let last = table.rect(ofRow: table.numberOfRows - 1)
        return try rightClick(at: NSPoint(x: last.midX, y: last.maxY + 50))
    }

    private func rightClick(at tablePoint: NSPoint) throws -> NSMenu? {
        let table = list.tableView
        let point = table.convert(tablePoint, to: nil)
        let event = try #require(
            NSEvent.mouseEvent(
                with: .rightMouseDown, location: point, modifierFlags: [], timestamp: 0,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1,
                pressure: 1))
        return table.menu(for: event)
    }
}

@MainActor
private func selectedNames(_ pane: Pane) -> Set<String> {
    guard case .only(let names) = pane.selection.members else { return [] }
    return Set(names.map(\.name))
}

@MainActor @Test func eachItemTakesItsTitleAndChordFromTheRegistryAndRunsOnTheClickedTable()
    throws
{
    let registry = try AppCommands.registry()
    let table = ListingTableView()

    let menu = try ContextMenuBuilder.build(
        ContextMenuBuilder.rowItems, registry: registry, target: table, selection: [])

    #expect(commandIDs(menu) == ids(ContextMenuBuilder.rowItems))
    // Open With and Share… run no command; OpenWithMenuTests and the Share… test cover them.
    for item in menu.items
    where !item.isSeparatorItem && item.title != OpenWithMenu.title
        && !(item.representedObject is NSSharingServicePicker)
    {
        let id = try #require(item.representedObject as? CommandID)
        let command = try #require(registry.command(for: id))
        #expect(item.title == command.title, "\(id)")
        #expect(item.target === table, "\(id)")
        #expect(item.action == #selector(ListingTableView.runMenuCommand(_:)), "\(id)")
        // As in the main menu, a key without Command, Control or Option shows no key equivalent.
        if let chord = command.chords.first,
            !chord.modifiers.isDisjoint(with: [.command, .control, .option])
        {
            #expect(item.keyEquivalent == chord.keyEquivalent, "\(id)")
            #expect(item.keyEquivalentModifierMask == chord.keyEquivalentModifierMask, "\(id)")
        } else {
            #expect(item.keyEquivalent.isEmpty, "\(id)")
        }
    }
}

@MainActor @Test func aContextMenuListingAnUnregisteredCommandFailsNamingIt() throws {
    let error = #expect(throws: ContextMenuBuilder.BuildError.self) {
        try ContextMenuBuilder.build(
            [.command(FileCommands.duplicate.id)], registry: CommandRegistry(),
            target: ListingTableView(), selection: [])
    }
    #expect(error?.description.contains(FileCommands.duplicate.id.rawValue) == true)
}

@MainActor @Test func itemsDisableWithTheirCommands() throws {
    let table = ListingTableView()
    table.canRunCommand = { $0 == FileCommands.duplicate.id }
    let menu = try ContextMenuBuilder.build(
        ContextMenuBuilder.rowItems, registry: try AppCommands.registry(), target: table,
        selection: [])

    // Open With turns itself off, with no app cache for the table. Share… is left out: its
    // picker turns it on.
    let enabled = menu.items.filter { item in
        !(item.representedObject is NSSharingServicePicker)
            && (item.target as? NSMenuItemValidation)?.validateMenuItem(item) ?? false
    }

    #expect(enabled.map(\.title) == [FileCommands.duplicate.title])
}

@MainActor @Test func choosingAnItemRunsItsCommandOnTheTable() throws {
    let table = ListingTableView()
    var ran: [CommandID] = []
    table.runCommand = { ran.append($0) }
    let menu = try ContextMenuBuilder.build(
        ContextMenuBuilder.rowItems, registry: try AppCommands.registry(), target: table,
        selection: [])
    let duplicate = try #require(menu.items.first { $0.title == FileCommands.duplicate.title })

    #expect(table.tryToPerform(try #require(duplicate.action), with: duplicate))

    #expect(ran == [FileCommands.duplicate.id])
}

@MainActor @Test func aRightClickOnAnUnselectedRowSelectsItAndShowsTheRowMenu() async throws {
    let setup = try await ListWindow(showing: [file("a.txt"), file("b.txt"), file("c.txt")])
    let pane = setup.list.pane
    pane.select(Selection([ExactName("a.txt")], cursor: ExactName("a.txt")))

    let menu = try #require(try setup.rightClick(row: 1))

    #expect(selectedNames(pane) == ["b.txt"])
    #expect(pane.selection.cursor == ExactName("b.txt"))
    #expect(commandIDs(menu) == ids(ContextMenuBuilder.rowItems))
}

@MainActor @Test func aRightClickOnASelectedRowKeepsTheSelection() async throws {
    let setup = try await ListWindow(showing: [file("a.txt"), file("b.txt"), file("c.txt")])
    let pane = setup.list.pane
    let both = Set(["a.txt", "c.txt"].map(ExactName.init))
    pane.select(Selection(both, cursor: ExactName("c.txt")))

    let menu = try #require(try setup.rightClick(row: 0))

    #expect(selectedNames(pane) == ["a.txt", "c.txt"])
    #expect(commandIDs(menu) == ids(ContextMenuBuilder.rowItems))
}

@MainActor @Test func aRightClickBelowTheRowsShowsTheFolderMenu() async throws {
    let setup = try await ListWindow(showing: [file("a.txt")])
    let pane = setup.list.pane
    pane.select(Selection([ExactName("a.txt")], cursor: ExactName("a.txt")))

    let menu = try #require(try setup.rightClickBelowTheRows())

    #expect(selectedNames(pane) == ["a.txt"])
    #expect(commandIDs(menu) == ids(ContextMenuBuilder.folderItems))
}

@MainActor @Test func itemsCarryTheSymbolsFinderShowsOnTheSameItems() throws {
    // Finder's context menu on macOS 26 shows these symbols on its items of the same names.
    #expect(ContextMenuBuilder.symbols[NavigationCommands.open.id] == "arrow.up.forward.app")
    #expect(ContextMenuBuilder.symbols[ViewCommands.toggleQuickLook.id] == "eye")
    #expect(ContextMenuBuilder.symbols[FileCommands.rename.id] == "pencil")
    #expect(ContextMenuBuilder.symbols[FileCommands.duplicate.id] == "plus.square.on.square")
    #expect(ContextMenuBuilder.symbols[ClipboardCommands.copy.id] == "doc.on.doc")
    #expect(ContextMenuBuilder.symbols[FileCommands.moveToTrash.id] == "trash")
    #expect(ContextMenuBuilder.symbols[FileCommands.newFolder.id] == "folder.badge.plus")
    #expect(ContextMenuBuilder.symbols[ClipboardCommands.paste.id] == "doc.on.clipboard")
    let registry = try AppCommands.registry()

    for items in [ContextMenuBuilder.rowItems, ContextMenuBuilder.folderItems] {
        let menu = try ContextMenuBuilder.build(
            items, registry: registry, target: ListingTableView(), selection: [])
        for item in menu.items {
            guard let id = item.representedObject as? CommandID else { continue }
            #expect((item.image != nil) == (ContextMenuBuilder.symbols[id] != nil), "\(id)")
        }
    }
}

@MainActor @Test func theRowMenuSharesTheSelectionAfterTheClipboardItems() async throws {
    let setup = try await ListWindow(showing: [file("a.txt"), file("b.txt")])

    let menu = try #require(try setup.rightClick(row: 1))

    let index = try #require(
        menu.items.firstIndex { $0.representedObject is NSSharingServicePicker })
    #expect(menu.items[index].title == "Share…")
    #expect(menu.items[index].image != nil)
    #expect(
        menu.items[index - 1].representedObject as? CommandID == SystemCommands.copyPath.id)
    let folderMenu = try #require(try setup.rightClickBelowTheRows())
    #expect(!folderMenu.items.contains { $0.representedObject is NSSharingServicePicker })
}
