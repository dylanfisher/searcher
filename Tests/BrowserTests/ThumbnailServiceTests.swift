import Base
import CoreGraphics
import Foundation
import TestSupport
import Testing

@testable import Browser

private func kind(_ type: DirectoryEntry.FileType, _ pathExtension: Substring) async -> EntryKind {
    await Task.detached { EntryKind(type, pathExtension: pathExtension) }.value
}

private func dataless(_ name: String) -> DirectoryEntry {
    DirectoryEntry(
        name: name, type: .regular, size: 1, modified: testDate, isHidden: false,
        isDataless: true)
}

private func link(_ name: String) -> DirectoryEntry {
    DirectoryEntry(
        name: name, type: .symbolicLink, size: nil, modified: testDate, isHidden: false,
        isDataless: false)
}

/// Quick Look makes a folder's icon too, as Finder draws it for that folder: a sheet of paper in a
/// folder with items, its tag's color, its custom icon
/// (docs/decisions/0129-row-icons-as-finder.md).
@Test func onlyAFileWhoseContentsAreHereAndArentTextOrAFolderShowsAThumbnail() async {
    let jpeg = await kind(.regular, "jpg")
    #expect(ThumbnailService.shows(file("a.jpg"), kind: jpeg))
    #expect(ThumbnailService.shows(file("a.pdf"), kind: await kind(.regular, "pdf")))
    #expect(ThumbnailService.shows(file("a.svg"), kind: await kind(.regular, "svg")))
    // Not downloaded: making one would download it.
    #expect(!ThumbnailService.shows(dataless("a.jpg"), kind: jpeg))
    // Text keeps its type icon, as Finder shows a JSON file.
    #expect(!ThumbnailService.shows(file("a.json"), kind: await kind(.regular, "json")))
    #expect(!ThumbnailService.shows(file("a.txt"), kind: await kind(.regular, "txt")))
    #expect(!ThumbnailService.shows(file("a.swift"), kind: await kind(.regular, "swift")))
    #expect(ThumbnailService.shows(folder("a.jpg"), kind: await kind(.directory, "jpg")))
    // A folder that isn't downloaded: Quick Look would list it, which downloads its items.
    let datalessFolder = DirectoryEntry(
        name: "b", type: .directory, size: nil, modified: testDate, isHidden: false,
        isDataless: true)
    #expect(!ThumbnailService.shows(datalessFolder, kind: await kind(.directory, "")))
    #expect(!ThumbnailService.shows(package("A.app"), kind: await kind(.package, "app")))
    #expect(!ThumbnailService.shows(link("a.jpg"), kind: await kind(.symbolicLink, "jpg")))
}

/// The local volume the tests' files are on.
private let disk = VolumeIdentity(device: "/dev/disk3s1", mountPoint: "/", kind: .local)

/// A network volume.
private let share = VolumeIdentity(
    device: "//nas/share", mountPoint: "/Volumes/share", kind: .network)

@Test func aThumbnailIsMadeOnABlockingCallThreadAndKeptForThatVersionOfTheFile() async throws {
    let maker = GatedThumbnailMaker()
    let service = ThumbnailService(maker: maker)
    let entry = file("a.jpg")
    let image = testThumbnail()
    #expect(service.cached(at: "/p/a.jpg", entry: entry, side: 16) == nil)

    let request = Task {
        try await service.thumbnail(at: "/p/a.jpg", entry: entry, side: 16, on: disk)
    }
    #expect(await maker.waitForCalls(1))
    maker.answer("/p/a.jpg", with: image)

    #expect(try await request.value === image)
    #expect(
        maker.calls == [
            .init(
                path: "/p/a.jpg", side: 16, scale: 2, framed: true, onMainThread: false,
                onBlockingCallThread: true)
        ])
    #expect(service.cached(at: "/p/a.jpg", entry: entry, side: 16)! === image)
    #expect(
        try await service.thumbnail(at: "/p/a.jpg", entry: entry, side: 16, on: disk) === image)
    #expect(maker.calls.count == 1)

    // Saved again: a new version, so the old thumbnail isn't shown for it.
    let saved = DirectoryEntry(
        name: "a.jpg", type: .regular, size: 1, modified: testDate.addingTimeInterval(1),
        isHidden: false, isDataless: false)
    #expect(service.cached(at: "/p/a.jpg", entry: saved, side: 16) == nil)
    #expect(service.cached(at: "/p/a.jpg", entry: file("a.jpg", size: 2), side: 16) == nil)
    // Tagged: a folder's icon takes its tag's color, so new tags are a new version.
    let tagged = DirectoryEntry(
        name: "a.jpg", type: .regular, size: 1, modified: testDate, isHidden: false,
        isDataless: false, tagLabels: TagLabels([1]))
    #expect(service.cached(at: "/p/a.jpg", entry: tagged, side: 16) == nil)
    // Another size is another thumbnail.
    #expect(service.cached(at: "/p/a.jpg", entry: entry, side: 128) == nil)
    _ = try await service.thumbnail(at: "/p/a.jpg", entry: saved, side: 16, on: disk)
    #expect(maker.calls.count == 2)
    #expect(service.calls.isIdle)
}

@Test func aFileWithNoThumbnailIsKeptAsHavingNone() async throws {
    let maker = GatedThumbnailMaker()
    maker.answer("/p/a.bin", with: nil)
    let service = ThumbnailService(maker: maker)

    #expect(
        try await service.thumbnail(at: "/p/a.bin", entry: file("a.bin"), side: 16, on: disk)
            == nil)
    #expect(
        try await service.thumbnail(at: "/p/a.bin", entry: file("a.bin"), side: 16, on: disk)
            == nil)

    #expect(maker.calls.count == 1)
    #expect(service.cached(at: "/p/a.bin", entry: file("a.bin"), side: 16) == .some(nil))
}

/// A folder refused an icon, as a volume mounted there before the mount table read it is, isn't
/// kept as having none: once the volume is unmounted, the folder asks again and gets its icon
/// (docs/decisions/0129-row-icons-as-finder.md).
@Test func aFolderRefusedAnIconIsNotKeptAsHavingNone() async throws {
    let maker = GatedThumbnailMaker()
    maker.answer("/p/music", with: nil)
    let service = ThumbnailService(maker: maker)
    let music = folder("music")

    #expect(try await service.thumbnail(at: "/p/music", entry: music, side: 18, on: disk) == nil)
    #expect(service.cached(at: "/p/music", entry: music, side: 18) == nil)

    let icon = testThumbnail()
    maker.answer("/p/music", with: icon)
    #expect(try await service.thumbnail(at: "/p/music", entry: music, side: 18, on: disk) === icon)
    #expect(maker.calls.count == 2)
}

/// A row's file is placed by the volume its folder's load read, not by its path's text: a folder
/// reached through a link under `/` onto a share is on the share, and its rows get none.
@Test func aRowOnANetworkVolumeIsNeverAskedForWhateverItsPathReads() async throws {
    let maker = GatedThumbnailMaker()
    // Answered, so a request that reached the maker would show rather than wait.
    maker.answer("/Users/me/nas/a.jpg", with: testThumbnail())
    let service = ThumbnailService(maker: maker)

    let thumbnail = try await service.thumbnail(
        at: "/Users/me/nas/a.jpg", entry: file("a.jpg"), side: 16, on: share)

    #expect(thumbnail == nil)
    #expect(maker.calls.isEmpty)
    #expect(service.calls.isIdle)
    #expect(!ThumbnailService.makes(on: share))
    #expect(ThumbnailService.makes(on: share, forPreview: true))
    #expect(ThumbnailService.makes(on: disk))
}

/// Finder's rows show a photo framed, in a rounded frame with a shadow, and its column preview
/// shows the image alone (0090-preview-column.md). The preview's is asked for unframed and kept
/// apart from the row's of the same file and size, so neither shows the other's.
@Test func thePreviewsThumbnailIsUnframedAndKeptApartFromTheRows() async throws {
    let maker = GatedThumbnailMaker()
    let service = ThumbnailService(maker: maker)
    let entry = file("a.jpg")
    let row = testThumbnail(pixels: 32)
    let preview = testThumbnail(pixels: 32)
    maker.answer("/p/a.jpg", with: row)
    _ = try await service.thumbnail(at: "/p/a.jpg", entry: entry, side: 16, on: disk)
    maker.answer("/p/a.jpg", with: preview)

    let made = try await service.thumbnail(
        at: "/p/a.jpg", entry: entry, side: 16, on: disk, forPreview: true)

    #expect(made === preview)
    #expect(maker.calls.map(\.framed) == [true, false])
    #expect(service.cached(at: "/p/a.jpg", entry: entry, side: 16)! === row)
    #expect(service.cached(at: "/p/a.jpg", entry: entry, side: 16, forPreview: true)! === preview)
    #expect(service.cachedSmaller(at: "/p/a.jpg", entry: entry, than: 512) === preview)
}

/// The preview's one file on a share is made, as Finder's preview shows it, on a
/// `BlockingCallThread` in the share's slot.
@Test func aPreviewOnANetworkVolumeIsMade() async throws {
    let maker = GatedThumbnailMaker()
    let image = testThumbnail()
    maker.answer("/Volumes/share/a.jpg", with: image)
    let service = ThumbnailService(maker: maker)

    let thumbnail = try await service.thumbnail(
        at: "/Volumes/share/a.jpg", entry: file("a.jpg"), side: 512, on: share, forPreview: true)

    #expect(thumbnail === image)
    #expect(
        maker.calls == [
            .init(
                path: "/Volumes/share/a.jpg", side: 512, scale: 2, framed: false,
                onMainThread: false, onBlockingCallThread: true)
        ])
    #expect(service.calls.isIdle)
}

/// A share makes one at a time. A preview request cancelled on a share, as when the selection
/// moves on, is stopped and frees the slot for the next, rather than reading on over the
/// network; one cancelled while it waits is never made. It isn't kept as having none, and its
/// late answer does nothing.
@Test func aCancelledPreviewOnAShareIsStoppedAndFreesTheSharesSlot() async throws {
    let maker = GatedThumbnailMaker()
    // A clock never advanced, so no request is given up.
    let service = ThumbnailService(maker: maker, clock: ManualClock())
    let paths = (0..<3).map { "/Volumes/share/\($0).jpg" }
    func preview(_ path: String) -> Task<CGImage?, any Error> {
        Task {
            try await service.thumbnail(
                at: path, entry: file("x.jpg"), side: 512, on: share, forPreview: true)
        }
    }
    let first = preview(paths[0])
    #expect(await maker.waitForCalls(1))
    let second = preview(paths[1])
    await bounded { service.calls.waitingCount(on: share) == 1 }
    let third = preview(paths[2])
    await bounded { service.calls.waitingCount(on: share) == 2 }

    // The selection moved on twice: the waiting one goes, then the one being made.
    second.cancel()
    first.cancel()

    #expect(await maker.waitForCalls(2))
    #expect(maker.paths == [paths[0], paths[2]])
    // A request left running would never end, so the test stops here rather than wait on it.
    try #require(maker.stopped == [paths[0]])
    await #expect(throws: CancellationError.self) { try await first.value }
    await #expect(throws: CancellationError.self) { try await second.value }
    maker.answer(paths[0], with: testThumbnail())
    #expect(service.cached(at: paths[0], entry: file("x.jpg"), side: 512) == nil)
    let image = testThumbnail()
    maker.answer(paths[2], with: image)
    #expect(try await third.value === image)
    #expect(service.calls.isIdle)
}

/// A share that never answers holds only its own slot: the preview of a file on another volume
/// is made meanwhile.
@Test func aShareThatNeverAnswersDoesntHoldAnotherVolumesPreview() async throws {
    let maker = GatedThumbnailMaker()
    let service = ThumbnailService(maker: maker, clock: ManualClock())
    let hung = Task {
        try await service.thumbnail(
            at: "/Volumes/share/a.jpg", entry: file("a.jpg"), side: 512, on: share,
            forPreview: true)
    }
    #expect(await maker.waitForCalls(1))
    let image = testThumbnail()
    maker.answer("/p/b.jpg", with: image)

    let local = try await service.thumbnail(
        at: "/p/b.jpg", entry: file("b.jpg"), side: 512, on: disk, forPreview: true)

    #expect(local === image)
    hung.cancel()
    // A request left running would never end, so the test stops here rather than wait on it.
    await bounded { maker.stopped == ["/Volumes/share/a.jpg"] }
    try #require(maker.stopped == ["/Volumes/share/a.jpg"])
    await #expect(throws: CancellationError.self) { try await hung.value }
    #expect(service.calls.isIdle)
}

/// A volume makes at most four at once; a request cancelled while it waits for a slot, as for a
/// row scrolled off screen, is never made.
@Test func aVolumeMakesFourAtOnceAndACancelledWaitingRequestIsNeverMade() async throws {
    let maker = GatedThumbnailMaker()
    let service = ThumbnailService(maker: maker)
    let paths = (0..<6).map { "/p/\($0).jpg" }
    let requests = paths.map { path in
        Task { try await service.thumbnail(at: path, entry: file("x.jpg"), side: 16, on: disk) }
    }
    #expect(await maker.waitForCalls(4))
    // The four in flight are whichever entered first; the two left wait.
    let started = Set(maker.paths)
    let waiting = paths.indices.filter { !started.contains(paths[$0]) }
    try #require(waiting.count == 2)

    requests[waiting[0]].cancel()
    maker.answer(maker.paths[0], with: testThumbnail())

    #expect(await maker.waitForCalls(5))
    #expect(!maker.paths.contains(paths[waiting[0]]))
    #expect(maker.paths.contains(paths[waiting[1]]))
    await #expect(throws: CancellationError.self) { try await requests[waiting[0]].value }
    for path in paths { maker.answer(path, with: nil) }
    for (index, request) in requests.enumerated() where index != waiting[0] {
        _ = try await request.value
    }
    #expect(service.calls.isIdle)
}

/// A request asked `first`, as the preview's is, waits ahead of rows' for the volume's slot.
@Test func aFirstRequestWaitsAheadOfTheOthers() async throws {
    let maker = GatedThumbnailMaker()
    let service = ThumbnailService(maker: maker)
    let rows = (0..<4).map { "/p/\($0).jpg" }
    let first = rows.map { path in
        Task { try await service.thumbnail(at: path, entry: file("x.jpg"), side: 16, on: disk) }
    }
    #expect(await maker.waitForCalls(4))
    let row = Task {
        try await service.thumbnail(at: "/p/row.jpg", entry: file("x.jpg"), side: 16, on: disk)
    }
    // The row waits before the preview asks.
    await bounded { !service.calls.isIdle && service.calls.waitingCount(on: disk) == 1 }
    let preview = Task {
        try await service.thumbnail(
            at: "/p/preview.jpg", entry: file("x.jpg"), side: 128, on: disk, forPreview: true)
    }
    await bounded { service.calls.waitingCount(on: disk) == 2 }

    maker.answer(rows[0], with: nil)

    #expect(await maker.waitForCalls(5))
    #expect(maker.paths[4] == "/p/preview.jpg")
    for path in rows + ["/p/row.jpg", "/p/preview.jpg"] { maker.answer(path, with: nil) }
    for request in first { _ = try await request.value }
    _ = try await row.value
    _ = try await preview.value
    #expect(service.calls.isIdle)
}

/// A thumbnail that doesn't come in `giveUp`, as for a broken file or a stalled disk, is stopped,
/// frees its slot for the next request and is kept as none for that version; its answer, if it
/// comes after all, does nothing.
@Test func aThumbnailThatDoesntComeIsGivenUpAndFreesItsSlot() async throws {
    let maker = GatedThumbnailMaker()
    let clock = ManualClock()
    let service = ThumbnailService(maker: maker, clock: clock)
    let paths = (0..<5).map { "/p/\($0).jpg" }
    let requests = paths.map { path in
        Task { try await service.thumbnail(at: path, entry: file("x.jpg"), side: 16, on: disk) }
    }
    #expect(await maker.waitForCalls(4))
    let hung = maker.paths
    await bounded { clock.waitingSleeps == 4 }

    clock.advance(by: ThumbnailService.giveUp)

    #expect(await maker.waitForCalls(5))
    let last = try #require(maker.paths.last)
    for path in hung {
        let index = try #require(paths.firstIndex(of: path))
        #expect(try await requests[index].value == nil)
        #expect(service.cached(at: path, entry: file("x.jpg"), side: 16) == .some(nil))
    }
    #expect(Set(maker.stopped) == Set(hung))
    // Late answers change nothing.
    for path in hung { maker.answer(path, with: testThumbnail()) }
    #expect(service.cached(at: hung[0], entry: file("x.jpg"), side: 16) == .some(nil))
    let image = testThumbnail()
    maker.answer(last, with: image)
    let lastIndex = try #require(paths.firstIndex(of: last))
    #expect(try await requests[lastIndex].value === image)
    #expect(service.calls.isIdle)
    // The wait of the one that came in time was stopped.
    await bounded { clock.waitingSleeps == 0 }
}

/// A preview on a share has `shareGiveUp`, not `giveUp`: a large file can take longer than
/// 5 s over SMB. One given up isn't kept as having none, so selecting the file again asks again.
@Test func aPreviewOnAShareIsGivenUpAfterThirtySecondsAndAskedAgainAfter() async throws {
    let maker = GatedThumbnailMaker()
    let clock = ManualClock()
    let service = ThumbnailService(maker: maker, clock: clock)
    let path = "/Volumes/share/a.cr3"
    func preview() -> Task<CGImage?, any Error> {
        Task {
            try await service.thumbnail(
                at: path, entry: file("a.cr3"), side: 512, on: share, forPreview: true)
        }
    }
    let first = preview()
    #expect(await maker.waitForCalls(1))
    await bounded { clock.waitingSleeps == 1 }

    clock.advance(by: ThumbnailService.giveUp)

    // Still waiting: its wait's deadline is further off.
    #expect(clock.waitingSleeps == 1)
    #expect(maker.stopped.isEmpty)
    clock.advance(by: ThumbnailService.shareGiveUp - ThumbnailService.giveUp)
    #expect(try await first.value == nil)
    #expect(maker.stopped == [path])
    #expect(service.cached(at: path, entry: file("a.cr3"), side: 512) == nil)
    await bounded { service.calls.isIdle }

    let again = preview()
    #expect(await maker.waitForCalls(2))
    let image = testThumbnail()
    maker.answer(path, with: image)
    #expect(try await again.value === image)
    #expect(service.calls.isIdle)
}

/// A `ThumbnailMaking` whose `makeThumbnail` blocks its thread until the test releases it, as a
/// call can on a share that stopped answering, and never answers.
private final class StuckThumbnailMaker: ThumbnailMaking, @unchecked Sendable {
    private let released = DispatchSemaphore(value: 0)
    // `lock` guards everything below.
    private let lock = NSLock()
    private var enteredPaths: [String] = []
    private var stoppedPaths: [String] = []

    func makeThumbnail(
        at path: String, side: Double, scale: Double, framed: Bool,
        done: @escaping @Sendable (CGImage?) -> Void
    ) -> @Sendable () -> Void {
        lock.withLock { enteredPaths.append(path) }
        released.wait()
        return { [self] in lock.withLock { stoppedPaths.append(path) } }
    }

    /// Lets one blocked call return.
    func release() { released.signal() }

    var entered: [String] { lock.withLock { enteredPaths } }
    var stopped: [String] { lock.withLock { stoppedPaths } }
}

/// A preview on a share cancelled while Quick Look's call hasn't returned ends the caller's
/// wait at once. The call keeps the share's one slot and its thread until it returns, as a hung
/// read does, so the next request waits without a thread.
@Test func aCancelWhileQuickLooksCallHangsEndsTheCallersWaitAtOnce() async throws {
    let maker = StuckThumbnailMaker()
    let service = ThumbnailService(maker: maker, clock: ManualClock())
    let hung = Task {
        try await service.thumbnail(
            at: "/Volumes/share/a.jpg", entry: file("a.jpg"), side: 512, on: share,
            forPreview: true)
    }
    await bounded { maker.entered == ["/Volumes/share/a.jpg"] }

    hung.cancel()

    #expect(await bounded(cancellation(of: hung)) == true)
    let next = Task {
        try await service.thumbnail(
            at: "/Volumes/share/b.jpg", entry: file("b.jpg"), side: 512, on: share,
            forPreview: true)
    }
    await bounded { service.calls.waitingCount(on: share) == 1 }
    next.cancel()
    await #expect(throws: CancellationError.self) { try await next.value }
    maker.release()
    await bounded { service.calls.isIdle }
}

/// A cancel that lands before Quick Look's call returns, and so before the making has a stop to
/// call, stops it as soon as the call returns, and frees the slot for the next request.
@Test func aCancelBeforeQuickLooksCallReturnsStopsItOnceItDoes() async throws {
    let maker = StuckThumbnailMaker()
    let service = ThumbnailService(maker: maker, clock: ManualClock())
    let first = Task {
        try await service.thumbnail(
            at: "/Volumes/share/a.jpg", entry: file("a.jpg"), side: 512, on: share,
            forPreview: true)
    }
    await bounded { maker.entered.count == 1 }
    first.cancel()
    #expect(await bounded(cancellation(of: first)) == true)
    let second = Task {
        try await service.thumbnail(
            at: "/Volumes/share/b.jpg", entry: file("b.jpg"), side: 512, on: share,
            forPreview: true)
    }
    await bounded { service.calls.waitingCount(on: share) == 1 }
    #expect(maker.stopped.isEmpty)

    maker.release()

    await bounded { maker.stopped == ["/Volumes/share/a.jpg"] }
    await bounded { maker.entered == ["/Volumes/share/a.jpg", "/Volumes/share/b.jpg"] }
    second.cancel()
    #expect(await bounded(cancellation(of: second)) == true)
    maker.release()
    await bounded { maker.stopped == ["/Volumes/share/a.jpg", "/Volumes/share/b.jpg"] }
    await bounded { service.calls.isIdle }
}

/// A share's preview whose Quick Look call never returns is given up after `shareGiveUp`: the
/// caller gets none, and nothing is kept, so selecting it again asks again. The call keeps the
/// share's one slot, and isn't stopped, until it returns.
@Test func aShareCallThatNeverReturnsIsGivenUpAndHoldsItsSlotUntilItDoes() async throws {
    let maker = StuckThumbnailMaker()
    let clock = ManualClock()
    let service = ThumbnailService(maker: maker, clock: clock)
    let path = "/Volumes/share/a.cr3"
    let hung = Task {
        try await service.thumbnail(
            at: path, entry: file("a.cr3"), side: 512, on: share, forPreview: true)
    }
    await bounded { maker.entered == [path] }
    await bounded { clock.waitingSleeps == 1 }

    clock.advance(by: ThumbnailService.shareGiveUp)

    #expect(await bounded(nothing(from: hung)) == true)
    #expect(service.cached(at: path, entry: file("a.cr3"), side: 512) == nil)
    #expect(maker.stopped.isEmpty)
    let next = Task {
        try await service.thumbnail(
            at: "/Volumes/share/b.jpg", entry: file("b.jpg"), side: 512, on: share,
            forPreview: true)
    }
    await bounded { service.calls.waitingCount(on: share) == 1 }
    #expect(maker.entered == [path])

    maker.release()

    await bounded { maker.stopped == [path] }
    await bounded { maker.entered.count == 2 }
    next.cancel()
    #expect(await bounded(cancellation(of: next)) == true)
    maker.release()
    await bounded { service.calls.isIdle }
}

/// A local call that never returns is given up after `giveUp`: the caller gets none and the
/// file is kept as having none. The call keeps its slot, and isn't stopped, until it returns.
@Test func aLocalCallThatNeverReturnsIsGivenUpAndHoldsItsSlotUntilItDoes() async throws {
    let maker = StuckThumbnailMaker()
    let clock = ManualClock()
    let service = ThumbnailService(maker: maker, clock: clock)
    let hung = Task {
        try await service.thumbnail(at: "/p/a.jpg", entry: file("a.jpg"), side: 16, on: disk)
    }
    await bounded { maker.entered == ["/p/a.jpg"] }
    await bounded { clock.waitingSleeps == 1 }

    clock.advance(by: ThumbnailService.giveUp)

    #expect(await bounded(nothing(from: hung)) == true)
    #expect(service.cached(at: "/p/a.jpg", entry: file("a.jpg"), side: 16) == .some(nil))
    #expect(maker.stopped.isEmpty)
    #expect(!service.calls.isIdle)

    maker.release()

    await bounded { maker.stopped == ["/p/a.jpg"] }
    await bounded { service.calls.isIdle }
}

/// Whether `request` ends with no thumbnail, without throwing, as a task that can't hang, for
/// `bounded` to wait on.
private func nothing(from request: Task<CGImage?, any Error>) -> Task<Bool, Never> {
    Task {
        do {
            return try await request.value == nil
        } catch {
            return false
        }
    }
}

/// Whether `request` ends by throwing `CancellationError`, as a task that can't hang, for
/// `bounded` to wait on.
private func cancellation(of request: Task<CGImage?, any Error>) -> Task<Bool, Never> {
    Task {
        do {
            _ = try await request.value
            return false
        } catch {
            return error is CancellationError
        }
    }
}

/// Polls `condition` until it holds, fails the test after `patience`.
private func bounded(_ condition: @Sendable () -> Bool) async {
    let deadline = Date(timeIntervalSinceNow: patience)
    while !condition() {
        if Date() > deadline {
            Issue.record("timed out waiting")
            return
        }
        try? await Task.sleep(for: .milliseconds(2))
    }
}
