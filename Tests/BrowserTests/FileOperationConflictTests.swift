import Base
import BrowserTestSupport
import Darwin
import Foundation
import TestSupport
import Testing

@testable import Browser

private let skipAll = ConflictResolution(choice: .skip, appliesToAll: true)
private let replace = ConflictResolution(choice: .replace, appliesToAll: false)
private let keepBoth = ConflictResolution(choice: .keepBoth, appliesToAll: false)

/// The folder a replace staged its copy in, from the fake's log.
private func stagingFolder(_ files: FakeFiles) throws -> String {
    let made = try #require(files.events.all.first { $0.hasPrefix("make folder ") })
    let folder = String(made.dropFirst("make folder ".count))
    #expect(
        (folder as NSString).lastPathComponent.hasPrefix(FileOperationQueue.stagingFolderPrefix))
    return folder
}

@Test func threeClashesAskOnceWhenTheFirstAnswerAppliesToAll() async throws {
    let files = FakeFiles(releasingAll: true)
    for name in ["a", "b", "c"] { files.place("/A/" + name) }
    let prompter = Prompter()
    prompter.answer(skipAll)
    let watcher = Watcher()
    let queue = makeQueue(files, watcher, prompter: prompter)

    let id = await enqueue(queue, .copy(["/S/a", "/S/b", "/S/c", "/S/d"], into: "/A"), watcher)

    #expect(await watcher.waitUntilFinished(id))
    #expect(
        prompter.conflicts.all == [
            ConflictRequest(
                operation: id, kind: .copy, source: FakeFiles.item("/S/a"),
                existing: FakeFiles.item("/A/a"), remaining: 2)
        ])
    #expect(!files.events.all.contains { $0.hasPrefix("copy /S/a") || $0.hasPrefix("copy /S/c") })
    let state = try #require(watcher.state(of: id))
    #expect(state.phase == .done)
    #expect(state.record.changes == [.created("/A/d", from: .copy(of: "/S/d"))])
    #expect(state.progress.itemsDone == 4)
    #expect(state.progress.total == TreeSizeWalker.Total(bytes: 10, files: 1, isPartial: false))
}

@Test func eachClashAsksWhenTheAnswerIsNotForAll() async throws {
    let files = FakeFiles(releasingAll: true)
    for name in ["a", "b"] { files.place("/A/" + name) }
    let prompter = Prompter()
    prompter.answer(ConflictResolution(choice: .skip, appliesToAll: false))
    prompter.answer(ConflictResolution(choice: .skip, appliesToAll: false))
    let watcher = Watcher()
    let queue = makeQueue(files, watcher, prompter: prompter)

    let id = await enqueue(queue, .copy(["/S/a", "/S/b"], into: "/A"), watcher)

    #expect(await watcher.waitUntilFinished(id))
    #expect(prompter.conflicts.all.map(\.existing.path) == ["/A/a", "/A/b"])
    #expect(prompter.conflicts.all.map(\.remaining) == [1, 0])
}

/// A folder onto a folder of the same name is one conflict, answered for the whole folder: what
/// is inside either one is never compared, and a replace puts the copied folder in place whole.
@Test func aConflictIsPerTopLevelItemWithNoFolderMerge() async throws {
    let files = FakeFiles(releasingAll: true)
    files.place("/A/album", isFolder: true)
    let prompter = Prompter()
    prompter.answer(replace)
    let watcher = Watcher()
    let queue = makeQueue(files, watcher, prompter: prompter)

    let id = await enqueue(queue, .copy(["/S/album"], into: "/A"), watcher)

    #expect(await watcher.waitUntilFinished(id))
    #expect(prompter.conflicts.all.count == 1)
    #expect(prompter.conflicts.all.first?.existing.isFolder == true)
    #expect(
        files.events.all.filter { $0.hasPrefix("inspect") } == [
            "inspect /A/album", "inspect /S/album",
        ])
    let staging = try stagingFolder(files)
    #expect(files.events.all.contains("copied /S/album to \(staging)/album"))
}

@Test func keepBothGivesTheNameWithTwo() async throws {
    let files = FakeFiles(releasingAll: true)
    files.place("/A/report 3.jpg")
    let prompter = Prompter()
    prompter.answer(keepBoth)
    let watcher = Watcher()
    let queue = makeQueue(files, watcher, prompter: prompter)

    let copy = await enqueue(queue, .copy(["/S/report 3.jpg"], into: "/A"), watcher)
    #expect(await watcher.waitUntilFinished(copy))

    #expect(files.events.all.contains("copied /S/report 3.jpg to /A/report 3 2.jpg"))
    #expect(
        watcher.state(of: copy)?.record.changes == [
            .created("/A/report 3 2.jpg", from: .copy(of: "/S/report 3.jpg"))
        ])
}

@Test func aMoveWithinAVolumeKeepsBothUnderTheNewName() async throws {
    let files = FakeFiles(releasingAll: true)
    files.place("/A/in/notes.txt")
    files.place("/A/sorted/notes.txt")
    let prompter = Prompter()
    prompter.answer(keepBoth)
    let watcher = Watcher()
    let queue = makeQueue(files, watcher, prompter: prompter)

    let move = await enqueue(queue, .move(["/A/in/notes.txt"], into: "/A/sorted"), watcher)
    #expect(await watcher.waitUntilFinished(move))

    #expect(prompter.conflicts.all.map(\.kind) == [.move])
    #expect(files.events.all.contains("move /A/in/notes.txt to /A/sorted/notes 2.txt"))
    #expect(
        watcher.state(of: move)?.record.changes == [
            .moved(from: "/A/in/notes.txt", to: "/A/sorted/notes 2.txt")
        ])
}

/// Pasting into the folder an item came from: a copy is named as Finder's Duplicate names it,
/// without asking; a move has nothing to do.
@Test func anItemOntoItselfAsksNothing() async throws {
    let files = FakeFiles(releasingAll: true)
    files.place("/A/x.txt")
    files.place("/A/x copy.txt")
    let watcher = Watcher()
    let queue = makeQueue(files, watcher)

    let copy = await enqueue(queue, .copy(["/A/x.txt"], into: "/A/"), watcher)
    #expect(await watcher.waitUntilFinished(copy))
    let move = await enqueue(queue, .move(["/A/x.txt"], into: "/A"), watcher)
    #expect(await watcher.waitUntilFinished(move))

    #expect(
        watcher.state(of: copy)?.record.changes == [
            .created("/A/x copy 2.txt", from: .copy(of: "/A/x.txt"))
        ])
    #expect(watcher.state(of: move)?.phase == .done)
    #expect(watcher.state(of: move)?.record.changes == [])
    #expect(!files.events.all.contains { $0.hasPrefix("move") })
}

@Test func replaceCopiesToAStagingFolderSoCancellingLeavesTheOriginal() async throws {
    let files = FakeFiles()
    files.place("/A/song.flac")
    let prompter = Prompter()
    prompter.answer(replace)
    let watcher = Watcher()
    let queue = makeQueue(files, watcher, prompter: prompter)
    let id = await enqueue(queue, .copy(["/S/song.flac"], into: "/A"), watcher)
    #expect(await files.events.wait { $0.contains("copy /S/song.flac") })

    await queue.cancel(id)

    #expect(await watcher.waitUntilFinished(id))
    #expect(watcher.state(of: id)?.phase == .cancelled(leftBehind: nil))
    let staging = try stagingFolder(files)
    #expect(!files.events.all.contains { $0.hasPrefix("move") || $0.hasPrefix("trash /") })
    #expect(files.events.all.last == "delete \(staging)")
    #expect(watcher.state(of: id)?.record.changes == [])
}

/// The cancel arrives as the copy returns: the copy is whole, but nothing replaces the original.
@Test func aCancelAsTheStagingCopyReturnsRemovesItAndLeavesTheOriginal() async throws {
    let files = FakeFiles()
    files.place("/A/song.flac")
    files.finishDespiteCancel(of: "/S/song.flac")
    let prompter = Prompter()
    prompter.answer(replace)
    let watcher = Watcher()
    let queue = makeQueue(files, watcher, prompter: prompter)
    let id = await enqueue(queue, .copy(["/S/song.flac"], into: "/A"), watcher)
    #expect(await files.events.wait { $0.contains("copy /S/song.flac") })

    await queue.cancel(id)

    #expect(await watcher.waitUntilFinished(id))
    #expect(watcher.state(of: id)?.phase == .cancelled(leftBehind: nil))
    let staging = try stagingFolder(files)
    #expect(
        Array(files.events.all.drop { !$0.hasPrefix("copied") }) == [
            "copied /S/song.flac to \(staging)/song.flac", "delete \(staging)/song.flac",
            "delete \(staging)",
        ])
    #expect(watcher.state(of: id)?.record.changes == [])
}

/// The app quits during the staging copy: the copier removes what it wrote, and the staging
/// folder goes before the cancel returns.
@Test func cancellingAllDuringAReplacesStagingCopyLeavesNoStagingFolderOrPartialItem()
    async throws
{
    let files = FakeFiles()
    files.place("/A/song.flac")
    let prompter = Prompter()
    prompter.answer(replace)
    let watcher = Watcher()
    let queue = makeQueue(files, watcher, prompter: prompter)
    let id = await enqueue(queue, .copy(["/S/song.flac"], into: "/A"), watcher)
    #expect(await files.events.wait { $0.contains("copy /S/song.flac") })

    await queue.cancelAllAndWait()

    #expect(watcher.state(of: id)?.phase == .cancelled(leftBehind: nil))
    let staging = try stagingFolder(files)
    #expect(
        Array(files.events.all.drop { !$0.hasPrefix("copy ") }) == [
            "copy /S/song.flac", "copy failed /S/song.flac", "delete \(staging)",
        ])
    #expect(watcher.state(of: id)?.record.changes == [])
}

/// A replace first removes the empty staging and drop folders a crash left beside its
/// destination. A folder with something in it stays, and so does a drop folder still in use.
@Test func aReplaceFirstRemovesEmptyFoldersEarlierRunsLeftBesideItsDestination() async throws {
    let files = FakeFiles(releasingAll: true)
    files.place("/A/song.flac")
    let prompter = Prompter()
    prompter.answer(replace)
    let watcher = Watcher()
    let queue = makeQueue(files, watcher, prompter: prompter)
    let live = try await queue.makeDropFolder(in: "/A")
    let stale = FileOperationQueue.stagingFolderPrefix + "stale"
    let full = FileOperationQueue.stagingFolderPrefix + "full"
    files.put(
        ["song.flac", (live.path as NSString).lastPathComponent, stale, full], in: "/A")
    files.fill("/A/" + full)

    let id = await enqueue(queue, .copy(["/S/song.flac"], into: "/A"), watcher)

    #expect(await watcher.waitUntilFinished(id))
    #expect(watcher.state(of: id)?.phase == .done)
    let events = files.events.all
    let listed = try #require(events.lastIndex(of: "list /A"))
    let sweep = Array(events[(listed + 1)...].prefix { !$0.hasPrefix("make folder") })
    #expect(sweep == ["remove folder /A/\(stale)", "not empty /A/\(full)"])
    #expect(!files.events.all.contains("remove folder \(live.path)"))
}

@Test func replaceTrashesTheOriginalFromItsPathThenMovesTheCopyIntoPlace() async throws {
    let files = FakeFiles(releasingAll: true)
    files.place("/A/song.flac")
    files.place("/A/in/cover.jpg")
    files.place("/A/sorted/cover.jpg")
    let prompter = Prompter()
    prompter.answer(replace)
    prompter.answer(replace)
    let watcher = Watcher()
    let queue = makeQueue(files, watcher, prompter: prompter)

    let copy = await enqueue(queue, .copy(["/S/song.flac"], into: "/A"), watcher)
    #expect(await watcher.waitUntilFinished(copy))
    let staging = try stagingFolder(files)
    #expect(
        Array(files.events.all.drop { !$0.hasPrefix("make folder") }) == [
            "make folder \(staging)", "copy /S/song.flac",
            "copied /S/song.flac to \(staging)/song.flac", "trash /A/song.flac",
            "move \(staging)/song.flac to /A/song.flac", "delete \(staging)",
        ])
    let trashed = URL(fileURLWithPath: "/A/.Trashes/501/song.flac")
    #expect(
        watcher.state(of: copy)?.record.changes == [
            .replaced("/A/song.flac", originalTrashedTo: trashed),
            .created("/A/song.flac", from: .copy(of: "/S/song.flac")),
        ])

    // A move within one volume stages by moving, not copying.
    let move = await enqueue(queue, .move(["/A/in/cover.jpg"], into: "/A/sorted"), watcher)
    #expect(await watcher.waitUntilFinished(move))
    #expect(watcher.state(of: move)?.phase == .done)
    #expect(
        watcher.state(of: move)?.record.changes == [
            .replaced(
                "/A/sorted/cover.jpg",
                originalTrashedTo: URL(fileURLWithPath: "/A/.Trashes/501/cover.jpg")),
            .moved(from: "/A/in/cover.jpg", to: "/A/sorted/cover.jpg"),
        ])
    #expect(!files.events.all.contains("copy /A/in/cover.jpg"))
}

/// A move to another volume that replaces an item keeps a source that changed while it was
/// copied: the copy is in place, the original in the Trash, and the source where it was.
@Test func aReplacingCrossVolumeMoveKeepsASourceThatChangedWhileItWasCopied() async throws {
    let files = FakeFiles(releasingAll: true)
    files.place("/A/song.flac")
    files.changeDuringCopy(of: "/S/song.flac")
    let prompter = Prompter()
    prompter.answer(replace)
    let watcher = Watcher()
    let queue = makeQueue(files, watcher, prompter: prompter)

    let move = await enqueue(queue, .move(["/S/song.flac"], into: "/A"), watcher)

    #expect(await watcher.waitUntilFinished(move))
    let staging = try stagingFolder(files)
    #expect(
        Array(files.events.all.drop { !$0.hasPrefix("make folder") }) == [
            "make folder \(staging)", "copy /S/song.flac",
            "copied /S/song.flac to \(staging)/song.flac", "trash /A/song.flac",
            "move \(staging)/song.flac to /A/song.flac", "delete \(staging)",
        ])
    let state = try #require(watcher.state(of: move))
    #expect(
        state.errors == [
            FileOperationError(reason: .changedDuringMove, path: "/S/song.flac", errno: nil)
        ])
    #expect(
        state.record.changes == [
            .replaced(
                "/A/song.flac",
                originalTrashedTo: URL(fileURLWithPath: "/A/.Trashes/501/song.flac")),
            .created("/A/song.flac", from: .copy(of: "/S/song.flac")),
        ])
}

@Test func aFailedMoveIntoPlacePutsTheOriginalBackFromTheTrash() async throws {
    let files = FakeFiles(releasingAll: true)
    files.place("/A/song.flac")
    let denied = FileOperationError(reason: .permissionDenied, path: "/A/song.flac", errno: EACCES)
    files.failMove(to: "/A/song.flac", with: denied)
    let prompter = Prompter()
    prompter.answer(replace)
    let watcher = Watcher()
    let queue = makeQueue(files, watcher, prompter: prompter)

    let id = await enqueue(queue, .copy(["/S/song.flac"], into: "/A"), watcher)

    #expect(await watcher.waitUntilFinished(id))
    let staging = try stagingFolder(files)
    #expect(
        Array(files.events.all.drop { !$0.hasPrefix("trash") }) == [
            "trash /A/song.flac", "move failed \(staging)/song.flac to /A/song.flac",
            "move /A/.Trashes/501/song.flac to /A/song.flac", "delete \(staging)/song.flac",
            "delete \(staging)",
        ])
    #expect(watcher.state(of: id)?.phase == .failed)
    #expect(watcher.state(of: id)?.errors == [denied])
    #expect(watcher.state(of: id)?.record.changes == [])
}

@Test func withNoTrashATrashAsksOnceToDeleteAndDoesNothingUntilAnswered() async throws {
    let files = FakeFiles(releasingAll: true)
    files.removeTrash()
    let prompter = Prompter()
    let watcher = Watcher()
    let queue = makeQueue(files, watcher, prompter: prompter)

    let id = await enqueue(queue, .trash(["/S/a", "/S/b"]), watcher)

    #expect(await prompter.confirms.wait { !$0.isEmpty })
    #expect(await watcher.waitUntil(id, is: .waitingForAnswer))
    try await pause()
    #expect(!files.events.all.contains { $0.hasPrefix("delete") || $0.hasPrefix("trash /") })
    prompter.answer(confirming: true)
    #expect(await watcher.waitUntilFinished(id))
    #expect(prompter.confirms.all == [.deleteImmediately(["/S/a", "/S/b"], operation: id)])
    #expect(files.events.all.filter { $0.hasPrefix("delete") } == ["delete /S/a", "delete /S/b"])
    #expect(watcher.state(of: id)?.phase == .done)
    #expect(watcher.state(of: id)?.record.changes == [.deleted("/S/a"), .deleted("/S/b")])

    let declined = await enqueue(queue, .trash(["/S/c"]), watcher)
    #expect(await prompter.confirms.wait { $0.count == 2 })
    prompter.answer(confirming: false)
    #expect(await watcher.waitUntilFinished(declined))
    #expect(watcher.state(of: declined)?.phase == .cancelled(leftBehind: nil))
    #expect(!files.events.all.contains("delete /S/c"))
}

@Test func withNoTrashAReplaceAsksOnceAfterTheCopyAndDeletesOnlyOnYes() async throws {
    let files = FakeFiles(releasingAll: true)
    files.removeTrash()
    files.place("/A/a")
    files.place("/A/b")
    let prompter = Prompter()
    prompter.answer(ConflictResolution(choice: .replace, appliesToAll: true))
    let watcher = Watcher()
    let queue = makeQueue(files, watcher, prompter: prompter)

    let id = await enqueue(queue, .copy(["/S/a", "/S/b"], into: "/A"), watcher)

    #expect(await prompter.confirms.wait { !$0.isEmpty })
    #expect(prompter.confirms.all == [.deleteImmediately(["/A/a", "/A/b"], operation: id)])
    #expect(await watcher.waitUntil(id, is: .waitingForAnswer))
    try await pause()
    let staging = try stagingFolder(files)
    #expect(files.events.all.contains("copied /S/a to \(staging)/a"))
    #expect(!files.events.all.contains { $0.hasPrefix("delete") || $0.hasPrefix("move") })
    prompter.answer(confirming: true)
    #expect(await watcher.waitUntilFinished(id))
    #expect(files.events.all.contains("delete /A/a"))
    #expect(files.events.all.contains("move \(staging)/a to /A/a"))
    #expect(
        watcher.state(of: id)?.record.changes == [
            .deleted("/A/a"), .created("/A/a", from: .copy(of: "/S/a")), .deleted("/A/b"),
            .created("/A/b", from: .copy(of: "/S/b")),
        ])
    #expect(prompter.confirms.all.count == 1)
}

@Test func decliningToDeleteWhereThereIsNoTrashCancelsAndRemovesTheStagedCopy() async throws {
    let files = FakeFiles(releasingAll: true)
    files.removeTrash()
    files.place("/A/a")
    let prompter = Prompter()
    prompter.answer(replace)
    prompter.answer(confirming: false)
    let watcher = Watcher()
    let queue = makeQueue(files, watcher, prompter: prompter)

    let id = await enqueue(queue, .copy(["/S/a"], into: "/A"), watcher)

    #expect(await watcher.waitUntilFinished(id))
    #expect(watcher.state(of: id)?.phase == .cancelled(leftBehind: nil))
    #expect(watcher.state(of: id)?.record.changes == [])
    let staging = try stagingFolder(files)
    #expect(
        Array(files.events.all.drop { !$0.hasPrefix("copied") }) == [
            "copied /S/a to \(staging)/a", "delete \(staging)/a", "delete \(staging)",
        ])
}

@Test func aCancelWhileTheDeleteQuestionWaitsRemovesTheStagedCopyAtOnce() async throws {
    let files = FakeFiles(releasingAll: true)
    files.removeTrash()
    files.place("/A/a")
    let prompter = Prompter()
    prompter.answer(replace)
    let watcher = Watcher()
    let queue = makeQueue(files, watcher, prompter: prompter)
    let id = await enqueue(queue, .copy(["/S/a"], into: "/A"), watcher)
    #expect(await prompter.confirms.wait { !$0.isEmpty })

    await queue.cancel(id)

    #expect(await watcher.waitUntilFinished(id))
    #expect(watcher.state(of: id)?.phase == .cancelled(leftBehind: nil))
    let staging = try stagingFolder(files)
    #expect(files.events.all.suffix(2) == ["delete \(staging)/a", "delete \(staging)"])
    prompter.answer(confirming: true)
    try await pause()
    #expect(!files.events.all.contains("delete /A/a"))
}

@Test func otherLanesKeepRunningWhileAnOperationWaitsForAnAnswer() async throws {
    let files = FakeFiles(releasingAll: true)
    files.place("/A/a")
    let prompter = Prompter()
    let watcher = Watcher()
    let queue = makeQueue(files, watcher, prompter: prompter)

    let asking = await enqueue(queue, .copy(["/S/a"], into: "/A"), watcher)
    #expect(await watcher.waitUntil(asking, is: .waitingForAnswer))
    let sameVolume = await enqueue(queue, .copy(["/S/b"], into: "/A"), watcher)
    let otherVolume = await enqueue(queue, .copy(["/S/c"], into: "/B"), watcher)
    let rename = await enqueue(queue, .rename("/S/d", to: "e"), watcher)

    #expect(await watcher.waitUntilFinished(sameVolume, otherVolume, rename))
    #expect(watcher.state(of: asking) == nil)
    prompter.answer(skipAll)
    #expect(await watcher.waitUntilFinished(asking))
}

@Test func aCancelWhileAQuestionWaitsFinishesAtOnceAndDropsTheAnswer() async throws {
    let files = FakeFiles(releasingAll: true)
    files.place("/A/a")
    let prompter = Prompter()
    let watcher = Watcher()
    let queue = makeQueue(files, watcher, prompter: prompter)
    let id = await enqueue(queue, .copy(["/S/a"], into: "/A"), watcher)
    #expect(await watcher.waitUntil(id, is: .waitingForAnswer))

    await queue.cancel(id)
    #expect(await watcher.waitUntilFinished(id))
    prompter.answer(replace)
    try await pause()

    #expect(watcher.state(of: id)?.phase == .cancelled(leftBehind: nil))
    #expect(!files.events.all.contains { $0.hasPrefix("copy") || $0.hasPrefix("make folder") })
    #expect(watcher.finished.all.filter { $0.id == id }.count == 1)
}

@Test func aWillUnmountFailsThatVolumesOperationsAndRemovesTheirPartialItems() async throws {
    let mountPoint = "/FileOperationConflictTests-unmount"
    let volume = VolumeIdentity(device: "/dev/fakeU", mountPoint: mountPoint, kind: .local)
    let files = FakeFiles()
    files.add(volume)
    files.place(mountPoint + "/replaced")
    files.place("/A/asking")
    files.place(mountPoint + "/asking")
    let prompter = Prompter()
    prompter.answer(replace)
    let watcher = Watcher()
    let queue = makeQueue(files, watcher, prompter: prompter)

    let replacing = await enqueue(queue, .copy(["/S/replaced"], into: mountPoint), watcher)
    #expect(await files.events.wait { $0.contains("copy /S/replaced") })
    let waiting = await enqueue(queue, .copy(["/S/waiting"], into: mountPoint), watcher)
    #expect(await watcher.waitUntil(waiting, is: .queued))
    let reading = await enqueue(queue, .copy([mountPoint + "/song"], into: "/B"), watcher)
    #expect(await files.events.wait { $0.contains("copy \(mountPoint)/song") })
    let asking = await enqueue(queue, .copy([mountPoint + "/asking"], into: "/A"), watcher)
    #expect(await watcher.waitUntil(asking, is: .waitingForAnswer))
    let elsewhere = await enqueue(queue, .copy(["/S/other"], into: "/A"), watcher)
    #expect(await files.events.wait { $0.contains("copy /S/other") })

    await VolumeEvents.willUnmount(at: mountPoint)

    #expect(await watcher.waitUntilFinished(replacing, waiting, reading, asking))
    let unreachable = FileOperationError(reason: .unreachable, path: mountPoint, errno: nil)
    for id in [replacing, waiting, reading, asking] {
        #expect(watcher.state(of: id)?.phase == .failed)
        #expect(watcher.state(of: id)?.errors == [unreachable])
    }
    let staging = try stagingFolder(files)
    #expect(files.events.all.contains("copy failed /S/replaced"))
    #expect(files.events.all.contains("delete \(staging)"))
    #expect(files.events.all.contains("copy failed \(mountPoint)/song"))
    #expect(!files.events.all.contains { $0.hasPrefix("trash /") || $0.contains("/S/waiting") })
    #expect(watcher.state(of: elsewhere) == nil)
    files.releaseAll()
    #expect(await watcher.waitUntilFinished(elsewhere))
    #expect(watcher.state(of: elsewhere)?.phase == .done)
}

@Test func aRefusedEjectLeavesTheVolumesOperationsRunning() async throws {
    let mountPoint = "/FileOperationConflictTests-eject"
    let volume = VolumeIdentity(device: "/dev/fakeE", mountPoint: mountPoint, kind: .local)
    let files = FakeFiles()
    files.add(volume)
    let watcher = Watcher()
    let queue = makeQueue(files, watcher, prompter: Prompter())
    let writing = await enqueue(queue, .copy(["/S/song"], into: mountPoint), watcher)
    #expect(await files.events.wait { $0.contains("copy /S/song") })
    let stub = StubSidebarVolumes()
    // A copy with files open on the volume is what makes the system refuse.
    stub.fail(with: "The volume is in use.")
    let sidebarVolume = SidebarVolume(mountPoint: mountPoint, name: "eject", kind: .local)

    await #expect(throws: SidebarVolume.EjectFailure.self) {
        try await stub.list().eject(sidebarVolume)
    }

    files.releaseAll()
    #expect(await watcher.waitUntilFinished(writing))
    #expect(watcher.state(of: writing)?.phase == .done)
}

@Test func planningFindsTopLevelConflictsOnly() throws {
    var inspected: [String] = []
    let plan = try OperationPlan.make(
        for: .copy(["/S/album", "/S/new"], into: "/A"),
        volumeOf: { _ throws(ListingError) in volumeA },
        measure: { _, _ in TreeSizeWalker.Total(bytes: 10, files: 2, isPartial: false) },
        inspect: { path throws(FileOperationError) in
            inspected.append(path)
            return path == "/A/new" ? nil : FakeFiles.item(path)
        },
        identify: { _ throws(FileOperationError) in nil },
        sourceHolding: { _, _ throws(FileOperationError) in nil },
        isCancelled: { false }, copies: {})

    #expect(inspected == ["/A/album", "/S/album", "/A/new"])
    #expect(
        plan.items.map(\.conflict) == [
            OperationPlan.Conflict(
                source: FakeFiles.item("/S/album"), existing: FakeFiles.item("/A/album")),
            nil,
        ])
}

/// Real volumes: replaces only items the test makes on a disk image, and removes the replaced
/// original from the image's trash afterwards.
@Suite(.serialized) struct FileOperationConflictDiskTests {
    @Test func replacingAFolderOnADiskImagePutsTheCopyInPlaceWholeAndTrashesTheOriginal()
        async throws
    {
        let folder = try TemporaryFolder("FileOperationConflictTests")
        let image = try await DiskImage("FileOperationConflictTests", megabytes: 4)
        let source = folder.url.path + "/album"
        let destination = image.mountPoint + "/album"
        for (path, file) in [(source, "new.txt"), (destination, "old.txt")] {
            try FileManager.default.createDirectory(
                atPath: path, withIntermediateDirectories: false)
            try Data(file.utf8).write(to: URL(fileURLWithPath: path + "/" + file))
        }
        let prompter = Prompter()
        prompter.answer(replace)
        let queue = FileOperationQueue(prompts: prompter.prompts) { _ in }

        let state = await queue.perform(.copy([source], into: image.mountPoint))

        #expect(state.phase == .done)
        #expect(try FileManager.default.contentsOfDirectory(atPath: destination) == ["new.txt"])
        #expect(
            try FileManager.default.contentsOfDirectory(atPath: image.mountPoint)
                .filter { !$0.hasPrefix(".") } == ["album"])
        #expect(
            try FileManager.default.contentsOfDirectory(atPath: image.mountPoint)
                .filter { $0.hasPrefix(FileOperationQueue.stagingFolderPrefix) }.isEmpty)
        guard case .replaced(destination, let trashed) = state.record.changes.first else {
            Issue.record("no replace in \(state.record.changes)")
            return
        }
        #expect(state.record.changes.last == .created(destination, from: .copy(of: source)))
        #expect(trashed.path.hasPrefix(image.mountPoint + "/.Trashes/"))
        #expect(trashed.lastPathComponent == "album")
        #expect(
            try FileManager.default.contentsOfDirectory(atPath: trashed.path) == ["old.txt"])
        try FileManager.default.removeItem(at: trashed)
        try await image.detach()
    }
}
