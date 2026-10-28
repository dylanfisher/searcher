import Base
import BrowserTestSupport
import Darwin
import Foundation
import TestSupport
import Testing

@testable import Browser

// Tag toggles through the queue and their undo and redo, on the real file system
// (docs/decisions/0121-tag-commands.md). Tags are compared as Finder stores them, each name
// with its color.

private let red = FinderTag.all[0]
private let blue = FinderTag.all[4]
private let redEntry = red.entry
private let blueEntry = blue.entry
private let greenEntry = FinderTag.all[3].entry
/// A tag of the user's own whose color, 4, only the item's entry holds: no tag list need know it.
private let work = "Work\n4"
/// A tag with no color, stored without a number.
private let home = "Home"

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
        try FinderTags.entries(at: path)
    }
}

/// Sets the tags as another app would, outside the queue.
private func setTags(_ tags: [String], _ path: String) async throws {
    try await BlockingCallThread.run { () throws(FileOperationError) in
        try FinderTags.set(entries: tags, at: path)
    }
}

/// The item that holds `Work\n4` keeps that entry, color and all, through the toggle, its
/// undo and its redo.
@MainActor @Test func aTagAddedToTwoFilesUndoesAndRedoesAsFinderNamesIt() async throws {
    let folder = try TemporaryFolder("FileOperationTagTests")
    let a = try await file("a.txt", in: folder, tags: [work])
    let b = try await file("b.txt", in: folder)
    let harness = Harness()

    let state = await harness.perform(.toggleTag(red, on: [a, b]))

    #expect(state.phase == .done)
    #expect(try await tags(a) == [work, redEntry])
    #expect(try await tags(b) == [redEntry])
    #expect(harness.history.undoTitle == "Undo Add Tag “Red”")

    let undone = try await harness.undo()
    #expect(undone.phase == .done)
    #expect(try await tags(a) == [work])
    #expect(try await tags(b) == [])
    #expect(harness.history.undoTitle == "Undo")
    #expect(harness.history.redoTitle == "Redo Add Tag “Red”")

    let redone = try await harness.redo()
    #expect(redone.phase == .done)
    #expect(try await tags(a) == [work, redEntry])
    #expect(try await tags(b) == [redEntry])
    #expect(harness.history.undoTitle == "Undo Add Tag “Red”")
    #expect(!harness.history.canRedo)
}

/// Finder's rule for a selection where some items have the tag: the click adds it to the rest,
/// and the items that had it are left as they are, so undo leaves them with it.
@MainActor @Test func aMixedSelectionGetsTheTagAndUndoLeavesItOnItemsThatHadIt() async throws {
    let folder = try TemporaryFolder("FileOperationTagTests")
    let had = try await file("had.txt", in: folder, tags: [redEntry, work])
    let lacked = try await file("lacked.txt", in: folder, tags: [blueEntry])
    let harness = Harness()

    let state = await harness.perform(.toggleTag(red, on: [had, lacked]))

    #expect(
        state.record.changes == [.tagged(lacked, from: [blueEntry], to: [blueEntry, redEntry])])
    #expect(try await tags(had) == [redEntry, work])
    #expect(try await tags(lacked) == [blueEntry, redEntry])

    _ = try await harness.undo()
    #expect(try await tags(had) == [redEntry, work])
    #expect(try await tags(lacked) == [blueEntry])
}

@MainActor @Test func aTagEveryItemHasIsTakenOffEachAndUndoPutsBackTheExactList() async throws {
    let folder = try TemporaryFolder("FileOperationTagTests")
    let a = try await file("a.txt", in: folder, tags: [work, redEntry, home])
    let b = try await file("b.txt", in: folder, tags: [redEntry])
    let harness = Harness()

    await harness.perform(.toggleTag(red, on: [a, b]))

    #expect(try await tags(a) == [work, home])
    #expect(try await tags(b) == [])
    #expect(harness.history.undoTitle == "Undo Remove Tag “Red”")

    _ = try await harness.undo()
    #expect(try await tags(a) == [work, redEntry, home])
    #expect(try await tags(b) == [redEntry])
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

    let state = await harness.perform(.toggleTag(red, on: [locked, open]))

    #expect(state.phase == .failed)
    #expect(state.errors.map(\.reason) == [.permissionDenied])
    #expect(state.errors.map(\.path) == [locked])
    #expect(try await tags(open) == [redEntry])
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
    await harness.perform(.toggleTag(red, on: [a, b]))
    try await setTags([redEntry, greenEntry], b)

    let undone = try await harness.undo()

    #expect(undone.phase == .failed)
    #expect(undone.errors == [FileOperationError(reason: .tagsChanged, path: b, errno: nil)])
    #expect(try await tags(a) == [redEntry])
    #expect(try await tags(b) == [redEntry, greenEntry])
    #expect(harness.history.undoTitle == "Undo Add Tag “Red”")

    // Set back, the kept entry undoes.
    try await setTags([redEntry], b)
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
    await harness.perform(.toggleTag(red, on: [a, b]))
    let renamed = folder.url.appending(path: "c.txt").path
    #expect(rename(b, renamed) == 0)

    let undone = try await harness.undo()

    #expect(undone.phase == .failed)
    #expect(undone.errors.map(\.reason) == [.sourceGone])
    #expect(try await tags(a) == [redEntry])
    #expect(try await tags(renamed) == [redEntry])
    #expect(!harness.history.canUndo)
}

/// An undo whose write fails for one item after the check undoes the rest, and keeps that item
/// to undo again, so nothing is left that can't be undone.
@MainActor @Test func anUndoFailingForOneItemKeepsItToUndoAgain() async throws {
    let folder = try TemporaryFolder("FileOperationTagTests")
    let a = try await file("a.txt", in: folder)
    let b = try await file("b.txt", in: folder)
    let harness = Harness()
    await harness.perform(.toggleTag(red, on: [a, b]))
    #expect(chmod(b, 0o444) == 0)
    defer { chmod(b, 0o644) }

    let undone = try await harness.undo()

    #expect(undone.phase == .failed)
    #expect(undone.errors.map(\.path) == [b])
    #expect(try await tags(a) == [])
    #expect(try await tags(b) == [redEntry])
    #expect(harness.history.undoTitle == "Undo Add Tag “Red”")
    #expect(harness.history.redoTitle == "Redo Add Tag “Red”")

    #expect(chmod(b, 0o644) == 0)
    _ = try await harness.undo()
    #expect(try await tags(b) == [])
    // Redo puts back both halves, the later undo first.
    _ = try await harness.redo()
    _ = try await harness.redo()
    #expect(try await tags(a) == [redEntry])
    #expect(try await tags(b) == [redEntry])
}

/// Items on two volumes are one toggle and one entry, undone and redone together.
@MainActor @Test func itemsOnTwoVolumesToggleUndoAndRedoTogether() async throws {
    let folder = try TemporaryFolder("FileOperationTagTests")
    let image = try await DiskImage("FileOperationTagTests")
    let local = try await file("local.txt", in: folder)
    let other = image.mountPoint + "/other.txt"
    try Data("other".utf8).write(to: URL(fileURLWithPath: other))
    let harness = Harness()

    let state = await harness.perform(.toggleTag(blue, on: [local, other]))

    #expect(state.phase == .done)
    #expect(try await tags(local) == [blueEntry])
    #expect(try await tags(other) == [blueEntry])
    _ = try await harness.undo()
    #expect(try await tags(local) == [])
    #expect(try await tags(other) == [])
    _ = try await harness.redo()
    #expect(try await tags(local) == [blueEntry])
    #expect(try await tags(other) == [blueEntry])
    try await image.detach()
}

/// A toggle that changed nothing, every item having been unreadable, makes no entry.
@MainActor @Test func aToggleThatChangedNothingMakesNoEntry() async throws {
    let folder = try TemporaryFolder("FileOperationTagTests")
    let gone = folder.url.appending(path: "gone.txt").path
    let harness = Harness()

    let state = await harness.perform(.toggleTag(red, on: [gone]))

    #expect(state.phase == .failed)
    #expect(state.errors.map(\.reason) == [.sourceGone])
    #expect(harness.history.undoTitle == "Undo")
}

/// Another app changing only a tag's color counts as a change: the undo would write the old
/// color back over it, so it refuses as for any other change since.
@MainActor @Test func aColorChangedSinceFailsTheUndo() async throws {
    let folder = try TemporaryFolder("FileOperationTagTests")
    let a = try await file("a.txt", in: folder, tags: [work])
    let harness = Harness()
    await harness.perform(.toggleTag(red, on: [a]))
    try await setTags(["Work\n1", redEntry], a)

    let undone = try await harness.undo()

    #expect(undone.errors == [FileOperationError(reason: .tagsChanged, path: a, errno: nil)])
    #expect(try await tags(a) == ["Work\n1", redEntry])
}

/// Redo checks as undo does: tags changed since the undo fail it, nothing changes, and the
/// entry is kept once.
@MainActor @Test func tagsChangedSinceFailTheRedoAndChangeNothing() async throws {
    let folder = try TemporaryFolder("FileOperationTagTests")
    let a = try await file("a.txt", in: folder, tags: [work])
    let harness = Harness()
    await harness.perform(.toggleTag(red, on: [a]))
    _ = try await harness.undo()
    try await setTags([work, blueEntry], a)

    let redone = try await harness.redo()

    #expect(redone.phase == .failed)
    #expect(redone.errors == [FileOperationError(reason: .tagsChanged, path: a, errno: nil)])
    #expect(try await tags(a) == [work, blueEntry])
    #expect(harness.history.redoTitle == "Redo Add Tag “Red”")

    try await setTags([work], a)
    _ = try await harness.redo()
    #expect(try await tags(a) == [work, redEntry])
}

/// A toggle of many items whose undo fails for some keeps exactly those to undo again.
@MainActor @Test func aLargeToggleUndoneInPartKeepsTheItemsThatFailed() async throws {
    let folder = try TemporaryFolder("FileOperationTagTests")
    var paths: [String] = []
    for index in 0..<120 {
        paths.append(try await file("\(index).txt", in: folder, tags: [work]))
    }
    let harness = Harness()
    await harness.perform(.toggleTag(red, on: paths))
    let locked = paths.indices.filter { $0 % 7 == 0 }.map { paths[$0] }
    for path in locked { #expect(chmod(path, 0o444) == 0) }
    defer { for path in locked { chmod(path, 0o644) } }

    let undone = try await harness.undo()

    #expect(Set(undone.errors.map(\.path)) == Set(locked))
    for path in paths {
        #expect(try await tags(path) == (locked.contains(path) ? [work, redEntry] : [work]))
    }
    for path in locked { #expect(chmod(path, 0o644) == 0) }
    _ = try await harness.undo()
    for path in locked { #expect(try await tags(path) == [work]) }
}

/// The remainder of a large tag entry reads each path once, as for a move
/// (`theRemainderOfALargeEntryReadsEachPathOnce`).
@MainActor @Test func theRemainderOfALargeTagEntryReadsEachPathOnce() {
    let changes = (0..<400).map {
        OperationRecord.Change.tagged("/A/\($0)", from: [work], to: [work, redEntry])
    }
    // Last first; every third failed.
    let done = changes.indices.reversed().filter { $0 % 3 != 0 }.map {
        OperationRecord.Change.tagged("/A/\($0)", from: [work, redEntry], to: [work])
    }
    var reads = 0

    let left = UndoHistory.remainder(of: changes, after: done) { path in
        reads += 1
        return FileOperation.comparable(path)
    }

    #expect(left == changes.indices.filter { $0 % 3 == 0 }.map { changes[$0] })
    #expect(reads <= 2 * (changes.count + done.count))
}
