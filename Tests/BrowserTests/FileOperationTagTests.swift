import Base
import BrowserTestSupport
import Darwin
import Foundation
import TestSupport
import Testing

@testable import Browser

// Tag toggles through the queue and their undo and redo, on the real file system
// (docs/decisions/0121-tag-commands.md).

/// A queue over the real file system and the history that follows it, as the app's windows
/// make them.
@MainActor
private final class Harness {
    let queue: FileOperationQueue
    let history = UndoHistory(log: { _ in })

    init() {
        let (finished, feed) = AsyncStream.makeStream(of: FileOperationQueue.Snapshot.self)
        history.follow(finished)
        queue = FileOperationQueue(
            prompts: .unexpected, onChange: { _ in }, onAnyFinish: { feed.yield($0) })
    }

    /// Runs `operation` and waits until the history has taken it in.
    @discardableResult
    func perform(_ operation: FileOperation) async -> OperationState {
        let state = await queue.perform(operation)
        await history.catchUp(with: queue)
        return state
    }

    func undo() async throws -> OperationState {
        try #require(await history.undo(with: queue).value, "the undo did nothing")
    }

    func redo() async throws -> OperationState {
        try #require(await history.redo(with: queue).value, "the redo did nothing")
    }
}

/// A file named `name` in `folder` with the tags `tags`; its path.
private func file(_ name: String, in folder: TemporaryFolder, tags: [String] = []) async throws
    -> String
{
    let path = folder.url.appending(path: name).path
    try Data(name.utf8).write(to: URL(fileURLWithPath: path))
    if !tags.isEmpty { try await setTags(tags, path) }
    return path
}

private func tags(_ path: String) async throws -> [String] {
    try await BlockingCallThread.run { () throws(FileOperationError) -> [String] in
        try FinderTags.names(at: path)
    }
}

/// Sets the tags as another app would, outside the queue.
private func setTags(_ tags: [String], _ path: String) async throws {
    try await BlockingCallThread.run { () throws(FileOperationError) in
        try FinderTags.set(tags, at: path)
    }
}

@MainActor @Test func aTagAddedToTwoFilesUndoesAndRedoesAsFinderNamesIt() async throws {
    let folder = try TemporaryFolder("FileOperationTagTests")
    let a = try await file("a.txt", in: folder, tags: ["Work"])
    let b = try await file("b.txt", in: folder)
    let harness = Harness()

    let state = await harness.perform(.toggleTag("Red", on: [a, b]))

    #expect(state.phase == .done)
    #expect(try await tags(a) == ["Work", "Red"])
    #expect(try await tags(b) == ["Red"])
    #expect(harness.history.undoTitle == "Undo Add Tag “Red”")

    let undone = try await harness.undo()
    #expect(undone.phase == .done)
    #expect(try await tags(a) == ["Work"])
    #expect(try await tags(b) == [])
    #expect(harness.history.undoTitle == "Undo")
    #expect(harness.history.redoTitle == "Redo Add Tag “Red”")

    let redone = try await harness.redo()
    #expect(redone.phase == .done)
    #expect(try await tags(a) == ["Work", "Red"])
    #expect(try await tags(b) == ["Red"])
    #expect(harness.history.undoTitle == "Undo Add Tag “Red”")
    #expect(!harness.history.canRedo)
}

/// Finder's rule for a selection where some items have the tag: the click adds it to the rest,
/// and the items that had it are left as they are, so undo leaves them with it.
@MainActor @Test func aMixedSelectionGetsTheTagAndUndoLeavesItOnItemsThatHadIt() async throws {
    let folder = try TemporaryFolder("FileOperationTagTests")
    let had = try await file("had.txt", in: folder, tags: ["Red", "Work"])
    let lacked = try await file("lacked.txt", in: folder, tags: ["Blue"])
    let harness = Harness()

    let state = await harness.perform(.toggleTag("Red", on: [had, lacked]))

    #expect(state.record.changes == [.tagged(lacked, from: ["Blue"], to: ["Blue", "Red"])])
    #expect(try await tags(had) == ["Red", "Work"])
    #expect(try await tags(lacked) == ["Blue", "Red"])

    _ = try await harness.undo()
    #expect(try await tags(had) == ["Red", "Work"])
    #expect(try await tags(lacked) == ["Blue"])
}

@MainActor @Test func aTagEveryItemHasIsTakenOffEachAndUndoPutsBackTheExactList() async throws {
    let folder = try TemporaryFolder("FileOperationTagTests")
    let a = try await file("a.txt", in: folder, tags: ["Work", "Red", "Home"])
    let b = try await file("b.txt", in: folder, tags: ["Red"])
    let harness = Harness()

    await harness.perform(.toggleTag("Red", on: [a, b]))

    #expect(try await tags(a) == ["Work", "Home"])
    #expect(try await tags(b) == [])
    #expect(harness.history.undoTitle == "Undo Remove Tag “Red”")

    _ = try await harness.undo()
    #expect(try await tags(a) == ["Work", "Red", "Home"])
    #expect(try await tags(b) == ["Red"])
    #expect(harness.history.redoTitle == "Redo Remove Tag “Red”")
}

/// A file whose tags can't be written fails in the queue, naming it, and the items that did
/// change make an entry that undoes them.
@MainActor @Test func aReadOnlyFileFailsAndTheOthersStayUndoable() async throws {
    let folder = try TemporaryFolder("FileOperationTagTests")
    let locked = try await file("locked.txt", in: folder)
    let open = try await file("open.txt", in: folder)
    #expect(chmod(locked, 0o444) == 0)
    defer { chmod(locked, 0o644) }
    let harness = Harness()

    let state = await harness.perform(.toggleTag("Red", on: [locked, open]))

    #expect(state.phase == .failed)
    #expect(state.errors.map(\.reason) == [.permissionDenied])
    #expect(state.errors.map(\.path) == [locked])
    #expect(try await tags(open) == ["Red"])
    #expect(harness.history.undoTitle == "Undo Add Tag “Red”")

    _ = try await harness.undo()
    #expect(try await tags(open) == [])
    #expect(try await tags(locked) == [])
}

/// Undo never overwrites tags another app changed since: the check fails naming the item,
/// nothing changes, and the entry is kept once, as for an item in the way.
@MainActor @Test func tagsChangedSinceFailTheUndoAndChangeNothing() async throws {
    let folder = try TemporaryFolder("FileOperationTagTests")
    let a = try await file("a.txt", in: folder)
    let b = try await file("b.txt", in: folder)
    let harness = Harness()
    await harness.perform(.toggleTag("Red", on: [a, b]))
    try await setTags(["Red", "Green"], b)

    let undone = try await harness.undo()

    #expect(undone.phase == .failed)
    #expect(undone.errors == [FileOperationError(reason: .tagsChanged, path: b, errno: nil)])
    #expect(try await tags(a) == ["Red"])
    #expect(try await tags(b) == ["Red", "Green"])
    #expect(harness.history.undoTitle == "Undo Add Tag “Red”")

    // Set back, the kept entry undoes.
    try await setTags(["Red"], b)
    _ = try await harness.undo()
    #expect(try await tags(a) == [])
    #expect(try await tags(b) == [])
}

/// A tagged item renamed or deleted since is gone from where the entry has it: nothing is
/// changed, and the entry is dropped, as for a moved item deleted since.
@MainActor @Test func aTaggedItemRenamedSinceFailsTheUndoAndDropsTheEntry() async throws {
    let folder = try TemporaryFolder("FileOperationTagTests")
    let a = try await file("a.txt", in: folder)
    let b = try await file("b.txt", in: folder)
    let harness = Harness()
    await harness.perform(.toggleTag("Red", on: [a, b]))
    let renamed = folder.url.appending(path: "c.txt").path
    #expect(rename(b, renamed) == 0)

    let undone = try await harness.undo()

    #expect(undone.phase == .failed)
    #expect(undone.errors.map(\.reason) == [.sourceGone])
    #expect(try await tags(a) == ["Red"])
    #expect(try await tags(renamed) == ["Red"])
    #expect(!harness.history.canUndo)
}

/// An undo whose write fails for one item after the check undoes the rest, and keeps that item
/// to undo again, so nothing is left that can't be undone.
@MainActor @Test func anUndoFailingForOneItemKeepsItToUndoAgain() async throws {
    let folder = try TemporaryFolder("FileOperationTagTests")
    let a = try await file("a.txt", in: folder)
    let b = try await file("b.txt", in: folder)
    let harness = Harness()
    await harness.perform(.toggleTag("Red", on: [a, b]))
    #expect(chmod(b, 0o444) == 0)
    defer { chmod(b, 0o644) }

    let undone = try await harness.undo()

    #expect(undone.phase == .failed)
    #expect(undone.errors.map(\.path) == [b])
    #expect(try await tags(a) == [])
    #expect(try await tags(b) == ["Red"])
    #expect(harness.history.undoTitle == "Undo Add Tag “Red”")
    #expect(harness.history.redoTitle == "Redo Add Tag “Red”")

    #expect(chmod(b, 0o644) == 0)
    _ = try await harness.undo()
    #expect(try await tags(b) == [])
    // Redo puts back both halves, the later undo first.
    _ = try await harness.redo()
    _ = try await harness.redo()
    #expect(try await tags(a) == ["Red"])
    #expect(try await tags(b) == ["Red"])
}

/// Items on two volumes are one toggle and one entry, undone and redone together.
@MainActor @Test func itemsOnTwoVolumesToggleUndoAndRedoTogether() async throws {
    let folder = try TemporaryFolder("FileOperationTagTests")
    let image = try await DiskImage("FileOperationTagTests")
    let local = try await file("local.txt", in: folder)
    let other = image.mountPoint + "/other.txt"
    try Data("other".utf8).write(to: URL(fileURLWithPath: other))
    let harness = Harness()

    let state = await harness.perform(.toggleTag("Blue", on: [local, other]))

    #expect(state.phase == .done)
    #expect(try await tags(local) == ["Blue"])
    #expect(try await tags(other) == ["Blue"])
    _ = try await harness.undo()
    #expect(try await tags(local) == [])
    #expect(try await tags(other) == [])
    _ = try await harness.redo()
    #expect(try await tags(local) == ["Blue"])
    #expect(try await tags(other) == ["Blue"])
    try await image.detach()
}

/// A toggle that changed nothing, every item having been unreadable, makes no entry.
@MainActor @Test func aToggleThatChangedNothingMakesNoEntry() async throws {
    let folder = try TemporaryFolder("FileOperationTagTests")
    let gone = folder.url.appending(path: "gone.txt").path
    let harness = Harness()

    let state = await harness.perform(.toggleTag("Red", on: [gone]))

    #expect(state.phase == .failed)
    #expect(state.errors.map(\.reason) == [.sourceGone])
    #expect(harness.history.undoTitle == "Undo")
}
