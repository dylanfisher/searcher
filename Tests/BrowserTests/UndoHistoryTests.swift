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
private func followedQueue<C: Clock<Duration>>(
    _ history: UndoHistory, fileSystem: FileOperationQueue.FileSystem = .real,
    prompter: Prompter = Prompter(), watcher: Watcher = Watcher(), clock: C = ContinuousClock()
) -> FileOperationQueue {
    let (finished, feed) = AsyncStream.makeStream(of: FileOperationQueue.Snapshot.self)
    history.follow(finished)
    return FileOperationQueue(
        fileSystem: fileSystem, prompts: prompter.prompts, clock: clock,
        onChange: { watcher.snapshots.append($0) }, onAnyFinish: { feed.yield($0) })
}

/// A queue over the real file system, whose questions `prompter` answers, and the history that
/// follows it.
@MainActor
private final class Harness {
    let prompter = Prompter()
    let queue: FileOperationQueue
    let history = UndoHistory(log: { _ in })

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

/// The state an undo or redo ended in; fails when the press did nothing or didn't end in time.
@MainActor
private func value(
    of task: Task<OperationState?, Never>, fileID: String = #fileID,
    filePath: String = #filePath, line: Int = #line, column: Int = #column
) async throws -> OperationState {
    let state = await result(
        of: task, fileID: fileID, filePath: filePath, line: line, column: column)
    return try #require(
        state, "the press did nothing",
        sourceLocation: SourceLocation(
            fileID: fileID, filePath: filePath, line: line, column: column))
}

/// What a press ended with, nil when it did nothing; records an issue if it hasn't ended in
/// time, as a press waiting on something held would never end.
@MainActor
private func result(
    of task: Task<OperationState?, Never>, fileID: String = #fileID,
    filePath: String = #filePath, line: Int = #line, column: Int = #column
) async -> OperationState? {
    await bounded(task, fileID: fileID, filePath: filePath, line: line, column: column) ?? nil
}

private func write(_ text: String, to path: String) throws {
    try Data(text.utf8).write(to: URL(fileURLWithPath: path))
}

private func read(_ path: String) throws -> String {
    try String(contentsOfFile: path, encoding: .utf8)
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
    #expect(await result(of: harness.history.undo(with: harness.queue)) == nil)
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
    // Only a missing folder keeps an entry; this one would block every older undo.
    #expect(!harness.history.canUndo)
}

/// An item whose folder is gone too, as on a drive that isn't mounted, fails the undo naming
/// the outermost folder that is gone; that can clear, so the entry stays, and once the folder
/// is back the undo runs.
@MainActor @Test func anUndoWhoseFolderIsGoneKeepsItsEntry() async throws {
    let files = FakeFiles()
    let watcher = Watcher()
    let history = UndoHistory(log: { _ in })
    let queue = followedQueue(history, fileSystem: files.fileSystem(), watcher: watcher)
    recordEarlier(
        history, .move(["/A/x"], into: "/A/drive/in"),
        finished(.moved(from: "/A/x", to: "/A/drive/in/x")))

    let undone = try await value(of: history.undo(with: queue))

    #expect(
        undone.errors == [
            FileOperationError(reason: .sourceGone, path: "/A/drive", errno: ENOENT)
        ])
    #expect(history.undoTitle == "Undo Move 1 Item")
    files.place("/A/drive/in/x")
    #expect(try await value(of: history.undo(with: queue)).phase == .done)
    #expect(files.events.all.contains("move /A/drive/in/x to /A/x"))
}

/// An operation a press waited for that settled, here by a pause, and then made an entry
/// before the press's turn came after the press: the press does nothing rather than undo it.
@MainActor @Test(.timeLimit(.minutes(2)))
func aPressDoesNothingWhenWhatItWaitedForSettlesThenMakesAnEntry() async throws {
    let files = FakeFiles()
    let watcher = Watcher()
    let history = UndoHistory(log: { _ in })
    let queue = await queueAfterARename(files, history, watcher, clock: ManualClock())
    // Undone across volumes, so the first press copies back and holds until released.
    files.release("/A/far")
    _ = await queue.perform(.move(["/A/far"], into: "/B"))
    await history.catchUp(with: queue)
    files.place("/B/far")
    let first = history.undo(with: queue)
    #expect(await files.events.wait { $0.contains("copy /B/far") })
    files.holdVolume(of: "/A/in")
    let moveID = FileOperationQueue.ID(queue.submittedCount)
    let move = queue.submit(.move(["/A/near"], into: "/A/in"))
    #expect(await files.events.wait { $0.contains("holding volume /A/in") })
    let second = history.undo(with: queue)

    await queue.pause(moveID)
    files.letVolumeGo(of: "/A/in")
    await queue.resume(moveID)
    #expect(await bounded(move)?.record.changes == [.moved(from: "/A/near", to: "/A/in/near")])
    files.releaseAll()

    #expect(await result(of: first)?.phase == .done)
    #expect(await result(of: second) == nil)
    #expect(!files.events.all.contains("move /A/in/near to /A/near"))
    #expect(history.undoTitle == "Undo Move 1 Item")
}

/// A kept entry whose undo finds the folder missing again is dropped, and the operation says so.
@MainActor @Test func aKeptEntryFailingAgainIsDropped() async throws {
    let files = FakeFiles()
    let watcher = Watcher()
    let history = UndoHistory(log: { _ in })
    let queue = followedQueue(history, fileSystem: files.fileSystem(), watcher: watcher)
    recordEarlier(
        history, .rename("/A/a", to: "b"), finished(.moved(from: "/A/a", to: "/A/b")))
    recordEarlier(
        history, .move(["/A/x"], into: "/A/drive/in"),
        finished(.moved(from: "/A/x", to: "/A/drive/in/x")))

    let first = try await value(of: history.undo(with: queue))
    #expect(history.undoTitle == "Undo Move 1 Item")
    let operation = FileOperation.undo(
        OperationRecord(changes: [.moved(from: "/A/x", to: "/A/drive/in/x")]),
        title: "Undo Move 1 Item", isRetry: false)
    #expect(!FileOperation.dropsUndoEntry(operation, after: first))

    let second = try await value(of: history.undo(with: queue))

    #expect(second.errors == first.errors)
    #expect(history.undoTitle == "Undo Rename")
    let retry = FileOperation.undo(
        OperationRecord(changes: [.moved(from: "/A/x", to: "/A/drive/in/x")]),
        title: "Undo Move 1 Item", isRetry: true)
    #expect(FileOperation.dropsUndoEntry(retry, after: second))
}

/// An undo is one more queued operation, so the main actor never waits on it.
@MainActor @Test func anUndoRunsAsAQueuedOperation() async throws {
    let files = FakeFiles()
    let watcher = Watcher()
    let history = UndoHistory(log: { _ in })
    let queue = followedQueue(history, fileSystem: files.fileSystem(), watcher: watcher)
    files.place("/A/b")
    recordEarlier(history, .rename("/A/a", to: "b"), finished(.moved(from: "/A/a", to: "/A/b")))

    let undone = history.undo(with: queue)
    #expect(!history.canUndo)

    #expect(await result(of: undone)?.phase == .done)
    #expect(files.events.all.contains("move /A/b to /A/a"))
}

// MARK: What a press waits for

/// A queue on fake files whose finished operations `history` follows, with a rename of `/A/a`
/// to `/A/b` already taken in. Its clock stands still unless a test passes another, so no
/// operation settles past `pressWait` however long a loaded machine takes to run it.
@MainActor
private func queueAfterARename<C: Clock<Duration>>(
    _ files: FakeFiles, _ history: UndoHistory, _ watcher: Watcher, clock: C = ManualClock()
) async -> FileOperationQueue {
    let queue = followedQueue(
        history, fileSystem: files.fileSystem(), watcher: watcher, clock: clock)
    _ = await queue.perform(.rename("/A/a", to: "b"))
    await history.catchUp(with: queue)
    files.place("/A/b")
    return queue
}

/// Cmd-Z during a large copy undoes the newest finished change at once, as in Finder: the
/// copy's entry comes only once it ends.
@MainActor @Test(.timeLimit(.minutes(2))) func cmdZOnARenameDuringALargeCopyRunsAtOnce()
    async throws
{
    let files = FakeFiles()
    let watcher = Watcher()
    let history = UndoHistory(log: { _ in })
    let queue = await queueAfterARename(files, history, watcher)
    let copy = await enqueue(queue, .copy(["/S/big"], into: "/A"), watcher)
    #expect(await files.events.wait { $0.contains("copy /S/big") })

    let undone = try await value(of: history.undo(with: queue))

    #expect(undone.phase == .done)
    #expect(files.events.all.contains("move /A/b to /A/a"))
    #expect(watcher.state(of: copy) == nil)
    files.releaseAll()
    #expect(await watcher.waitUntilFinished(copy))
    await history.catchUp(with: queue)
    #expect(history.undoTitle == "Undo Copy")
    #expect(!history.canRedo)
}

/// Neither a paused operation nor one waiting for an answer holds a press.
@MainActor @Test(.timeLimit(.minutes(2))) func aPressDoesntWaitForAPausedOrAskingOperation()
    async throws
{
    let files = FakeFiles()
    let watcher = Watcher()
    let prompter = Prompter()
    let history = UndoHistory(log: { _ in })
    let (finished, feed) = AsyncStream.makeStream(of: FileOperationQueue.Snapshot.self)
    history.follow(finished)
    let queue = FileOperationQueue(
        fileSystem: files.fileSystem(), prompts: prompter.prompts, clock: ContinuousClock(),
        onChange: { watcher.snapshots.append($0) }, onAnyFinish: { feed.yield($0) })
    _ = await queue.perform(.rename("/A/a", to: "b"))
    _ = await queue.perform(.rename("/A/c", to: "d"))
    await history.catchUp(with: queue)
    files.place("/A/b")
    files.place("/A/d")
    files.place("/A/m/x")
    files.place("/A/n/x")
    let asking = await enqueue(queue, .move(["/A/m/x"], into: "/A/n"), watcher)
    #expect(await watcher.waitUntil(asking, is: .waitingForAnswer))
    // Held in its plan, so only the pause settles it.
    files.holdScan(of: "/A/p")
    let paused = await enqueue(queue, .move(["/A/p"], into: "/B"), watcher)
    #expect(await files.events.wait { $0.contains("holding scan /A/p") })
    await queue.pause(paused)

    #expect(try await value(of: history.undo(with: queue)).phase == .done)
    #expect(files.events.all.contains("move /A/d to /A/c"))
    await queue.cancel(asking)
    await queue.cancel(paused)
    files.letScanGo(of: "/A/p")
}

/// The Undo item stays on while a copy runs and names the newest finished change; once the copy
/// ends, it names the copy.
@MainActor @Test(.timeLimit(.minutes(2)))
func theUndoItemNamesTheNewestFinishedChangeWhileACopyRuns() async throws {
    let files = FakeFiles()
    let watcher = Watcher()
    let history = UndoHistory(log: { _ in })
    let queue = await queueAfterARename(files, history, watcher)
    let pane = Pane(
        location: Location(path: "/A"), service: ListingService(),
        systemActions: StubSystemActions(), settings: untouchedSettings())
    let context = CommandContext(pane: pane, fileOperations: queue, undoHistory: history)
    let undo = try #require(UndoCommands.bindings.first { $0.command == UndoCommands.undo })

    let copy = await enqueue(queue, .copy(["/S/big"], into: "/A"), watcher)

    #expect(undo.isEnabled?(context) == true)
    #expect(undo.title?(context) == "Undo Rename")
    files.releaseAll()
    #expect(await watcher.waitUntilFinished(copy))
    await settle { undo.title?(context) == "Undo Copy" }
}

/// Cmd-Shift-Z during a copy redoes at once too.
@MainActor @Test(.timeLimit(.minutes(2))) func aRedoDuringACopyRunsAtOnce() async throws {
    let files = FakeFiles()
    let watcher = Watcher()
    let history = UndoHistory(log: { _ in })
    let queue = await queueAfterARename(files, history, watcher)
    #expect(await result(of: history.undo(with: queue))?.phase == .done)
    files.remove("/A/b")
    files.place("/A/a")
    let copy = await enqueue(queue, .copy(["/S/big"], into: "/B"), watcher)
    #expect(await files.events.wait { $0.contains("copy /S/big") })

    #expect(try await value(of: history.redo(with: queue)).phase == .done)

    #expect(files.events.all.filter { $0 == "move /A/a to /A/b" }.count == 2)
    files.releaseAll()
    #expect(await watcher.waitUntilFinished(copy))
}

/// Pressed in the same turn as a key that queued an operation, Undo waits the milliseconds
/// that operation takes. If it changed nothing, the press was for it, so it does nothing rather
/// than undo the change before it: failed, refused, every item skipped, or done with nothing
/// to do.
@MainActor
@Test(
    .timeLimit(.minutes(2)),
    arguments: [
        "failed", "refused", "skipped", "nothing to do",
    ])
func aPressForAnOperationThatChangedNothingDoesNothing(_ ending: String) async throws {
    let files = FakeFiles()
    let watcher = Watcher()
    let history = UndoHistory(log: { _ in })
    let queue = await queueAfterARename(files, history, watcher)
    // Copies `/S/big` into `/A`, so a rename of `/A/big` is refused.
    _ = await enqueue(queue, .copy(["/S/big"], into: "/A"), watcher)
    #expect(await files.events.wait { $0.contains("copy /S/big") })
    files.failMove(
        to: "/A/r", with: FileOperationError(reason: .permissionDenied, path: "/A/r", errno: EACCES)
    )
    files.place("/A/x")
    let operation: FileOperation =
        switch ending {
        case "failed": .rename("/A/q", to: "r")
        case "refused": .rename("/A/big", to: "r")
        // An item moved into the folder it is in has nothing to do, and asks nothing.
        case "skipped": .move(["/A/x"], into: "/A")
        default: .trash([])
        }

    let state = queue.submit(operation)
    let undo = history.undo(with: queue)

    #expect(await bounded(state)?.record.changes.isEmpty == true)
    #expect(await result(of: undo) == nil)
    #expect(!files.events.all.contains("move /A/b to /A/a"))
    #expect(history.undoTitle == "Undo Rename")
    files.releaseAll()
}

/// The same press made once the history has taken the operation in undoes the change before
/// it: the press no longer waits for anything.
@MainActor @Test func aPressAfterAnOperationThatChangedNothingUndoesTheChangeBefore()
    async throws
{
    let files = FakeFiles()
    let watcher = Watcher()
    let history = UndoHistory(log: { _ in })
    let queue = await queueAfterARename(files, history, watcher)
    _ = await queue.perform(.trash([]))
    await history.catchUp(with: queue)

    #expect(try await value(of: history.undo(with: queue)).phase == .done)
    #expect(files.events.all.contains("move /A/b to /A/a"))
}

/// The user cancelling the operation a press waits for is the same: the press does nothing.
@MainActor @Test(.timeLimit(.minutes(2)))
func aPressForAnOperationCancelledBeforeItChangedAnythingDoesNothing()
    async throws
{
    let files = FakeFiles()
    let watcher = Watcher()
    let history = UndoHistory(log: { _ in })
    // A clock that doesn't move, so the move never passes the press wait.
    let queue = await queueAfterARename(files, history, watcher, clock: ManualClock())
    files.holdVolume(of: "/A/in")
    let moveID = FileOperationQueue.ID(queue.submittedCount)
    let move = queue.submit(.move(["/A/near"], into: "/A/in"))
    let undo = history.undo(with: queue)
    #expect(await files.events.wait { $0.contains("holding volume /A/in") })

    await queue.cancel(moveID)

    #expect(await bounded(move)?.phase == .cancelled(leftBehind: nil))
    #expect(await result(of: undo) == nil)
    #expect(!files.events.all.contains("move /A/b to /A/a"))
    files.letVolumeGo(of: "/A/in")
}

/// A move to another volume says so before its pre-scan, so like a copy or a duplicate still
/// being planned it never holds a press.
@MainActor @Test(.timeLimit(.minutes(2)))
func aPressDoesntWaitForACopyDuplicateOrMoveAcrossVolumesStillPlanning() async throws {
    let files = FakeFiles()
    let watcher = Watcher()
    let history = UndoHistory(log: { _ in })
    let queue = await queueAfterARename(files, history, watcher, clock: ManualClock())
    for path in ["/A/far", "/S/big", "/A/dup"] { files.holdScan(of: path) }
    _ = queue.submit(.move(["/A/far"], into: "/B"))
    _ = queue.submit(.copy(["/S/big"], into: "/A"))
    _ = queue.submit(.duplicate(["/A/dup"]))
    #expect(
        await files.events.wait { events in
            ["/A/far", "/S/big", "/A/dup"].allSatisfy { events.contains("holding scan \($0)") }
        })

    let undo = history.undo(with: queue)

    // Waited for with a timeout, then let go, so a press that waits fails rather than hangs.
    #expect(await files.events.wait { $0.contains("move /A/b to /A/a") })
    for path in ["/A/far", "/S/big", "/A/dup"] { files.letScanGo(of: path) }
    files.releaseAll()
    #expect(await result(of: undo)?.phase == .done)
}

/// A move whose volume read hangs, as on a share that stopped answering, holds a press for no
/// more than `pressWait`.
@MainActor @Test(.timeLimit(.minutes(2))) func aPressWaitsAtMostThePressWait() async throws {
    let files = FakeFiles()
    let watcher = Watcher()
    let history = UndoHistory(log: { _ in })
    let clock = ManualClock()
    let queue = await queueAfterARename(files, history, watcher, clock: clock)
    files.holdVolume(of: "/A/in")
    _ = queue.submit(.move(["/A/near"], into: "/A/in"))
    #expect(await files.events.wait { $0.contains("holding volume /A/in") })

    let undo = history.undo(with: queue)
    try await pause()
    #expect(!files.events.all.contains("move /A/b to /A/a"))
    clock.advance(by: FileOperationQueue.pressWait)

    #expect(await files.events.wait { $0.contains("move /A/b to /A/a") })
    files.letVolumeGo(of: "/A/in")
    #expect(await result(of: undo)?.phase == .done)
}

/// Pausing the operation a press waits for lets the press go ahead.
@MainActor @Test(.timeLimit(.minutes(2))) func pausingTheOperationAPressWaitsForLetsItGo()
    async throws
{
    let files = FakeFiles()
    let watcher = Watcher()
    let history = UndoHistory(log: { _ in })
    let queue = await queueAfterARename(files, history, watcher, clock: ManualClock())
    files.holdVolume(of: "/A/in")
    let moveID = FileOperationQueue.ID(queue.submittedCount)
    _ = queue.submit(.move(["/A/near"], into: "/A/in"))
    #expect(await files.events.wait { $0.contains("holding volume /A/in") })
    let undo = history.undo(with: queue)
    try await pause()
    #expect(!files.events.all.contains("move /A/b to /A/a"))

    await queue.pause(moveID)

    #expect(await files.events.wait { $0.contains("move /A/b to /A/a") })
    await queue.cancel(moveID)
    files.letVolumeGo(of: "/A/in")
    #expect(await result(of: undo)?.phase == .done)
}

/// An operation that finished before the press counts for nothing, however late the history
/// hears of it: an empty one doesn't stop the press, and neither does a reported failure.
@MainActor @Test(.timeLimit(.minutes(2)))
func anOperationFinishedBeforeThePressCountsForNothing() async throws {
    let folder = try TemporaryFolder("UndoHistoryTests")
    let root = folder.url.path
    try write("a", to: root + "/a.txt")
    let history = UndoHistory(log: { _ in })
    let held = HeldFinishes()
    let queue = heldQueue(history, held)
    _ = await queue.perform(.rename(root + "/a.txt", to: "b.txt"))
    held.release()
    await settle { history.canUndo }
    _ = await queue.perform(.trash([]))
    await queue.report(
        .receive(name: "mail.eml", app: nil, into: root),
        errors: [FileOperationError(reason: .unreachable, path: root, errno: ETIMEDOUT)])

    let undo = history.undo(with: queue)
    try await Task.sleep(for: .milliseconds(50))
    held.release()

    #expect(try await value(of: undo).phase == .done)
    #expect(exists(root + "/a.txt"))
}

/// Presses run one at a time in the order made: two quick presses of Undo undo two entries,
/// and two of Redo redo them again.
@MainActor @Test(.timeLimit(.minutes(2))) func twoQuickPressesUndoTwoEntriesAndRedoThem()
    async throws
{
    let files = FakeFiles()
    let watcher = Watcher()
    let history = UndoHistory(log: { _ in })
    let queue = await queueAfterARename(files, history, watcher)
    _ = await queue.perform(.rename("/A/c", to: "d"))
    await history.catchUp(with: queue)
    files.place("/A/d")

    let first = history.undo(with: queue)
    let second = history.undo(with: queue)
    #expect(history.isBusy)

    #expect(try await value(of: first).record.changes == [.moved(from: "/A/d", to: "/A/c")])
    #expect(try await value(of: second).record.changes == [.moved(from: "/A/b", to: "/A/a")])
    #expect(!history.canUndo)
    #expect(history.redoTitle == "Redo Rename")
    files.remove("/A/b")
    files.remove("/A/d")
    files.place("/A/a")
    files.place("/A/c")

    let redoFirst = history.redo(with: queue)
    let redoSecond = history.redo(with: queue)

    #expect(try await value(of: redoFirst).record.changes == [.moved(from: "/A/a", to: "/A/b")])
    #expect(try await value(of: redoSecond).record.changes == [.moved(from: "/A/c", to: "/A/d")])
    #expect(!history.canRedo)
    #expect(!history.isBusy)
}

/// A press waiting its turn behind a running undo does nothing if a new change is made
/// meanwhile: the press named the change before it.
@MainActor @Test(.timeLimit(.minutes(2)))
func aPressWaitingItsTurnWhileANewChangeIsMadeDoesNothing() async throws {
    let files = FakeFiles()
    let watcher = Watcher()
    let history = UndoHistory(log: { _ in })
    let queue = await queueAfterARename(files, history, watcher)
    // Undone across volumes, so the first undo copies back and holds until released.
    files.release("/A/far")
    _ = await queue.perform(.move(["/A/far"], into: "/B"))
    await history.catchUp(with: queue)
    files.place("/B/far")
    let first = history.undo(with: queue)
    #expect(await files.events.wait { $0.contains("copy /B/far") })
    let second = history.undo(with: queue)

    _ = await queue.perform(.rename("/A/q", to: "r"))
    files.releaseAll()

    #expect(await result(of: first)?.phase == .done)
    #expect(await result(of: second) == nil)
    #expect(!files.events.all.contains("move /A/b to /A/a"))
    #expect(history.undoTitle == "Undo Rename")
}

// MARK: What a copy that didn't finish recorded

/// A copy cancelled after its first item recorded that item only, and its undo trashes only
/// that item.
@MainActor @Test func aPartlyCancelledCopyUndoesOnlyWhatItMade() async throws {
    let files = FakeFiles()
    let watcher = Watcher()
    let history = UndoHistory(log: { _ in })
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
    let history = UndoHistory(log: { _ in })
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
    let history = UndoHistory(log: { _ in })
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
    let history = UndoHistory(log: { _ in })
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
    let history = UndoHistory(log: { _ in })
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

    /// A duplicate of ~/Downloads carries `group:everyone deny delete`, which refuses a move out
    /// of the Trash as it refuses one in; both go, and it keeps the ACL in each place
    /// (docs/decisions/0105-trash-past-a-deny-delete-acl.md).
    @Test func aFolderWhoseACLDeniesDeletingItIsTrashedAndPutBackKeepingIt() async throws {
        let image = try await DiskImage("UndoHistoryTests")
        let folder = image.mountPoint + "/Downloads copy"
        try makeFolder(folder)
        try denyDelete(folder)
        let acl = try #require(aclText(folder))
        let harness = Harness()

        let trashed = await harness.perform(.trash([folder]))
        guard case .trashed(_, let url) = trashed.record.changes.first else {
            Issue.record("the trash recorded \(trashed.record.changes) \(trashed.errors)")
            return
        }
        #expect(aclText(url.path) == acl)

        let undone = try await harness.undo()
        #expect(undone.record.changes == [.putBack(from: url, to: folder)])
        #expect(!exists(url.path))
        #expect(aclText(folder) == acl)
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

    /// A new folder something was put in since, as from Finder, goes to the Trash with what is
    /// in it, where Put Back can bring it all back (0072 edge case 8).
    @Test func undoingANewFolderThatHoldsItemsTrashesItWhole() async throws {
        let image = try await DiskImage("UndoHistoryTests")
        let root = image.mountPoint
        let harness = Harness()
        await harness.perform(.newFolder(in: root))
        try write("kept", to: root + "/untitled folder/inside.txt")

        let undone = try await harness.undo()

        guard case .uncreated(_, .newFolder, let trashed) = undone.record.changes.first else {
            Issue.record("the undo recorded \(undone.record.changes)")
            return
        }
        #expect(!exists(root + "/untitled folder"))
        #expect(try read(trashed.path + "/inside.txt") == "kept")
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

    /// exFAT makes its inodes up and they change when it is mounted again, so an item there is
    /// known by a fingerprint: its type and birth time. Editing it in place keeps it the same
    /// item; another file saved at the path fails the undo.
    @Test func onExFATAnUndoChecksAFingerprint() async throws {
        let image = try await DiskImage("UndoExFAT", megabytes: 40, fileSystem: "ExFAT")
        let root = image.mountPoint
        try write("a", to: root + "/a.txt")
        let harness = Harness()

        let renamed = await harness.perform(.rename(root + "/a.txt", to: "b.txt"))
        guard case .fingerprint = renamed.record.identities.values.first else {
            Issue.record("the rename recorded \(renamed.record.identities)")
            return
        }
        // Edited in place since, as in Finder, it is still the item the rename moved.
        let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: root + "/b.txt"))
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("+".utf8))
        try handle.close()
        #expect(try await harness.undo().phase == .done)
        #expect(try read(root + "/a.txt") == "a+")

        await harness.perform(.rename(root + "/a.txt", to: "b.txt"))
        // exFAT keeps birth times to 10 ms.
        try await Task.sleep(for: .milliseconds(50))
        try write("saved", to: root + "/c.txt")
        try FileManager.default.removeItem(atPath: root + "/b.txt")
        #expect(rename(root + "/c.txt", root + "/b.txt") == 0)
        let undone = try await harness.undo()
        #expect(undone.errors.map(\.reason) == [.notTheSameItem])
        #expect(try read(root + "/b.txt") == "saved")
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

/// An undo whose paths a running operation uses is refused at once, and its entry stays where
/// it was (0072 edge case 20). A second press waits its turn and is refused the same way.
@MainActor @Test(.timeLimit(.minutes(2))) func aRefusedUndoKeepsItsEntry() async throws {
    let files = FakeFiles()
    let watcher = Watcher()
    let history = UndoHistory(log: { _ in })
    let queue = followedQueue(history, fileSystem: files.fileSystem(), watcher: watcher)
    files.place("/A/m/x")
    files.place("/A/b")
    recordEarlier(
        history, .move(["/A/x"], into: "/A/m"), finished(.moved(from: "/A/x", to: "/A/m/x")))
    recordEarlier(history, .rename("/A/a", to: "b"), finished(.moved(from: "/A/a", to: "/A/b")))
    // It reads the renamed item, so an undo of the rename is refused while it runs.
    let copy = await enqueue(queue, .copy(["/A/b"], into: "/B"), watcher)
    #expect(await files.events.wait { $0.contains("copy /A/b") })

    let first = history.undo(with: queue)
    let second = history.undo(with: queue)

    for press in [first, second] {
        guard case .refused = await result(of: press)?.phase else {
            Issue.record("the undo wasn't refused")
            return
        }
    }
    #expect(history.undoTitle == "Undo Rename")
    #expect(!history.canRedo)
    files.releaseAll()
    #expect(await watcher.waitUntilFinished(copy))
    await history.catchUp(with: queue)
    #expect(history.undoTitle == "Undo Copy")
    files.place("/B/b")
    #expect(await result(of: history.undo(with: queue))?.phase == .done)
    #expect(await result(of: history.undo(with: queue))?.phase == .done)
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
    let history = UndoHistory(log: { _ in })
    let queue = followedQueue(history, fileSystem: files.fileSystem(), watcher: watcher)
    files.place("/B/x")
    files.place("/A/q")
    recordEarlier(history, .move(["/A/x"], into: "/B"), finished(.moved(from: "/A/x", to: "/B/x")))
    let undo = history.undo(with: queue)
    #expect(await files.events.wait { $0.contains("copy /B/x") })

    recordEarlier(history, .rename("/A/p", to: "q"), finished(.moved(from: "/A/p", to: "/A/q")))
    files.releaseAll()

    #expect(await result(of: undo)?.phase == .done)
    #expect(files.events.all.contains("delete /B/x"))
    #expect(!history.canRedo)
    #expect(history.undoTitle == "Undo Rename")
    #expect(await result(of: history.undo(with: queue))?.phase == .done)
    #expect(!history.canUndo)
}

/// A move between volumes undone whose copy back is made but whose item can't be deleted where
/// it was: the copy back is in no entry, so there is no Redo, and the move stays to undo. Its
/// check then names the copy in the way, which drops it: both copies are kept.
@MainActor @Test func anUndoThatCopiesBackButCantDeleteOffersNoRedo() async throws {
    let files = FakeFiles(releasingAll: true)
    let watcher = Watcher()
    let history = UndoHistory(log: { _ in })
    let queue = followedQueue(history, fileSystem: files.fileSystem(), watcher: watcher)
    files.place("/B/x")
    let denied = FileOperationError(reason: .permissionDenied, path: "/B/x", errno: EACCES)
    files.failDelete(of: "/B/x", with: denied)
    recordEarlier(history, .move(["/A/x"], into: "/B"), finished(.moved(from: "/A/x", to: "/B/x")))

    let undone = try await value(of: history.undo(with: queue))

    #expect(undone.phase == .failed)
    #expect(undone.errors == [denied])
    #expect(!history.canRedo)
    #expect(history.undoTitle == "Undo Move 1 Item")
    files.place("/A/x")
    let again = try await value(of: history.undo(with: queue))
    #expect(again.errors == [FileOperationError(reason: .exists, path: "/A/x", errno: EEXIST)])
    #expect(!history.canUndo)
}

/// An undo that fails part way, its check passed, keeps what it couldn't undo as the entry to
/// undo again, and what it did as the entry Redo reverses, so nothing is left that can't be
/// undone.
@MainActor @Test func anUndoFailingAtItsSecondOfThreeStepsKeepsTheRestToUndo() async throws {
    let files = FakeFiles()
    let watcher = Watcher()
    let history = UndoHistory(log: { _ in })
    let queue = followedQueue(history, fileSystem: files.fileSystem(), watcher: watcher)
    let names = ["p1", "p2", "p3"]
    for name in names { files.place("/A/d/\(name)") }
    recordEarlier(
        history, .move(names.map { "/A/\($0)" }, into: "/A/d"),
        OperationState(
            phase: .done,
            progress: OperationState.Progress(
                itemsDone: 3, itemCount: 3, copied: CopyProgress(bytes: 0, files: 0), total: nil),
            errors: [],
            record: OperationRecord(
                changes: names.map { .moved(from: "/A/\($0)", to: "/A/d/\($0)") })))
    let denied = FileOperationError(reason: .permissionDenied, path: "/A/p2", errno: EACCES)
    files.failMove(to: "/A/p2", with: denied)

    let undone = try await value(of: history.undo(with: queue))

    #expect(undone.phase == .failed)
    #expect(undone.errors == [denied])
    #expect(
        undone.record.changes == [
            .moved(from: "/A/d/p3", to: "/A/p3"), .moved(from: "/A/d/p1", to: "/A/p1"),
        ])
    #expect(history.undoTitle == "Undo Move 3 Items")
    #expect(history.redoTitle == "Redo Move 3 Items")
    let again = try await value(of: history.undo(with: queue))
    #expect(again.record.changes == [.moved(from: "/A/d/p2", to: "/A/p2")])
    #expect(!history.canUndo)
    files.remove("/A/d/p2")
    files.place("/A/p2")
    let redone = try await value(of: history.redo(with: queue))
    #expect(redone.record.changes == [.moved(from: "/A/p2", to: "/A/d/p2")])
    #expect(history.canRedo)
}

/// A redo of a replace whose source is removed between the check and the copy: the original
/// went to the Trash first, so the redo's entry holds that trash and Undo puts the original
/// back; the copy that failed stays on Redo (0072 edge case 14).
@MainActor @Test func aRedoWhoseSourceGoesBetweenCheckAndCopyCanBeUndone() async throws {
    let files = FakeFiles(releasingAll: true)
    let watcher = Watcher()
    let history = UndoHistory(log: { _ in })
    let queue = followedQueue(history, fileSystem: files.fileSystem(), watcher: watcher)
    let original = URL(fileURLWithPath: "/S/.Trashes/501/old/a")
    recordEarlier(
        history, .copy(["/S/a"], into: "/A"),
        finished(
            .replaced("/A/a", originalTrashedTo: original),
            .created("/A/a", from: .copy(of: "/S/a"))))
    files.place("/A/a")
    #expect(try await value(of: history.undo(with: queue)).phase == .done)
    #expect(history.redoTitle == "Redo Replace")
    let gone = FileOperationError(reason: .sourceGone, path: "/S/a", errno: ENOENT)
    files.failCopy(of: "/S/a", with: gone)

    let redone = try await value(of: history.redo(with: queue))

    #expect(redone.errors == [gone])
    #expect(redone.record.changes.map(\.location) == ["/S/.Trashes/501/a"])
    #expect(history.undoTitle == "Undo Replace")
    #expect(history.redoTitle == "Redo Replace")
    files.remove("/A/a")
    #expect(try await value(of: history.undo(with: queue)).phase == .done)
    #expect(files.events.all.contains("move /S/.Trashes/501/a to /A/a"))
}

/// A move to another volume whose source couldn't be deleted is recorded as a copy, so its undo
/// trashes the copy and leaves the source (0072 edge case 19).
@MainActor @Test func undoingAMoveWhoseSourceCouldntBeDeletedTrashesTheCopy() async throws {
    let files = FakeFiles(releasingAll: true)
    let watcher = Watcher()
    let history = UndoHistory(log: { _ in })
    let queue = followedQueue(history, fileSystem: files.fileSystem(), watcher: watcher)
    files.place("/A/x")
    let denied = FileOperationError(reason: .permissionDenied, path: "/A/x", errno: EACCES)
    files.failDelete(of: "/A/x", with: denied)

    let moved = await queue.perform(.move(["/A/x"], into: "/B"))
    await history.catchUp(with: queue)

    #expect(moved.record.changes == [.created("/B/x", from: .copy(of: "/A/x"))])
    #expect(history.undoTitle == "Undo Move 1 Item")
    files.place("/B/x")
    #expect(try await value(of: history.undo(with: queue)).phase == .done)
    #expect(files.events.all.contains("trash /B/x"))
    #expect(!files.events.all.contains { $0.hasPrefix("move /B/x") })
    #expect(files.events.all.filter { $0.hasPrefix("delete") } == ["delete failed /A/x"])
}

/// A move to another volume that kept its changed source undoes as a copy: the copy goes to
/// the Trash and the source stays as it is.
@MainActor @Test func undoingAMoveThatKeptAChangedSourceTrashesTheCopy() async throws {
    let files = FakeFiles(releasingAll: true)
    let watcher = Watcher()
    let history = UndoHistory(log: { _ in })
    let queue = followedQueue(history, fileSystem: files.fileSystem(), watcher: watcher)
    files.place("/A/x")
    files.changeDuringCopy(of: "/A/x")

    let moved = await queue.perform(.move(["/A/x"], into: "/B"))
    await history.catchUp(with: queue)

    #expect(moved.record.changes == [.created("/B/x", from: .copy(of: "/A/x"))])
    #expect(history.undoTitle == "Undo Move 1 Item")
    files.place("/B/x")
    #expect(try await value(of: history.undo(with: queue)).phase == .done)
    #expect(files.events.all.contains("trash /B/x"))
    #expect(!files.events.all.contains { $0.hasPrefix("move /B/x") })
    #expect(!files.events.all.contains { $0.hasPrefix("delete") })
}

/// Undoing a move to another volume moves the item back by a copy, and keeps the item where
/// the move left it when it changed during that copy.
@MainActor @Test func anUndoThatCopiesBackKeepsAnItemThatChangedWhileItWasCopied() async throws {
    let files = FakeFiles(releasingAll: true)
    let watcher = Watcher()
    let history = UndoHistory(log: { _ in })
    let queue = followedQueue(history, fileSystem: files.fileSystem(), watcher: watcher)
    files.place("/A/x")

    let moved = await queue.perform(.move(["/A/x"], into: "/B"))
    await history.catchUp(with: queue)
    #expect(moved.record.changes == [.moved(from: "/A/x", to: "/B/x")])
    files.remove("/A/x")
    files.place("/B/x")
    files.changeDuringCopy(of: "/B/x")

    let undone = try await value(of: history.undo(with: queue))

    #expect(
        undone.errors == [
            FileOperationError(reason: .changedDuringMove, path: "/B/x", errno: nil)
        ])
    #expect(undone.record.changes == [.created("/A/x", from: .copy(of: "/B/x"))])
    #expect(files.events.all.filter { $0.hasPrefix("delete") } == ["delete /A/x"])
}

// MARK: Identity of items

/// Another inode at the recorded path, on a volume whose IDs persist, is another item, and the
/// undo fails.
@MainActor @Test func anotherInodeAtTheRecordedPathFailsTheUndo() async throws {
    let files = FakeFiles()
    let watcher = Watcher()
    let history = UndoHistory(log: { _ in })
    let queue = await queueAfterARename(files, history, watcher)
    files.identify("/A/b", as: .persistent(volume: "fake", inode: 7))

    let undone = try await value(of: history.undo(with: queue))

    #expect(
        undone.errors == [FileOperationError(reason: .notTheSameItem, path: "/A/b", errno: nil)])
    #expect(!files.events.all.contains("move /A/b to /A/a"))
    #expect(!history.canUndo)
}

/// An operation an item of which couldn't be identified can't be undone: its entry reads
/// "Can’t Undo", holds back the entries before it, and the reason is logged.
@MainActor @Test func anOperationWithAnUnidentifiedItemCantBeUndone() async throws {
    let files = FakeFiles()
    let watcher = Watcher()
    let logged = EventLog<String>()
    let history = UndoHistory(log: { logged.append($0) })
    let queue = await queueAfterARename(files, history, watcher)
    let unread = FileOperationError(reason: .other, path: "/A/d", errno: nil)
    files.failIdentity(of: "/A/d", with: unread)

    let renamed = await queue.perform(.rename("/A/c", to: "d"))
    await history.catchUp(with: queue)

    #expect(renamed.record.unidentified == [unread])
    #expect(history.undoTitle == "Can’t Undo Rename")
    #expect(!history.canUndo)
    #expect(await result(of: history.undo(with: queue)) == nil)
    #expect(!files.events.all.contains("move /A/b to /A/a"))
    #expect(logged.all.count == 1)
    #expect(logged.all.first?.contains("/A/d") == true)
}

/// An undo whose result can't be identified offers no Redo, and Redo can't reach older entries
/// past it, so they go too.
@MainActor @Test func anUnidentifiedUndoClearsOlderRedoEntries() async throws {
    let files = FakeFiles()
    let watcher = Watcher()
    let history = UndoHistory(log: { _ in })
    let queue = await queueAfterARename(files, history, watcher)
    _ = await queue.perform(.rename("/A/c", to: "d"))
    await history.catchUp(with: queue)
    files.place("/A/d")
    #expect(try await value(of: history.undo(with: queue)).phase == .done)
    #expect(history.canRedo)
    files.failIdentity(
        of: "/A/a", with: FileOperationError(reason: .other, path: "/A/a", errno: nil))

    #expect(try await value(of: history.undo(with: queue)).record.unidentified.count == 1)

    #expect(!history.canRedo)
}

/// A redo whose result can't be identified goes on Undo as Can’t Undo, and the older entries
/// under it go, as for a delete.
@MainActor @Test func anUnidentifiedRedoIsCantUndoAndClearsOlderEntries() async throws {
    let files = FakeFiles()
    let watcher = Watcher()
    let history = UndoHistory(log: { _ in })
    let queue = await queueAfterARename(files, history, watcher)
    _ = await queue.perform(.rename("/A/c", to: "d"))
    await history.catchUp(with: queue)
    files.place("/A/d")
    #expect(try await value(of: history.undo(with: queue)).phase == .done)
    files.remove("/A/d")
    files.place("/A/c")
    files.failIdentity(
        of: "/A/d", with: FileOperationError(reason: .other, path: "/A/d", errno: nil))

    #expect(try await value(of: history.redo(with: queue)).record.unidentified.count == 1)

    #expect(history.undoTitle == "Can’t Undo Rename")
    #expect(history.undoCount == 1)
}

/// A Can’t Undo entry clears the entries under it and then counts toward the 100 like any.
@MainActor @Test func aCantUndoEntryCountsTowardTheHundred() {
    let history = UndoHistory(log: { _ in })
    for number in 1...5 {
        recordEarlier(
            history, .rename("/A/\(number)", to: "n\(number)"),
            finished(.moved(from: "/A/\(number)", to: "/A/n\(number)")))
    }
    var unidentified = finished(.moved(from: "/A/u", to: "/A/v"))
    unidentified.record.unidentified = [
        FileOperationError(reason: .other, path: "/A/v", errno: nil)
    ]
    recordEarlier(history, .rename("/A/u", to: "v"), unidentified)
    #expect(history.undoCount == 1)
    #expect(history.undoTitle == "Can’t Undo Rename")

    for number in 1...UndoHistory.limit {
        recordEarlier(
            history, .rename("/B/\(number)", to: "n\(number)"),
            finished(.moved(from: "/B/\(number)", to: "/B/n\(number)")))
    }

    #expect(history.undoCount == 100)
    #expect(history.canUndo)
}

// MARK: Limit

@MainActor @Test func theHistoryKeepsTheLastHundredEntries() {
    let history = UndoHistory(log: { _ in })
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
    let history = UndoHistory(log: { _ in })
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
    let history = UndoHistory(log: { _ in })
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
@MainActor @Test(.timeLimit(.minutes(2))) func undoStopsWaitingWhenTheFinishedStreamEnds()
    async throws
{
    let folder = try TemporaryFolder("UndoHistoryTests")
    let root = folder.url.path
    try write("a", to: root + "/a.txt")
    let history = UndoHistory(log: { _ in })
    let held = HeldFinishes()
    let queue = heldQueue(history, held)
    _ = await queue.perform(.rename(root + "/a.txt", to: "b.txt"))

    let undo = history.undo(with: queue)
    held.end()

    #expect(await result(of: undo) == nil)
    #expect(!history.isBusy)
}

// MARK: In a server's share

/// A paste into a share selected in the server's column, and a move inside the share with the
/// server as the first column, undo on the paths their records name, and the trail stays as it
/// was (docs/decisions/0114-server-location.md).
@MainActor @Test func undoInAShareActsOnItsPathsAndLeavesTheServerColumn() async throws {
    let files = FakeFiles(releasingAll: true)
    files.add(mountedShare("music"))
    let history = UndoHistory(log: { _ in })
    let queue = followedQueue(history, fileSystem: files.fileSystem())
    let fixture = await PaneFixture.atServer(folders: [
        "/Volumes/music": [folder("a"), folder("b")], "/Volumes/music/a": [file("x.txt")],
        "/Volumes/music/b": [],
    ])
    fixture.pane.setViewMode(.column)
    let trail = try #require(fixture.pane.columnTrail)
    let server = trail.focused.pane
    await settle { server.state.isLoaded }
    server.select(Selection([ExactName("music")], cursor: ExactName("music")))
    await settle { trail.columns.count == 2 && trail.columns[1].pane.state.isLoaded }
    let clipboard = CutState(clipboard: MemoryClipboard())
    clipboard.copy([URL(fileURLWithPath: "/S/x.txt")])
    let paste = try #require(
        ClipboardCommands.bindings.first { $0.command == ClipboardCommands.paste })

    paste.run(
        CommandContext(
            pane: server, workspace: Workspace(tab: fixture.tab), fileOperations: queue,
            clipboard: clipboard))
    await settle { queue.submittedCount == 1 && queue.unfinishedCount == 0 }
    await history.catchUp(with: queue)
    let columns = trail.columns.map(\.pane)
    files.place("/Volumes/music/x.txt")
    #expect(history.undoTitle == "Undo Copy")
    #expect(try await value(of: history.undo(with: queue)).phase == .done)

    #expect(files.events.all.filter { $0.hasPrefix("trash") } == ["trash /Volumes/music/x.txt"])
    #expect(trail.columns.map(\.pane).elementsEqual(columns, by: ===))
    #expect(trail.focusedIndex == 0)
    #expect(server.selection.cursor == ExactName("music"))

    files.place("/Volumes/music/a/x.txt")
    _ = await queue.perform(.move(["/Volumes/music/a/x.txt"], into: "/Volumes/music/b"))
    await history.catchUp(with: queue)
    files.remove("/Volumes/music/a/x.txt")
    files.place("/Volumes/music/a", isFolder: true)
    files.place("/Volumes/music/b/x.txt")
    #expect(try await value(of: history.undo(with: queue)).phase == .done)

    #expect(files.events.all.contains("move /Volumes/music/b/x.txt to /Volumes/music/a/x.txt"))
    #expect(trail.columns.map(\.pane).elementsEqual(columns, by: ===))
    #expect(server.state.names == ["main", "music"])
}
