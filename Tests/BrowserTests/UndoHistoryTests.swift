import Base
import BrowserTestSupport
import Darwin
import Foundation
import TestSupport
import Testing

@testable import Browser

private let undoChord = KeyChord("z", modifiers: .command)
private let redoChord = KeyChord("z", modifiers: [.command, .shift])

/// A queue on `fileSystem` whose finished operations `history` follows, as the app's windows
/// make theirs. `watcher` gets its snapshots.
@MainActor
private func followedQueue(
    _ history: UndoHistory, fileSystem: FileOperationQueue.FileSystem = .real,
    prompter: Prompter = Prompter(), watcher: Watcher = Watcher()
) -> FileOperationQueue {
    let (finished, feed) = AsyncStream.makeStream(of: FileOperationQueue.Snapshot.self)
    history.follow(finished)
    return FileOperationQueue(
        fileSystem: fileSystem, prompts: prompter.prompts, clock: ContinuousClock(),
        onChange: { watcher.snapshots.append($0) }, onAnyFinish: { feed.yield($0) })
}

/// A queue over the real file system, whose questions `prompter` answers, and the history that
/// follows it.
@MainActor
private final class Harness {
    let prompter = Prompter()
    let queue: FileOperationQueue
    let history = UndoHistory()

    init() {
        queue = followedQueue(history, prompter: prompter)
    }

    /// Runs `operation` and waits until the history has taken it in.
    @discardableResult
    func perform(_ operation: FileOperation) async -> OperationState {
        let state = await queue.perform(operation)
        await history.catchUp(with: queue)
        return state
    }

    func undo() async throws -> OperationState {
        try await value(of: history.undo(with: queue))
    }

    func redo() async throws -> OperationState {
        try await value(of: history.redo(with: queue))
    }
}

/// The state an undo or redo ended in; fails when the history was busy or had nothing to do.
@MainActor
private func value(of task: Task<OperationState?, Never>?) async throws -> OperationState {
    let task = try #require(task, "the history was busy")
    return try #require(await task.value, "there was nothing to undo or redo")
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

/// The names in the folder at `path`, hidden ones left out, sorted.
private func names(in path: String) throws -> [String] {
    try FileManager.default.contentsOfDirectory(atPath: path).filter { !$0.hasPrefix(".") }.sorted()
}

/// Every path under `root` with what each file holds, hidden items and what is in them left out.
private func tree(_ root: String) throws -> [String] {
    try names(in: root).flatMap { name in
        let path = root + "/" + name
        var isFolder: ObjCBool = false
        FileManager.default.fileExists(atPath: path, isDirectory: &isFolder)
        guard isFolder.boolValue else { return ["\(name): \(try read(path))"] }
        return try [name + "/"] + tree(path).map { name + "/" + $0 }
    }
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

/// Copies, new folders and duplicates make entries named as Finder names them. Nothing is undone
/// here, so nothing reaches the user's Trash.
@MainActor @Test func copiesNewFoldersAndDuplicatesMakeEntriesNamedAsFinderNamesThem()
    async throws
{
    let folder = try TemporaryFolder("UndoHistoryTests")
    let root = folder.url.path
    try makeFolder(root + "/B")
    try write("a", to: root + "/a.txt")
    let harness = Harness()

    #expect(await harness.perform(.copy([root + "/a.txt"], into: root + "/B")).phase == .done)
    #expect(harness.history.undoTitle == "Undo Copy")
    #expect(await harness.perform(.newFolder(in: root)).phase == .done)
    #expect(harness.history.undoTitle == "Undo New Folder")
    #expect(await harness.perform(.duplicate([root + "/a.txt"])).phase == .done)
    #expect(harness.history.undoTitle == "Undo Duplicate")
    #expect(harness.history.canUndo)
}

/// A copy whose items were all skipped, or that was refused, changed nothing and makes no entry.
@MainActor @Test func aCopyThatMadeNothingMakesNoEntry() async throws {
    let folder = try TemporaryFolder("UndoHistoryTests")
    let root = folder.url.path
    try makeFolder(root + "/B")
    try write("a", to: root + "/a.txt")
    try write("old", to: root + "/B/a.txt")
    let harness = Harness()
    await harness.perform(.rename(root + "/a.txt", to: "a2.txt"))
    _ = try await harness.undo()
    harness.prompter.answer(ConflictResolution(choice: .skip, appliesToAll: false))

    let copied = await harness.perform(.copy([root + "/a.txt"], into: root + "/B"))

    #expect(copied.phase == .done)
    #expect(copied.record.changes.isEmpty)
    #expect(!harness.history.canUndo)
    // An operation that makes no entry leaves Redo as it was.
    #expect(harness.history.redoTitle == "Redo Rename")
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
    #expect(try await #require(harness.history.undo(with: harness.queue)).value == nil)
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

/// An undo is one more queued operation, so the main actor never waits on it.
@MainActor @Test func anUndoRunsAsAQueuedOperation() async throws {
    let files = FakeFiles()
    let watcher = Watcher()
    let history = UndoHistory()
    let queue = followedQueue(history, fileSystem: files.fileSystem(), watcher: watcher)
    files.place("/A/b")
    recordEarlier(history, .rename("/A/a", to: "b"), finished(.moved(from: "/A/a", to: "/A/b")))

    let undone = try #require(history.undo(with: queue))
    #expect(!history.canUndo)

    #expect(await undone.value?.phase == .done)
    #expect(files.events.all.contains("move /A/b to /A/a"))
}

// MARK: Waiting for the operation an undo is for

/// A queue on fake files whose finished operations `history` follows, with a rename of `/A/a`
/// to `/A/b` already taken in.
@MainActor
private func queueAfterARename(_ files: FakeFiles, _ history: UndoHistory, _ watcher: Watcher)
    async -> FileOperationQueue
{
    let queue = followedQueue(history, fileSystem: files.fileSystem(), watcher: watcher)
    _ = await queue.perform(.rename("/A/a", to: "b"))
    await history.catchUp(with: queue)
    files.place("/A/b")
    return queue
}

/// Cmd-Z pressed while a copy runs is for that copy: it waits for the copy to end and trashes
/// what it made, rather than undoing the change before it.
@MainActor @Test func undoPressedWhileACopyRunsWaitsForItAndUndoesIt() async throws {
    let files = FakeFiles()
    let watcher = Watcher()
    let history = UndoHistory()
    let queue = await queueAfterARename(files, history, watcher)
    let copy = await enqueue(queue, .copy(["/S/big"], into: "/A"), watcher)
    #expect(await files.events.wait { $0.contains("copy /S/big") })

    let undo = try #require(history.undo(with: queue))
    try await pause()

    #expect(!files.events.all.contains { $0.hasPrefix("trash") || $0 == "move /A/b to /A/a" })
    files.place("/A/big")
    files.releaseAll()
    #expect(await watcher.waitUntilFinished(copy))
    let undone = try #require(await undo.value)
    #expect(undone.phase == .done)
    #expect(
        undone.record.changes == [
            .uncreated(
                "/A/big", from: .copy(of: "/S/big"),
                trashedTo: URL(fileURLWithPath: "/S/.Trashes/501/big"))
        ])
    #expect(!files.events.all.contains("move /A/b to /A/a"))
    #expect(history.undoTitle == "Undo Rename")
    #expect(history.redoTitle == "Redo Copy")
}

/// While an operation that may make an entry is unfinished, the Undo and Redo items are off:
/// their titles would name an older change than the one a press would undo.
@MainActor @Test func undoAndRedoItemsAreOffWhileAnOperationIsUnfinished() async throws {
    let files = FakeFiles()
    let watcher = Watcher()
    let history = UndoHistory()
    let queue = await queueAfterARename(files, history, watcher)
    let pane = Pane(
        location: Location(path: "/A"), service: ListingService(),
        systemActions: StubSystemActions(), settings: untouchedSettings())
    let context = CommandContext(pane: pane, fileOperations: queue, undoHistory: history)
    let undo = try #require(UndoCommands.bindings.first { $0.command == UndoCommands.undo })
    #expect(undo.isEnabled?(context) == true)

    let copy = await enqueue(queue, .copy(["/S/big"], into: "/A"), watcher)

    #expect(undo.isEnabled?(context) == false)
    files.releaseAll()
    #expect(await watcher.waitUntilFinished(copy))
    await settle { undo.isEnabled?(context) == true }
    #expect(undo.title?(context) == "Undo Copy")
}

/// Cancelling the copy an undo waits for is taken as the undo: it does nothing more, and the
/// change before the copy stays.
@MainActor @Test func anUndoWaitingForACopyTheUserCancelsDoesNothing() async throws {
    let files = FakeFiles()
    let watcher = Watcher()
    let history = UndoHistory()
    let queue = await queueAfterARename(files, history, watcher)
    let copy = await enqueue(queue, .copy(["/S/big"], into: "/A"), watcher)
    #expect(await files.events.wait { $0.contains("copy /S/big") })
    let undo = try #require(history.undo(with: queue))

    await queue.cancel(copy)

    #expect(await undo.value == nil)
    #expect(!files.events.all.contains("move /A/b to /A/a"))
    #expect(history.undoTitle == "Undo Rename")
    #expect(!history.isBusy)
}

/// A change made after the press, while the undo waits, means the press no longer names the
/// last change: the undo does nothing rather than undo the wrong one.
@MainActor @Test func anUndoWaitingWhileANewChangeIsMadeDoesNothing() async throws {
    let files = FakeFiles()
    let watcher = Watcher()
    let history = UndoHistory()
    let queue = await queueAfterARename(files, history, watcher)
    let copy = await enqueue(queue, .copy(["/S/big"], into: "/A"), watcher)
    #expect(await files.events.wait { $0.contains("copy /S/big") })
    let undo = try #require(history.undo(with: queue))

    _ = await queue.perform(.rename("/B/c", to: "d"))
    files.releaseAll()
    #expect(await watcher.waitUntilFinished(copy))

    #expect(await undo.value == nil)
    #expect(!files.events.all.contains { $0.hasPrefix("trash") })
    #expect(!files.events.all.contains("move /B/d to /B/c"))
    #expect(history.undoTitle == "Undo Copy")
}

/// Cmd-Shift-Z pressed while a copy runs waits for it too; the copy's entry clears Redo, so the
/// redo does nothing.
@MainActor @Test func aRedoPressedWhileACopyRunsWaitsAndFindsRedoCleared() async throws {
    let files = FakeFiles()
    let watcher = Watcher()
    let history = UndoHistory()
    let queue = await queueAfterARename(files, history, watcher)
    #expect(try await #require(history.undo(with: queue)).value?.phase == .done)
    files.remove("/A/b")
    files.place("/A/a")
    #expect(history.redoTitle == "Redo Rename")
    let copy = await enqueue(queue, .copy(["/S/big"], into: "/A"), watcher)
    #expect(await files.events.wait { $0.contains("copy /S/big") })

    let redo = try #require(history.redo(with: queue))
    try await pause()
    #expect(files.events.all.filter { $0 == "move /A/a to /A/b" }.count == 1)
    files.releaseAll()
    #expect(await watcher.waitUntilFinished(copy))

    #expect(await redo.value == nil)
    #expect(files.events.all.filter { $0 == "move /A/a to /A/b" }.count == 1)
    #expect(history.undoTitle == "Undo Copy")
    #expect(!history.canRedo)
}

// MARK: What a copy that didn't finish recorded

/// A copy cancelled after its first item recorded that item only, and its undo trashes only
/// that item.
@MainActor @Test func aPartlyCancelledCopyUndoesOnlyWhatItMade() async throws {
    let files = FakeFiles()
    let watcher = Watcher()
    let history = UndoHistory()
    let queue = followedQueue(history, fileSystem: files.fileSystem(), watcher: watcher)
    let copy = await enqueue(queue, .copy(["/S/a", "/S/b"], into: "/A"), watcher)
    files.release("/S/a")
    #expect(await files.events.wait { $0.contains("copy /S/b") })

    await queue.cancel(copy)
    #expect(await watcher.waitUntilFinished(copy))
    await history.catchUp(with: queue)

    #expect(
        watcher.state(of: copy)?.record.changes == [.created("/A/a", from: .copy(of: "/S/a"))])
    #expect(history.undoTitle == "Undo Copy")
    files.place("/A/a")
    #expect(try await value(of: history.undo(with: queue)).phase == .done)
    #expect(files.events.all.filter { $0.hasPrefix("trash") } == ["trash /A/a"])
}

/// A copy whose second item failed recorded the first only, and its undo trashes only that.
@MainActor @Test func aPartlyFailedCopyUndoesOnlyWhatItMade() async throws {
    let files = FakeFiles(releasingAll: true)
    let watcher = Watcher()
    let history = UndoHistory()
    let queue = followedQueue(history, fileSystem: files.fileSystem(), watcher: watcher)
    files.failCopy(
        of: "/S/b", with: FileOperationError(reason: .permissionDenied, path: "/S/b", errno: EACCES)
    )

    let copied = await queue.perform(.copy(["/S/a", "/S/b"], into: "/A"))
    await history.catchUp(with: queue)

    #expect(copied.phase == .failed)
    #expect(copied.record.changes == [.created("/A/a", from: .copy(of: "/S/a"))])
    files.place("/A/a")
    #expect(try await value(of: history.undo(with: queue)).phase == .done)
    #expect(files.events.all.filter { $0.hasPrefix("trash") } == ["trash /A/a"])
}

/// A copy cancelled before it made anything makes no entry.
@MainActor @Test func aCopyCancelledBeforeItMadeAnythingMakesNoEntry() async throws {
    let files = FakeFiles()
    let watcher = Watcher()
    let history = UndoHistory()
    let queue = followedQueue(history, fileSystem: files.fileSystem(), watcher: watcher)
    let copy = await enqueue(queue, .copy(["/S/a"], into: "/A"), watcher)
    #expect(await files.events.wait { $0.contains("copy /S/a") })

    await queue.cancel(copy)
    #expect(await watcher.waitUntilFinished(copy))
    await history.catchUp(with: queue)

    #expect(!history.canUndo)
    #expect(history.undoTitle == "Undo")
}

/// Where the volume has no Trash, an undo of a copy fails naming the item and deletes nothing;
/// the entry is dropped.
@MainActor @Test func undoingACopyWhereTheVolumeHasNoTrashFailsAndDeletesNothing() async throws {
    let files = FakeFiles(releasingAll: true)
    let watcher = Watcher()
    let history = UndoHistory()
    let queue = followedQueue(history, fileSystem: files.fileSystem(), watcher: watcher)
    files.removeTrash()
    _ = await queue.perform(.copy(["/S/a"], into: "/A"))
    await history.catchUp(with: queue)
    files.place("/A/a")

    let undone = try await value(of: history.undo(with: queue))

    #expect(undone.phase == .failed)
    #expect(undone.errors == [FileOperationError(reason: .noTrash, path: "/A/a", errno: nil)])
    #expect(!files.events.all.contains { $0.hasPrefix("delete") })
    #expect(!history.canUndo)
    #expect(!history.canRedo)
}

/// Files a drop promised are moved in from the queue's drop folder, which is removed once the
/// drop ends, so their undo trashes them, as for a copy, and Redo puts them back from the Trash.
@MainActor @Test func aDropsFilesUndoToTheTrashAndRedoFromIt() async throws {
    let files = FakeFiles()
    let watcher = Watcher()
    let history = UndoHistory()
    let queue = followedQueue(history, fileSystem: files.fileSystem(), watcher: watcher)
    let drop = try await queue.makeDropFolder(in: "/A")

    let moved = await queue.perform(.move([drop.path + "/mail.eml"], into: "/A"))
    await history.catchUp(with: queue)
    _ = await queue.removeDropFolder(drop)

    #expect(moved.record.changes == [.created("/A/mail.eml", from: .drop)])
    files.place("/A/mail.eml")
    let undone = try await value(of: history.undo(with: queue))
    #expect(undone.phase == .done)
    #expect(files.events.all.contains("trash /A/mail.eml"))
    files.remove("/A/mail.eml")
    let redone = try await value(of: history.redo(with: queue))
    #expect(redone.phase == .done)
    #expect(files.events.all.contains("move /S/.Trashes/501/mail.eml to /A/mail.eml"))
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
    // Both are off while it runs; Redo has the entry once the undo has run.
    #expect(undo.isEnabled?(context) == false)
    #expect(redo.isEnabled?(context) == false)
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
        guard
            case .uncreated(destination + "/song.txt", .copy(source + "/song.txt"), let newItem) =
                undone.record.changes.first
        else {
            Issue.record("the undo recorded \(undone.record.changes)")
            return
        }
        #expect(try read(newItem.path) == "new")

        // Redo copies from the source again, as Finder does, rather than from the Trash.
        try write("newer", to: source + "/song.txt")
        _ = try await harness.redo()
        #expect(try read(destination + "/song.txt") == "newer")
        #expect(try read(newItem.path) == "new")
        #expect(harness.history.undoTitle == "Undo Replace")
        _ = try await harness.undo()
        #expect(try read(destination + "/song.txt") == "old")
        try await image.detach()
    }

    /// Undo Copy trashes the items the copy made and nothing else in the folder: an item already
    /// there, and one whose name the copy skipped, stay. Redo copies from the sources again.
    @Test func undoingACopyTrashesOnlyWhatItMadeAndRedoCopiesAgain() async throws {
        let image = try await DiskImage("UndoHistoryTests", megabytes: 4)
        let root = image.mountPoint
        try makeFolder(root + "/B")
        try write("kept", to: root + "/B/kept.txt")
        try write("old", to: root + "/B/skipped.txt")
        try write("a", to: root + "/a.txt")
        try write("skip", to: root + "/skipped.txt")
        try makeFolder(root + "/album")
        try write("song", to: root + "/album/song.txt")
        let harness = Harness()
        harness.prompter.answer(ConflictResolution(choice: .skip, appliesToAll: false))
        let before = try names(in: root + "/B")

        let copied = await harness.perform(
            .copy(
                [root + "/a.txt", root + "/skipped.txt", root + "/album"], into: root + "/B"))

        #expect(copied.phase == .done)
        #expect(harness.history.undoTitle == "Undo Copy")
        let undone = try await harness.undo()
        #expect(undone.phase == .done)
        #expect(try names(in: root + "/B") == before)
        #expect(try read(root + "/B/kept.txt") == "kept")
        #expect(try read(root + "/B/skipped.txt") == "old")
        #expect(try read(root + "/a.txt") == "a")
        #expect(try read(root + "/album/song.txt") == "song")
        #expect(harness.history.redoTitle == "Redo Copy")

        let redone = try await harness.redo()
        #expect(redone.phase == .done)
        #expect(try read(root + "/B/a.txt") == "a")
        #expect(try read(root + "/B/album/song.txt") == "song")
        #expect(try read(root + "/B/skipped.txt") == "old")
        #expect(harness.history.undoTitle == "Undo Copy")
        #expect(try await harness.undo().phase == .done)
        #expect(try names(in: root + "/B") == before)
        try await image.detach()
    }

    /// Keep Both made "a 2.txt" beside "a.txt"; undoing it leaves the folder as it was before.
    @Test func undoingAKeepBothCopyLeavesTheFolderAsItWas() async throws {
        let image = try await DiskImage("UndoHistoryTests")
        let root = image.mountPoint
        try makeFolder(root + "/B")
        try write("old", to: root + "/B/a.txt")
        try write("new", to: root + "/a.txt")
        let harness = Harness()
        harness.prompter.answer(ConflictResolution(choice: .keepBoth, appliesToAll: false))
        let before = try names(in: root + "/B")

        await harness.perform(.copy([root + "/a.txt"], into: root + "/B"))
        #expect(try read(root + "/B/a 2.txt") == "new")

        #expect(try await harness.undo().phase == .done)
        #expect(try names(in: root + "/B") == before)
        #expect(try read(root + "/B/a.txt") == "old")
        _ = try await harness.redo()
        #expect(try read(root + "/B/a 2.txt") == "new")
        try await image.detach()
    }

    @Test func undoingANewFolderTrashesItAndRedoMakesItAgain() async throws {
        let image = try await DiskImage("UndoHistoryTests")
        let root = image.mountPoint
        let harness = Harness()

        let made = await harness.perform(.newFolder(in: root))
        #expect(made.record.changes == [.created(root + "/untitled folder", from: .newFolder)])
        #expect(harness.history.undoTitle == "Undo New Folder")

        #expect(try await harness.undo().phase == .done)
        #expect(!exists(root + "/untitled folder"))
        #expect(harness.history.redoTitle == "Redo New Folder")
        #expect(try await harness.redo().phase == .done)
        #expect(try names(in: root + "/untitled folder") == [])
        #expect(harness.history.undoTitle == "Undo New Folder")
        try await image.detach()
    }

    @Test func undoingADuplicateTrashesTheCopyAndRedoMakesItAgain() async throws {
        let image = try await DiskImage("UndoHistoryTests")
        let root = image.mountPoint
        try write("a", to: root + "/a.txt")
        let harness = Harness()

        await harness.perform(.duplicate([root + "/a.txt"]))
        #expect(try read(root + "/a copy.txt") == "a")
        #expect(harness.history.undoTitle == "Undo Duplicate")

        #expect(try await harness.undo().phase == .done)
        #expect(!exists(root + "/a copy.txt"))
        #expect(try read(root + "/a.txt") == "a")
        #expect(try await harness.redo().phase == .done)
        #expect(try read(root + "/a copy.txt") == "a")
        try await image.detach()
    }

    /// One made item replaced by another since, and another deleted: the undo fails naming
    /// both and trashes nothing, not even the third item, which is still in place.
    @Test func aMadeItemChangedSinceFailsTheUndoNamingItAndChangesNothing() async throws {
        let image = try await DiskImage("UndoHistoryTests")
        let root = image.mountPoint
        try makeFolder(root + "/B")
        for name in ["a", "b", "c"] { try write(name, to: root + "/\(name).txt") }
        let harness = Harness()
        await harness.perform(
            .copy([root + "/a.txt", root + "/b.txt", root + "/c.txt"], into: root + "/B"))
        try write("saved", to: root + "/B/new.txt")
        #expect(rename(root + "/B/new.txt", root + "/B/a.txt") == 0)
        try FileManager.default.removeItem(atPath: root + "/B/b.txt")

        let undone = try await harness.undo()

        #expect(undone.phase == .failed)
        #expect(
            undone.errors == [
                FileOperationError(reason: .sourceGone, path: root + "/B/b.txt", errno: ENOENT),
                FileOperationError(reason: .notTheSameItem, path: root + "/B/a.txt", errno: nil),
            ])
        #expect(undone.record.changes.isEmpty)
        #expect(try read(root + "/B/a.txt") == "saved")
        #expect(try read(root + "/B/c.txt") == "c")
        #expect(!harness.history.canUndo)
        #expect(!harness.history.canRedo)
        try await image.detach()
    }

    /// A made item moved elsewhere since fails the undo naming where the record left it.
    @Test func aMadeItemMovedSinceFailsTheUndo() async throws {
        let image = try await DiskImage("UndoHistoryTests")
        let root = image.mountPoint
        let harness = Harness()
        await harness.perform(.newFolder(in: root))
        #expect(rename(root + "/untitled folder", root + "/Photos") == 0)

        let undone = try await harness.undo()

        #expect(
            undone.errors == [
                FileOperationError(
                    reason: .sourceGone, path: root + "/untitled folder", errno: ENOENT)
            ])
        #expect(exists(root + "/Photos"))
        try await image.detach()
    }

    /// Redo Copy after the source is gone fails naming it and makes nothing.
    @Test func redoingACopyWhoseSourceIsGoneFailsNamingIt() async throws {
        let image = try await DiskImage("UndoHistoryTests")
        let root = image.mountPoint
        try makeFolder(root + "/B")
        try write("a", to: root + "/a.txt")
        try write("b", to: root + "/b.txt")
        let harness = Harness()
        await harness.perform(.copy([root + "/a.txt", root + "/b.txt"], into: root + "/B"))
        _ = try await harness.undo()
        try FileManager.default.removeItem(atPath: root + "/b.txt")

        let redone = try await harness.redo()

        #expect(redone.phase == .failed)
        #expect(
            redone.errors == [
                FileOperationError(reason: .sourceGone, path: root + "/b.txt", errno: ENOENT)
            ])
        #expect(try names(in: root + "/B") == [])
        #expect(!harness.history.canRedo)
        try await image.detach()
    }

    /// Redo New Folder where the name is taken now, or the folder it went in is gone, fails
    /// naming the path and makes nothing.
    @Test func redoingANewFolderWhosePlaceIsTakenOrGoneFails() async throws {
        let image = try await DiskImage("UndoHistoryTests")
        let root = image.mountPoint
        try makeFolder(root + "/In")
        let harness = Harness()
        await harness.perform(.newFolder(in: root))
        _ = try await harness.undo()
        try write("x", to: root + "/untitled folder")

        let taken = try await harness.redo()

        #expect(
            taken.errors == [
                FileOperationError(reason: .exists, path: root + "/untitled folder", errno: EEXIST)
            ])
        #expect(try read(root + "/untitled folder") == "x")

        await harness.perform(.newFolder(in: root + "/In"))
        _ = try await harness.undo()
        try FileManager.default.removeItem(atPath: root + "/In")

        let gone = try await harness.redo()

        #expect(
            gone.errors == [
                FileOperationError(reason: .sourceGone, path: root + "/In", errno: ENOENT)
            ])
        #expect(!exists(root + "/In"))
        try await image.detach()
    }

    /// Copies, new folders, renames, duplicates and trashes made from two windows undo last
    /// first through either window's Undo, and the volume ends as it began.
    @Test func aMixedSequenceFromTwoWindowsUndoesInOrder() async throws {
        let image = try await DiskImage("UndoHistoryTests", megabytes: 4)
        let root = image.mountPoint
        try makeFolder(root + "/One")
        try makeFolder(root + "/Two")
        try write("a", to: root + "/One/a.txt")
        try write("b", to: root + "/Two/b.txt")
        let harness = Harness()
        let contexts = ["/One", "/Two"].map { path in
            CommandContext(
                pane: Pane(
                    location: Location(path: root + path), service: ListingService(),
                    systemActions: StubSystemActions(), settings: untouchedSettings()),
                fileOperations: harness.queue, undoHistory: harness.history)
        }
        let before = try tree(root)
        let undo = try #require(UndoCommands.bindings.first { $0.command == UndoCommands.undo })

        await harness.perform(.copy([root + "/One/a.txt"], into: root + "/Two"))
        await harness.perform(.newFolder(in: root + "/Two"))
        await harness.perform(.rename(root + "/One/a.txt", to: "z.txt"))
        await harness.perform(.duplicate([root + "/Two/b.txt"]))
        await harness.perform(.trash([root + "/One/z.txt"]))

        let titles = [
            "Undo Move to Trash", "Undo Duplicate", "Undo Rename", "Undo New Folder", "Undo Copy",
        ]
        for (number, title) in titles.enumerated() {
            let context = contexts[number % 2]
            #expect(undo.title?(context) == title)
            undo.run(context)
            await settle { !harness.history.isBusy }
        }
        #expect(!harness.history.canUndo)
        #expect(try tree(root) == before)
        try await image.detach()
    }

    /// exFAT makes its inodes up and they change when it is mounted again, so nothing records an
    /// identity there, and an undo checks only that the items are where the record says.
    @Test func onExFATAnUndoChecksPresenceOnly() async throws {
        let image = try await DiskImage("UndoExFAT", megabytes: 40, fileSystem: "ExFAT")
        try write("a", to: image.mountPoint + "/a.txt")
        let harness = Harness()

        let renamed = await harness.perform(.rename(image.mountPoint + "/a.txt", to: "b.txt"))
        #expect(renamed.record.identities.isEmpty)

        #expect(try await harness.undo().phase == .done)
        #expect(try read(image.mountPoint + "/a.txt") == "a")
        try await image.detach()
    }
}

// MARK: Identity

/// An item put at the path since, as a save that writes a new file and renames it over the old
/// one, isn't the item the record changed, so the undo leaves it.
@MainActor @Test func anotherItemAtTheRecordedPathFailsTheUndo() async throws {
    let folder = try TemporaryFolder("UndoHistoryTests")
    let root = folder.url.path
    try write("a", to: root + "/a.txt")
    let harness = Harness()
    await harness.perform(.rename(root + "/a.txt", to: "b.txt"))
    try write("new", to: root + "/c.txt")
    try FileManager.default.removeItem(atPath: root + "/b.txt")
    #expect(rename(root + "/c.txt", root + "/b.txt") == 0)

    let undone = try await harness.undo()

    #expect(undone.phase == .failed)
    #expect(undone.errors.map(\.path) == [root + "/b.txt"])
    #expect(undone.errors.map(\.reason) == [.notTheSameItem])
    #expect(try read(root + "/b.txt") == "new")
    #expect(!exists(root + "/a.txt"))
    #expect(!harness.history.canUndo)
}

// MARK: One at a time

/// A finished operation's state, as the queue reports it.
private func finished(_ changes: OperationRecord.Change...) -> OperationState {
    OperationState(
        phase: .done,
        progress: OperationState.Progress(
            itemsDone: changes.count, itemCount: changes.count,
            copied: CopyProgress(bytes: 0, files: 0), total: nil),
        errors: [], record: OperationRecord(changes: changes))
}

/// A press while an undo is still running does nothing, so the entry under it isn't undone out
/// of turn; a refused undo leaves its entry where it was.
@MainActor @Test func aRefusedUndoKeepsItsEntryAndAPressWhileItRunsIsIgnored() async throws {
    let files = FakeFiles()
    let watcher = Watcher()
    let history = UndoHistory()
    let queue = followedQueue(history, fileSystem: files.fileSystem(), watcher: watcher)
    files.place("/A/m/x")
    files.place("/A/b")
    recordEarlier(
        history, .move(["/A/x"], into: "/A/m"), finished(.moved(from: "/A/x", to: "/A/m/x")))
    recordEarlier(history, .rename("/A/a", to: "b"), finished(.moved(from: "/A/a", to: "/A/b")))

    let first = history.undo(with: queue)
    let second = history.undo(with: queue)
    // Queued after the press, so the undo doesn't wait for it; it reads the renamed item, so the
    // undo is refused while it runs.
    let copy = queue.submit(.copy(["/A/b"], into: "/B"))

    #expect(second == nil)
    let refused = try #require(first)
    guard case .refused = await refused.value?.phase else {
        Issue.record("the undo wasn't refused")
        return
    }
    #expect(history.undoTitle == "Undo Rename")
    #expect(!history.canRedo)
    files.releaseAll()
    #expect(await copy.value.phase == .done)
    await history.catchUp(with: queue)
    #expect(history.undoTitle == "Undo Copy")
    files.place("/B/b")
    #expect(try await #require(history.undo(with: queue)).value?.phase == .done)
    #expect(try await #require(history.undo(with: queue)).value?.phase == .done)
    #expect(files.events.all.contains("move /A/b to /A/a"))
    #expect(!files.events.all.contains("move /A/m/x to /A/x"))
    #expect(history.undoTitle == "Undo Move 1 Item")
}

/// An undo that ends after a new change was recorded doesn't offer a Redo the new change
/// cleared, and its entry leaves from under the new one. Undoing a move between volumes copies
/// the item back and deletes it where it was.
@MainActor @Test func anUndoEndingAfterANewChangeOffersNoRedo() async throws {
    let files = FakeFiles()
    let watcher = Watcher()
    let history = UndoHistory()
    let queue = followedQueue(history, fileSystem: files.fileSystem(), watcher: watcher)
    files.place("/B/x")
    files.place("/A/q")
    recordEarlier(history, .move(["/A/x"], into: "/B"), finished(.moved(from: "/A/x", to: "/B/x")))
    let undo = try #require(history.undo(with: queue))
    #expect(await files.events.wait { $0.contains("copy /B/x") })

    recordEarlier(history, .rename("/A/p", to: "q"), finished(.moved(from: "/A/p", to: "/A/q")))
    files.releaseAll()

    #expect(await undo.value?.phase == .done)
    #expect(files.events.all.contains("delete /B/x"))
    #expect(!history.canRedo)
    #expect(history.undoTitle == "Undo Rename")
    #expect(try await #require(history.undo(with: queue)).value?.phase == .done)
    #expect(!history.canUndo)
}

/// A move between volumes undone whose copy back is made but whose item can't be deleted where
/// it was is left as it is: no Redo, no entry.
@MainActor @Test func anUndoThatCopiesBackButCantDeleteOffersNoRedo() async throws {
    let files = FakeFiles(releasingAll: true)
    let watcher = Watcher()
    let history = UndoHistory()
    let queue = followedQueue(history, fileSystem: files.fileSystem(), watcher: watcher)
    files.place("/B/x")
    let denied = FileOperationError(reason: .permissionDenied, path: "/B/x", errno: EACCES)
    files.failDelete(of: "/B/x", with: denied)
    recordEarlier(history, .move(["/A/x"], into: "/B"), finished(.moved(from: "/A/x", to: "/B/x")))

    let undone = try await value(of: history.undo(with: queue))

    #expect(undone.phase == .failed)
    #expect(undone.errors == [denied])
    #expect(!history.canRedo)
    #expect(!history.canUndo)
}

// MARK: Limit

@MainActor @Test func theHistoryKeepsTheLastHundredEntries() {
    let history = UndoHistory()
    recordEarlier(
        history, .trash(["/A/a"]),
        finished(.trashed(from: "/A/a", to: URL(fileURLWithPath: "/A/.Trashes/a"))))
    for number in 1...UndoHistory.limit {
        recordEarlier(
            history, .rename("/A/\(number)", to: "n\(number)"),
            finished(.moved(from: "/A/\(number)", to: "/A/n\(number)")))
    }

    #expect(history.undoCount == 100)
    #expect(history.undoTitle == "Undo Rename")
}

/// Copies, new folders and duplicates count toward the 100 like any entry.
@MainActor @Test func madeItemsCountTowardTheHundred() {
    let history = UndoHistory()
    for number in 1...UndoHistory.limit {
        recordEarlier(
            history, .rename("/A/\(number)", to: "n\(number)"),
            finished(.moved(from: "/A/\(number)", to: "/A/n\(number)")))
    }
    recordEarlier(
        history, .newFolder(in: "/A"), finished(.created("/A/untitled folder", from: .newFolder)))
    recordEarlier(
        history, .copy(["/S/a"], into: "/A"),
        finished(.created("/A/a", from: .copy(of: "/S/a"))))

    #expect(history.undoCount == 100)
    #expect(history.undoTitle == "Undo Copy")
}

/// Takes in `operation` as one queued before any undo or redo the test presses.
@MainActor
private func recordEarlier(
    _ history: UndoHistory, _ operation: FileOperation, _ state: OperationState
) {
    history.record(operation, state, id: FileOperationQueue.ID(-1))
}

// MARK: Catching up

/// Finished operations the queue reported, held until the test lets the history hear of them.
private final class HeldFinishes: @unchecked Sendable {
    private let lock = NSLock()
    private var held: [FileOperationQueue.Snapshot] = []
    let stream: AsyncStream<FileOperationQueue.Snapshot>
    private let feed: AsyncStream<FileOperationQueue.Snapshot>.Continuation

    init() {
        (stream, feed) = AsyncStream.makeStream(of: FileOperationQueue.Snapshot.self)
    }

    func add(_ snapshot: FileOperationQueue.Snapshot) {
        lock.withLock { held.append(snapshot) }
    }

    func release() {
        let released = lock.withLock {
            defer { held.removeAll() }
            return held
        }
        for snapshot in released {
            feed.yield(snapshot)
        }
    }

    func end() {
        feed.finish()
    }
}

/// A queue over the real file system whose finished operations reach `history` only when
/// `held` lets them.
@MainActor
private func heldQueue(_ history: UndoHistory, _ held: HeldFinishes) -> FileOperationQueue {
    history.follow(held.stream)
    return FileOperationQueue(
        fileSystem: .real, prompts: Prompter().prompts, clock: ContinuousClock(),
        onChange: { _ in }, onAnyFinish: { held.add($0) })
}

/// Undo pressed after an operation ends but before the history has heard of it waits for it, and
/// undoes it rather than the one before.
@MainActor @Test func undoWaitsForTheOperationThatJustEnded() async throws {
    let folder = try TemporaryFolder("UndoHistoryTests")
    let root = folder.url.path
    try write("a", to: root + "/a.txt")
    try write("b", to: root + "/b.txt")
    let history = UndoHistory()
    let held = HeldFinishes()
    let queue = heldQueue(history, held)
    _ = await queue.perform(.rename(root + "/a.txt", to: "a2.txt"))
    held.release()
    await settle { history.canUndo }
    _ = await queue.perform(.rename(root + "/b.txt", to: "b2.txt"))

    let undo = history.undo(with: queue)
    try await Task.sleep(for: .milliseconds(50))
    held.release()

    #expect(try await value(of: undo).phase == .done)
    #expect(exists(root + "/b.txt"))
    #expect(exists(root + "/a2.txt"))
}

/// When the stream of finished operations ends, a waiting undo stops waiting and the history is
/// free again.
@MainActor @Test(.timeLimit(.minutes(1))) func undoStopsWaitingWhenTheFinishedStreamEnds()
    async throws
{
    let folder = try TemporaryFolder("UndoHistoryTests")
    let root = folder.url.path
    try write("a", to: root + "/a.txt")
    let history = UndoHistory()
    let held = HeldFinishes()
    let queue = heldQueue(history, held)
    _ = await queue.perform(.rename(root + "/a.txt", to: "b.txt"))

    let undo = try #require(history.undo(with: queue))
    held.end()

    #expect(await undo.value == nil)
    #expect(!history.isBusy)
}
