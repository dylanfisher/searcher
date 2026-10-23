import Base
import Darwin
import Foundation
import TestSupport
import Testing

@testable import Browser

private let volumeA = VolumeIdentity(device: "/dev/fakeA", mountPoint: "/A", kind: .local)
private let volumeB = VolumeIdentity(device: "/dev/fakeB", mountPoint: "/B", kind: .local)
private let volumeS = VolumeIdentity(device: "/dev/fakeS", mountPoint: "/S", kind: .local)

/// A file system for queue tests that touches no disk: paths under `/A`, `/B` and `/S` are on
/// three volumes, and every call is logged. A copy logs its start, reports `progressSteps`
/// changes, then waits until its source is released or the copy is cancelled.
private final class FakeFiles: @unchecked Sendable {
    let events = EventLog<String>()
    private let condition = NSCondition()
    private var released: Set<String> = []
    private var allReleased = false
    private var copyFailures: [String: FileOperationError] = [:]
    private var cancelFailures: [String: FileOperationError] = [:]
    private var progressSteps = 0

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

    func reportProgress(steps: Int) {
        condition.withLock { progressSteps = steps }
    }

    func fileSystem() -> FileOperationQueue.FileSystem {
        FileOperationQueue.FileSystem(
            volumeOf: { path throws(ListingError) in
                for volume in [volumeA, volumeB, volumeS]
                where isPath(path, atOrUnder: volume.mountPoint) {
                    return volume
                }
                throw ListingError(path: path, code: ENOENT)
            },
            measure: { _, _ in TreeSizeWalker.Total(bytes: 10, files: 1, isPartial: false) },
            makeCopier: { FakeCopier(files: self) },
            move: { source, destination throws(FileOperationError) in
                self.events.append("move \(source) to \(destination)")
            },
            trash: { path throws(FileOperationError) in
                self.events.append("trash \(path)")
                return URL(
                    fileURLWithPath: "/S/.Trashes/501/" + (path as NSString).lastPathComponent)
            },
            deletePermanently: { path throws(FileOperationError) in
                self.events.append("delete \(path)")
            },
            makeUntitledFolder: { folder throws(FileOperationError) in
                self.events.append("new folder in \(folder)")
                return folder + "/untitled folder"
            },
            isTaken: { _, _ throws(FileOperationError) in false })
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
            if copier.isCancelled {
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

private final class FakeCopier: FileOperationQueue.Copier, @unchecked Sendable {
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

/// What the queue told its observer and each operation's `onFinish`.
private final class Watcher: @unchecked Sendable {
    let snapshots = EventLog<[FileOperationQueue.Snapshot]>()
    let finished = EventLog<FileOperationQueue.Snapshot>()

    func state(of id: FileOperationQueue.ID) -> OperationState? {
        finished.all.first { $0.id == id }?.state
    }

    func waitUntilFinished(_ ids: FileOperationQueue.ID...) async -> Bool {
        await finished.wait { done in ids.allSatisfy { id in done.contains { $0.id == id } } }
    }
}

private func makeQueue<C: Clock<Duration>>(
    _ files: FakeFiles, _ watcher: Watcher, clock: C = ContinuousClock()
) -> FileOperationQueue {
    FileOperationQueue(fileSystem: files.fileSystem(), clock: clock) {
        watcher.snapshots.append($0)
    }
}

private func enqueue(
    _ queue: FileOperationQueue, _ operation: FileOperation, _ watcher: Watcher
) async -> FileOperationQueue.ID {
    await queue.enqueue(operation) { watcher.finished.append($0) }
}

/// Lets work that would break an expectation have the time to do it.
private func pause() async throws {
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

    // The lane takes its operations in the order their plans finish, so any of the three on
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
    let move = await enqueue(queue, .move(["/A/x"], into: "/A/sorted"), watcher)
    let trash = await enqueue(queue, .trash(["/A/old"]), watcher)
    let newFolder = await enqueue(queue, .newFolder(in: "/A"), watcher)

    #expect(await watcher.waitUntilFinished(rename, move, trash, newFolder))
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
        files.events.all == [
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
    let partial = await enqueue(queue, .copy(["/S/locked"], into: "/B"), watcher)
    let waiting = await enqueue(queue, .copy(["/S/waiting"], into: "/A"), watcher)
    #expect(
        await files.events.wait { $0.contains("copy /S/clean") && $0.contains("copy /S/locked") })

    await queue.cancel(waiting)
    await queue.cancel(clean)
    await queue.cancel(partial)

    #expect(await watcher.waitUntilFinished(clean, partial, waiting))
    #expect(watcher.state(of: clean)?.phase == .cancelled(leftBehind: nil))
    #expect(watcher.state(of: partial)?.phase == .cancelled(leftBehind: locked))
    #expect(watcher.state(of: waiting)?.phase == .cancelled(leftBehind: nil))
    #expect(!files.events.all.contains("copy /S/waiting"))
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
        let queue = FileOperationQueue { _ in }

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
        let queue = FileOperationQueue { _ in }

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
