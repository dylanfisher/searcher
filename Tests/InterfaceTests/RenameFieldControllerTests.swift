import AppKit
import Base
import Browser
import BrowserTestSupport
import Foundation
import TestSupport
import Testing

@testable import Interface

/// A window that is never shown but says it is key, or not, as a test sets it, so AppKit draws
/// its first responder's selection as in the key window.
@MainActor
private final class KeyWindow: NSWindow {
    var isKey = true
    override var isKeyWindow: Bool { isKey }
}

/// A pane over a real temporary folder in a window that is never shown, its list's table with the
/// keys, and a queue of its own. The app has no queue for the pane's context to pass yet, so the
/// tables run the file commands with a context that has this one, and Rename starts the field
/// as the pane's own context does.
@MainActor
private final class Fixture {
    let folder: TemporaryFolder
    let window = KeyWindow(
        contentRect: NSRect(x: 0, y: 0, width: 800, height: 400), styleMask: [.titled],
        backing: .buffered, defer: true)
    let pane: Pane
    let controller: PaneViewController
    let queue: FileOperationQueue
    /// Follows the queue, as the app's history does.
    let history = UndoHistory(log: { _ in })
    /// Every snapshot the queue reported, so a test can count the operations it was given.
    let snapshots = EventLog<FileOperationQueue.Snapshot>()

    /// With `monitors` false no monitor watches the folder, as on a volume that reports no
    /// changes.
    /// `lister` lists the folder in place of the file system.
    init(_ names: String..., monitors: Bool = true, lister: (any Lister)? = nil) async throws {
        folder = try TemporaryFolder("RenameFieldControllerTests")
        for name in names {
            try Data(name.utf8).write(to: folder.url.appending(path: name))
        }
        pane = Pane(
            location: Location(path: folder.url.path),
            service: lister.map { ListingService(lister: $0) } ?? ListingService(),
            systemActions: StubSystemActions(), settings: untouchedSettings(), isFocused: true)
        controller = PaneViewController(
            pane: pane, iconCache: TypeIconCache { _ in NSImage() }, formatter: .init(),
            tableView: ListingTableView(), monitorsFolders: monitors)
        let snapshots = snapshots
        let (finished, feed) = AsyncStream.makeStream(of: FileOperationQueue.Snapshot.self)
        queue = FileOperationQueue(
            prompts: .unexpected,
            onChange: { reported in
                for snapshot in reported { snapshots.append(snapshot) }
            }, onAnyFinish: { feed.yield($0) })
        history.follow(finished)
        window.isReleasedWhenClosed = false
        controller.view.frame = NSRect(x: 0, y: 0, width: 800, height: 400)
        window.contentView?.addSubview(controller.view)
        let pane = pane
        await settle { pane.state.isLoaded && (!monitors || pane.monitor != nil) }
        window.makeFirstResponder(controller.keyView)
        useQueue(in: controller.listingViewController.tableView)
    }

    /// Stops the monitor before the folder goes.
    func stop() {
        pane.monitor?.stop()
        for column in pane.columnTrail?.columns ?? [] {
            column.pane.monitor?.stop()
        }
    }

    /// Runs `table`'s commands with a context that has the fixture's queue.
    func useQueue(in table: ListingTableView) {
        let bindings = Dictionary(
            uniqueKeysWithValues: AppCommands.bindings.map { ($0.command.id, $0) })
        table.runCommand = { [unowned self] id in
            guard let binding = bindings[id] else {
                preconditionFailure("no command is bound to \(id)")
            }
            binding.run(
                CommandContext(
                    pane: pane.commandPane, fileOperations: queue,
                    editName: { [unowned self] in controller.editName(queue: queue) },
                    undoHistory: history))
        }
    }

    var table: ListingTableView {
        guard let table = window.firstResponder as? ListingTableView else {
            preconditionFailure(
                "no table has the keys: \(String(describing: window.firstResponder))")
        }
        return table
    }

    var field: RenameFieldController { controller.listingViewController.renameField }

    /// Selects `name` alone and waits for the selection to settle.
    func select(_ name: String) async {
        pane.commandPane.select(Selection([ExactName(name)], cursor: ExactName(name)))
        await settle { self.selectedNames == [name] }
    }

    func press(_ characters: String, _ modifiers: NSEvent.ModifierFlags = []) throws {
        table.keyDown(with: try keyEvent(characters, modifiers: modifiers))
    }

    /// The field editor typing goes to, when `field`, the list's by default, has the keys.
    func editor(of field: RenameFieldController? = nil) throws -> NSTextView {
        let editor = try #require(window.firstResponder as? NSTextView)
        #expect(editor.isFieldEditor)
        #expect(editor.delegate === (field ?? self.field).field)
        return editor
    }

    /// Types `text` over the selected part of the name.
    func type(_ text: String) throws {
        try editor().insertText(text, replacementRange: NSRange(location: NSNotFound, length: 0))
    }

    /// Sends Return or Esc to the field as its editor would.
    func send(_ selector: Selector) throws {
        let editor = try editor()
        #expect(field.control(field.field, textView: editor, doCommandBy: selector))
    }

    func exists(_ name: String) -> Bool {
        FileManager.default.fileExists(atPath: folder.url.path + "/" + name)
    }

    var operationCount: Int { Set(snapshots.all.map(\.id)).count }

    var selectedNames: Set<String> {
        let selection = pane.commandPane.selection
        guard selection.isSettled, case .only(let names) = selection.members else { return [] }
        return Set(names.map(\.name))
    }

    /// The selected names once a late patch, for a file the fixture wrote before its monitor
    /// started, has finished resolving the selection. `selectedNames` reads an unsettled one as empty.
    func settledSelectedNames() async -> Set<String> {
        await settle { self.pane.commandPane.selection.isSettled }
        return selectedNames
    }
}

private let returnKey = "\r"

@MainActor @Test func returnOnAFileOpensAFieldWithTheNameLessItsExtensionSelected() async throws {
    let fixture = try await Fixture("song.flac", "other.txt")
    defer { fixture.stop() }
    await fixture.select("song.flac")

    try fixture.press(returnKey)

    let editor = try fixture.editor()
    #expect(fixture.field.field.stringValue == "song.flac")
    #expect(editor.selectedRange == NSRange(location: 0, length: 4))
    #expect(fixture.field.isEditing)
}

/// The row view and name cell of `name`'s row in `list`, laid out as on screen.
@MainActor
private func nameRow(_ name: String, in list: ListingViewController) throws
    -> (row: NSTableRowView, cell: NSTableCellView)
{
    list.view.window?.contentView?.layoutSubtreeIfNeeded()
    list.tableView.layoutSubtreeIfNeeded()
    let row = try #require(list.listing?.row(named: name))
    let rowView = try #require(list.tableView.rowView(atRow: row, makeIfNecessary: false))
    // The name cell is the one with the icon.
    let cells = (0..<rowView.numberOfColumns).compactMap {
        rowView.view(atColumn: $0) as? NSTableCellView
    }
    let cell = try #require(cells.first { $0.imageView != nil })
    return (rowView, cell)
}

/// As Finder's: a box in the text background color, with no border, bezel or focus ring,
/// starting where the name's label does, in its font, the name in the label color with the
/// system's text selection, as wide as the name with the editor's padding, and the label under
/// it hidden so the old name doesn't show through.
@MainActor
private func expectFieldOverItsLabel(
    _ rename: RenameFieldController, in list: ListingViewController, name: String
) throws {
    let (_, cell) = try nameRow(name, in: list)
    let label = try #require(cell.textField)
    let field = rename.field
    #expect(field.focusRingType == .none)
    #expect(!field.isBezeled)
    #expect(!field.isBordered)
    #expect(field.drawsBackground)
    #expect(field.backgroundColor == .textBackgroundColor)
    #expect(field.textColor == .labelColor)
    #expect(field.font == label.font)
    let editor = try #require(field.currentEditor() as? NSTextView)
    #expect(
        editor.selectedTextAttributes[.backgroundColor] as? NSColor
            == .selectedTextBackgroundColor)
    let table = list.tableView
    let box = table.convert(field.frame, from: field.superview)
    let labelFrame = table.convert(label.frame, from: cell)
    #expect(box.origin == labelFrame.origin)
    #expect(box.height == labelFrame.height)
    let textWidth = (name as NSString).size(withAttributes: [.font: try #require(label.font)])
        .width
    let padding = try #require(editor.textContainer).lineFragmentPadding
    #expect(box.width == (textWidth + 2 * padding).rounded(.up) + 1)
    #expect(box.width < labelFrame.width)
    #expect(label.isHidden)
}

@MainActor @Test func theFieldSitsBorderlessOverTheNamesLabelInTheList() async throws {
    let fixture = try await Fixture("song.flac")
    defer { fixture.stop() }
    await fixture.select("song.flac")

    try fixture.press(returnKey)

    let list = fixture.controller.listingViewController
    try expectFieldOverItsLabel(fixture.field, in: list, name: "song.flac")
    try fixture.send(#selector(NSResponder.cancelOperation(_:)))
    #expect(try nameRow("song.flac", in: list).cell.textField?.isHidden == false)
}

/// A folder's name in a column ends before its chevron, and so does the field.
@MainActor @Test func theFieldSitsBorderlessOverAFoldersLabelInAColumn() async throws {
    let fixture = try await Fixture("song.flac")
    defer { fixture.stop() }
    try FileManager.default.createDirectory(
        at: fixture.folder.url.appending(path: "Stuff"), withIntermediateDirectories: false)
    await settle { fixture.pane.state.listing?.row(named: "Stuff") != nil }
    let column = try await showColumns(fixture)
    await fixture.select("Stuff")

    try fixture.press(returnKey)

    #expect(column.renameField.isEditing)
    try expectFieldOverItsLabel(column.renameField, in: column, name: "Stuff")
}

/// The box grows with the name typed, up to the room the name has before the row's end.
@MainActor @Test func theFieldGrowsWithTheNameUpToTheRoomItHas() async throws {
    let fixture = try await Fixture("song.flac")
    defer { fixture.stop() }
    await fixture.select("song.flac")
    let list = fixture.controller.listingViewController
    try fixture.press(returnKey)
    let field = fixture.field.field
    let start = field.frame.width
    let room = try nameRow("song.flac", in: list).cell.textField?.frame.width ?? 0

    try fixture.type("a longer name for the song")

    #expect(field.frame.width > start)
    // The move into the clip view's coordinates leaves the width a hair off whole points.
    #expect(abs(field.frame.width - fixture.field.fittingWidth) < 0.001)
    #expect(field.frame.width < room)

    try fixture.type(String(repeating: "much longer ", count: 40))

    #expect(field.frame.width == room)
}

/// Finder keeps the selected row in the accent color while its name is edited, in its box;
/// the table no longer has the keys, so AppKit alone would draw the row grey.
@MainActor @Test func theRowStaysEmphasizedWhileItsNameIsEdited() async throws {
    let fixture = try await Fixture("song.flac", "other.txt")
    defer { fixture.stop() }
    await fixture.select("song.flac")
    let list = fixture.controller.listingViewController

    try fixture.press(returnKey)

    let (rowView, _) = try nameRow("song.flac", in: list)
    #expect(rowView.isSelected)
    #expect(rowView.isEmphasized)
    #expect(rowView.interiorBackgroundStyle == .emphasized)
    let other = try nameRow("other.txt", in: list).row
    #expect(other.interiorBackgroundStyle == .normal)
}

@MainActor @Test func aColumnsRowStaysEmphasizedWhileItsNameIsEdited() async throws {
    let fixture = try await Fixture("song.flac")
    defer { fixture.stop() }
    let column = try await showColumns(fixture)
    await fixture.select("song.flac")

    try fixture.press(returnKey)

    let (rowView, _) = try nameRow("song.flac", in: column)
    #expect(rowView.isEmphasized)
}

/// In a window that isn't key the row is drawn grey, as AppKit draws a selection there; it
/// turns back when the window is key again. The name in its box keeps the label color.
@MainActor @Test func theRowIsNotEmphasizedWhileTheWindowIsNotKey() async throws {
    let fixture = try await Fixture("song.flac")
    defer { fixture.stop() }
    await fixture.select("song.flac")
    let list = fixture.controller.listingViewController
    try fixture.press(returnKey)
    let rowView = try nameRow("song.flac", in: list).row

    fixture.window.isKey = false
    NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: fixture.window)

    #expect(!rowView.isEmphasized)
    #expect(fixture.field.field.textColor == .labelColor)

    fixture.window.isKey = true
    NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: fixture.window)

    #expect(rowView.isEmphasized)
    #expect(fixture.field.field.textColor == .labelColor)
}

/// The row lets AppKit's emphasis back once the field closes.
@MainActor @Test func theRowKeepsNoEmphasisOnceTheFieldCloses() async throws {
    let fixture = try await Fixture("song.flac")
    defer { fixture.stop() }
    await fixture.select("song.flac")
    let list = fixture.controller.listingViewController
    try fixture.press(returnKey)
    let rowView = try nameRow("song.flac", in: list).row
    #expect(rowView.isEmphasized)

    try fixture.send(#selector(NSResponder.cancelOperation(_:)))

    // A window that is never shown draws no table's selection emphasized, key or not.
    #expect(!rowView.isEmphasized)
    #expect(!list.tableView.keepsSelectionEmphasized)
}

/// Undo in the field undoes only this rename's typing: one closed by Esc or Return leaves
/// nothing for the next to undo.
@MainActor @Test(arguments: [false, true])
func eachRenameStartsWithNothingToUndo(closingByReturn: Bool) async throws {
    let fixture = try await Fixture("song.flac", "other.txt")
    defer { fixture.stop() }
    await fixture.select("song.flac")
    try fixture.press(returnKey)
    try fixture.type("zz")
    #expect(try fixture.editor().undoManager?.canUndo == true)
    if closingByReturn {
        try fixture.send(#selector(NSResponder.insertNewline(_:)))
        await settle { fixture.exists("zz.flac") && !fixture.field.isShown }
    } else {
        try fixture.send(#selector(NSResponder.cancelOperation(_:)))
    }

    await fixture.select("other.txt")
    try fixture.press(returnKey)

    let editor = try fixture.editor()
    #expect(editor.undoManager?.canUndo == false)
    editor.undoManager?.undo()
    #expect(editor.string == "other.txt")
}

/// Pasted styled text takes the field's font and color, as typed text does.
@MainActor @Test func pastedStyledTextTakesTheFieldsLook() async throws {
    let fixture = try await Fixture("song.flac")
    defer { fixture.stop() }
    await fixture.select("song.flac")
    try fixture.press(returnKey)
    let editor = try fixture.editor()
    let styled = NSAttributedString(
        string: "big",
        attributes: [.font: NSFont.boldSystemFont(ofSize: 30), .foregroundColor: NSColor.red])
    let pasteboard = NSPasteboard(name: NSPasteboard.Name("RN1-RenameFieldControllerTests"))
    defer { pasteboard.releaseGlobally() }
    pasteboard.clearContents()
    pasteboard.writeObjects([styled])

    #expect(editor.readSelection(from: pasteboard))

    #expect(editor.string == "big.flac")
    let attributes = editor.textStorage?.attributes(at: 0, effectiveRange: nil) ?? [:]
    #expect(attributes[.font] as? NSFont == ListingViewController.nameFont)
    #expect(attributes[.foregroundColor] as? NSColor == .labelColor)
}

/// The field edits in an editor of its own, apart from the window's, which every other text
/// field in it uses.
@MainActor @Test func theFieldEditsInAnEditorOfItsOwn() async throws {
    let fixture = try await Fixture("song.flac")
    defer { fixture.stop() }
    await fixture.select("song.flac")

    try fixture.press(returnKey)

    let shared = fixture.window.fieldEditor(true, for: nil)
    #expect(try fixture.editor() !== shared)
}

@MainActor @Test func aFolderNameIsSelectedWhole() async throws {
    let fixture = try await Fixture()
    defer { fixture.stop() }
    try FileManager.default.createDirectory(
        at: fixture.folder.url.appending(path: "Stuff.txt"), withIntermediateDirectories: false)
    await settle { fixture.pane.state.listing?.row(named: "Stuff.txt") != nil }
    await fixture.select("Stuff.txt")

    try fixture.press(returnKey)

    #expect(try fixture.editor().selectedRange == NSRange(location: 0, length: 9))
}

@MainActor @Test func typingAndReturnRenamesOnceAndTheSelectionFollowsTheNewName() async throws {
    let fixture = try await Fixture("song.flac", "other.txt")
    defer { fixture.stop() }
    await fixture.select("song.flac")
    try fixture.press(returnKey)
    let row = try #require(fixture.pane.state.listing?.row(named: "song.flac"))
    let fieldFrame = fixture.field.field.frame

    try fixture.type("tune")
    try fixture.send(#selector(NSResponder.insertNewline(_:)))

    // The field holds the new name over the old row until the monitor lists the renamed entry.
    #expect(fixture.field.field.stringValue == "tune.flac")
    #expect(!fixture.field.field.isHidden)
    #expect(fixture.field.field.frame.origin == fieldFrame.origin)
    #expect(fixture.pane.state.listing?.row(named: "song.flac") == row)
    await settle { fixture.exists("tune.flac") && !fixture.exists("song.flac") }
    await settle { fixture.selectedNames == ["tune.flac"] }
    await settle { !fixture.field.isShown }
    #expect(fixture.operationCount == 1)
    #expect(fixture.window.firstResponder === fixture.controller.keyView)
}

/// The rename the field commits is tagged with the workspace of the window its list is in, so
/// that window's operations panel lists it.
@MainActor @Test func aCommittedRenameCarriesTheListsWorkspace() async throws {
    let fixture = try await Fixture("song.flac")
    defer { fixture.stop() }
    let workspace = UUID()
    fixture.controller.listingViewController.workspaceID = workspace
    await fixture.select("song.flac")
    try fixture.press(returnKey)

    try fixture.type("tune")
    try fixture.send(#selector(NSResponder.insertNewline(_:)))

    await settle { fixture.exists("tune.flac") && !fixture.snapshots.all.isEmpty }
    #expect(fixture.snapshots.all.allSatisfy { $0.workspace == workspace })
}

@MainActor @Test func anInvalidNameShowsWhyAndKeepsTheFieldOpen() async throws {
    let fixture = try await Fixture("song.flac")
    defer { fixture.stop() }
    await fixture.select("song.flac")
    try fixture.press(returnKey)

    try fixture.type("a:b")
    try fixture.send(#selector(NSResponder.insertNewline(_:)))

    #expect(fixture.field.message == RenameFieldController.message(for: .colon))
    #expect(fixture.field.isEditing)
    _ = try fixture.editor()
    try await Task.sleep(for: .milliseconds(100))
    #expect(fixture.operationCount == 0)
    #expect(fixture.exists("song.flac"))

    // Typing again clears the message.
    try fixture.type("c")
    #expect(fixture.field.message == nil)
}

@MainActor @Test func anExistingNameIsRefusedWithAMessage() async throws {
    let fixture = try await Fixture("song.flac", "other.flac")
    defer { fixture.stop() }
    await fixture.select("song.flac")
    try fixture.press(returnKey)

    try fixture.type("other")
    try fixture.send(#selector(NSResponder.insertNewline(_:)))

    await settle { fixture.field.message != nil }
    #expect(
        fixture.field.message == "The name “other.flac” is already taken. Choose another one.")
    #expect(fixture.field.isEditing)
    #expect(fixture.field.field.stringValue == "other.flac")
    _ = try fixture.editor()
    #expect(fixture.exists("song.flac") && fixture.exists("other.flac"))
    #expect(fixture.operationCount == 1)
}

@MainActor @Test func escIssuesNothingAndGivesTheKeysBack() async throws {
    let fixture = try await Fixture("song.flac")
    defer { fixture.stop() }
    await fixture.select("song.flac")
    try fixture.press(returnKey)

    try fixture.type("tune")
    try fixture.send(#selector(NSResponder.cancelOperation(_:)))

    #expect(!fixture.field.isShown)
    #expect(fixture.window.firstResponder === fixture.controller.keyView)
    try await Task.sleep(for: .milliseconds(100))
    #expect(fixture.operationCount == 0)
    #expect(fixture.exists("song.flac"))
    #expect(await fixture.settledSelectedNames() == ["song.flac"])
}

@MainActor @Test func typeToSelectDoesNotFireWhileTheFieldIsOpen() async throws {
    let fixture = try await Fixture("song.flac", "other.txt")
    defer { fixture.stop() }
    await fixture.select("song.flac")
    let list = fixture.controller.listingViewController.tableView
    try fixture.press(returnKey)

    try fixture.editor().keyDown(with: try keyEvent("o"))

    #expect(list.typeSelect.query == "")
    #expect(await fixture.settledSelectedNames() == ["song.flac"])
    #expect(fixture.field.field.stringValue == "o.flac")
}

@MainActor @Test func newFolderEntersRenameOnTheNewRow() async throws {
    let fixture = try await Fixture("song.flac")
    defer { fixture.stop() }

    try fixture.press("N", [.command, .shift])

    await settle { fixture.field.isEditing }
    #expect(await fixture.settledSelectedNames() == ["untitled folder"])
    #expect(fixture.field.field.stringValue == "untitled folder")
    #expect(try fixture.editor().selectedRange == NSRange(location: 0, length: 15))
}

@MainActor @Test func selectingSomethingElseBeforeTheNewFolderShowsEntersNoRename() async throws {
    let fixture = try await Fixture("song.flac")
    defer { fixture.stop() }

    try fixture.press("N", [.command, .shift])
    await fixture.select("song.flac")

    await settle { fixture.exists("untitled folder") }
    await settle { fixture.pane.state.listing?.row(named: "untitled folder") != nil }
    try await Task.sleep(for: .milliseconds(100))
    #expect(!fixture.field.isShown)
    #expect(await fixture.settledSelectedNames() == ["song.flac"])
}

@MainActor @Test func renameWorksInTheFocusedColumn() async throws {
    let fixture = try await Fixture("song.flac")
    defer { fixture.stop() }
    try fixture.press("3", .command)
    let pane = fixture.pane
    // Only the focused column matters. The ancestors include the real temporary directory, which
    // can hold tens of thousands of entries and list for longer than a settle waits.
    await settle {
        guard let focused = pane.columnTrail?.focused.pane else { return false }
        return focused.state.isLoaded && focused.monitor != nil
    }
    let column = try #require(fixture.controller.columnViewController.focusedController)
    #expect(fixture.window.firstResponder === column.tableView)
    fixture.useQueue(in: column.tableView)
    await fixture.select("song.flac")

    try fixture.press(returnKey)
    #expect(column.renameField.isEditing)
    #expect(!fixture.controller.listingViewController.renameField.isShown)
    let editor = try fixture.editor(of: column.renameField)
    editor.insertText("tune", replacementRange: NSRange(location: NSNotFound, length: 0))
    #expect(
        column.renameField.control(
            column.renameField.field, textView: editor,
            doCommandBy: #selector(NSResponder.insertNewline(_:))))

    await settle { fixture.exists("tune.flac") }
    await settle { fixture.selectedNames == ["tune.flac"] }
}

/// Switches the fixture's pane to column mode and waits for the focused column to list and be
/// watched, its table with the keys running commands with the fixture's queue. Returns the
/// focused column's controller.
@MainActor
private func showColumns(_ fixture: Fixture) async throws -> ListingViewController {
    try fixture.press("3", .command)
    let pane = fixture.pane
    // Only the focused column matters. The ancestors include the real temporary directory, which
    // can hold tens of thousands of entries and list for longer than a settle waits.
    await settle {
        guard let focused = pane.columnTrail?.focused.pane else { return false }
        return focused.state.isLoaded && focused.monitor != nil
    }
    let column = try #require(fixture.controller.columnViewController.focusedController)
    #expect(fixture.window.firstResponder === column.tableView)
    fixture.useQueue(in: column.tableView)
    return column
}

/// New Folder opens the field in a column too, and the change that lists the folder, or the
/// new folder's own column opening, doesn't take the keys back to the table.
@MainActor @Test func newFolderEntersRenameInTheFocusedColumn() async throws {
    let fixture = try await Fixture("song.flac")
    defer { fixture.stop() }
    let column = try await showColumns(fixture)
    await fixture.select("song.flac")

    try fixture.press("N", [.command, .shift])

    await settle { fixture.selectedNames == ["untitled folder"] }
    #expect(column.renameField.isEditing)
    let trail = try #require(fixture.pane.columnTrail)
    await settle { trail.columns.last?.pane.location.name == "untitled folder" }
    await settle { trail.columns.last?.pane.state.isLoaded == true }
    #expect(column.renameField.isEditing)
    #expect(column.renameField.field.stringValue == "untitled folder")
    #expect(try fixture.editor(of: column.renameField).selectedRange.length == 15)
}

/// With a folder selected in the focused column, New Folder makes the folder in it and opens
/// the field in that folder's column, which takes the keys, as Finder's column view does.
@MainActor @Test func newFolderWithAFolderSelectedEntersRenameInThatFoldersColumn()
    async throws
{
    let fixture = try await Fixture("song.flac")
    defer { fixture.stop() }
    try FileManager.default.createDirectory(
        at: fixture.folder.url.appending(path: "_test"), withIntermediateDirectories: false)
    await settle { fixture.pane.state.listing?.row(named: "_test") != nil }
    _ = try await showColumns(fixture)
    let trail = try #require(fixture.pane.columnTrail)
    await fixture.select("_test")
    await settle {
        guard let last = trail.columns.last?.pane else { return false }
        return last.location.name == "_test" && last.state.isLoaded && last.monitor != nil
    }
    let inner = try #require(trail.columns.last?.pane)

    try fixture.press("N", [.command, .shift])

    await settle {
        fixture.pane.commandPane === inner && fixture.selectedNames == ["untitled folder"]
    }
    #expect(fixture.exists("_test/untitled folder"))
    #expect(!fixture.exists("untitled folder"))
    let column = try #require(fixture.controller.columnViewController.focusedController)
    #expect(column.pane === inner)
    #expect(column.renameField.isEditing)
    #expect(try fixture.editor(of: column.renameField).selectedRange.length == 15)
}

/// A switch to the list while a column's name field has the keys gives them to the list's
/// table: the field keeps the keys only while its column is the focused one shown.
@MainActor @Test func switchingToTheListWithAColumnsFieldOpenGivesTheListTheKeys() async throws {
    let fixture = try await Fixture("song.flac")
    defer { fixture.stop() }
    let column = try await showColumns(fixture)
    await fixture.select("song.flac")
    try fixture.press(returnKey)
    #expect(column.renameField.isEditing)

    fixture.pane.setViewMode(.list)

    #expect(fixture.pane.viewMode == .list)
    #expect(fixture.window.firstResponder === fixture.controller.listingViewController.tableView)
    #expect(!column.renameField.isEditing)
    #expect(fixture.operationCount == 0)

    fixture.pane.setViewMode(.column)
    let focused = try #require(fixture.controller.columnViewController.focusedController)
    #expect(fixture.window.firstResponder === focused.tableView)
}

@MainActor @Test func returnOnTheUnchangedNameClosesTheFieldWithNothingQueued() async throws {
    let fixture = try await Fixture("song.flac")
    defer { fixture.stop() }
    await fixture.select("song.flac")
    try fixture.press(returnKey)

    try fixture.send(#selector(NSResponder.insertNewline(_:)))

    #expect(!fixture.field.isShown)
    #expect(fixture.window.firstResponder === fixture.controller.keyView)
    try await Task.sleep(for: .milliseconds(100))
    #expect(fixture.operationCount == 0)
}

/// A New Folder that makes nothing leaves nothing waiting: a name that shows up and is
/// selected alone afterwards doesn't open the field.
@MainActor @Test func aFailedNewFolderEntersNoRenameLater() async throws {
    let fixture = try await Fixture("song.flac")
    defer { fixture.stop() }
    let path = fixture.folder.url.path
    #expect(chmod(path, 0o555) == 0)
    defer { chmod(path, 0o755) }

    try fixture.press("N", [.command, .shift])
    #expect(await fixture.snapshots.wait { $0.contains { $0.state.phase == .failed } })
    #expect(chmod(path, 0o755) == 0)
    try Data().write(to: fixture.folder.url.appending(path: "new.txt"))
    await settle { fixture.pane.state.listing?.row(named: "new.txt") != nil }
    await fixture.select("new.txt")

    try await Task.sleep(for: .milliseconds(100))
    #expect(!fixture.field.isShown)
}

/// With no monitor the old name stays listed; after the timeout the pane lists the folder
/// again, which drops it, and the field closes.
@MainActor @Test func theFieldStopsWaitingForAPatchThatNeverComes() async throws {
    let fixture = try await Fixture("song.flac", monitors: false)
    defer { fixture.stop() }
    let clock = ManualClock()
    fixture.field.startWait = RenameFieldController.waiter(on: clock)
    await fixture.select("song.flac")
    try fixture.press(returnKey)
    try fixture.type("tune")
    try fixture.send(#selector(NSResponder.insertNewline(_:)))
    await settle { fixture.exists("tune.flac") }
    try await Task.sleep(for: .milliseconds(100))
    #expect(fixture.field.isShown)
    #expect(fixture.pane.state.listing?.row(named: "song.flac") != nil)

    clock.advance(by: RenameFieldController.patchTimeout)

    await settle { !fixture.field.isShown }
    #expect(fixture.pane.state.listing?.row(named: "tune.flac") != nil)
}

/// Lists the folder from the file system once, then holds every later call until `release`, as
/// a volume that stopped answering after the first listing.
private final class FirstListingOnly: Lister, @unchecked Sendable {
    let calls = EventLog<String>()
    private let gate = DispatchSemaphore(value: 0)

    func list(_ path: String, onBatch: ([DirectoryEntry]) throws -> Void) throws {
        calls.append(path)
        if calls.all.count > 1 {
            gate.wait()
        }
        try DirectoryLister().list(path, onBatch: onBatch)
    }

    /// Lets the held call go ahead.
    func release() {
        gate.signal()
    }
}

/// After a relist the field closes when the second wait ends, even with no listing landing.
@MainActor @Test func theFieldClosesWhenTheRelistDoesNotLand() async throws {
    let lister = FirstListingOnly()
    let fixture = try await Fixture("song.flac", monitors: false, lister: lister)
    defer {
        fixture.stop()
        lister.release()
    }
    let clock = ManualClock()
    fixture.field.startWait = RenameFieldController.waiter(on: clock)
    await fixture.select("song.flac")
    try fixture.press(returnKey)
    try fixture.type("tune")
    try fixture.send(#selector(NSResponder.insertNewline(_:)))
    await settle { fixture.exists("tune.flac") }
    try await Task.sleep(for: .milliseconds(100))
    #expect(fixture.field.isShown)

    clock.advance(by: RenameFieldController.patchTimeout)
    #expect(await lister.calls.wait { $0.count == 2 })
    try await Task.sleep(for: .milliseconds(100))
    #expect(fixture.field.isShown)
    clock.advance(by: RenameFieldController.patchTimeout)

    await settle { !fixture.field.isShown }
    #expect(fixture.pane.state.listing?.row(named: "song.flac") != nil)
}

// MARK: The keys moving elsewhere

extension Fixture {
    /// Gives the keys to another text field in the window, as a click on it does, and returns
    /// that field.
    @discardableResult
    func clickElsewhere() -> NSTextField {
        let other = NSTextField(frame: NSRect(x: 0, y: 0, width: 100, height: 20))
        window.contentView?.addSubview(other)
        #expect(window.makeFirstResponder(other))
        return other
    }

    /// Whether `other`'s editor has the keys.
    func hasKeys(_ other: NSTextField) -> Bool {
        (window.firstResponder as? NSTextView)?.delegate === other
    }

    /// Whether the rename field's editor has the keys.
    var fieldHasKeys: Bool {
        (window.firstResponder as? NSTextView)?.delegate === field.field
    }

    /// Tells the field its editing ended, as the window does at the moment the keys leave it:
    /// the field's editor still has them and the view they go to hasn't taken them yet. A move
    /// to the table here shows, where a full hand-off to another view would replace it.
    func endEditingAsTheKeysLeave() {
        field.controlTextDidEndEditing(
            Notification(name: NSControl.textDidEndEditingNotification, object: field.field))
    }

    var tableHasKeys: Bool { window.firstResponder is ListingTableView }
}

@MainActor @Test func aRenameOnFocusLossLeavesTheKeysForTheViewTakingThem() async throws {
    let fixture = try await Fixture("song.flac")
    defer { fixture.stop() }
    await fixture.select("song.flac")
    try fixture.press(returnKey)
    try fixture.type("tune")

    fixture.endEditingAsTheKeysLeave()

    #expect(!fixture.tableHasKeys)
    #expect(fixture.fieldHasKeys)
    await settle { fixture.exists("tune.flac") && !fixture.exists("song.flac") }
}

@MainActor @Test func anEmptiedNameOnFocusLossLeavesTheKeysForTheViewTakingThem() async throws {
    let fixture = try await Fixture("song.flac")
    defer { fixture.stop() }
    await fixture.select("song.flac")
    try fixture.press(returnKey)
    let editor = try fixture.editor()
    editor.selectAll(nil)
    editor.deleteBackward(nil)

    fixture.endEditingAsTheKeysLeave()

    #expect(!fixture.field.isShown)
    #expect(!fixture.tableHasKeys)
}

/// The click that moves the keys can also take the pane to another folder before the rename
/// starts; the entry of that name there must not be renamed.
@MainActor @Test func aClickThatAlsoChangesFolderRenamesNothing() async throws {
    let fixture = try await Fixture("song.flac")
    defer { fixture.stop() }
    let sub = fixture.folder.url.appending(path: "sub")
    try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: false)
    try Data().write(to: sub.appending(path: "song.flac"))
    await settle { fixture.pane.state.listing?.row(named: "sub") != nil }
    await fixture.select("song.flac")
    try fixture.press(returnKey)
    try fixture.type("tune")

    fixture.clickElsewhere()
    fixture.pane.navigate(to: fixture.pane.location.child(named: "sub"))

    try await Task.sleep(for: .milliseconds(200))
    #expect(fixture.exists("song.flac"))
    #expect(fixture.exists("sub/song.flac"))
    #expect(!fixture.exists("sub/tune.flac"))
    #expect(!fixture.exists("tune.flac"))
    #expect(fixture.operationCount == 0)
}

@MainActor @Test func clickingElsewhereRenamesAndLeavesTheKeysWhereTheyWent() async throws {
    let fixture = try await Fixture("song.flac", "other.txt")
    defer { fixture.stop() }
    await fixture.select("song.flac")
    try fixture.press(returnKey)
    try fixture.type("tune")

    let other = fixture.clickElsewhere()

    #expect(fixture.hasKeys(other))
    #expect(!fixture.field.isEditing)
    await settle { fixture.exists("tune.flac") && !fixture.exists("song.flac") }
    await settle { !fixture.field.isShown }
    #expect(fixture.hasKeys(other))
    #expect(fixture.operationCount == 1)
}

@MainActor @Test func tabRenames() async throws {
    let fixture = try await Fixture("song.flac")
    defer { fixture.stop() }
    await fixture.select("song.flac")
    try fixture.press(returnKey)
    try fixture.type("tune")

    try fixture.editor().doCommand(by: #selector(NSResponder.insertTab(_:)))

    await settle { fixture.exists("tune.flac") && !fixture.exists("song.flac") }
    #expect(fixture.operationCount == 1)
}

/// Finder shows why in an alert and then edits the name again; the field shows why under
/// itself and takes the keys back.
@MainActor @Test func clickingElsewhereWithATakenNameTakesTheKeysBackAndShowsWhy() async throws {
    let fixture = try await Fixture("song.flac", "other.flac")
    defer { fixture.stop() }
    await fixture.select("song.flac")
    try fixture.press(returnKey)
    try fixture.type("other")

    fixture.clickElsewhere()

    await settle { fixture.field.message != nil }
    #expect(
        fixture.field.message == "The name “other.flac” is already taken. Choose another one.")
    #expect(fixture.field.isEditing)
    #expect(fixture.fieldHasKeys)
    #expect(fixture.field.field.stringValue == "other.flac")
    #expect(fixture.exists("song.flac") && fixture.exists("other.flac"))
}

@MainActor @Test func clickingElsewhereWithAnInvalidNameTakesTheKeysBackAndShowsWhy() async throws {
    let fixture = try await Fixture("song.flac")
    defer { fixture.stop() }
    await fixture.select("song.flac")
    try fixture.press(returnKey)
    try fixture.type("a:b")

    fixture.clickElsewhere()

    await settle { fixture.fieldHasKeys }
    #expect(fixture.field.message == RenameFieldController.message(for: .colon))
    #expect(fixture.field.isEditing)
    #expect(fixture.field.field.stringValue == "a:b.flac")
    try await Task.sleep(for: .milliseconds(100))
    #expect(fixture.operationCount == 0)
    #expect(fixture.exists("song.flac"))
}

/// As in Finder, an emptied name puts the old one back.
@MainActor @Test func clickingElsewhereWithAnEmptyNameKeepsTheOldName() async throws {
    let fixture = try await Fixture("song.flac")
    defer { fixture.stop() }
    await fixture.select("song.flac")
    try fixture.press(returnKey)
    let editor = try fixture.editor()
    editor.selectAll(nil)
    editor.deleteBackward(nil)
    #expect(editor.string.isEmpty)

    let other = fixture.clickElsewhere()

    #expect(!fixture.field.isShown)
    #expect(fixture.field.message == nil)
    try await Task.sleep(for: .milliseconds(100))
    #expect(fixture.hasKeys(other))
    #expect(fixture.operationCount == 0)
    #expect(fixture.exists("song.flac"))
}

@MainActor @Test func clickingElsewhereWithTheNameUnchangedClosesTheField() async throws {
    let fixture = try await Fixture("song.flac")
    defer { fixture.stop() }
    await fixture.select("song.flac")
    try fixture.press(returnKey)

    let other = fixture.clickElsewhere()

    #expect(!fixture.field.isShown)
    #expect(fixture.hasKeys(other))
    try await Task.sleep(for: .milliseconds(100))
    #expect(fixture.operationCount == 0)
}

@MainActor @Test func returnWhileTheRenameWaitsForItsRowStartsNoSecondRename() async throws {
    let fixture = try await Fixture("song.flac", monitors: false)
    defer { fixture.stop() }
    fixture.field.startWait = RenameFieldController.waiter(on: ManualClock())
    await fixture.select("song.flac")
    try fixture.press(returnKey)
    try fixture.type("tune")
    try fixture.send(#selector(NSResponder.insertNewline(_:)))
    #expect(fixture.window.firstResponder === fixture.controller.keyView)

    try fixture.press(returnKey)
    #expect(!fixture.field.isEditing)
    await settle { fixture.exists("tune.flac") }
    try await Task.sleep(for: .milliseconds(100))
    try fixture.press(returnKey)

    #expect(!fixture.field.isEditing)
    #expect(fixture.field.field.stringValue == "tune.flac")
    #expect(fixture.window.firstResponder === fixture.controller.keyView)
    #expect(fixture.operationCount == 1)
}

/// Waits, with no monitor, until the rename of song.flac to tune.flac is done and the field
/// shows the new name over the old row.
@MainActor
private func renameAndWait(_ fixture: Fixture) async throws {
    fixture.field.startWait = RenameFieldController.waiter(on: ManualClock())
    await fixture.select("song.flac")
    try fixture.press(returnKey)
    try fixture.type("tune")
    try fixture.send(#selector(NSResponder.insertNewline(_:)))
    await settle { fixture.exists("tune.flac") }
    try await Task.sleep(for: .milliseconds(100))
    #expect(fixture.field.isShown)
}

@MainActor @Test func leavingTheFolderWhileTheFieldWaitsClosesIt() async throws {
    let fixture = try await Fixture("song.flac", monitors: false)
    defer { fixture.stop() }
    try await renameAndWait(fixture)
    let parent = try #require(fixture.pane.location.parent)

    fixture.pane.navigate(to: parent)

    #expect(!fixture.field.isShown)
}

@MainActor @Test func switchingToColumnsWhileTheFieldWaitsClosesIt() async throws {
    let fixture = try await Fixture("song.flac", monitors: false)
    defer { fixture.stop() }
    try await renameAndWait(fixture)

    try fixture.press("3", .command)

    #expect(fixture.pane.viewMode == .column)
    #expect(!fixture.field.isShown)
}

/// Cmd-Z in the name field undoes its typing, through the Edit menu's Undo as the key reaches
/// it, and queues no undo of the file rename the history holds.
@MainActor @Test func cmdZInTheNameFieldUndoesTypingAndNoFileChange() async throws {
    let fixture = try await Fixture("a.txt")
    defer { fixture.stop() }
    let root = fixture.folder.url.path
    _ = await fixture.queue.perform(.rename(root + "/a.txt", to: "b.txt"))
    await fixture.history.catchUp(with: fixture.queue)
    #expect(fixture.history.canUndo)
    await settle { fixture.pane.state.listing?.row(named: "b.txt") != nil }
    await fixture.select("b.txt")
    try fixture.press(returnKey)
    try fixture.type("zzz")
    let editor = try fixture.editor()
    #expect(editor.string == "zzz.txt")
    let operations = fixture.operationCount

    // The item Cmd-Z picks in the menu bar, and the responder its action reaches from the
    // window's first responder.
    let menu = try MainMenuBuilder.build(appName: "Searcher", registry: AppCommands.registry())
    let edit = try #require(menu.items.first { $0.title == "Edit" }?.submenu)
    let undo = try #require(
        edit.items.first { $0.keyEquivalent == "z" && $0.keyEquivalentModifierMask == .command })
    let action = try #require(undo.action)
    let taker = responder(for: action, from: fixture.window.firstResponder)
    // The field editor's typing is in its window's undo manager, which the window's undo:
    // runs; the list's table, which would undo a file change, isn't in the chain.
    #expect(taker === fixture.window, "\(String(describing: taker))")
    #expect(NSApplication.shared.sendAction(action, to: taker, from: undo))

    #expect(editor.string == "b.txt")
    try await Task.sleep(for: .milliseconds(100))
    #expect(fixture.operationCount == operations)
    #expect(fixture.exists("b.txt"))
    #expect(fixture.history.canUndo)
}

/// The first responder from `first` up the chain that answers `action`.
@MainActor
private func responder(for action: Selector, from first: NSResponder?) -> NSResponder? {
    var responder = first
    while let current = responder {
        if current.responds(to: action) { return current }
        responder = current.nextResponder
    }
    return nil
}
