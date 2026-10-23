import Base
import Darwin
import Foundation
import TestSupport
import Testing

@testable import Browser

private let undoChord = KeyChord("z", modifiers: .command)
private let redoChord = KeyChord("z", modifiers: [.command, .shift])

/// A queue over the real file system, whose questions `prompter` answers, and the history it
/// feeds, as the app's windows feed theirs.
@MainActor
private final class Harness {
    let prompter = Prompter()
    let queue: FileOperationQueue
    let history = UndoHistory()

    init() {
        queue = FileOperationQueue(
            fileSystem: .real, prompts: prompter.prompts, clock: ContinuousClock()
        ) { _ in }
    }

    /// Runs `operation` and gives its end to the history.
    @discardableResult
    func perform(_ operation: FileOperation) async -> OperationState {
        let state = await queue.perform(operation)
        history.record(operation, state)
        return state
    }

    func undo() async throws -> OperationState {
        try await #require(history.undo(with: queue)).value
    }

    func redo() async throws -> OperationState {
        try await #require(history.redo(with: queue)).value
    }
}

private func write(_ text: String, to path: String) throws {
    try Data(text.utf8).write(to: URL(fileURLWithPath: path))
}

private func read(_ path: String) throws -> String {
    try String(contentsOfFile: path, encoding: .utf8)
}

private func exists(_ path: String) -> Bool {
    var info = stat()
    return lstat(path, &info) == 0
}

private func makeFolder(_ path: String) throws {
    try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: false)
}

// MARK: Move and rename

@MainActor @Test func undoMovesItemsBackAndRedoMovesThemAgain() async throws {
    let folder = try TemporaryFolder("UndoHistoryTests")
    let root = folder.url.path
    try makeFolder(root + "/B")
    try write("a", to: root + "/a.txt")
    try write("b", to: root + "/b.txt")
    try write("c", to: root + "/c.txt")
    let harness = Harness()

    await harness.perform(
        .move([root + "/a.txt", root + "/b.txt", root + "/c.txt"], into: root + "/B"))

    #expect(harness.history.undoTitle == "Undo Move 3 Items")
    #expect(harness.history.redoTitle == "Redo")
    let undone = try await harness.undo()
    #expect(undone.phase == .done)
    #expect(try read(root + "/a.txt") == "a")
    #expect(try read(root + "/c.txt") == "c")
    #expect(!exists(root + "/B/a.txt"))
    #expect(harness.history.undoTitle == "Undo")
    #expect(!harness.history.canUndo)
    #expect(harness.history.redoTitle == "Redo Move 3 Items")

    let redone = try await harness.redo()
    #expect(redone.phase == .done)
    #expect(try read(root + "/B/b.txt") == "b")
    #expect(!exists(root + "/b.txt"))
    #expect(harness.history.undoTitle == "Undo Move 3 Items")
    #expect(!harness.history.canRedo)
}

@MainActor @Test func undoRenamesBackAndRedoRenamesAgain() async throws {
    let folder = try TemporaryFolder("UndoHistoryTests")
    let root = folder.url.path
    try write("report", to: root + "/draft.txt")
    let harness = Harness()

    await harness.perform(.rename(root + "/draft.txt", to: "final.txt"))
    #expect(harness.history.undoTitle == "Undo Rename")

    _ = try await harness.undo()
    #expect(try read(root + "/draft.txt") == "report")
    #expect(!exists(root + "/final.txt"))

    _ = try await harness.redo()
    #expect(try read(root + "/final.txt") == "report")
    #expect(!exists(root + "/draft.txt"))
}

/// Undo is app-wide: the last change undoes first, whichever pane or window made it.
@MainActor @Test func undoGoesBackOneChangeAtATimeLastFirst() async throws {
    let folder = try TemporaryFolder("UndoHistoryTests")
    let root = folder.url.path
    try makeFolder(root + "/B")
    try write("a", to: root + "/a.txt")
    let harness = Harness()

    await harness.perform(.move([root + "/a.txt"], into: root + "/B"))
    await harness.perform(.rename(root + "/B/a.txt", to: "z.txt"))
    #expect(harness.history.undoTitle == "Undo Rename")

    _ = try await harness.undo()
    #expect(exists(root + "/B/a.txt"))
    #expect(harness.history.undoTitle == "Undo Move 1 Item")
    _ = try await harness.undo()
    #expect(exists(root + "/a.txt"))
    #expect(harness.history.redoTitle == "Redo Move 1 Item")
}

// MARK: What makes an entry

@MainActor @Test func copiesNewFoldersAndDuplicatesMakeNoEntry() async throws {
    let folder = try TemporaryFolder("UndoHistoryTests")
    let root = folder.url.path
    try makeFolder(root + "/B")
    try write("a", to: root + "/a.txt")
    let harness = Harness()

    #expect(await harness.perform(.copy([root + "/a.txt"], into: root + "/B")).phase == .done)
    #expect(await harness.perform(.newFolder(in: root)).phase == .done)
    #expect(await harness.perform(.duplicate([root + "/a.txt"])).phase == .done)

    #expect(!harness.history.canUndo)
    #expect(harness.history.undoTitle == "Undo")
    #expect(harness.history.undo(with: harness.queue) == nil)
}

@MainActor @Test func aNewOperationClearsRedo() async throws {
    let folder = try TemporaryFolder("UndoHistoryTests")
    let root = folder.url.path
    try makeFolder(root + "/B")
    try write("a", to: root + "/a.txt")
    try write("b", to: root + "/b.txt")
    let harness = Harness()
    await harness.perform(.move([root + "/a.txt"], into: root + "/B"))
    _ = try await harness.undo()
    #expect(harness.history.canRedo)

    await harness.perform(.rename(root + "/b.txt", to: "c.txt"))

    #expect(!harness.history.canRedo)
    #expect(harness.history.redoTitle == "Redo")
    #expect(harness.history.undoTitle == "Undo Rename")
}

@MainActor @Test func aDeleteCantBeUndoneAndHoldsBackEarlierEntries() async throws {
    let folder = try TemporaryFolder("UndoHistoryTests")
    let root = folder.url.path
    try write("a", to: root + "/a.txt")
    try write("b", to: root + "/b.txt")
    let harness = Harness()
    await harness.perform(.rename(root + "/a.txt", to: "c.txt"))

    await harness.perform(.deleteImmediately([root + "/b.txt"]))

    #expect(harness.history.undoTitle == "Can’t Undo Delete")
    #expect(!harness.history.canUndo)
    #expect(harness.history.undo(with: harness.queue) == nil)
    #expect(exists(root + "/c.txt"))
}

// MARK: Checks before undoing

@MainActor @Test func aMovedFileDeletedMeanwhileFailsTheUndoNamingItAndDropsTheEntry()
    async throws
{
    let folder = try TemporaryFolder("UndoHistoryTests")
    let root = folder.url.path
    try makeFolder(root + "/B")
    try write("a", to: root + "/a.txt")
    try write("b", to: root + "/b.txt")
    let harness = Harness()
    await harness.perform(.move([root + "/a.txt", root + "/b.txt"], into: root + "/B"))
    try FileManager.default.removeItem(atPath: root + "/B/a.txt")

    let undone = try await harness.undo()

    #expect(undone.phase == .failed)
    #expect(
        undone.errors == [
            FileOperationError(reason: .sourceGone, path: root + "/B/a.txt", errno: ENOENT)
        ])
    // Nothing is undone when one item isn't where the record says.
    #expect(exists(root + "/B/b.txt"))
    #expect(!exists(root + "/b.txt"))
    #expect(undone.record.changes.isEmpty)
    #expect(!harness.history.canUndo)
    #expect(!harness.history.canRedo)
}

@MainActor @Test func anItemNowAtTheOldPathFailsTheUndoNamingIt() async throws {
    let folder = try TemporaryFolder("UndoHistoryTests")
    let root = folder.url.path
    try write("a", to: root + "/a.txt")
    let harness = Harness()
    await harness.perform(.rename(root + "/a.txt", to: "b.txt"))
    try write("new", to: root + "/a.txt")

    let undone = try await harness.undo()

    #expect(
        undone.errors == [FileOperationError(reason: .exists, path: root + "/a.txt", errno: EEXIST)]
    )
    #expect(try read(root + "/a.txt") == "new")
    #expect(try read(root + "/b.txt") == "a")
}

/// An undo is one more queued operation: it runs beside a copy that holds its lane, rather than
/// waiting for it or holding up the main actor.
@MainActor @Test func anUndoRunsWhileACopyIsStillRunning() async throws {
    let files = FakeFiles()
    let watcher = Watcher()
    let queue = makeQueue(files, watcher)
    let history = UndoHistory()
    files.place("/A/b")
    history.record(
        .rename("/A/a", to: "b"),
        OperationState(
            phase: .done,
            progress: OperationState.Progress(
                itemsDone: 1, itemCount: 1, copied: CopyProgress(bytes: 0, files: 0), total: nil),
            errors: [], record: OperationRecord(changes: [.moved(from: "/A/a", to: "/A/b")])))
    let copy = await enqueue(queue, .copy(["/S/big"], into: "/A"), watcher)
    #expect(await files.events.wait { $0.contains("copy /S/big") })

    let undone = try #require(history.undo(with: queue))
    #expect(!history.canUndo)

    #expect(await undone.value.phase == .done)
    #expect(files.events.all.contains("move /A/b to /A/a"))
    #expect(watcher.state(of: copy) == nil)
    files.releaseAll()
    #expect(await watcher.waitUntilFinished(copy))
}

// MARK: Commands

@MainActor @Test func undoAndRedoAreOnTheirChordsAndOffWithNothingToDo() async throws {
    let registry = try AppCommands.registry()
    #expect(registry.command(for: undoChord) == UndoCommands.undo)
    #expect(registry.command(for: redoChord) == UndoCommands.redo)

    let folder = try TemporaryFolder("UndoHistoryTests")
    let root = folder.url.path
    try write("a", to: root + "/a.txt")
    let harness = Harness()
    let pane = Pane(
        location: Location(path: root), service: ListingService(),
        systemActions: StubSystemActions(), settings: untouchedSettings())
    let context = CommandContext(
        pane: pane, fileOperations: harness.queue, undoHistory: harness.history)
    let undo = try #require(UndoCommands.bindings.first { $0.command == UndoCommands.undo })
    let redo = try #require(UndoCommands.bindings.first { $0.command == UndoCommands.redo })
    #expect(undo.isEnabled?(context) == false)
    #expect(undo.title?(context) == "Undo")

    await harness.perform(.rename(root + "/a.txt", to: "b.txt"))

    #expect(undo.isEnabled?(context) == true)
    #expect(undo.title?(context) == "Undo Rename")
    #expect(undo.isEnabled?(CommandContext(pane: pane, fileOperations: harness.queue)) == false)
    undo.run(context)
    // The entry leaves at once; Redo has it once the undo has run.
    #expect(undo.title?(context) == "Undo")
    await settle { redo.isEnabled?(context) == true }
    #expect(redo.title?(context) == "Redo Rename")
    #expect(exists(root + "/a.txt"))
}

// MARK: Trash and replace on a volume

/// Trashes only files the test makes on a disk image, so nothing reaches the user's Trash.
@MainActor @Suite(.serialized) struct UndoHistoryDiskImageTests {
    @Test func undoingATrashBringsTheFileBackFromItsTrashURL() async throws {
        let image = try await DiskImage("UndoHistoryTests")
        let file = image.mountPoint + "/report.txt"
        try write("report", to: file)
        let harness = Harness()

        let trashed = await harness.perform(.trash([file]))
        guard case .trashed(_, let url) = trashed.record.changes.first else {
            Issue.record("the trash recorded \(trashed.record.changes)")
            return
        }
        #expect(harness.history.undoTitle == "Undo Move to Trash")

        let undone = try await harness.undo()
        #expect(undone.record.changes == [.putBack(from: url, to: file)])
        #expect(try read(file) == "report")
        #expect(!exists(url.path))

        let redone = try await harness.redo()
        guard case .trashed(file, let again) = redone.record.changes.first else {
            Issue.record("the redo recorded \(redone.record.changes)")
            return
        }
        #expect(!exists(file))
        #expect(try read(again.path) == "report")
        try await image.detach()
    }

    @Test func undoingAReplaceTrashesTheNewItemAndPutsTheOriginalBack() async throws {
        let image = try await DiskImage("UndoHistoryTests")
        let source = image.mountPoint + "/new"
        let destination = image.mountPoint + "/dest"
        try makeFolder(source)
        try makeFolder(destination)
        try write("new", to: source + "/song.txt")
        try write("old", to: destination + "/song.txt")
        let harness = Harness()
        harness.prompter.answer(ConflictResolution(choice: .replace, appliesToAll: false))

        let copied = await harness.perform(.copy([source + "/song.txt"], into: destination))
        #expect(copied.phase == .done)
        #expect(harness.history.undoTitle == "Undo Replace")

        let undone = try await harness.undo()
        #expect(undone.phase == .done)
        #expect(try read(destination + "/song.txt") == "old")
        guard case .trashed(destination + "/song.txt", let newItem) = undone.record.changes.first
        else {
            Issue.record("the undo recorded \(undone.record.changes)")
            return
        }
        #expect(try read(newItem.path) == "new")

        _ = try await harness.redo()
        #expect(try read(destination + "/song.txt") == "new")
        #expect(harness.history.undoTitle == "Undo Replace")
        try await image.detach()
    }
}
