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
    #expect(try await #require(harness.history.undo(with: harness.queue)).value == nil)
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

/// An undo is one more queued operation: it runs beside a copy that holds its lane, rather than
/// waiting for it or holding up the main actor.
@MainActor @Test func anUndoRunsWhileACopyIsStillRunning() async throws {
    let files = FakeFiles()
    let watcher = Watcher()
    let history = UndoHistory()
    let queue = followedQueue(history, fileSystem: files.fileSystem(), watcher: watcher)
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

    #expect(await undone.value?.phase == .done)
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
    history.record(.move(["/A/x"], into: "/A/m"), finished(.moved(from: "/A/x", to: "/A/m/x")))
    history.record(.rename("/A/a", to: "b"), finished(.moved(from: "/A/a", to: "/A/b")))
    // The copy reads the renamed item, so its undo is refused while the copy runs.
    let copy = await enqueue(queue, .copy(["/A/b"], into: "/B"), watcher)
    #expect(await files.events.wait { $0.contains("copy /A/b") })

    let first = history.undo(with: queue)
    let second = history.undo(with: queue)

    #expect(second == nil)
    let refused = try #require(first)
    guard case .refused = await refused.value?.phase else {
        Issue.record("the undo wasn't refused")
        return
    }
    #expect(history.undoTitle == "Undo Rename")
    #expect(!history.canRedo)
    files.releaseAll()
    #expect(await watcher.waitUntilFinished(copy))
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
    history.record(.move(["/A/x"], into: "/B"), finished(.moved(from: "/A/x", to: "/B/x")))
    let undo = try #require(history.undo(with: queue))
    #expect(await files.events.wait { $0.contains("copy /B/x") })

    history.record(.rename("/A/p", to: "q"), finished(.moved(from: "/A/p", to: "/A/q")))
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
    history.record(.move(["/A/x"], into: "/B"), finished(.moved(from: "/A/x", to: "/B/x")))

    let undone = try await value(of: history.undo(with: queue))

    #expect(undone.phase == .failed)
    #expect(undone.errors == [denied])
    #expect(!history.canRedo)
    #expect(!history.canUndo)
}

// MARK: Limit

@MainActor @Test func theHistoryKeepsTheLastHundredEntries() {
    let history = UndoHistory()
    history.record(
        .trash(["/A/a"]),
        finished(.trashed(from: "/A/a", to: URL(fileURLWithPath: "/A/.Trashes/a"))))
    for number in 1...UndoHistory.limit {
        history.record(
            .rename("/A/\(number)", to: "n\(number)"),
            finished(.moved(from: "/A/\(number)", to: "/A/n\(number)")))
    }

    #expect(history.undoCount == 100)
    #expect(history.undoTitle == "Undo Rename")
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
