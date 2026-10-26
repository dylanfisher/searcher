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

@Test func onlyAFileWhoseContentsAreHereAndArentTextShowsAThumbnail() async {
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
    #expect(!ThumbnailService.shows(folder("a.jpg"), kind: await kind(.directory, "jpg")))
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
                path: "/p/a.jpg", side: 16, scale: 2, onMainThread: false,
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
                path: "/Volumes/share/a.jpg", side: 512, scale: 2, onMainThread: false,
                onBlockingCallThread: true)
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

/// Polls `condition` until it holds, failing the test after 5 seconds.
private func bounded(_ condition: @Sendable () -> Bool) async {
    let deadline = Date(timeIntervalSinceNow: 5)
    while !condition() {
        if Date() > deadline {
            Issue.record("timed out waiting")
            return
        }
        try? await Task.sleep(for: .milliseconds(2))
    }
}
