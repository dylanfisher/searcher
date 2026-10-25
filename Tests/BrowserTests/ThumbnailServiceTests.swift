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

@Test func aThumbnailIsMadeOnABlockingCallThreadAndKeptForThatVersionOfTheFile() async throws {
    let maker = GatedThumbnailMaker()
    let service = ThumbnailService(maker: maker, mountedVolumes: { [] })
    let entry = file("a.jpg")
    let image = testThumbnail()
    #expect(service.cached(at: "/p/a.jpg", entry: entry, side: 16) == nil)

    let request = Task { try await service.thumbnail(at: "/p/a.jpg", entry: entry, side: 16) }
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
    #expect(try await service.thumbnail(at: "/p/a.jpg", entry: entry, side: 16) === image)
    #expect(maker.calls.count == 1)

    // Saved again: a new version, so the old thumbnail isn't shown for it.
    let saved = DirectoryEntry(
        name: "a.jpg", type: .regular, size: 1, modified: testDate.addingTimeInterval(1),
        isHidden: false, isDataless: false)
    #expect(service.cached(at: "/p/a.jpg", entry: saved, side: 16) == nil)
    #expect(service.cached(at: "/p/a.jpg", entry: file("a.jpg", size: 2), side: 16) == nil)
    // Another size is another thumbnail.
    #expect(service.cached(at: "/p/a.jpg", entry: entry, side: 128) == nil)
    _ = try await service.thumbnail(at: "/p/a.jpg", entry: saved, side: 16)
    #expect(maker.calls.count == 2)
    #expect(service.calls.isIdle)
}

@Test func aFileWithNoThumbnailIsKeptAsHavingNone() async throws {
    let maker = GatedThumbnailMaker()
    maker.answer("/p/a.bin", with: nil)
    let service = ThumbnailService(maker: maker, mountedVolumes: { [] })

    #expect(try await service.thumbnail(at: "/p/a.bin", entry: file("a.bin"), side: 16) == nil)
    #expect(try await service.thumbnail(at: "/p/a.bin", entry: file("a.bin"), side: 16) == nil)

    #expect(maker.calls.count == 1)
    #expect(service.cached(at: "/p/a.bin", entry: file("a.bin"), side: 16) == .some(nil))
}

@Test func aFileOnANetworkVolumeIsNeverAskedFor() async throws {
    let maker = GatedThumbnailMaker()
    let share = VolumeIdentity(device: "//nas/share", mountPoint: "/Volumes/share", kind: .network)
    let local = VolumeIdentity(device: "/dev/disk3s1", mountPoint: "/", kind: .local)
    // Answered, so a request that reached the maker would show rather than wait.
    maker.answer("/Volumes/share/a.jpg", with: testThumbnail())
    let service = ThumbnailService(maker: maker, mountedVolumes: { [local, share] })

    let thumbnail = try await service.thumbnail(
        at: "/Volumes/share/a.jpg", entry: file("a.jpg"), side: 16)

    #expect(thumbnail == nil)
    #expect(maker.calls.isEmpty)
    #expect(service.calls.isIdle)
}

/// A volume makes at most four at once; a request cancelled while it waits for a slot, as for a
/// row scrolled off screen, is never made.
@Test func aVolumeMakesFourAtOnceAndACancelledWaitingRequestIsNeverMade() async throws {
    let maker = GatedThumbnailMaker()
    let service = ThumbnailService(maker: maker, mountedVolumes: { [] })
    let paths = (0..<6).map { "/p/\($0).jpg" }
    let requests = paths.map { path in
        Task { try await service.thumbnail(at: path, entry: file("x.jpg"), side: 16) }
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
