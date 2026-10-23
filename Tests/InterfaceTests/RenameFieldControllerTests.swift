import AppKit
import Base
import Browser
import Foundation
import TestSupport
import Testing

@testable import Interface

/// A pane over a real temporary folder in a window that is never shown, its list's table with the
/// keys, and a queue of its own. The app has no queue for the pane's context to pass yet, so the
/// tables run the file commands with a context that has this one, and Rename starts the field
/// as the pane's own context does.
@MainActor
private final class Fixture {
    let folder: TemporaryFolder
    let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 800, height: 400), styleMask: [.titled],
        backing: .buffered, defer: true)
    let pane: Pane
    let controller: PaneViewController
    let queue: FileOperationQueue
    /// Every snapshot the queue reported, so a test can count the operations it was given.
    let snapshots = EventLog<FileOperationQueue.Snapshot>()

    init(_ names: String...) async throws {
        folder = try TemporaryFolder("RenameFieldControllerTests")
        for name in names {
            try Data(name.utf8).write(to: folder.url.appending(path: name))
        }
        pane = Pane(
            location: Location(path: folder.url.path), service: ListingService(),
            systemActions: StubSystemActions(), settings: untouchedSettings(), isFocused: true)
        controller = PaneViewController(
            pane: pane, iconCache: TypeIconCache { _ in NSImage() }, formatter: .init(),
            tableView: ListingTableView(), monitorsFolders: true)
        let snapshots = snapshots
        queue = FileOperationQueue(
            prompts: FileOperationQueue.Prompts(
                resolve: { request in preconditionFailure("a rename asked \(request)") },
                confirm: { request in preconditionFailure("a rename asked \(request)") })
        ) { reported in
            for snapshot in reported { snapshots.append(snapshot) }
        }
        window.isReleasedWhenClosed = false
        controller.view.frame = NSRect(x: 0, y: 0, width: 800, height: 400)
        window.contentView?.addSubview(controller.view)
        let pane = pane
        await settle { pane.state.isLoaded && pane.monitor != nil }
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
                    editName: { [unowned self] in controller.editName(queue: queue) }))
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
    #expect(fixture.field.field.frame == fieldFrame)
    #expect(fixture.pane.state.listing?.row(named: "song.flac") == row)
    await settle { fixture.exists("tune.flac") && !fixture.exists("song.flac") }
    await settle { fixture.selectedNames == ["tune.flac"] }
    await settle { !fixture.field.isShown }
    #expect(fixture.operationCount == 1)
    #expect(fixture.window.firstResponder === fixture.controller.keyView)
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
    #expect(fixture.field.message == "The name “other.flac” is already taken. Choose another one.")
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
    #expect(fixture.selectedNames == ["song.flac"])
}

@MainActor @Test func typeToSelectDoesNotFireWhileTheFieldIsOpen() async throws {
    let fixture = try await Fixture("song.flac", "other.txt")
    defer { fixture.stop() }
    await fixture.select("song.flac")
    let list = fixture.controller.listingViewController.tableView
    try fixture.press(returnKey)

    try fixture.editor().keyDown(with: try keyEvent("o"))

    #expect(list.typeSelect.query == "")
    #expect(fixture.selectedNames == ["song.flac"])
    #expect(fixture.field.field.stringValue == "o.flac")
}

@MainActor @Test func newFolderEntersRenameOnTheNewRow() async throws {
    let fixture = try await Fixture("song.flac")
    defer { fixture.stop() }

    try fixture.press("N", [.command, .shift])

    await settle { fixture.field.isEditing }
    #expect(fixture.selectedNames == ["untitled folder"])
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
    #expect(fixture.selectedNames == ["song.flac"])
}

@MainActor @Test func renameWorksInTheFocusedColumn() async throws {
    let fixture = try await Fixture("song.flac")
    defer { fixture.stop() }
    try fixture.press("3", .command)
    let pane = fixture.pane
    await settle {
        pane.columnTrail?.columns.allSatisfy { $0.pane.state.isLoaded && $0.pane.monitor != nil }
            ?? false
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
