import Base
import Foundation
import TestSupport
import Testing

@testable import Browser

private let share = VolumeIdentity(
    device: "//dylan@nas.local/Music", mountPoint: "/private/tmp/fake-mount/Music", kind: .network)
private let otherShare = VolumeIdentity(
    device: "//dylan@nas.local/Photos", mountPoint: share.mountPoint, kind: .network)

/// Entries covering every field and file type, a non-ASCII name and a date with a fraction.
private let album = ListingCache.Folder(
    entries: [
        file("01 Intro.flac", size: 12_345_678),
        folder("Scans"),
        DirectoryEntry(
            name: "Café Ünïcode.m4a", type: .regular, size: 0,
            modified: Date(timeIntervalSinceReferenceDate: 700_000_000.123_456), isHidden: true,
            isDataless: true),
        DirectoryEntry(
            name: "link", type: .symbolicLink, size: nil, modified: testDate, isHidden: false,
            isDataless: false),
        DirectoryEntry(
            name: "fifo", type: .other, size: nil, modified: testDate, isHidden: false,
            isDataless: false),
    ],
    listedAt: Date(timeIntervalSinceReferenceDate: 780_000_000.5))

private let albumSize = FolderSizeCache.Record(
    size: FolderSize(
        bytes: 123_456_789, isPartial: true,
        walkedAt: Date(timeIntervalSinceReferenceDate: 780_000_001.25)),
    folderModified: Date(timeIntervalSinceReferenceDate: 779_000_000.5))

private func roots(_ folder: TemporaryFolder) -> StoreRoots {
    StoreRoots(
        caches: folder.url.appending(path: "Caches"),
        applicationSupport: folder.url.appending(path: "Application Support"))
}

private func store(
    _ folder: TemporaryFolder, log: EventLog<String> = EventLog(), byteCap: Int = 50_000_000,
    clock: ManualClock = ManualClock(),
    write: @escaping @Sendable (Data, URL) throws -> Void = { try AtomicWrite.write($0, to: $1) }
) -> ListingCacheStore {
    ListingCacheStore(
        roots: roots(folder), log: { log.append($0) }, byteCap: byteCap, clock: clock,
        write: write)
}

@Test func storeThenLoadReturnsEqualEntriesAndListedAtDate() async throws {
    let folder = try TemporaryFolder("ListingCacheStoreTests")
    let writer = store(folder)
    await writer.save(["/Music/Album": album], for: share)
    await writer.flush()

    let loaded = await store(folder).load(share)
    #expect(loaded == ["/Music/Album": album])
}

@Test func folderSizesAreKeptInTheVolumesFileBesideItsListings() async throws {
    let folder = try TemporaryFolder("ListingCacheStoreTests")
    let writer = store(folder)
    await writer.save(["/Music/Album": album], for: share)
    await writer.saveSizes(["/Music/Album": albumSize], for: share)
    await writer.flush()

    let reader = store(folder)
    #expect(await reader.load(share) == ["/Music/Album": album])
    #expect(await reader.loadSizes(share) == ["/Music/Album": albumSize])
    let files = try FileManager.default.contentsOfDirectory(
        atPath: roots(folder).caches.appending(path: "listings").path)
    #expect(files == [writer.url(for: share).lastPathComponent])
}

@Test func writingListingsKeepsSizesWrittenEarlierAndTheOtherWayRound() async throws {
    let folder = try TemporaryFolder("ListingCacheStoreTests")
    let sizesFirst = store(folder)
    await sizesFirst.saveSizes(["/Music/Album": albumSize], for: share)
    await sizesFirst.flush()
    let foldersNext = store(folder)
    await foldersNext.save(["/Music/Album": album], for: share)
    await foldersNext.flush()
    #expect(await store(folder).loadSizes(share) == ["/Music/Album": albumSize])

    let sizesLast = store(folder)
    await sizesLast.saveSizes([:], for: share)
    await sizesLast.flush()
    let reader = store(folder)
    #expect(await reader.load(share) == ["/Music/Album": album])
    #expect(await reader.loadSizes(share).isEmpty)
}

@Test func filesLiveInListingsUnderTheCachesRoot() async throws {
    let folder = try TemporaryFolder("ListingCacheStoreTests")
    let writer = store(folder)
    await writer.save(["/Music/Album": album], for: share)
    await writer.flush()

    let url = writer.url(for: share)
    #expect(
        url.deletingLastPathComponent().path
            == roots(folder).caches.appending(path: "listings").path)
    #expect(FileManager.default.fileExists(atPath: url.path))
}

enum StoreDamage: CaseIterable, Sendable {
    case missingField, extraField, randomBytes, versionField, sizeOnFolder, missingSizes,
        extraFieldInASize
}

@Test(arguments: StoreDamage.allCases)
func aFileThatDoesNotDecodeIsDeletedAndLoggedAndMisses(_ damage: StoreDamage) async throws {
    let folder = try TemporaryFolder("ListingCacheStoreTests")
    let writer = store(folder)
    await writer.save(["/Music/Album": album], for: share)
    await writer.saveSizes(["/Music/Album": albumSize], for: share)
    await writer.flush()
    let url = writer.url(for: share)

    let data = try Data(contentsOf: url)
    var plist =
        try PropertyListSerialization.propertyList(from: data, format: nil) as! [String: Any]
    var folders = plist["folders"] as! [String: Any]
    var stored = folders["/Music/Album"] as! [String: Any]
    var entries = stored["entries"] as! [[String: Any]]
    let damaged: Data
    switch damage {
    case .missingField:
        entries[0]["modified"] = nil
    case .extraField:
        entries[0]["comment"] = "not part of the shape"
    case .versionField:
        plist["version"] = 2
    case .sizeOnFolder:
        // `album`'s second entry is the folder "Scans".
        entries[1]["size"] = Int64(1)
    case .missingSizes:
        plist["sizes"] = nil
    case .extraFieldInASize:
        var sizes = plist["sizes"] as! [String: Any]
        var size = sizes["/Music/Album"] as! [String: Any]
        size["physicalBytes"] = Int64(1)
        sizes["/Music/Album"] = size
        plist["sizes"] = sizes
    case .randomBytes:
        break
    }
    stored["entries"] = entries
    folders["/Music/Album"] = stored
    plist["folders"] = folders
    if damage == .randomBytes {
        var generator = SystemRandomNumberGenerator()
        damaged = Data((0..<512).map { _ in UInt8.random(in: 0...255, using: &generator) })
    } else {
        damaged = try PropertyListSerialization.data(
            fromPropertyList: plist, format: .binary, options: 0)
    }
    try damaged.write(to: url)

    let log = EventLog<String>()
    let reader = store(folder, log: log)
    let loaded = await reader.load(share)
    #expect(loaded.isEmpty)
    #expect(await reader.loadSizes(share).isEmpty)
    #expect(!FileManager.default.fileExists(atPath: url.path))
    #expect(log.all.count == 1)
    #expect(log.all.first?.contains(url.path) == true)
}

@Test func aDifferentShareAtTheSameMountPointHasNoFile() async throws {
    let folder = try TemporaryFolder("ListingCacheStoreTests")
    let writer = store(folder)
    await writer.save(["/Music/Album": album], for: share)
    await writer.flush()

    #expect(await store(folder).load(otherShare).isEmpty)
    #expect(await store(folder).load(share).count == 1)
}

@Test func writesWaitForTheDelayAndRunOffTheMainThread() async throws {
    let folder = try TemporaryFolder("ListingCacheStoreTests")
    let clock = ManualClock()
    let writes = EventLog<Bool>()
    let writer = store(folder, clock: clock) { data, url in
        writes.append(Thread.isMainThread)
        try AtomicWrite.write(data, to: url)
    }
    await writer.save(["/Music/Album": album], for: share)
    await writer.save(["/Music/Album": album, "/Music/Other": album], for: share)

    #expect(await !writes.wait(timeout: 0.2) { !$0.isEmpty })
    clock.advance(by: ListingCacheStore.writeDelay)
    #expect(await writes.wait { !$0.isEmpty })
    // Both saves went out in one write.
    #expect(await !writes.wait(timeout: 0.2) { $0.count > 1 })
    #expect(writes.all == [false])
    #expect(await store(folder).load(share).count == 2)
}

@Test func writingOnTheMainThreadTraps() async {
    await #expect(processExitsWith: .failure) {
        await MainActor.run {
            ListingCacheStore.write(Data(), to: URL(fileURLWithPath: "/dev/null")) { _, _ in }
        }
    }
}

@Test func theOldestVolumeFileIsDroppedPastTheByteCap() async throws {
    let folder = try TemporaryFolder("ListingCacheStoreTests")
    let volumes = (0..<3).map {
        VolumeIdentity(device: "//nas/share\($0)", mountPoint: "/fake/share\($0)", kind: .network)
    }
    let probe = store(folder)
    await probe.save(["/a": album], for: volumes[0])
    await probe.flush()
    let fileSize =
        try FileManager.default.attributesOfItem(
            atPath: probe.url(for: volumes[0]).path)[.size] as! Int

    // Room for two files of this size, not three.
    let writer = store(folder, byteCap: fileSize * 2 + fileSize / 2)
    await writer.save(["/a": album], for: volumes[1])
    await writer.flush()
    // volumes[0]'s file is older than volumes[1]'s whatever the timestamp resolution.
    try FileManager.default.setAttributes(
        [.modificationDate: Date(timeIntervalSinceNow: -3600)],
        ofItemAtPath: writer.url(for: volumes[0]).path)
    await writer.save(["/a": album], for: volumes[2])
    await writer.flush()

    #expect(!FileManager.default.fileExists(atPath: writer.url(for: volumes[0]).path))
    #expect(FileManager.default.fileExists(atPath: writer.url(for: volumes[1]).path))
    #expect(FileManager.default.fileExists(atPath: writer.url(for: volumes[2]).path))
}

@Test func aLoadSeesASaveNotYetWritten() async throws {
    let folder = try TemporaryFolder("ListingCacheStoreTests")
    let writer = store(folder)
    await writer.save(["/Music/Album": album], for: share)
    #expect(await writer.load(share) == ["/Music/Album": album])
}

@Test func aFileHoldingAnotherVolumeIsDeletedAndLoggedAndMisses() async throws {
    let folder = try TemporaryFolder("ListingCacheStoreTests")
    let writer = store(folder)
    await writer.save(["/Music/Album": album], for: share)
    await writer.flush()
    let url = writer.url(for: otherShare)
    try FileManager.default.copyItem(at: writer.url(for: share), to: url)

    let log = EventLog<String>()
    #expect(await store(folder, log: log).load(otherShare).isEmpty)
    #expect(!FileManager.default.fileExists(atPath: url.path))
    #expect(log.all.count == 1)
    #expect(log.all.first?.contains(url.path) == true)
}

@Test func aVolumeOverTheByteCapIsNotWrittenAndIsLoggedOnce() async throws {
    let folder = try TemporaryFolder("ListingCacheStoreTests")
    let small = VolumeIdentity(device: "//nas/small", mountPoint: "/fake/small", kind: .network)
    let probe = store(folder)
    await probe.save([:], for: small)
    await probe.flush()
    let smallFile = probe.url(for: small)
    let smallSize =
        try FileManager.default.attributesOfItem(atPath: smallFile.path)[.size] as! Int

    let log = EventLog<String>()
    let writes = EventLog<URL>()
    // Room for the small volume's file and a few hundred bytes, less than `album` encodes to.
    let writer = store(folder, log: log, byteCap: smallSize + 300) { data, url in
        writes.append(url)
        try AtomicWrite.write(data, to: url)
    }
    for _ in 0..<2 {
        await writer.save(["/Music/Album": album], for: share)
        await writer.flush()
    }

    #expect(writes.all.isEmpty)
    #expect(!FileManager.default.fileExists(atPath: writer.url(for: share).path))
    #expect(FileManager.default.fileExists(atPath: smallFile.path))
    #expect(log.all.count == 1)
    #expect(log.all.first?.contains(share.device) == true)

    // Once it fits it's written, and going over again logs again.
    let empty = ListingCache.Folder(entries: [], listedAt: testDate)
    await writer.save(["/Music/Album": empty], for: share)
    await writer.flush()
    #expect(writes.all == [writer.url(for: share)])
    await writer.save(["/Music/Album": album], for: share)
    await writer.flush()
    #expect(log.all.count == 2)
}

@Test func aKeptVolumesFileOutlivesTheByteCap() async throws {
    let folder = try TemporaryFolder("ListingCacheStoreTests")
    let volumes = (0..<3).map {
        VolumeIdentity(device: "//nas/share\($0)", mountPoint: "/fake/share\($0)", kind: .network)
    }
    let probe = store(folder)
    await probe.save(["/a": album], for: volumes[0])
    await probe.flush()
    let fileSize =
        try FileManager.default.attributesOfItem(
            atPath: probe.url(for: volumes[0]).path)[.size] as! Int

    // Room for two files of this size, not three.
    let writer = store(folder, byteCap: fileSize * 2 + fileSize / 2)
    await writer.keep([volumes[0]])
    await writer.save(["/a": album], for: volumes[1])
    await writer.flush()
    try FileManager.default.setAttributes(
        [.modificationDate: Date(timeIntervalSinceNow: -3600)],
        ofItemAtPath: writer.url(for: volumes[0]).path)
    try FileManager.default.setAttributes(
        [.modificationDate: Date(timeIntervalSinceNow: -1800)],
        ofItemAtPath: writer.url(for: volumes[1]).path)
    await writer.save(["/a": album], for: volumes[2])
    await writer.flush()

    #expect(FileManager.default.fileExists(atPath: writer.url(for: volumes[0]).path))
    #expect(!FileManager.default.fileExists(atPath: writer.url(for: volumes[1]).path))
    #expect(FileManager.default.fileExists(atPath: writer.url(for: volumes[2]).path))
}

@Test func aPathIsPlacedOnTheVolumeWithTheLongestMountPointHoldingIt() async throws {
    let folder = try TemporaryFolder("ListingCacheStoreTests")
    let outer = VolumeIdentity(device: "//nas/all", mountPoint: "/fake/x", kind: .network)
    let older = VolumeIdentity(device: "//nas/old", mountPoint: "/fake/x/Music", kind: .network)
    let newer = VolumeIdentity(device: "//nas/new", mountPoint: "/fake/x/Music", kind: .network)
    let writer = store(folder)
    for volume in [outer, older, newer] {
        await writer.save(["\(volume.mountPoint)/Album": album], for: volume)
    }
    await writer.flush()
    try FileManager.default.setAttributes(
        [.modificationDate: Date(timeIntervalSinceNow: -3600)],
        ofItemAtPath: writer.url(for: older).path)

    let reader = store(folder)
    let found = await reader.volume(holding: "/fake/x/Music/Album/Disc 1")
    #expect(found?.volume == newer)
    #expect(found?.folders == ["/fake/x/Music/Album": album])
    #expect(await reader.volume(holding: "/fake/x/Photos")?.volume == outer)
    #expect(await reader.volume(holding: "/fake/y") == nil)
}

@Test func aFileNotNamedForAVolumeIsDeletedAtTheNextWrite() async throws {
    let folder = try TemporaryFolder("ListingCacheStoreTests")
    let writer = store(folder)
    await writer.save(["/Music/Album": album], for: share)
    await writer.flush()
    let stray = writer.url(for: share).deletingLastPathComponent()
        .appending(path: String(repeating: "0", count: 64) + ".plist")
    try FileManager.default.copyItem(at: writer.url(for: share), to: stray)

    let log = EventLog<String>()
    let next = store(folder, log: log)
    await next.save(["/Music/Album": album], for: share)
    await next.flush()

    #expect(!FileManager.default.fileExists(atPath: stray.path))
    #expect(FileManager.default.fileExists(atPath: writer.url(for: share).path))
    #expect(log.all.count == 1)
    #expect(log.all.first?.contains(stray.path) == true)
}
