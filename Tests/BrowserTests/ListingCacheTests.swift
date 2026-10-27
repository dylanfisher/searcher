import Base
import BrowserTestSupport
import Foundation
import TestSupport
import Testing

@testable import Browser

private func share(_ name: String) -> VolumeIdentity {
    VolumeIdentity(device: "//nas/\(name)", mountPoint: "/fake/\(name)", kind: .network)
}

private let listing = ListingCache.Folder(
    entries: [file("a"), folder("b")], listedAt: Date(timeIntervalSinceReferenceDate: 1_000))

private func store(
    _ folder: TemporaryFolder, log: EventLog<String> = EventLog(),
    byteCap: Int = ListingCacheStore.defaultByteCap
) -> ListingCacheStore {
    ListingCacheStore(
        roots: roots(folder),
        log: { log.append($0) }, byteCap: byteCap, clock: ManualClock())
}

@Test func anInsertDuringASlowReadWinsOverTheFile() async {
    let path = "/fake/a/x"
    let older = ListingCache.Folder(entries: [file("old")], listedAt: testDate)
    let reads = EventLog<Int>()
    let release = AsyncStream<Void>.makeStream()
    // The first read waits for the test; any later one finds no file.
    let cache = ListingCache(
        load: { _ in
            let call = reads.all.count
            reads.append(call)
            guard call == 0 else { return [:] }
            for await _ in release.stream {}
            return [path: older]
        }, save: { _, _ in }, flush: {})

    let lookup = Task { await cache.folder(at: path, on: share("a")) }
    #expect(await reads.wait { $0.count == 1 })
    await cache.insert(listing, at: path, on: share("a"))
    release.continuation.finish()

    #expect(await lookup.value == listing)
    #expect(await cache.folder(at: path, on: share("a")) == listing)
}

@Test func aFolderInsertedOnANetworkVolumeHits() async {
    let cache = ListingCache(store: nil)
    await cache.insert(listing, at: "/fake/a/x", on: share("a"))
    #expect(await cache.folder(at: "/fake/a/x", on: share("a")) == listing)
    #expect(await cache.folder(at: "/fake/a/y", on: share("a")) == nil)
}

@Test func localVolumesAreNeverStored() async throws {
    let temporary = try TemporaryFolder("ListingCacheTests")
    let local = VolumeIdentity(device: "/dev/disk9s1", mountPoint: "/", kind: .local)
    let cache = ListingCache(store: store(temporary))
    await cache.insert(listing, at: "/Users", on: local)
    await cache.flush()

    #expect(await cache.folder(at: "/Users", on: local) == nil)
    let listings = temporary.url.appending(path: "Caches/listings")
    let files = (try? FileManager.default.contentsOfDirectory(atPath: listings.path)) ?? []
    #expect(files.isEmpty)
}

@Test func aDifferentShareAtTheSameMountPointMisses() async throws {
    let temporary = try TemporaryFolder("ListingCacheTests")
    let music = VolumeIdentity(device: "//nas/Music", mountPoint: "/fake/share", kind: .network)
    let photos = VolumeIdentity(device: "//nas/Photos", mountPoint: "/fake/share", kind: .network)
    let cache = ListingCache(store: store(temporary))
    await cache.insert(listing, at: "/fake/share/x", on: music)
    await cache.flush()

    #expect(await cache.folder(at: "/fake/share/x", on: photos) == nil)
    #expect(
        await ListingCache(store: store(temporary)).folder(at: "/fake/share/x", on: photos) == nil)
}

@Test func theLeastRecentlyUsedVolumeIsEvictedPastTheCap() async {
    let cache = ListingCache(volumeCap: 2, store: nil)
    await cache.insert(listing, at: "/fake/a/x", on: share("a"))
    await cache.insert(listing, at: "/fake/b/x", on: share("b"))
    // Using a makes b the least recently used.
    #expect(await cache.folder(at: "/fake/a/x", on: share("a")) != nil)
    await cache.insert(listing, at: "/fake/c/x", on: share("c"))

    #expect(await cache.folder(at: "/fake/a/x", on: share("a")) != nil)
    #expect(await cache.folder(at: "/fake/b/x", on: share("b")) == nil)
    #expect(await cache.folder(at: "/fake/c/x", on: share("c")) != nil)
}

/// A folder of `count` files, listed `at` seconds after the reference date.
private func folder(of count: Int, at seconds: Double) -> ListingCache.Folder {
    ListingCache.Folder(
        entries: (0..<count).map { file("f\($0)") },
        listedAt: Date(timeIntervalSinceReferenceDate: seconds))
}

@Test func pastTheEntryCapTheLeastRecentlyUsedVolumeGoesFirst() async {
    let cache = ListingCache(entryCap: 4, store: nil)
    await cache.insert(folder(of: 2, at: 1), at: "/fake/a/x", on: share("a"))
    await cache.insert(folder(of: 2, at: 2), at: "/fake/b/x", on: share("b"))
    // Using a makes b the least recently used.
    #expect(await cache.folder(at: "/fake/a/x", on: share("a")) != nil)
    await cache.insert(folder(of: 2, at: 3), at: "/fake/c/x", on: share("c"))

    #expect(await cache.folder(at: "/fake/a/x", on: share("a")) != nil)
    #expect(await cache.folder(at: "/fake/b/x", on: share("b")) == nil)
    #expect(await cache.folder(at: "/fake/c/x", on: share("c")) != nil)
}

@Test func aVolumePastTheEntryCapDropsItsLeastRecentlyListedFolders() async {
    let saves = EventLog<Set<String>>()
    let cache = ListingCache(
        entryCap: 4, load: nil, save: { folders, _ in saves.append(Set(folders.keys)) },
        flush: {})
    await cache.insert(folder(of: 2, at: 2), at: "/fake/a/y", on: share("a"))
    await cache.insert(folder(of: 2, at: 1), at: "/fake/a/x", on: share("a"))
    await cache.insert(folder(of: 2, at: 3), at: "/fake/a/z", on: share("a"))

    #expect(await cache.folder(at: "/fake/a/x", on: share("a")) == nil)
    #expect(await cache.folder(at: "/fake/a/y", on: share("a")) != nil)
    #expect(await cache.folder(at: "/fake/a/z", on: share("a")) != nil)
    // The volume's file keeps what memory keeps.
    #expect(saves.all.last == ["/fake/a/y", "/fake/a/z"])
}

@Test func aFolderLargerThanTheEntryCapIsKeptAlone() async {
    let cache = ListingCache(entryCap: 4, store: nil)
    await cache.insert(folder(of: 2, at: 1), at: "/fake/a/x", on: share("a"))
    await cache.insert(folder(of: 6, at: 2), at: "/fake/a/big", on: share("a"))

    #expect(await cache.folder(at: "/fake/a/x", on: share("a")) == nil)
    #expect(await cache.folder(at: "/fake/a/big", on: share("a"))?.entries.count == 6)
}

@Test func aVolumeEvictedFromMemoryIsReadBackFromItsFile() async throws {
    let temporary = try TemporaryFolder("ListingCacheTests")
    let cache = ListingCache(volumeCap: 1, store: store(temporary))
    await cache.insert(listing, at: "/fake/a/x", on: share("a"))
    await cache.insert(listing, at: "/fake/b/x", on: share("b"))
    #expect(await cache.folder(at: "/fake/a/x", on: share("a")) == listing)
}

@Test func listingsOutliveTheCache() async throws {
    let temporary = try TemporaryFolder("ListingCacheTests")
    let first = ListingCache(store: store(temporary))
    await first.insert(listing, at: "/fake/a/x", on: share("a"))
    await first.flush()

    // A folder added after a relaunch keeps the ones already in the volume's file.
    let second = ListingCache(store: store(temporary))
    await second.insert(listing, at: "/fake/a/y", on: share("a"))
    await second.flush()

    let third = ListingCache(store: store(temporary))
    #expect(await third.folder(at: "/fake/a/x", on: share("a")) == listing)
    #expect(await third.folder(at: "/fake/a/y", on: share("a")) == listing)
}

@Test func aFlushThatNeverFinishesReturnsAtItsDeadline() async {
    let never = AsyncStream<Void>.makeStream()
    defer { never.continuation.finish() }
    let cache = ListingCache(
        load: nil, save: { _, _ in }, flush: { for await _ in never.stream {} })
    let clock = ManualClock()
    let deadline = clock.now.advanced(by: .seconds(2))

    let flushed = Task { await cache.flush(by: deadline, clock: clock) }
    clock.advance(by: .seconds(2))

    #expect(await flushed.value == false)
}

@Test func aFlushThatFinishesInTimeSaysSo() async {
    let cache = ListingCache(load: nil, save: { _, _ in }, flush: {})
    let clock = ManualClock()

    #expect(await cache.flush(by: clock.now.advanced(by: .seconds(2)), clock: clock))
}

@Test func aFlushWritesAnInsertStartedJustBeforeIt() async throws {
    let temporary = try TemporaryFolder("ListingCacheTests")
    let cache = ListingCache(store: store(temporary))

    cache.startInsert(listing, at: "/fake/a/x", on: share("a"))
    #expect(
        await cache.flush(by: ContinuousClock.now.advanced(by: .seconds(5)), clock: .continuous))

    let reread = ListingCache(store: store(temporary))
    #expect(await reread.folder(at: "/fake/a/x", on: share("a")) == listing)
}

@Test func aSavedWorkspacesFoldersOutliveTheEntryCap() async {
    let cache = ListingCache(entryCap: 4, store: nil)
    await cache.restore(folders: ["/fake/a/kept"], mountedVolumes: { [] })
    await cache.insert(folder(of: 2, at: 1), at: "/fake/a/kept", on: share("a"))
    await cache.insert(folder(of: 2, at: 2), at: "/fake/a/y", on: share("a"))
    await cache.insert(folder(of: 2, at: 3), at: "/fake/a/z", on: share("a"))
    // Past the cap again, with a, which holds the kept folder, the least recently used volume.
    await cache.insert(folder(of: 2, at: 4), at: "/fake/b/x", on: share("b"))

    #expect(await cache.folder(at: "/fake/b/x", on: share("b")) != nil)
    #expect(await cache.folder(at: "/fake/a/kept", on: share("a")) != nil)
    // The least recently listed folder that isn't kept went instead.
    #expect(await cache.folder(at: "/fake/a/y", on: share("a")) == nil)
    #expect(await cache.folder(at: "/fake/a/z", on: share("a")) != nil)
}

@Test func aRestoreReadsTheMountedVolumesHoldingTheFoldersOffTheMainThread() async throws {
    let temporary = try TemporaryFolder("ListingCacheTests")
    let writer = ListingCache(store: store(temporary))
    await writer.insert(listing, at: "/fake/a/x", on: share("a"))
    await writer.flush()
    let reads = EventLog<Bool>()

    let cache = ListingCache(store: store(temporary))
    await cache.restore(folders: ["/fake/a/x", "/Users/dylan"]) {
        reads.append(Thread.isMainThread)
        return [share("a")]
    }
    try FileManager.default.removeItem(
        at: temporary.url.appending(path: "Caches/listings"))

    #expect(reads.all == [false])
    #expect(await cache.folder(at: "/fake/a/x", on: share("a")) == listing)
}

@Test func aRestoredPanesVolumeFileOutlivesTheByteCap() async throws {
    let temporary = try TemporaryFolder("ListingCacheTests")
    let writer = store(temporary)
    await writer.save(["/fake/a/x": listing], for: share("a"))
    await writer.flush()
    let file = writer.url(for: share("a"))
    try FileManager.default.setAttributes(
        [.modificationDate: Date(timeIntervalSinceNow: -3600)], ofItemAtPath: file.path)
    let size = try FileManager.default.attributesOfItem(atPath: file.path)[.size] as! Int

    // Room for one volume's file, not two.
    let cache = ListingCache(store: store(temporary, byteCap: size + size / 2))
    await cache.restore(folders: ["/fake/a/x"], mountedVolumes: { [share("a")] })
    await cache.insert(listing, at: "/fake/b/x", on: share("b"))
    await cache.flush()

    #expect(FileManager.default.fileExists(atPath: file.path))
    #expect(!FileManager.default.fileExists(atPath: writer.url(for: share("b")).path))
}

@Test func aRestoreKeepsTheFolderOfEveryPaneInTheStoredWorkspaces() async {
    let cache = ListingCache(entryCap: 2, store: nil)
    let layout = Layout()
    let pane = TabState.PaneState(
        location: Location(path: "/fake/a/kept"), viewMode: .list, history: History(),
        selection: [], cursor: nil, sortColumn: .name, sortAscending: true,
        columnWidths: ColumnWidths())
    let saved = WorkspaceState(
        id: UUID(), name: "Albums", frame: Rect(x: 0, y: 0, width: 800, height: 600),
        tabs: [TabState(layout: layout, panes: [layout.focused: pane])], selectedTab: 0,
        showsSidebar: false)

    await cache.restore(
        WorkspaceStore.Contents(session: nil, workspaces: [saved.id: saved], snapshots: [:]),
        mountedVolumes: { [] })
    await cache.insert(folder(of: 2, at: 1), at: "/fake/a/kept", on: share("a"))
    await cache.insert(folder(of: 2, at: 2), at: "/fake/a/other", on: share("a"))

    #expect(await cache.folder(at: "/fake/a/kept", on: share("a")) != nil)
}

/// A server's listing isn't cached, so a pane at one keeps no folder; a restored session with
/// one keeps the other panes' folders.
@Test func aPaneAtAServerKeepsNoFolder() throws {
    let layout = Layout()
    let server = try #require(Server(host: "HAL9000._smb._tcp.local"))
    let state = { (location: Location) in
        TabState.PaneState(
            location: location, viewMode: .list, history: History(), selection: [], cursor: nil,
            sortColumn: .name, sortAscending: true, columnWidths: ColumnWidths())
    }
    let tab = { (location: Location) in
        TabState(layout: layout, panes: [layout.focused: state(location)])
    }
    let saved = WorkspaceState(
        id: UUID(), name: nil, frame: Rect(x: 0, y: 0, width: 800, height: 600),
        tabs: [tab(.server(server)), tab(Location(path: "/fake/a/kept"))], selectedTab: 0,
        showsSidebar: false)

    #expect(ListingCache.folders(of: [saved]) == ["/fake/a/kept"])
}

@Test func keepingNewFoldersReplacesTheOnesTheCapsLeave() async {
    let cache = ListingCache(entryCap: 4, store: nil)
    await cache.restore(folders: ["/fake/a/old"], mountedVolumes: { [] })
    await cache.keep(folders: ["/fake/a/new"])
    await cache.insert(folder(of: 2, at: 1), at: "/fake/a/old", on: share("a"))
    await cache.insert(folder(of: 2, at: 2), at: "/fake/a/new", on: share("a"))
    await cache.insert(folder(of: 2, at: 3), at: "/fake/a/y", on: share("a"))

    #expect(await cache.folder(at: "/fake/a/new", on: share("a")) != nil)
    // The oldest listing, no longer kept, went to make room.
    #expect(await cache.folder(at: "/fake/a/old", on: share("a")) == nil)
}

@Test func keepingFoldersMovesTheByteCapsProtectionToTheirVolumeFiles() async throws {
    let temporary = try TemporaryFolder("ListingCacheTests")
    let writer = store(temporary)
    await writer.save(["/fake/a/x": listing], for: share("a"))
    await writer.save(["/fake/b/x": listing], for: share("b"))
    await writer.flush()
    let fileA = writer.url(for: share("a"))
    let fileB = writer.url(for: share("b"))
    for (file, age) in [(fileA, -7200.0), (fileB, -3600.0)] {
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSinceNow: age)], ofItemAtPath: file.path)
    }
    let size = try FileManager.default.attributesOfItem(atPath: fileA.path)[.size] as! Int

    // Room for two files, not three.
    let cache = ListingCache(store: store(temporary, byteCap: size * 2 + size / 2))
    await cache.restore(folders: ["/fake/a/x"], mountedVolumes: { [share("a"), share("b")] })
    await cache.keep(folders: ["/fake/b/x"])
    await cache.insert(listing, at: "/fake/c/x", on: share("c"))
    await cache.flush()

    // a is the oldest file and no longer kept, so it goes for c; b stays.
    #expect(!FileManager.default.fileExists(atPath: fileA.path))
    #expect(FileManager.default.fileExists(atPath: fileB.path))
}

@Test func keepingFoldersStillKeepsTheVolumeOfAFolderRestoredFromTheStore() async throws {
    let temporary = try TemporaryFolder("ListingCacheTests")
    let writer = store(temporary)
    await writer.save(["/fake/a/x": listing], for: share("a"))
    await writer.flush()
    let file = writer.url(for: share("a"))
    try FileManager.default.setAttributes(
        [.modificationDate: Date(timeIntervalSinceNow: -3600)], ofItemAtPath: file.path)
    let size = try FileManager.default.attributesOfItem(atPath: file.path)[.size] as! Int

    let cache = ListingCache(store: store(temporary, byteCap: size + size / 2))
    // The share isn't mounted, so its file is found in the store.
    await cache.restore(folders: ["/fake/a/x"], mountedVolumes: { [] })
    await cache.keep(folders: ["/fake/a/x", "/fake/z"], mountedVolumes: { [] })
    await cache.insert(listing, at: "/fake/b/x", on: share("b"))
    await cache.flush()

    #expect(FileManager.default.fileExists(atPath: file.path))
}

@Test func keepingAColdFolderOfAMountedShareKeepsTheSharesFile() async throws {
    let temporary = try TemporaryFolder("ListingCacheTests")
    let writer = store(temporary)
    await writer.save(["/fake/a/x": listing], for: share("a"))
    await writer.flush()
    let file = writer.url(for: share("a"))
    try FileManager.default.setAttributes(
        [.modificationDate: Date(timeIntervalSinceNow: -3600)], ofItemAtPath: file.path)
    let size = try FileManager.default.attributesOfItem(atPath: file.path)[.size] as! Int

    let cache = ListingCache(store: store(temporary, byteCap: size + size / 2))
    // No listing of the folder yet, so no key for it in the share's folders.
    await cache.keep(folders: ["/fake/a/new"], mountedVolumes: { [share("a")] })
    await cache.insert(listing, at: "/fake/b/x", on: share("b"))
    await cache.flush()

    #expect(FileManager.default.fileExists(atPath: file.path))
}

@Test func keepingAFolderOfAVolumeLeftMemoryKeepsItsFile() async throws {
    let temporary = try TemporaryFolder("ListingCacheTests")
    let first = ListingCache(volumeCap: 1, store: store(temporary))
    await first.insert(listing, at: "/fake/a/x", on: share("a"))
    await first.flush()
    let file = store(temporary).url(for: share("a"))
    try FileManager.default.setAttributes(
        [.modificationDate: Date(timeIntervalSinceNow: -3600)], ofItemAtPath: file.path)
    let size = try FileManager.default.attributesOfItem(atPath: file.path)[.size] as! Int

    // A new cache starts with a out of memory, as one the volume cap dropped is.
    let cache = ListingCache(volumeCap: 1, store: store(temporary, byteCap: size + size / 2))
    await cache.keep(folders: ["/fake/a/x"], mountedVolumes: { [share("a")] })
    await cache.insert(listing, at: "/fake/b/x", on: share("b"))
    await cache.flush()

    #expect(FileManager.default.fileExists(atPath: file.path))
}

@Test func savesKeepingAColdFolderReadItsVolumeFileOnceThroughVolumePressure() async {
    let loads = EventLog<String>()
    let cache = ListingCache(
        volumeCap: 1,
        load: { volume in
            loads.append(volume.device)
            return [:]
        }, save: { _, _ in }, flush: {}, findVolume: { _ in nil })
    let mounted: @Sendable () -> [VolumeIdentity] = { [share("x"), share("y")] }
    for second in 1...3 {
        await cache.keep(folders: ["/fake/x/cold"], mountedVolumes: mounted)
        await cache.insert(folder(of: 1, at: Double(second)), at: "/fake/y/z", on: share("y"))
    }

    #expect(loads.all.filter { $0 == "//nas/x" }.count == 1)
}

@Test func aSaveAfterAnEjectDoesNotMakeTheSharePlacedAsRestored() async throws {
    let temporary = try TemporaryFolder("ListingCacheTests")
    let writer = store(temporary)
    await writer.save(["/fake/a/x": listing], for: share("a"))
    await writer.flush()

    let cache = ListingCache(store: store(temporary))
    await cache.keep(folders: ["/fake/a/x"], mountedVolumes: { [] })

    #expect(cache.restoredVolume(holding: "/fake/a/x") == nil)
}

@Test func keepingFoldersHoldsTheOldAndTheNewVolumeBeforeTheNewFileIsRead() async {
    let events = EventLog<String>()
    let cache = ListingCache(
        load: { volume in
            events.append("load \(volume.device)")
            return [:]
        }, save: { _, _ in }, flush: {},
        findVolume: { _ in nil },
        keepFiles: { volumes in events.append("hold \(volumes.map(\.device).sorted())") })
    let mounted: @Sendable () -> [VolumeIdentity] = { [share("a"), share("b")] }
    await cache.keep(folders: ["/fake/a/x"], mountedVolumes: mounted)
    let before = events.all.count
    await cache.keep(folders: ["/fake/b/x"], mountedVolumes: mounted)

    // a stays held until b is, and b is held before its file is read.
    #expect(
        Array(events.all.dropFirst(before)) == [
            "hold [\"//nas/a\", \"//nas/b\"]", "load //nas/b", "hold [\"//nas/b\"]",
        ])
}
