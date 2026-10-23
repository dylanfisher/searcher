import Base
import BrowserTestSupport
import Darwin
import Foundation
import TestSupport
import Testing

@testable import Browser

let volumeA = VolumeIdentity(device: "/dev/fakeA", mountPoint: "/A", kind: .local)
let volumeB = VolumeIdentity(device: "/dev/fakeB", mountPoint: "/B", kind: .local)
let volumeS = VolumeIdentity(device: "/dev/fakeS", mountPoint: "/S", kind: .local)

/// A file system for queue tests that touches no disk: paths under `/A`, `/B` and `/S` are on
/// three volumes, and every call is logged. A copy logs its start, reports `progressSteps`
/// changes, then waits until its source is released or the copy is cancelled. A pre-scan of a
/// held path waits until it is let go, as one on a share that stopped answering does. Every
/// path under `/S` exists; elsewhere only what a test places does, so a copy or move into
/// another volume has no conflict unless the test places one.
final class FakeFiles: @unchecked Sendable {
    let events = EventLog<String>()
    private let condition = NSCondition()
    private var volumes = [volumeA, volumeB, volumeS]
    private var placed: [String: ConflictRequest.Item] = [:]
    private var hasNoTrash = false
    private var heldScans: Set<String> = []
    private var released: Set<String> = []
    private var allReleased = false
    private var copyFailures: [String: FileOperationError] = [:]
    private var cancelFailures: [String: FileOperationError] = [:]
    private var moveFailures: [String: FileOperationError] = [:]
    private var deleteFailures: [String: FileOperationError] = [:]
    private var finishesDespiteCancel: Set<String> = []
    private var progressSteps = 0
    private var contents: [String: [String]] = [:]
    private var filled: Set<String> = []

    init(releasingAll: Bool = false) {
        allReleased = releasingAll
    }

    func release(_ source: String) {
        condition.withLock {
            released.insert(source)
            condition.broadcast()
        }
    }

    func releaseAll() {
        condition.withLock {
            allReleased = true
            condition.broadcast()
        }
    }

    /// The copy of `source` throws `error` once released.
    func failCopy(of source: String, with error: FileOperationError) {
        condition.withLock { copyFailures[source] = error }
    }

    /// A cancelled copy of `source` throws `error`, as `FileCopier` does when it can't remove
    /// what it wrote.
    func failCancel(of source: String, with error: FileOperationError) {
        condition.withLock { cancelFailures[source] = error }
    }

    /// The next move to `destination` throws `error`.
    func failMove(to destination: String, with error: FileOperationError) {
        condition.withLock { moveFailures[destination] = error }
    }

    /// The next delete of `path` throws `error`.
    func failDelete(of path: String, with error: FileOperationError) {
        condition.withLock { deleteFailures[path] = error }
    }

    /// The copy of `source` returns as if it had finished when it is cancelled: a cancel that
    /// arrives as the copy returns.
    func finishDespiteCancel(of source: String) {
        condition.withLock { _ = finishesDespiteCancel.insert(source) }
    }

    func holdScan(of path: String) {
        condition.withLock { _ = heldScans.insert(path) }
    }

    func letScanGo(of path: String) {
        condition.withLock {
            heldScans.remove(path)
            condition.broadcast()
        }
    }

    func reportProgress(steps: Int) {
        condition.withLock { progressSteps = steps }
    }

    /// Adds a volume, for tests that unmount one no other test uses.
    func add(_ volume: VolumeIdentity) {
        condition.withLock { volumes.append(volume) }
    }

    /// Puts an item at `path`, so a copy or move onto it is a conflict.
    func place(_ path: String, isFolder: Bool = false) {
        condition.withLock { placed[path] = Self.item(path, isFolder: isFolder) }
    }

    /// Puts items named `names` in `folder`, for a listing of it.
    func put(_ names: [String], in folder: String) {
        condition.withLock { contents[folder] = names }
    }

    /// Removing the folder at `path` as an empty one fails with `ENOTEMPTY`.
    func fill(_ path: String) {
        condition.withLock { _ = filled.insert(path) }
    }

    /// Makes every volume one without a trash: a trash throws `noTrash`.
    func removeTrash() {
        condition.withLock { hasNoTrash = true }
    }

    static func item(_ path: String, isFolder: Bool = false) -> ConflictRequest.Item {
        ConflictRequest.Item(
            path: path, isFolder: isFolder, bytes: isFolder ? nil : 10,
            modified: Date(timeIntervalSince1970: 1_000_000))
    }

    func fileSystem() -> FileOperationQueue.FileSystem {
        FileOperationQueue.FileSystem(
            volumeOf: { path throws(ListingError) in
                let volumes = self.condition.withLock { self.volumes }
                for volume in volumes where isPath(path, atOrUnder: volume.mountPoint) {
                    return volume
                }
                throw ListingError(path: path, code: ENOENT)
            },
            measure: { path, _ in
                self.condition.withLock {
                    if self.heldScans.contains(path) { self.events.append("holding scan \(path)") }
                    while self.heldScans.contains(path) { self.condition.wait() }
                }
                return TreeSizeWalker.Total(bytes: 10, files: 1, isPartial: false)
            },
            makeCopier: { FakeCopier(files: self) },
            move: { source, destination throws(FileOperationError) in
                if let failure = self.condition.withLock({
                    self.moveFailures.removeValue(forKey: destination)
                }) {
                    self.events.append("move failed \(source) to \(destination)")
                    throw failure
                }
                self.events.append("move \(source) to \(destination)")
            },
            trash: { path throws(FileOperationError) in
                if self.condition.withLock({ self.hasNoTrash }) {
                    throw FileOperationError(reason: .noTrash, path: path, errno: nil)
                }
                self.events.append("trash \(path)")
                return URL(
                    fileURLWithPath: "/S/.Trashes/501/" + (path as NSString).lastPathComponent)
            },
            deletePermanently: { path throws(FileOperationError) in
                if let failure = self.condition.withLock({
                    self.deleteFailures.removeValue(forKey: path)
                }) {
                    self.events.append("delete failed \(path)")
                    throw failure
                }
                self.events.append("delete \(path)")
            },
            makeUntitledFolder: { folder throws(FileOperationError) in
                self.events.append("new folder in \(folder)")
                return folder + "/untitled folder"
            },
            makeFolder: { name, folder throws(FileOperationError) in
                self.events.append("make folder \(folder)/\(name)")
                return folder + "/" + name
            },
            isTaken: { name, folder throws(FileOperationError) in
                self.condition.withLock { self.placed[folder + "/" + name] != nil }
            },
            inspect: { path throws(FileOperationError) in
                self.events.append("inspect \(path)")
                if let item = self.condition.withLock({ self.placed[path] }) { return item }
                return isPath(path, atOrUnder: "/S") ? Self.item(path) : nil
            },
            listNames: { folder throws(FileOperationError) in
                self.events.append("list \(folder)")
                return self.condition.withLock { self.contents[folder] ?? [] }
            },
            removeEmptyFolder: { folder throws(FileOperationError) in
                if self.condition.withLock({ self.filled.contains(folder) }) {
                    self.events.append("not empty \(folder)")
                    throw FileOperationError(errno: ENOTEMPTY, path: folder)
                }
                self.events.append("remove folder \(folder)")
            },
            makeIdentifier: {
                { path throws(FileOperationError) in
                    let isPlaced = self.condition.withLock { self.placed[path] != nil }
                    return isPlaced || isPath(path, atOrUnder: "/S")
                        ? OperationRecord.ItemIdentity(volume: "fake", inode: 0) : nil
                }
            })
    }

    /// Runs on the copy's thread.
    fileprivate func copy(
        _ source: String, to destination: String, copier: FakeCopier,
        progress: (CopyProgress) -> Void
    ) throws -> CopyProgress {
        events.append("copy \(source)")
        let steps = condition.withLock { progressSteps }
        for step in 0..<steps { progress(CopyProgress(bytes: Int64(step + 1), files: 0)) }
        if steps > 0 { events.append("reported \(source)") }
        let outcome: Result<Void, any Error> = condition.withLock {
            while !allReleased, !released.contains(source), !copier.isCancelled {
                condition.wait()
            }
            if copier.isCancelled, !finishesDespiteCancel.contains(source) {
                return .failure(cancelFailures[source] ?? CancellationError())
            }
            if let failure = copyFailures[source] { return .failure(failure) }
            return .success(())
        }
        do {
            try outcome.get()
        } catch {
            events.append("copy failed \(source)")
            throw error
        }
        events.append("copied \(source) to \(destination)")
        return CopyProgress(bytes: 10, files: 1)
    }

    fileprivate func wake() {
        condition.withLock { condition.broadcast() }
    }
}

final class FakeCopier: FileOperationQueue.Copier, @unchecked Sendable {
    private let files: FakeFiles
    private let lock = NSLock()
    private var cancelled = false

    init(files: FakeFiles) {
        self.files = files
    }

    var isCancelled: Bool { lock.withLock { cancelled } }

    func copy(
        _ source: String, to destination: String, progress: (CopyProgress) -> Void
    ) throws -> CopyProgress {
        try files.copy(source, to: destination, copier: self, progress: progress)
    }

    func pause() { files.events.append("pause") }
    func resume() { files.events.append("resume") }

    func cancel() {
        lock.withLock { cancelled = true }
        files.wake()
    }
}

/// Answers the queue's questions with the answers a test gives, in order, and logs each one.
/// A question with no answer given waits for one.
final class Prompter: @unchecked Sendable {
    let conflicts = EventLog<ConflictRequest>()
    let confirms = EventLog<ConfirmRequest>()
    private let lock = NSLock()
    private var resolutions: [ConflictResolution] = []
    private var confirmations: [Bool] = []

    func answer(_ resolution: ConflictResolution) {
        lock.withLock { resolutions.append(resolution) }
    }

    func answer(confirming: Bool) {
        lock.withLock { confirmations.append(confirming) }
    }

    var prompts: FileOperationQueue.Prompts {
        FileOperationQueue.Prompts(
            resolve: { request in
                self.conflicts.append(request)
                while true {
                    if let answer = self.lock.withLock({ self.resolutions.popFirst() }) {
                        return answer
                    }
                    try? await Task.sleep(for: .milliseconds(2))
                }
            },
            confirm: { request in
                self.confirms.append(request)
                while true {
                    if let answer = self.lock.withLock({ self.confirmations.popFirst() }) {
                        return answer
                    }
                    try? await Task.sleep(for: .milliseconds(2))
                }
            })
    }
}

extension Array {
    fileprivate mutating func popFirst() -> Element? {
        isEmpty ? nil : removeFirst()
    }
}

/// What the queue told its observer and each operation's `onFinish`.
final class Watcher: @unchecked Sendable {
    let snapshots = EventLog<[FileOperationQueue.Snapshot]>()
    let finished = EventLog<FileOperationQueue.Snapshot>()

    func state(of id: FileOperationQueue.ID) -> OperationState? {
        finished.all.first { $0.id == id }?.state
    }

    func waitUntilFinished(_ ids: FileOperationQueue.ID...) async -> Bool {
        await finished.wait { done in ids.allSatisfy { id in done.contains { $0.id == id } } }
    }

    /// Waits until a snapshot has shown the operation in `phase`.
    func waitUntil(_ id: FileOperationQueue.ID, is phase: OperationState.Phase) async -> Bool {
        await snapshots.wait { sent in
            sent.contains { $0.contains { $0.id == id && $0.state.phase == phase } }
        }
    }
}

func makeQueue<C: Clock<Duration>>(
    _ files: FakeFiles, _ watcher: Watcher, prompter: Prompter = Prompter(),
    clock: C = ContinuousClock()
) -> FileOperationQueue {
    FileOperationQueue(fileSystem: files.fileSystem(), prompts: prompter.prompts, clock: clock) {
        watcher.snapshots.append($0)
    }
}

func enqueue(
    _ queue: FileOperationQueue, _ operation: FileOperation, _ watcher: Watcher
) async -> FileOperationQueue.ID {
    await queue.enqueue(operation) { watcher.finished.append($0) }
}

/// Lets work that would break an expectation have the time to do it.
func pause() async throws {
    try await Task.sleep(for: .milliseconds(100))
}

@Test func copiesToOneVolumeRunOneAfterAnotherAndToTwoVolumesAtOnce() async throws {
    let files = FakeFiles()
    let watcher = Watcher()
    let queue = makeQueue(files, watcher)

    let first = await enqueue(queue, .copy(["/S/a"], into: "/A"), watcher)
    let second = await enqueue(queue, .copy(["/S/b"], into: "/A/inner"), watcher)
    let move = await enqueue(queue, .move(["/S/c"], into: "/A"), watcher)
    let otherVolume = await enqueue(queue, .copy(["/S/d"], into: "/B"), watcher)

    // An operation still being planned can be overtaken by a later one, so any of the three on
    // `/A` may go first; one at a time does.
    let onA = ["/S/a", "/S/b", "/S/c"]
    var released: Set<String> = []
    for count in 1...3 {
        #expect(
            await files.events.wait { events in
                events.contains("copy /S/d")
                    && onA.filter { events.contains("copy \($0)") }.count == count
            })
        try await pause()
        let started = onA.filter { files.events.all.contains("copy \($0)") }
        #expect(started.count == count)
        let running = try #require(started.first { !released.contains($0) })
        released.insert(running)
        files.release(running)
    }
    files.release("/S/d")
    #expect(await watcher.waitUntilFinished(first, second, move, otherVolume))
    for id in [first, second, move, otherVolume] {
        #expect(watcher.state(of: id)?.phase == .done)
    }
    #expect(
        watcher.state(of: move)?.record.changes == [.moved(from: "/S/c", to: "/A/c")])
}

@Test func aRenameDuringALongCopyFinishesFirstOutsideTheLanes() async throws {
    let files = FakeFiles()
    let watcher = Watcher()
    let queue = makeQueue(files, watcher)
    let copy = await enqueue(queue, .copy(["/S/album"], into: "/A"), watcher)
    #expect(await files.events.wait { $0.contains("copy /S/album") })

    let rename = await enqueue(queue, .rename("/S/notes.txt", to: "todo.txt"), watcher)
    let renameOnTheCopysVolume = await enqueue(queue, .rename("/A/notes.txt", to: "b.txt"), watcher)
    let move = await enqueue(queue, .move(["/A/x"], into: "/A/sorted"), watcher)
    let trash = await enqueue(queue, .trash(["/A/old"]), watcher)
    let newFolder = await enqueue(queue, .newFolder(in: "/A"), watcher)

    #expect(await watcher.waitUntilFinished(rename, renameOnTheCopysVolume, move, trash, newFolder))
    #expect(watcher.state(of: renameOnTheCopysVolume)?.phase == .done)
    #expect(watcher.state(of: copy) == nil)
    #expect(
        watcher.state(of: rename)?.record.changes == [
            .moved(from: "/S/notes.txt", to: "/S/todo.txt")
        ])
    #expect(watcher.state(of: move)?.record.changes == [.moved(from: "/A/x", to: "/A/sorted/x")])
    #expect(
        watcher.state(of: trash)?.record.changes == [
            .trashed(from: "/A/old", to: URL(fileURLWithPath: "/S/.Trashes/501/old"))
        ])
    #expect(watcher.state(of: newFolder)?.record.changes == [.created("/A/untitled folder")])
    #expect(!files.events.all.contains { $0.hasPrefix("copy failed") })

    files.releaseAll()
    #expect(await watcher.waitUntilFinished(copy))
    #expect(watcher.state(of: copy)?.record.changes == [.created("/A/album")])
}

@Test func anOperationTouchingAnItemACopyReadsOrWritesIsRefusedNamingIt() async throws {
    let files = FakeFiles()
    let watcher = Watcher()
    let queue = makeQueue(files, watcher)
    let copy = await enqueue(queue, .copy(["/S/album"], into: "/A"), watcher)
    #expect(await files.events.wait { $0.contains("copy /S/album") })

    let refused: [(FileOperation, String)] = [
        (.rename("/S/album/01.flac", to: "one.flac"), "/S/album/01.flac"),
        (.trash(["/S/album"]), "/S/album"),
        (.move(["/S"], into: "/B"), "/S"),
        (.rename("/A/album", to: "Album"), "/A/album"),
        (.copy(["/B/album"], into: "/A"), "/A/album"),
        // APFS compares names without case, so these name the same items.
        (.rename("/s/ALBUM/01.flac", to: "one.flac"), "/s/ALBUM/01.flac"),
        (.trash(["/S/Album/"]), "/S/Album/"),
    ]
    for (operation, path) in refused {
        let id = await enqueue(queue, operation, watcher)
        #expect(await watcher.waitUntilFinished(id))
        #expect(watcher.state(of: id)?.phase == .refused(.inUse(path: path)), "\(operation)")
    }
    // Reading the same items doesn't change them, so a second copy may run beside the first.
    let secondCopy = await enqueue(queue, .copy(["/S/album"], into: "/B"), watcher)
    let unrelated = await enqueue(queue, .rename("/S/other", to: "renamed"), watcher)
    #expect(await watcher.waitUntilFinished(unrelated))
    #expect(watcher.state(of: unrelated)?.phase == .done)
    #expect(!files.events.all.contains { $0.hasPrefix("trash") || $0.contains("01.flac") })

    files.releaseAll()
    #expect(await watcher.waitUntilFinished(copy, secondCopy))
    #expect(watcher.state(of: secondCopy)?.phase == .done)
}

@Test func aFolderIntoItsOwnSubfolderIsRefusedAtPlanTime() async throws {
    let files = FakeFiles(releasingAll: true)
    let watcher = Watcher()
    let queue = makeQueue(files, watcher)

    let id = await enqueue(queue, .copy(["/S/album"], into: "/S/album/disc 1"), watcher)

    #expect(await watcher.waitUntilFinished(id))
    #expect(watcher.state(of: id)?.phase == .refused(.intoItself(source: "/S/album")))
    #expect(files.events.all.isEmpty)
}

@Test func aCrossVolumeMoveRemovesEachSourceOnlyAfterItsCopySucceeds() async throws {
    let files = FakeFiles(releasingAll: true)
    let denied = FileOperationError(reason: .permissionDenied, path: "/S/b", errno: EACCES)
    files.failCopy(of: "/S/b", with: denied)
    let watcher = Watcher()
    let queue = makeQueue(files, watcher)

    let id = await enqueue(queue, .move(["/S/a", "/S/b", "/S/c"], into: "/A"), watcher)

    #expect(await watcher.waitUntilFinished(id))
    #expect(
        files.events.all.filter { !$0.hasPrefix("inspect") } == [
            "copy /S/a", "copied /S/a to /A/a", "delete /S/a",
            "copy /S/b", "copy failed /S/b",
            "copy /S/c", "copied /S/c to /A/c", "delete /S/c",
        ])
    let state = try #require(watcher.state(of: id))
    #expect(state.phase == .failed)
    #expect(state.errors == [denied])
    #expect(
        state.record.changes == [
            .moved(from: "/S/a", to: "/A/a"), .moved(from: "/S/c", to: "/A/c"),
        ])
    #expect(state.progress.itemsDone == 3)
}

@Test func aVolumeErrorStopsTheItemsLeftAfterIt() async throws {
    let files = FakeFiles(releasingAll: true)
    let full = FileOperationError(reason: .noSpace, path: "/A/a", errno: ENOSPC)
    files.failCopy(of: "/S/a", with: full)
    let watcher = Watcher()
    let queue = makeQueue(files, watcher)

    let id = await enqueue(queue, .copy(["/S/a", "/S/b"], into: "/A"), watcher)

    #expect(await watcher.waitUntilFinished(id))
    #expect(!files.events.all.contains("copy /S/b"))
    #expect(watcher.state(of: id)?.phase == .failed)
    #expect(watcher.state(of: id)?.errors == [full])
}

@Test func aCancelSaysWhetherItLeftPartOfTheCopyBehind() async throws {
    let files = FakeFiles()
    let locked = FileOperationError(
        reason: .permissionDenied, path: "/A/locked/file", errno: EPERM)
    files.failCancel(of: "/S/locked", with: locked)
    let watcher = Watcher()
    let queue = makeQueue(files, watcher)
    let clean = await enqueue(queue, .copy(["/S/clean"], into: "/A"), watcher)
    #expect(await files.events.wait { $0.contains("copy /S/clean") })
    let partial = await enqueue(queue, .copy(["/S/locked"], into: "/B"), watcher)
    #expect(await files.events.wait { $0.contains("copy /S/locked") })
    let waiting = await enqueue(queue, .copy(["/S/waiting"], into: "/A"), watcher)
    #expect(await watcher.waitUntil(waiting, is: .queued))

    await queue.cancel(waiting)
    await queue.cancel(clean)
    await queue.cancel(partial)

    #expect(await watcher.waitUntilFinished(clean, partial, waiting))
    #expect(watcher.state(of: clean)?.phase == .cancelled(leftBehind: nil))
    #expect(watcher.state(of: partial)?.phase == .cancelled(leftBehind: locked))
    #expect(watcher.state(of: waiting)?.phase == .cancelled(leftBehind: nil))
    #expect(!files.events.all.contains("copy /S/waiting"))
}

@Test func aLaneStartsItsWaitingOperationsInTheOrderQueued() async throws {
    let files = FakeFiles()
    let watcher = Watcher()
    let queue = makeQueue(files, watcher)
    let first = await enqueue(queue, .copy(["/S/a"], into: "/A"), watcher)
    #expect(await files.events.wait { $0.contains("copy /S/a") })
    files.holdScan(of: "/S/b")
    let second = await enqueue(queue, .copy(["/S/b"], into: "/A"), watcher)
    let third = await enqueue(queue, .copy(["/S/c"], into: "/A"), watcher)
    // The third's plan finishes first; the second is planned before the lane frees.
    #expect(await watcher.waitUntil(third, is: .queued))
    files.letScanGo(of: "/S/b")
    #expect(await watcher.waitUntil(second, is: .queued))

    files.release("/S/a")

    #expect(await files.events.wait { $0.contains("copy /S/b") })
    try await pause()
    #expect(!files.events.all.contains("copy /S/c"))
    files.releaseAll()
    #expect(await watcher.waitUntilFinished(first, second, third))
}

@Test func cancelFinishesAnOperationWhosePlanIsStuckAtOnce() async throws {
    let files = FakeFiles(releasingAll: true)
    files.holdScan(of: "/S/stuck")
    let watcher = Watcher()
    let queue = makeQueue(files, watcher)
    let stuck = await enqueue(queue, .copy(["/S/stuck"], into: "/A"), watcher)
    #expect(await files.events.wait { $0.contains("holding scan /S/stuck") })

    await queue.cancel(stuck)

    #expect(await watcher.waitUntilFinished(stuck))
    #expect(watcher.state(of: stuck)?.phase == .cancelled(leftBehind: nil))
    // The lane was never taken, and the plan's late result is dropped.
    let next = await enqueue(queue, .copy(["/S/next"], into: "/A"), watcher)
    #expect(await watcher.waitUntilFinished(next))
    files.letScanGo(of: "/S/stuck")
    try await pause()
    #expect(!files.events.all.contains("copy /S/stuck"))
    #expect(watcher.finished.all.filter { $0.id == stuck }.count == 1)
}

@Test func pauseAndResumeReachTheCopierAndShowInTheState() async throws {
    let files = FakeFiles()
    let watcher = Watcher()
    let queue = makeQueue(files, watcher)
    let id = await enqueue(queue, .copy(["/S/a"], into: "/A"), watcher)
    #expect(await files.events.wait { $0.contains("copy /S/a") })

    await queue.pause(id)
    #expect(await files.events.wait { $0.contains("pause") })
    #expect(
        await watcher.snapshots.wait { $0.last?.first { $0.id == id }?.state.phase == .paused })
    await queue.resume(id)
    #expect(await files.events.wait { $0.contains("resume") })
    #expect(
        await watcher.snapshots.wait { $0.last?.first { $0.id == id }?.state.phase == .running })

    files.releaseAll()
    #expect(await watcher.waitUntilFinished(id))
}

@Test func snapshotsReachTheObserverAtMostTenTimesASecond() async throws {
    let files = FakeFiles()
    files.reportProgress(steps: 200)
    let watcher = Watcher()
    let clock = ManualClock()
    let queue = makeQueue(files, watcher, clock: clock)

    let id = await enqueue(queue, .copy(["/S/a"], into: "/A"), watcher)
    #expect(await files.events.wait { $0.contains("reported /S/a") })
    try await pause()

    // The first change goes out at once; everything after it waits for the interval.
    #expect(watcher.snapshots.all.count == 1)
    clock.advance(by: FileOperationQueue.snapshotInterval - .milliseconds(1))
    try await pause()
    #expect(watcher.snapshots.all.count == 1)
    clock.advance(by: .milliseconds(1))
    #expect(await watcher.snapshots.wait { $0.count == 2 })
    let latest = try #require(watcher.snapshots.all.last?.first { $0.id == id })
    #expect(latest.state.phase == .running)
    #expect(latest.state.progress.copied == CopyProgress(bytes: 200, files: 0))
    #expect(
        latest.state.progress.total == TreeSizeWalker.Total(bytes: 10, files: 1, isPartial: false))

    files.releaseAll()
    #expect(await watcher.waitUntilFinished(id))
    try await pause()
    #expect(watcher.snapshots.all.count == 2)
    clock.advance(by: FileOperationQueue.snapshotInterval)
    #expect(await watcher.snapshots.wait { $0.count == 3 })
    let last = try #require(watcher.snapshots.all.last)
    #expect(last.map(\.id) == [id])
    #expect(last.first?.state.phase == .done)
    #expect(last.first?.state.progress.copied == CopyProgress(bytes: 10, files: 1))
    // Nothing is running, so nothing more is sent, not even an empty list.
    clock.advance(by: FileOperationQueue.snapshotInterval)
    clock.advance(by: FileOperationQueue.snapshotInterval)
    try await pause()
    #expect(watcher.snapshots.all.count == 3)
    // A finished operation is in one snapshot, then leaves the list.
    await queue.enqueue(.newFolder(in: "/A"))
    clock.advance(by: FileOperationQueue.snapshotInterval)
    #expect(
        await watcher.snapshots.wait { $0.count >= 4 && $0.last?.contains { $0.id == id } == false }
    )
}

/// Real volumes: trashes only files the test makes on a disk image, and removes them from the
/// image's trash afterwards.
@Suite(.serialized) struct FileOperationQueueDiskTests {
    @Test func trashOnADiskImageRecordsEachTrashURL() async throws {
        let image = try await DiskImage("FileOperationQueueTests")
        let paths = ["one.txt", "two.txt"].map { image.mountPoint + "/" + $0 }
        for path in paths { try Data(path.utf8).write(to: URL(fileURLWithPath: path)) }
        let queue = FileOperationQueue(prompts: .unexpected) { _ in }

        let state = await queue.perform(.trash(paths))

        #expect(state.phase == .done)
        let trashed = state.record.changes.compactMap { change -> URL? in
            guard case .trashed(_, let url) = change else { return nil }
            return url
        }
        #expect(trashed.count == 2)
        for url in trashed {
            #expect(url.path.hasPrefix(image.mountPoint + "/.Trashes/"))
            #expect(FileManager.default.fileExists(atPath: url.path))
        }
        for path in paths { #expect(!FileManager.default.fileExists(atPath: path)) }
        for url in trashed { try FileManager.default.removeItem(at: url) }
        try await image.detach()
    }

    @Test func aMoveToADiskImageCopiesThenRemovesEachSourceAndKeepsOneThatFailed() async throws {
        let folder = try TemporaryFolder("FileOperationQueueTests")
        let image = try await DiskImage("FileOperationQueueTests")
        let source = folder.url.path
        try Data("readable".utf8).write(to: URL(fileURLWithPath: source + "/readable.txt"))
        try Data("unreadable".utf8).write(to: URL(fileURLWithPath: source + "/unreadable.txt"))
        #expect(chmod(source + "/unreadable.txt", 0) == 0)
        let queue = FileOperationQueue(prompts: .unexpected) { _ in }

        let state = await queue.perform(
            .move([source + "/readable.txt", source + "/unreadable.txt"], into: image.mountPoint))

        #expect(state.phase == .failed)
        #expect(state.errors.map(\.reason) == [.permissionDenied])
        #expect(
            state.record.changes == [
                .moved(from: source + "/readable.txt", to: image.mountPoint + "/readable.txt")
            ])
        #expect(
            try String(contentsOfFile: image.mountPoint + "/readable.txt", encoding: .utf8)
                == "readable")
        #expect(!FileManager.default.fileExists(atPath: source + "/readable.txt"))
        #expect(FileManager.default.fileExists(atPath: source + "/unreadable.txt"))
        #expect(!FileManager.default.fileExists(atPath: image.mountPoint + "/unreadable.txt"))
        try await image.detach()
    }
}

// MARK: Drop folders

@Test func aDropFolderIsMadeHiddenInTheTargetAndRemovedWhenEmpty() async throws {
    let files = FakeFiles()
    let queue = makeQueue(files, Watcher())

    let dropFolder = try await queue.makeDropFolder(in: "/A/photos")
    let name = (dropFolder.path as NSString).lastPathComponent
    #expect(dropFolder.path == "/A/photos/" + name)
    #expect(name.hasPrefix(FileOperationQueue.dropFolderPrefix))
    #expect(await queue.removeDropFolder(dropFolder).isEmpty)

    #expect(
        files.events.all == [
            "list /A/photos", "make folder /A/photos/\(name)", "list \(dropFolder.path)",
            "remove folder \(dropFolder.path)",
        ])
}

@Test func whatADropLeftInItsFolderGoesToTheTrashNotAway() async throws {
    let files = FakeFiles()
    let queue = makeQueue(files, Watcher())
    let dropFolder = try await queue.makeDropFolder(in: "/A")
    files.put(["skipped.jpg"], in: dropFolder.path)

    #expect(await queue.removeDropFolder(dropFolder).isEmpty)

    #expect(files.events.all.contains("trash \(dropFolder.path)/skipped.jpg"))
    #expect(files.events.all.last == "remove folder \(dropFolder.path)")
    #expect(!files.events.all.contains { $0.hasPrefix("delete ") })
}

@Test func withNoTrashADropFolderIsLeftAndTheFailureReturned() async throws {
    let files = FakeFiles()
    let queue = makeQueue(files, Watcher())
    let dropFolder = try await queue.makeDropFolder(in: "/A")
    files.put(["skipped.jpg"], in: dropFolder.path)
    files.removeTrash()

    let errors = await queue.removeDropFolder(dropFolder)

    #expect(
        errors == [
            FileOperationError(
                reason: .noTrash, path: dropFolder.path + "/skipped.jpg", errno: nil)
        ])
    #expect(!files.events.all.contains { $0.hasPrefix("remove folder") || $0.hasPrefix("delete ") })
}

@Test func pendingDropFoldersAreRemovedTogetherOnce() async throws {
    let files = FakeFiles()
    let queue = makeQueue(files, Watcher())
    let first = try await queue.makeDropFolder(in: "/A")
    let second = try await queue.makeDropFolder(in: "/B")
    let removed = try await queue.makeDropFolder(in: "/A")
    _ = await queue.removeDropFolder(removed)

    #expect(await queue.removePendingDropFolders().isEmpty)
    #expect(await queue.removePendingDropFolders().isEmpty)

    let removals = files.events.all.filter { $0.hasPrefix("remove folder") }
    #expect(
        Set(removals) == Set([first, second, removed].map { "remove folder \($0.path)" }))
    #expect(removals.count == 3)
}

@Test func aReportedFailureShowsAsAFinishedFailedOperation() async throws {
    let watcher = Watcher()
    let queue = makeQueue(FakeFiles(), watcher)
    let error = FileOperationError(reason: .permissionDenied, path: "/A", errno: EACCES)
    let operation = FileOperation.receive(name: nil, app: "Mail", into: "/A")

    await queue.report(operation, errors: [error])

    #expect(
        await watcher.snapshots.wait { sent in
            sent.contains { snapshots in
                snapshots.contains {
                    $0.operation == operation && $0.state.phase == .failed
                        && $0.state.errors == [error]
                }
            }
        })
}

@Test func aDropFolderRemovedAtQuitIsLeftAloneByItsDropLater() async throws {
    let files = FakeFiles()
    let queue = makeQueue(files, Watcher())
    let dropFolder = try await queue.makeDropFolder(in: "/A")

    #expect(await queue.removePendingDropFolders().isEmpty)
    #expect(await queue.removeDropFolder(dropFolder).isEmpty)

    #expect(files.events.all.filter { $0.hasPrefix("remove folder") }.count == 1)
}

@Test func aDropFolderItsDropRemovedIsLeftAloneAtQuit() async throws {
    let files = FakeFiles()
    let queue = makeQueue(files, Watcher())
    let first = try await queue.makeDropFolder(in: "/A")
    let second = try await queue.makeDropFolder(in: "/B")

    // Both at once: the quit's removal and the drop's, in either order.
    async let atQuit = queue.removePendingDropFolders()
    async let byDrop = queue.removeDropFolder(second)
    #expect(await atQuit.isEmpty)
    #expect(await byDrop.isEmpty)

    let removals = files.events.all.filter { $0.hasPrefix("remove folder") }
    #expect(removals.sorted() == ["remove folder \(first.path)", "remove folder \(second.path)"])
}

@Test func aDropFolderIsListedWithoutFollowingASymlinkInItsPlace() throws {
    let root = try TemporaryFolder("FileOperationQueueTests")
    let real = root.url.appending(path: "real")
    try FileManager.default.createDirectory(at: real, withIntermediateDirectories: false)
    try Data("x".utf8).write(to: real.appending(path: "x"))
    let link = root.url.appending(path: "link").path
    try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: real.path)
    let listNames = FileOperationQueue.FileSystem.real.listNames

    #expect(try listNames(real.path) == ["x"])
    #expect(throws: FileOperationError.self) { try listNames(link) }
}

@Test func makingADropFolderFirstRemovesEmptyFoldersEarlierRunsLeftBesideIt() async throws {
    let files = FakeFiles()
    let queue = makeQueue(files, Watcher())
    let staging = FileOperationQueue.stagingFolderPrefix + "stale"
    let drop = FileOperationQueue.dropFolderPrefix + "stale"
    let full = FileOperationQueue.dropFolderPrefix + "full"
    files.put(["photo.jpg", staging, drop, full, ".searcher-other"], in: "/A")
    files.fill("/A/" + full)

    let dropFolder = try await queue.makeDropFolder(in: "/A")

    #expect(
        files.events.all == [
            "list /A", "remove folder /A/\(staging)", "remove folder /A/\(drop)",
            "not empty /A/\(full)", "make folder \(dropFolder.path)",
        ])
}

// MARK: Quitting

@Test func cancelAllStopsEveryUnfinishedOperationAndReturnsOnceEachHasFinished() async throws {
    let files = FakeFiles()
    files.holdScan(of: "/S/planning")
    let watcher = Watcher()
    let queue = makeQueue(files, watcher)
    let running = await enqueue(queue, .copy(["/S/a"], into: "/A"), watcher)
    #expect(await files.events.wait { $0.contains("copy /S/a") })
    let waiting = await enqueue(queue, .copy(["/S/b"], into: "/A"), watcher)
    #expect(await watcher.waitUntil(waiting, is: .queued))
    let planning = await enqueue(queue, .copy(["/S/planning"], into: "/B"), watcher)
    #expect(await files.events.wait { $0.contains("holding scan /S/planning") })

    await queue.cancelAllAndWait()

    for id in [running, waiting, planning] {
        #expect(watcher.state(of: id)?.phase == .cancelled(leftBehind: nil))
    }
    #expect(!files.events.all.contains { $0.hasPrefix("copied") })
    files.letScanGo(of: "/S/planning")
}

/// A copier whose copy ignores a cancel until the test lets it go, as one blocked on a share
/// that stopped answering does.
private final class StuckCopier: FileOperationQueue.Copier, @unchecked Sendable {
    let events: EventLog<String>
    let gate = DispatchSemaphore(value: 0)

    init(events: EventLog<String>) {
        self.events = events
    }

    func copy(
        _ source: String, to destination: String, progress: (CopyProgress) -> Void
    ) throws -> CopyProgress {
        events.append("stuck copy \(source)")
        gate.wait()
        throw CancellationError()
    }

    func pause() {}
    func resume() {}
    func cancel() {}
}

@Test func cancelAllGivesUpAtItsDeadlineWhileACopyIgnoresTheCancel() async throws {
    let files = FakeFiles()
    let copier = StuckCopier(events: files.events)
    var fileSystem = files.fileSystem()
    fileSystem.makeCopier = { copier }
    let watcher = Watcher()
    let queue = FileOperationQueue(
        fileSystem: fileSystem, prompts: Prompter().prompts, clock: ContinuousClock()
    ) { watcher.snapshots.append($0) }
    let id = await enqueue(queue, .copy(["/S/a"], into: "/A"), watcher)
    #expect(await files.events.wait { $0.contains("stuck copy /S/a") })
    let clock = ContinuousClock()

    #expect(await !queue.cancelAll(by: clock.now.advanced(by: .milliseconds(50)), clock: clock))

    copier.gate.signal()
    #expect(await watcher.waitUntilFinished(id))
    #expect(await queue.cancelAll(by: clock.now.advanced(by: .seconds(5)), clock: clock))
}

/// Cancels everything with a 2 s deadline and says whether it finished well inside it.
private func cancelAllFinishesAtOnce(_ queue: FileOperationQueue) async -> Bool {
    let clock = ContinuousClock()
    let start = clock.now
    let finished = await queue.cancelAll(by: start.advanced(by: .seconds(2)), clock: clock)
    return finished && start.duration(to: clock.now) < .milliseconds(500)
}

/// A cancel finishes an operation still planning at once, before cancel-all waits for it.
@Test func cancelAllReturnsAtOnceWhenOnlyAPlanningCopyIsLeft() async throws {
    let files = FakeFiles()
    files.holdScan(of: "/S/planning")
    let watcher = Watcher()
    let queue = makeQueue(files, watcher)
    let planning = await enqueue(queue, .copy(["/S/planning"], into: "/B"), watcher)
    #expect(await files.events.wait { $0.contains("holding scan /S/planning") })

    #expect(await cancelAllFinishesAtOnce(queue))

    #expect(watcher.state(of: planning)?.phase == .cancelled(leftBehind: nil))
    files.letScanGo(of: "/S/planning")
}

/// A cancel finishes an operation waiting for an answer at once, as it does one queued in its
/// lane. A queued one always has a running one ahead of it, whose end would wake the wait, so
/// this is the case where nothing else does.
@Test func cancelAllReturnsAtOnceWhenOnlyAnOperationWaitingForAnAnswerIsLeft() async throws {
    let files = FakeFiles()
    files.place("/A/a")
    let watcher = Watcher()
    let queue = makeQueue(files, watcher)
    let asking = await enqueue(queue, .copy(["/S/a"], into: "/A"), watcher)
    #expect(await watcher.waitUntil(asking, is: .waitingForAnswer))

    #expect(await cancelAllFinishesAtOnce(queue))

    #expect(watcher.state(of: asking)?.phase == .cancelled(leftBehind: nil))
}

/// An undo reads `finishedCount` first; a copy already in its lane doesn't hold it.
@Test func finishedCountDoesNotWaitForACopyInItsLane() async throws {
    let files = FakeFiles()
    let watcher = Watcher()
    let queue = makeQueue(files, watcher)
    let trash = await enqueue(queue, .trash(["/A/old"]), watcher)
    #expect(await watcher.waitUntilFinished(trash))
    let copy = await enqueue(queue, .copy(["/S/album"], into: "/A"), watcher)
    #expect(await files.events.wait { $0.contains("copy /S/album") })
    let counts = EventLog<Int>()

    Task { counts.append(await queue.finishedCount) }

    #expect(await counts.wait { !$0.isEmpty })
    #expect(counts.all == [1])
    files.releaseAll()
    #expect(await watcher.waitUntilFinished(copy))
}
